#pragma once

#include <qbytearray.h>
#include <qdir.h>
#include <qfile.h>
#include <qfileinfo.h>
#include <qglobal.h>
#include <qrandom.h>
#include <qregularexpression.h>
#include <qstring.h>
#include <qt_windows.h>

#include <functional>
#include <string>

namespace caelestia::shell::windows {

// Owns exactly one per-instance cache directory:
//
//   <cacheRoot>/clipboard/<pid>-<16 hex random>
//
// Previews and explicitly opened text files live directly in that directory.
// Nothing is created before a valid, fully qualified local cacheRoot is known.
//
// The directory is flat by design and cleanup never recurses. It enumerates
// only the direct files of the instance directory, deletes only regular files
// without FILE_ATTRIBUTE_REPARSE_POINT, skips every other entry, and then calls
// RemoveDirectoryW, which only removes an empty directory (and removes a
// junction link, not its target). QFileInfo::isSymLink() does not report NTFS
// junctions, so the reparse-point attribute is the authoritative check.
//
// Every create, write and delete first verifies that the instance directory,
// the clipboard parent and the cache root itself are real directories without
// FILE_ATTRIBUTE_REPARSE_POINT. A junction, symlink or replaced path at any
// level makes the operation a no-op.
//
// The policy is WinRT-free so clipboard-logic-tests can exercise the delete
// boundary without reading or modifying the real clipboard history.
class ClipboardCacheDirectory {
public:
    static constexpr int TOKEN_HEX_DIGITS = 16;

    // Only a fully qualified local drive path with at least one component.
    // Drive-relative ("C:relative"), bare drive roots ("C:\"), UNC, \\?\, \\.\
    // and relative paths are all refused. A dot or parent component that
    // survives normalization is refused too.
    [[nodiscard]] static bool validRoot(const QString& root) {
        static const QRegularExpression pattern(QStringLiteral("^[A-Za-z]:[\\\\/][^\\\\/]"));
        if (!pattern.match(root).hasMatch())
            return false;
        const auto normalized = QDir::cleanPath(root);
        if (!pattern.match(normalized).hasMatch())
            return false;
        auto relative = normalized.mid(3);
        relative.replace(QLatin1Char('\\'), QLatin1Char('/'));
        const auto parts = relative.split(QLatin1Char('/'), Qt::SkipEmptyParts);
        if (parts.isEmpty())
            return false;
        for (const auto& part: parts) {
            if (part == QStringLiteral(".") || part == QStringLiteral(".."))
                return false;
        }
        return true;
    }

    [[nodiscard]] static QString normalizedRoot(const QString& root) {
        return validRoot(root) ? QDir::cleanPath(root) : QString();
    }

    [[nodiscard]] static QString makeInstanceName(quint32 pid, quint64 token) {
        return QStringLiteral("%1-%2").arg(pid).arg(token, TOKEN_HEX_DIGITS, 16, QLatin1Char('0'));
    }

    [[nodiscard]] static bool validInstanceName(const QString& name) {
        static const QRegularExpression pattern(QStringLiteral("^[1-9][0-9]{0,9}-[0-9a-f]{16}$"));
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
        if (!m_configured || name.isEmpty() || name == QStringLiteral(".") || name == QStringLiteral("..") ||
            name.contains(QLatin1Char('/')) || name.contains(QLatin1Char('\\'))) {
            return {};
        }
        return m_path + QLatin1Char('/') + name;
    }

    // Creates the clipboard parent and the instance directory only below an
    // already-existing real cache root. Existing files, junctions or other
    // reparse points are never replaced.
    [[nodiscard]] bool ensure(QString* error = nullptr) const {
        if (!m_configured) {
            setError(error, QStringLiteral("No clipboard cache root is configured."));
            return false;
        }
        if (!isRealDirectory(m_root)) {
            setError(error, unsafeMessage());
            return false;
        }
        if (!requireDirectory(basePath(m_root), error) || !requireDirectory(m_path, error))
            return false;
        return true;
    }

    // Re-checked immediately before a write. A directory that has since become
    // a junction (or otherwise stopped being a real directory) is never written
    // through.
    [[nodiscard]] bool ready() const {
        return m_configured && isRealDirectory(m_root) && isRealDirectory(basePath(m_root)) && isRealDirectory(m_path);
    }

