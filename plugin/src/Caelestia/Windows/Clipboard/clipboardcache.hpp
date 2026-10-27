#pragma once

#include <qbytearray.h>
#include <qdir.h>
#include <qfile.h>
#include <qfileinfo.h>
#include <qglobal.h>
#include <qloggingcategory.h>
#include <qrandom.h>
#include <qregularexpression.h>
#include <qstring.h>
#include <qt_windows.h>

#include <cstring>
#include <functional>
#include <string>
#include <vector>

namespace caelestia::shell::windows {

namespace cache_detail {

inline QLoggingCategory& log() {
    static QLoggingCategory category("caelestia.windows.clipboard.cache");
    return category;
}

} // namespace cache_detail

class ClipboardCacheDeletion;

// Owns exactly one per-instance cache directory:
//
//   <cacheRoot>/clipboard/<pid>-<16 hex random>
//
// Previews and explicitly opened text files live directly in that directory.
// Nothing is created before a valid, fully qualified local cacheRoot is known.
//
// The directory is flat by design and cleanup never recurses. It enumerates
// only the direct files of the instance directory, deletes only regular files
// without FILE_ATTRIBUTE_REPARSE_POINT, skips every other entry, and then
// deletes the directory itself. QFileInfo::isSymLink() does not report NTFS
// junctions, so the reparse-point attribute is the authoritative check.
//
// Every create and write first verifies that the instance directory, the
// clipboard parent and the cache root itself are real directories without
// FILE_ATTRIBUTE_REPARSE_POINT. A junction, symlink or replaced path at any
// level makes the operation a no-op.
//
// Deletion does not trust a path after validation. ClipboardCacheDeletion
// opens the cache root, the clipboard parent and the candidate directory with
// FILE_FLAG_OPEN_REPARSE_POINT, rejects reparse points through their handle,
// verifies the parent chain by volume serial and file ID, and then deletes the
// held directory and its verified direct children by handle. A path swapped for
// a junction between validation and deletion therefore cannot redirect it.
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
        if (!m_configured)
            return false;
        return removeValidatedFile(m_root, m_path, path);
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
    friend class ClipboardCacheDeletion;

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

    [[nodiscard]] static bool removeValidated(const QString& root, const QString& path);
    [[nodiscard]] static bool removeValidatedFile(
        const QString& root, const QString& directory, const QString& path);

    bool m_configured = false;
    QString m_root;
    QString m_name;
    QString m_path;
};

// One held, identity-verified delete transaction. The cache root, the
// clipboard parent and the candidate instance directory stay open for the
// whole operation, so a rename or junction swap at any of those paths cannot
// redirect the deletion. Direct children are opened with
// FILE_FLAG_OPEN_REPARSE_POINT and must match the file ID the held directory
// reported; anything else is skipped.
class ClipboardCacheDeletion {
public:
    enum class OpenResult { Opened, Missing, Refused };

    ClipboardCacheDeletion() = default;
    ClipboardCacheDeletion(const ClipboardCacheDeletion&) = delete;
    ClipboardCacheDeletion& operator=(const ClipboardCacheDeletion&) = delete;

    // Opens the whole chain. The candidate may be missing (already collected);
    // any reparse point, replaced parent or identity mismatch is Refused.
    [[nodiscard]] OpenResult open(const QString& root, const QString& path) {
        m_path.clear();
        if (!ClipboardCacheDirectory::validRoot(root) || path.isEmpty() || !QDir::isAbsolutePath(path))
            return OpenResult::Refused;

        const auto cleanRoot = QDir::cleanPath(root);
        const auto base = ClipboardCacheDirectory::basePath(cleanRoot);
        const auto target = QDir::cleanPath(path);
        const auto name = QFileInfo(target).fileName();
        if (!ClipboardCacheDirectory::validInstanceName(name)
            || !ClipboardCacheDirectory::directChild(base, target)) {
            return OpenResult::Refused;
        }

        if (!m_root.openDirectory(cleanRoot) || !m_root.isRealDirectory())
            return refuse(QStringLiteral("the cache root is not a real directory"));
        if (!m_base.openDirectory(base) || !m_base.isRealDirectory())
            return refuse(QStringLiteral("the clipboard parent is not a real directory"));
        if (!m_root.contains(QStringLiteral("clipboard"), m_base))
            return refuse(QStringLiteral("the clipboard parent is not the held cache root's child"));
        if (!m_instance.openDirectory(target)) {
            if (m_instance.error() == ERROR_FILE_NOT_FOUND || m_instance.error() == ERROR_PATH_NOT_FOUND)
                return OpenResult::Missing;
            return refuse(QStringLiteral("the instance directory could not be opened"));
        }
        if (!m_instance.isRealDirectory())
            return refuse(QStringLiteral("the instance directory is a reparse point or not a directory"));
        if (!m_base.contains(name, m_instance))
            return refuse(QStringLiteral("the instance directory is not the held clipboard parent's child"));

        m_path = target;
        return OpenResult::Opened;
    }

