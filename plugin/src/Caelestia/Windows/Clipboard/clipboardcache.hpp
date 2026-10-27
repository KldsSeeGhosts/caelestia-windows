#pragma once

#include <functional>

#include <qdir.h>
#include <qfileinfo.h>
#include <qglobal.h>
#include <qregularexpression.h>
#include <qstring.h>

namespace caelestia::shell::windows {

// Owns exactly one per-instance cache directory:
//
//   <cacheRoot>/clipboard/<pid>-<16 hex random>
//
// Previews and explicitly opened text files live directly in that directory.
// Nothing is created before a valid, absolute, non-empty cacheRoot is known.
// Cleanup accepts only the exact instance directory below
// <cacheRoot>/clipboard/<instance> after canonical-path validation, so an
// empty, relative or replaced path can never turn into a directory-wide delete.
//
// The policy is WinRT-free so clipboard-logic-tests can exercise the delete
// boundary without reading or modifying the real clipboard history.
class ClipboardCacheDirectory {
public:
    static constexpr int TOKEN_HEX_DIGITS = 16;

    [[nodiscard]] static bool validRoot(const QString& root) {
        if (root.isEmpty() || !QDir::isAbsolutePath(root))
            return false;
        const auto normalized = QDir::cleanPath(root);
        return QDir::isAbsolutePath(normalized) && normalized != QStringLiteral("/");
    }

    [[nodiscard]] static QString normalizedRoot(const QString& root) {
        return validRoot(root) ? QDir::cleanPath(root) : QString();
    }

    [[nodiscard]] static QString makeInstanceName(quint32 pid, quint64 token) {
        return QStringLiteral("%1-%2").arg(pid).arg(token, TOKEN_HEX_DIGITS, 16, QLatin1Char('0'));
    }

    [[nodiscard]] static bool validInstanceName(const QString& name) {
        static const QRegularExpression pattern(
            QStringLiteral("^[1-9][0-9]{0,9}-[0-9a-f]{16}$"));
        return pattern.match(name).hasMatch();
    }

    // A root may only be configured once per instance: silently switching it
    // would orphan the directory that this instance still owns.
    bool configure(const QString& root, quint32 pid, quint64 token) {
        if (m_configured)
            return normalizedRoot(root) == m_root;
        const auto normalized = normalizedRoot(root);
        if (normalized.isEmpty())
            return false;
        m_root = normalized;
        m_name = makeInstanceName(pid, token);
        if (!validInstanceName(m_name)) {
            m_root.clear();
            m_name.clear();
            return false;
        }
        m_path = m_root + QStringLiteral("/clipboard/") + m_name;
        m_configured = true;
        return true;
    }

    [[nodiscard]] bool configured() const { return m_configured; }
    [[nodiscard]] QString root() const { return m_root; }
    [[nodiscard]] QString name() const { return m_name; }
    [[nodiscard]] QString path() const { return m_path; }

    [[nodiscard]] QString filePath(const QString& name) const {
        if (!m_configured || name.isEmpty())
            return {};
        return m_path + QLatin1Char('/') + name;
    }

    [[nodiscard]] bool ensure(QString* error = nullptr) const {
        if (!m_configured) {
            if (error != nullptr)
                *error = QStringLiteral("No clipboard cache root is configured.");
            return false;
        }
        const auto base = m_root + QStringLiteral("/clipboard");
        if (!QDir().mkpath(base) || !QDir().mkpath(m_path)) {
            if (error != nullptr)
                *error = QStringLiteral("The clipboard cache directory could not be created.");
            return false;
        }
        return true;
    }

    // Deletes this instance's directory only. A no-op when nothing was ever
    // configured (for example shutdown before the queued cache setter ran).
    bool remove() {
        if (!m_configured)
            return true;
        return removeValidated(m_root, m_path);
    }

    // Startup cleanup: removes only sibling directories whose name matches the
    // instance pattern and whose pid is not a running process. This process and
    // any other live instance are never touched.
    static int removeDeadSiblings(const QString& root, const QString& ownName,
        const std::function<bool(quint32)>& processAlive) {
        if (!validRoot(root) || !validInstanceName(ownName))
            return 0;

        const auto normalized = normalizedRoot(root);
        const QDir base(normalized + QStringLiteral("/clipboard"));
        if (!base.exists())
            return 0;

        int removed = 0;
        const auto entries = base.entryInfoList(QDir::Dirs | QDir::NoDotAndDotDot);
        for (const auto& entry: entries) {
            const auto name = entry.fileName();
            if (name == ownName || !validInstanceName(name))
                continue;

            bool ok = false;
            const auto pid = name.section(QLatin1Char('-'), 0, 0).toUInt(&ok);
            if (!ok || pid == 0 || processAlive(pid))
                continue;
            if (removeValidated(normalized, entry.absoluteFilePath()))
                ++removed;
        }
        return removed;
    }

private:
    [[nodiscard]] static Qt::CaseSensitivity pathCase() {
#ifdef Q_OS_WIN
        return Qt::CaseInsensitive;
#else
        return Qt::CaseSensitive;
#endif
    }

    // True only for a direct child. This rejects the parent itself, deeper
    // paths and anything reached through a symlink outside the cache base.
    [[nodiscard]] static bool directChild(const QString& parent, const QString& child) {
        if (parent.isEmpty() || child.isEmpty())
            return false;
        const auto cleanParent = QDir::cleanPath(parent);
        const auto cleanChild = QDir::cleanPath(child);
        if (cleanParent.isEmpty() || cleanChild.isEmpty()
            || cleanParent.compare(cleanChild, pathCase()) == 0) {
            return false;
        }
        const auto prefix = cleanParent + QLatin1Char('/');
        if (!cleanChild.startsWith(prefix, pathCase()))
            return false;
        const auto remainder = cleanChild.mid(prefix.size());
        return !remainder.isEmpty() && !remainder.contains(QLatin1Char('/'));
    }

    [[nodiscard]] static bool removeValidated(const QString& root, const QString& path) {
        if (!validRoot(root) || path.isEmpty() || !QDir::isAbsolutePath(path))
            return false;

        const QFileInfo target(path);
        // The instance directory itself must never be a symlink: resolving it
        // would let a replaced path delete an unrelated directory.
        if (target.isSymLink())
            return false;

        const auto base = QFileInfo(QDir::cleanPath(root) + QStringLiteral("/clipboard"));
        const auto canonicalBase = base.canonicalFilePath();
        if (canonicalBase.isEmpty())
            return false;

        const auto canonicalTarget = target.canonicalFilePath();
        if (canonicalTarget.isEmpty())
            return true; // Already gone: nothing to delete.

        const auto name = QFileInfo(canonicalTarget).fileName();
        if (!validInstanceName(name) || name != target.fileName())
            return false;
        if (!directChild(canonicalBase, canonicalTarget))
            return false;

        return QDir(canonicalTarget).removeRecursively();
    }

    bool m_configured = false;
    QString m_root;
    QString m_name;
    QString m_path;
};

} // namespace caelestia::shell::windows