    // Deletes this instance's directory only. A no-op when nothing was ever
    // configured or when any level is not a real directory.
    bool remove() {
        if (!m_configured)
            return true;
        return removeValidated(m_root, m_path);
    }

    // Writes `bytes` to a new direct file named `<stem>-<random hex>.<extension>`
    // and returns its path, or an empty string. NewOnly fails when the name
    // already exists, so an existing entry (for example a hard link planted at
    // a predictable name) is never opened or truncated. A name collision is
    // retried with a new suffix rather than reused.
    [[nodiscard]] QString writeFreshFile(const QString& stem, const QString& extension, const QByteArray& bytes) const {
        if (!ready())
            return {};
        for (int attempt = 0; attempt < 8; ++attempt) {
            const auto path = filePath(stem + QLatin1Char('-')
                + QString::number(QRandomGenerator::global()->generate64(), 16).rightJustified(16, QLatin1Char('0'))
                + QLatin1Char('.') + extension);
            if (path.isEmpty())
                return {};
            QFile file(path);
            if (!file.open(QIODevice::WriteOnly | QIODevice::NewOnly)) {
                if (QFileInfo::exists(path))
                    continue;
                return {};
            }
            const auto written = file.write(bytes);
            file.close();
            if (written != bytes.size()) {
                removeFile(path);
                return {};
            }
            return path;
        }
        return {};
    }

    // Deletes one direct file of the instance directory after the same layout
    // checks. Preview pruning uses this instead of QFile::remove.
    bool removeFile(const QString& path) const {
        if (!ready())
            return false;
        const auto clean = QDir::cleanPath(path);
        if (!directChild(m_path, clean) || !isRegularFile(clean))
            return false;
        return deleteFile(clean);
    }

    // Startup cleanup: removes only sibling directories whose name matches the
    // instance pattern and whose pid is not a running process. This process and
    // any other live instance are never touched. A sibling that is a junction
    // or any other reparse point is skipped without being opened.
    static int removeDeadSiblings(
        const QString& root, const QString& ownName, const std::function<bool(quint32)>& processAlive) {
        if (!validRoot(root) || !validInstanceName(ownName))
            return 0;

        const auto normalized = normalizedRoot(root);
        const auto base = basePath(normalized);
        if (!isRealDirectory(normalized) || !isRealDirectory(base))
            return 0;

        int removed = 0;
        const auto entries = QDir(base).entryInfoList(QDir::Dirs | QDir::NoDotAndDotDot);
        for (const auto& entry : entries) {
            const auto name = entry.fileName();
            if (name == ownName || !validInstanceName(name))
                continue;

            const auto path = entry.absoluteFilePath();
            // A dead-pid sibling may be a junction to somewhere else. Only a
            // real directory is ever enumerated or removed.
            if (!isRealDirectory(path))
                continue;

            bool ok = false;
            const auto pid = name.section(QLatin1Char('-'), 0, 0).toUInt(&ok);
            if (!ok || pid == 0 || processAlive(pid))
                continue;
            if (removeValidated(normalized, path))
                ++removed;
        }
        return removed;
    }

private:
    [[nodiscard]] static QString unsafeMessage() {
        return QStringLiteral("The clipboard cache directory is not a safe directory.");
    }

    static void setError(QString* error, const QString& message) {
        if (error != nullptr)
            *error = message;
    }

    [[nodiscard]] static QString basePath(const QString& root) {
        return QDir::cleanPath(root) + QStringLiteral("/clipboard");
    }

    [[nodiscard]] static DWORD attributesOf(const QString& path) {
        const auto wide = QDir::toNativeSeparators(path).toStdWString();
        return GetFileAttributesW(wide.c_str());
    }