    // Deletes only regular, non-reparse direct children through the held
    // instance directory. Returns false when any entry was skipped or could not
    // be deleted, so the caller does not claim a complete cleanup.
    [[nodiscard]] bool removeContents() {
        if (!m_instance.valid())
            return false;

        std::vector<Handle::Entry> entries;
        if (!Handle::list(m_instance.value, entries)) {
            qCWarning(cache_detail::log())
                << "Clipboard cache cleanup refused: the instance directory could not be enumerated.";
            return false;
        }

        bool complete = true;
        for (const auto& entry: entries) {
            if (entry.name == QStringLiteral(".") || entry.name == QStringLiteral(".."))
                continue;
            if ((entry.attributes & FILE_ATTRIBUTE_DIRECTORY) != 0
                || (entry.attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
                qCWarning(cache_detail::log())
                    << "Clipboard cache cleanup skipped a non-file entry.";
                complete = false;
                continue;
            }
            if (!removeEntry(entry))
                complete = false;
        }
        return complete;
    }

    // Deletes one named direct file after verifying it against the held
    // directory's own listing. Preview pruning uses this path.
    [[nodiscard]] bool removeChild(const QString& name) {
        if (!m_instance.valid() || name.isEmpty() || name == QStringLiteral(".")
            || name == QStringLiteral("..") || name.contains(QLatin1Char('/'))
            || name.contains(QLatin1Char('\\'))) {
            return false;
        }

        std::vector<Handle::Entry> entries;
        if (!Handle::list(m_instance.value, entries))
            return false;
        for (const auto& entry: entries) {
            if (entry.name.compare(name, Qt::CaseInsensitive) != 0)
                continue;
            if ((entry.attributes & FILE_ATTRIBUTE_DIRECTORY) != 0
                || (entry.attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
                return false;
            }
            return removeEntry(entry);
        }
        return false;
    }

    // Deletes the held instance directory itself, never a path that may have
    // replaced it. POSIX semantics unlink it immediately; FileDispositionInfo
    // is the fallback for older file systems.
    [[nodiscard]] bool removeSelf() { return m_instance.valid() && m_instance.deleteSelf(); }

private:
    struct Handle {
        struct Entry {
            QString name;
            FILE_ID_128 id {};
            DWORD attributes = 0;
        };

        HANDLE value = INVALID_HANDLE_VALUE;
        DWORD lastError = ERROR_SUCCESS;

        Handle() = default;
        ~Handle() { close(); }
        Handle(const Handle&) = delete;
        Handle& operator=(const Handle&) = delete;

        void close() {
            if (value != INVALID_HANDLE_VALUE) {
                CloseHandle(value);
                value = INVALID_HANDLE_VALUE;
            }
        }

        [[nodiscard]] DWORD error() const { return lastError; }
        [[nodiscard]] bool valid() const { return value != INVALID_HANDLE_VALUE; }

        [[nodiscard]] bool openDirectory(const QString& path) {
            return open(path, FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES | DELETE | SYNCHRONIZE,
                FILE_FLAG_BACKUP_SEMANTICS);
        }

        [[nodiscard]] bool openFile(const QString& path) {
            return open(path, DELETE | FILE_READ_ATTRIBUTES | SYNCHRONIZE, 0);
        }

        [[nodiscard]] bool open(const QString& path, DWORD access, DWORD flags) {
            close();
            const auto wide = QDir::toNativeSeparators(path).toStdWString();
            // FILE_FLAG_OPEN_REPARSE_POINT: never follow a junction or symlink.
            // FILE_SHARE_DELETE lets a deliberate swap happen while the held
            // handle keeps referring to the validated object; identity checks
            // below still refuse to delete through the new path.
            value = CreateFileW(wide.c_str(), access,
                FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING,
                flags | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
            lastError = value == INVALID_HANDLE_VALUE ? GetLastError() : ERROR_SUCCESS;
            return value != INVALID_HANDLE_VALUE;
        }

        [[nodiscard]] bool attributeTag(FILE_ATTRIBUTE_TAG_INFO& info) const {
            return valid()
                && GetFileInformationByHandleEx(value, FileAttributeTagInfo, &info, sizeof(info)) != 0;
        }

        [[nodiscard]] bool isRealDirectory() const {
            FILE_ATTRIBUTE_TAG_INFO info {};
            return attributeTag(info) && (info.FileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0
                && (info.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) == 0;
        }

        [[nodiscard]] bool isRegularFile() const {
            FILE_ATTRIBUTE_TAG_INFO info {};
            return attributeTag(info) && (info.FileAttributes & FILE_ATTRIBUTE_DIRECTORY) == 0
                && (info.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) == 0;
        }

        [[nodiscard]] bool fileId(FILE_ID_INFO& id) const {
            return valid() && GetFileInformationByHandleEx(value, FileIdInfo, &id, sizeof(id)) != 0;
        }

        // True only when `child` has the same volume serial and 128-bit file ID
        // as an entry named `name` directly in this held directory.
        [[nodiscard]] bool contains(const QString& name, const Handle& child) const {
            FILE_ID_INFO parentId {};
            FILE_ID_INFO childId {};
            if (!fileId(parentId) || !child.fileId(childId)
                || parentId.VolumeSerialNumber != childId.VolumeSerialNumber) {
                return false;
            }
            std::vector<Entry> entries;
            if (!list(value, entries))
                return false;
            for (const auto& entry: entries) {
                if (entry.name.compare(name, Qt::CaseInsensitive) == 0
                    && std::memcmp(&entry.id, &childId.FileId, sizeof(FILE_ID_128)) == 0) {
                    return true;
                }
            }
            return false;
        }

        [[nodiscard]] bool deleteSelf() const { return deleteByHandle(value); }

        // Enumerates the held directory itself, never a path. Restart first so
        // this helper is independent of an earlier enumeration on the handle.
        [[nodiscard]] static bool list(HANDLE handle, std::vector<Entry>& entries) {
            entries.clear();
            if (handle == INVALID_HANDLE_VALUE)
                return false;

            std::vector<BYTE> buffer(64 * 1024);
            auto infoClass = FileIdExtdDirectoryRestartInfo;
            for (;;) {
                if (!GetFileInformationByHandleEx(handle, infoClass, buffer.data(),
                        static_cast<DWORD>(buffer.size()))) {
                    const auto code = GetLastError();
                    if (code == ERROR_NO_MORE_FILES)
                        return true;
                    return false;
                }
                infoClass = FileIdExtdDirectoryInfo;

                auto* cursor = reinterpret_cast<FILE_ID_EXTD_DIR_INFO*>(buffer.data());
                for (;;) {
                    Entry entry;
                    entry.name = QString::fromWCharArray(cursor->FileName,
                        static_cast<qsizetype>(cursor->FileNameLength / sizeof(WCHAR)));
                    entry.id = cursor->FileId;
                    entry.attributes = cursor->FileAttributes;
                    entries.push_back(std::move(entry));
                    if (cursor->NextEntryOffset == 0)
                        break;
                    cursor = reinterpret_cast<FILE_ID_EXTD_DIR_INFO*>(
                        reinterpret_cast<BYTE*>(cursor) + cursor->NextEntryOffset);
                }
            }
        }

        [[nodiscard]] static bool deleteByHandle(HANDLE handle) {
            if (handle == INVALID_HANDLE_VALUE)
                return false;
            FILE_DISPOSITION_INFO_EX infoEx {};
            infoEx.Flags = FILE_DISPOSITION_FLAG_DELETE | FILE_DISPOSITION_FLAG_POSIX_SEMANTICS;
            if (SetFileInformationByHandle(handle, FileDispositionInfoEx, &infoEx, sizeof(infoEx)))
                return true;
            FILE_DISPOSITION_INFO info {};
            info.DeleteFile = TRUE;
            return SetFileInformationByHandle(handle, FileDispositionInfo, &info, sizeof(info)) != 0;
        }
    };

    [[nodiscard]] static OpenResult refuse(const QString& reason) {
        qCWarning(cache_detail::log()).noquote() << "Clipboard cache deletion refused:" << reason;
        return OpenResult::Refused;
    }

    [[nodiscard]] bool removeEntry(const Handle::Entry& entry) {
        const auto path = m_path + QLatin1Char('/') + entry.name;
        Handle child;
        if (!child.openFile(path) || !child.isRegularFile()) {
            qCWarning(cache_detail::log())
                << "Clipboard cache cleanup refused an entry that is no longer a regular file.";
            return false;
        }

        FILE_ID_INFO childId {};
        if (!child.fileId(childId)
            || std::memcmp(&childId.FileId, &entry.id, sizeof(FILE_ID_128)) != 0) {
            qCWarning(cache_detail::log())
                << "Clipboard cache cleanup refused an entry whose file identity changed.";
            return false;
        }

        if (!Handle::deleteByHandle(child.value)) {
            qCWarning(cache_detail::log()) << "Clipboard cache cleanup could not delete a file entry.";
            return false;
        }
        return true;
    }

    Handle m_root;
    Handle m_base;
    Handle m_instance;
    QString m_path;
};

inline bool ClipboardCacheDirectory::removeValidated(const QString& root, const QString& path) {
    ClipboardCacheDeletion deletion;
    const auto opened = deletion.open(root, path);
    if (opened == ClipboardCacheDeletion::OpenResult::Missing)
        return true; // Already gone: nothing to delete or follow.
    if (opened != ClipboardCacheDeletion::OpenResult::Opened)
        return false;
    if (!deletion.removeContents())
        return false;
    return deletion.removeSelf();
}

inline bool ClipboardCacheDirectory::removeValidatedFile(
    const QString& root, const QString& directory, const QString& path) {
    const auto clean = QDir::cleanPath(path);
    if (!directChild(directory, clean))
        return false;
    const auto name = QFileInfo(clean).fileName();
    if (name.isEmpty())
        return false;

    ClipboardCacheDeletion deletion;
    if (deletion.open(root, directory) != ClipboardCacheDeletion::OpenResult::Opened)
        return false;
    return deletion.removeChild(name);
}

} // namespace caelestia::shell::windows