    [[nodiscard]] static bool isRealDirectory(const QString& path) {
        const auto attributes = attributesOf(path);
        return attributes != INVALID_FILE_ATTRIBUTES && (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0 &&
               (attributes & FILE_ATTRIBUTE_REPARSE_POINT) == 0;
    }

    [[nodiscard]] static bool isRegularFile(const QString& path) {
        const auto attributes = attributesOf(path);
        return attributes != INVALID_FILE_ATTRIBUTES && (attributes & FILE_ATTRIBUTE_DIRECTORY) == 0 &&
               (attributes & FILE_ATTRIBUTE_REPARSE_POINT) == 0;
    }

    [[nodiscard]] static bool isMissing(const QString& path) {
        if (attributesOf(path) != INVALID_FILE_ATTRIBUTES)
            return false;
        const auto code = GetLastError();
        return code == ERROR_FILE_NOT_FOUND || code == ERROR_PATH_NOT_FOUND;
    }

    [[nodiscard]] static bool createRealDirectory(const QString& path) {
        const auto wide = QDir::toNativeSeparators(path).toStdWString();
        if (!CreateDirectoryW(wide.c_str(), nullptr))
            return false;
        return isRealDirectory(path);
    }

    // Creates a missing directory only after its parent was validated. An
    // existing file, junction or other reparse point is refused.
    [[nodiscard]] static bool requireDirectory(const QString& path, QString* error) {
        if (isRealDirectory(path))
            return true;
        if (!isMissing(path) || !createRealDirectory(path)) {
            setError(error, unsafeMessage());
            return false;
        }
        return true;
    }

    static bool deleteFile(const QString& path) {
        const auto wide = QDir::toNativeSeparators(path).toStdWString();
        return DeleteFileW(wide.c_str()) != 0;
    }

    [[nodiscard]] static bool removeEmptyDirectory(const QString& path) {
        const auto wide = QDir::toNativeSeparators(path).toStdWString();
        return RemoveDirectoryW(wide.c_str()) != 0;
    }

    [[nodiscard]] static Qt::CaseSensitivity pathCase() {
#ifdef Q_OS_WIN
        return Qt::CaseInsensitive;
#else
        return Qt::CaseSensitive;
#endif
    }

    // True only for a direct child. This rejects the parent itself and deeper
    // paths, so cleanup can never walk into a nested directory or junction.
    [[nodiscard]] static bool directChild(const QString& parent, const QString& child) {
        if (parent.isEmpty() || child.isEmpty())
            return false;
        const auto cleanParent = QDir::cleanPath(parent);
        const auto cleanChild = QDir::cleanPath(child);
        if (cleanParent.isEmpty() || cleanChild.isEmpty() || cleanParent.compare(cleanChild, pathCase()) == 0) {
            return false;
        }
        const auto prefix = cleanParent + QLatin1Char('/');
        if (!cleanChild.startsWith(prefix, pathCase()))
            return false;
        const auto remainder = cleanChild.mid(prefix.size());
        return !remainder.isEmpty() && !remainder.contains(QLatin1Char('/'));
    }

    // Deletes only regular files directly in the validated directory. Every
    // subdirectory, junction and other reparse point is deliberately skipped so
    // a later RemoveDirectoryW fails without touching anything outside.
    static void deleteFlatFiles(const QString& directory) {
        const QDir dir(directory);
        const auto entries = dir.entryInfoList(QDir::AllEntries | QDir::NoDotAndDotDot | QDir::Hidden | QDir::System);
        for (const auto& entry : entries) {
            const auto path = entry.absoluteFilePath();
            if (!isRegularFile(path))
                continue;
            deleteFile(path);
        }
    }

    [[nodiscard]] static bool removeValidated(const QString& root, const QString& path) {
        if (!validRoot(root) || path.isEmpty() || !QDir::isAbsolutePath(path))
            return false;

        const auto cleanRoot = QDir::cleanPath(root);
        const auto base = basePath(cleanRoot);
        const auto target = QDir::cleanPath(path);

        // The root and clipboard parent must be real directories before even
        // looking at the target. A junction at either level is a no-op.
        if (!isRealDirectory(cleanRoot) || !isRealDirectory(base))
            return false;
        if (isMissing(target))
            return true; // Already gone: nothing to delete or follow.
        if (!isRealDirectory(target))
            return false;

        const auto name = QFileInfo(target).fileName();
        if (!validInstanceName(name) || name != QFileInfo(path).fileName() || !directChild(base, target)) {
            return false;
        }

        // The cache is flat. Remove only regular files directly in the
        // instance directory; never walk into a subdirectory or junction.
        deleteFlatFiles(target);

        // RemoveDirectoryW removes a junction link itself (not its target) and
        // refuses a directory that is still not empty.
        return removeEmptyDirectory(target) && !QFileInfo::exists(target);
    }

    bool m_configured = false;
    QString m_root;
    QString m_name;
    QString m_path;
};

} // namespace caelestia::shell::windows
