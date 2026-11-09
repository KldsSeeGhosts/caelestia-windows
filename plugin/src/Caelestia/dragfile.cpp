#include "dragfile.hpp"

#include <qdir.h>
#include <qfile.h>
#include <qfileinfo.h>
#include <qloggingcategory.h>
#include <qregularexpression.h>
#include <quuid.h>

#ifdef Q_OS_WIN
#include <qt_windows.h>

#include <string>
#endif

namespace {

Q_LOGGING_CATEGORY(lcDragFile, "caelestia.dragfile", QtInfoMsg)

constexpr auto dirPrefix = "caelestia-drag-";
constexpr int maxNameLength = 120;

QString withoutTrailingSlash(QString root) {
    while (root.size() > 1 && root.endsWith(QLatin1Char('/')))
        root.chop(1);
    return root;
}

const QRegularExpression& dirName() {
    static const QRegularExpression name(QStringLiteral("^([0-9a-f]{32})/([^/\\\\]+)\\z"));
    return name;
}

#ifdef CAELESTIA_DRAGFILE_HOOKS
std::function<void(caelestia::shell::dragfile::testing::Step, const QString&)>& hookFunction() {
    static std::function<void(caelestia::shell::dragfile::testing::Step, const QString&)> hook;
    return hook;
}

void runHook(caelestia::shell::dragfile::testing::Step step, const QString& directory) {
    if (const auto& hook = hookFunction())
        hook(step, directory);
}
#define DRAGFILE_HOOK(step, directory) runHook(caelestia::shell::dragfile::testing::Step::step, directory)
#else
#define DRAGFILE_HOOK(step, directory) ((void)0)
#endif

#ifdef Q_OS_WIN

// An owned Win32 handle.
class Handle {
public:
    Handle() = default;
    explicit Handle(HANDLE handle)
        : m_handle(handle) {}
    Handle(Handle&& other) noexcept
        : m_handle(other.m_handle) {
        other.m_handle = INVALID_HANDLE_VALUE;
    }
    Handle& operator=(Handle&& other) noexcept {
        if (this != &other) {
            reset();
            m_handle = other.m_handle;
            other.m_handle = INVALID_HANDLE_VALUE;
        }
        return *this;
    }
    Handle(const Handle&) = delete;
    Handle& operator=(const Handle&) = delete;
    ~Handle() { reset(); }

    bool valid() const { return m_handle != INVALID_HANDLE_VALUE; }
    HANDLE get() const { return m_handle; }

    void reset() {
        if (m_handle != INVALID_HANDLE_VALUE)
            CloseHandle(m_handle);
        m_handle = INVALID_HANDLE_VALUE;
    }

private:
    HANDLE m_handle = INVALID_HANDLE_VALUE;
};

LPCWSTR wide(const std::wstring& string) {
    return string.c_str();
}

std::wstring native(const QString& path) {
    return QDir::toNativeSeparators(path).toStdWString();
}

// The final path of an open handle in the form C:\dir\name, with no \\?\ prefix
// and no trailing backslash (except for a drive root), or an empty string.
QString finalPath(HANDLE handle) {
    std::wstring buffer(MAX_PATH, L'\0');
    for (int attempt = 0; attempt < 2; attempt++) {
        const auto length = GetFinalPathNameByHandleW(
            handle, buffer.data(), static_cast<DWORD>(buffer.size()), FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
        if (length == 0)
            return {};
        if (length < buffer.size()) {
            auto path = QString::fromWCharArray(buffer.data(), static_cast<qsizetype>(length));
            if (path.startsWith(QStringLiteral("\\\\?\\UNC\\")))
                path = QStringLiteral("\\\\") + path.mid(8);
            else if (path.startsWith(QStringLiteral("\\\\?\\")))
                path = path.mid(4);
            while (path.size() > 3 && path.endsWith(QLatin1Char('\\')))
                path.chop(1);
            return path;
        }
        buffer.resize(length + 1);
    }
    return {};
}

bool sameFinalPath(const QString& a, const QString& b) {
    return !a.isEmpty() && a.compare(b, Qt::CaseInsensitive) == 0;
}

QString joinFinal(QString directory, const QString& name) {
    while (directory.endsWith(QLatin1Char('\\')))
        directory.chop(1);
    return directory + QLatin1Char('\\') + name;
}

// Whether the handle is a plain directory or file: not a reparse point, and a
// directory exactly when `directory` says so.
bool hasKind(HANDLE handle, bool directory) {
    FILE_ATTRIBUTE_TAG_INFO tag{};
    if (!GetFileInformationByHandleEx(handle, FileAttributeTagInfo, &tag, sizeof(tag)))
        return false;
    if (tag.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)
        return false;
    return ((tag.FileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) == directory;
}

bool hasOneLink(HANDLE handle) {
    FILE_STANDARD_INFO standard{};
    return GetFileInformationByHandleEx(handle, FileStandardInfo, &standard, sizeof(standard))
        && standard.NumberOfLinks == 1 && !standard.DeletePending && !standard.Directory;
}

// Resolves the temp root once, following links. `error` is the Win32 error when it
// cannot be opened as a directory.
bool resolveRoot(const QString& base, QString& resolved, DWORD& error) {
    Handle handle(CreateFileW(wide(native(base)), FILE_READ_ATTRIBUTES,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS,
        nullptr));
    if (!handle.valid()) {
        error = GetLastError();
        return false;
    }

    FILE_ATTRIBUTE_TAG_INFO tag{};
    if (!GetFileInformationByHandleEx(handle.get(), FileAttributeTagInfo, &tag, sizeof(tag))
        || !(tag.FileAttributes & FILE_ATTRIBUTE_DIRECTORY)) {
        error = ERROR_DIRECTORY;
        return false;
    }

    resolved = finalPath(handle.get());
    error = resolved.isEmpty() ? ERROR_PATH_NOT_FOUND : ERROR_SUCCESS;
    return !resolved.isEmpty();
}

// Opens the drag directory itself, never what a reparse point points to. It denies
// FILE_SHARE_DELETE, so while this handle is open nobody can rename, delete or
// replace the directory. `error` is the Win32 error on failure.
Handle openDirectory(const QString& directory, DWORD& error) {
    Handle handle(CreateFileW(wide(native(directory)), DELETE | FILE_READ_ATTRIBUTES | FILE_LIST_DIRECTORY,
        FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
    error = handle.valid() ? ERROR_SUCCESS : GetLastError();
    return handle;
}

// The pinned handle must be a plain directory at <resolved root>\caelestia-drag-<id>.
bool isExpectedDirectory(HANDLE handle, const QString& expected) {
    return hasKind(handle, true) && sameFinalPath(finalPath(handle), expected);
}

// Every entry of a pinned directory, hidden and system ones included, enumerated
// through the handle.
bool listDirectory(HANDLE handle, QStringList& names) {
    alignas(8) char buffer[16 * 1024];
    auto request = FileIdBothDirectoryRestartInfo;
    for (;;) {
        if (!GetFileInformationByHandleEx(handle, request, buffer, sizeof(buffer)))
            return GetLastError() == ERROR_NO_MORE_FILES;
        request = FileIdBothDirectoryInfo;

        auto* info = reinterpret_cast<FILE_ID_BOTH_DIR_INFO*>(buffer);
        for (;;) {
            const auto name = QString::fromWCharArray(
                info->FileName, static_cast<qsizetype>(info->FileNameLength / sizeof(WCHAR)));
            if (name != QLatin1String(".") && name != QLatin1String(".."))
                names << name;
            if (info->NextEntryOffset == 0)
                break;
            info = reinterpret_cast<FILE_ID_BOTH_DIR_INFO*>(reinterpret_cast<char*>(info) + info->NextEntryOffset);
        }
    }
}

// Marks the object behind the handle for deletion. POSIX semantics remove the
// name at once; the fallback deletes when the last handle closes. A directory that
// still has entries is never deleted.
bool deleteByHandle(HANDLE handle) {
    FILE_DISPOSITION_INFO_EX extended{};
    extended.Flags = FILE_DISPOSITION_FLAG_DELETE | FILE_DISPOSITION_FLAG_POSIX_SEMANTICS;
    if (SetFileInformationByHandle(handle, FileDispositionInfoEx, &extended, sizeof(extended)))
        return true;

    FILE_DISPOSITION_INFO classic{};
    classic.DeleteFile = TRUE;
    return SetFileInformationByHandle(handle, FileDispositionInfo, &classic, sizeof(classic)) != 0;
}

bool isGone(const QString& path) {
    const auto attributes = GetFileAttributesW(wide(native(path)));
    if (attributes != INVALID_FILE_ATTRIBUTES)
        return false;
    const auto error = GetLastError();
    return error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND;
}

#endif // Q_OS_WIN

} // namespace

namespace caelestia::shell::dragfile {

#ifdef CAELESTIA_DRAGFILE_HOOKS
namespace testing {

void setHook(std::function<void(Step, const QString&)> hook) {
    hookFunction() = std::move(hook);
}

} // namespace testing
#endif

bool isReparsePoint(const QString& path) {
#ifdef Q_OS_WIN
    const auto attributes = GetFileAttributesW(reinterpret_cast<LPCWSTR>(QDir::toNativeSeparators(path).utf16()));
    return attributes == INVALID_FILE_ATTRIBUTES || (attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0;
#else
    return QFileInfo(path).isSymLink();
#endif
}

bool validName(const QString& name) {
    static const QString extension = QStringLiteral(".png");
    if (name.isEmpty() || name.size() > maxNameLength || !name.endsWith(extension))
        return false;

    const auto stem = name.chopped(extension.size());
    if (stem.isEmpty() || stem.front().isSpace() || stem.back().isSpace() || stem.endsWith(QLatin1Char('.')))
        return false;

    for (const auto ch : name) {
        if (ch.unicode() < 0x20 || QStringLiteral("\\/:*?\"<>|").contains(ch))
            return false;
    }

    // A device name is reserved on Windows with any extension: CON, CON.txt, COM1.
    static const QRegularExpression reserved(
        QStringLiteral("^(con|prn|aux|nul|com[0-9]|lpt[0-9])(\\.|\\z)"), QRegularExpression::CaseInsensitiveOption);
    return !reserved.match(stem).hasMatch();
}

#ifdef Q_OS_WIN

QString create(const QString& root, const QString& name) {
    if (!validName(name)) {
        qCWarning(lcDragFile) << "create: not a usable file name" << name;
        return {};
    }

    const auto base = withoutTrailingSlash(root);
    QString resolved;
    DWORD error = ERROR_SUCCESS;
    if (base.isEmpty() || !resolveRoot(base, resolved, error)) {
        qCWarning(lcDragFile) << "create: the temp directory is not usable" << root;
        return {};
    }
    DRAGFILE_HOOK(AfterRootResolved, base);

    // A random 128-bit name, and the directory is created only when it does not
    // exist, so a directory of another card, reload or process is never reused.
    for (int attempt = 0; attempt < 4; attempt++) {
        const auto id = QUuid::createUuid().toString(QUuid::Id128);
        const auto directory = base + QLatin1Char('/') + QLatin1String(dirPrefix) + id;
        if (!CreateDirectoryW(wide(native(directory)), nullptr))
            continue;
        // From here on this call made `directory`, and it may undo that, but only
        // through a handle that passed the checks below.
        DRAGFILE_HOOK(AfterDirectoryCreated, directory);

        const auto expectedDirectory = joinFinal(resolved, QLatin1String(dirPrefix) + id);
        const auto path = directory + QLatin1Char('/') + name;

        auto pinned = openDirectory(directory, error);
        const bool directoryOk = pinned.valid() && isExpectedDirectory(pinned.get(), expectedDirectory);

        Handle file; // the file this call created, when it did
        if (directoryOk) {
            // The pinned directory cannot be renamed or replaced, so this path
            // names a file inside it. CREATE_NEW fails when the name exists.
            DRAGFILE_HOOK(BeforeFileCreated, directory);
            file = Handle(CreateFileW(wide(native(path)), DELETE | FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE,
                nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
            if (file.valid() && hasKind(file.get(), false) && hasOneLink(file.get())
                && sameFinalPath(finalPath(file.get()), joinFinal(expectedDirectory, name)))
                return path;
        }

        // Undo only what this call created. A file handle exists only when
        // CREATE_NEW succeeded. The directory is deleted through the pinned handle
        // only when it passed the check, and only while it is empty. When the
        // directory check failed nothing is deleted: the path may now name
        // something else.
        if (file.valid()) {
            deleteByHandle(file.get());
            file.reset();
        }
        if (directoryOk)
            deleteByHandle(pinned.get());
        break;
    }

    qCWarning(lcDragFile) << "create: cannot create a drag file in the temp directory";
    return {};
}

bool remove(const QString& root, const QString& path) {
    const auto base = withoutTrailingSlash(root);
    const auto prefix = base + QLatin1Char('/') + QLatin1String(dirPrefix);
    // Paths on Windows are case-insensitive; the id part below is lower case hex.
    if (base.isEmpty() || !path.startsWith(prefix, Qt::CaseInsensitive)) {
        qCWarning(lcDragFile) << "remove: not a drag file path";
        return false;
    }

    const auto match = dirName().match(path.mid(prefix.size()));
    if (!match.hasMatch() || !validName(match.captured(2))) {
        qCWarning(lcDragFile) << "remove: not a drag file path";
        return false;
    }

    const auto name = match.captured(2);
    const auto directory = path.left(prefix.size() + 32);

    QString resolved;
    DWORD error = ERROR_SUCCESS;
    if (!resolveRoot(base, resolved, error)) {
        // No temp root means no drag directory in it.
        if (error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND)
            return true;
        qCWarning(lcDragFile) << "remove: the temp directory is not usable" << root;
        return false;
    }
    DRAGFILE_HOOK(AfterRootResolved, directory);

    // Pin the directory. Nobody can rename or delete it while this handle is open,
    // so every check below is about the directory that the deletes act on.
    const auto expectedDirectory = joinFinal(resolved, QLatin1String(dirPrefix) + match.captured(1));
    auto pinned = openDirectory(directory, error);
    if (!pinned.valid()) {
        if (error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND)
            return true;
        qCWarning(lcDragFile) << "remove: cannot open the directory" << directory << error;
        return false;
    }
    if (!isExpectedDirectory(pinned.get(), expectedDirectory)) {
        qCWarning(lcDragFile) << "remove: not the expected plain directory" << directory;
        return false;
    }

    // At most the one expected file. Hidden and system entries count too.
    QStringList entries;
    if (!listDirectory(pinned.get(), entries)) {
        qCWarning(lcDragFile) << "remove: cannot list the directory" << directory;
        return false;
    }
    if (entries.size() > 1 || (entries.size() == 1 && entries.constFirst().compare(name, Qt::CaseInsensitive) != 0)) {
        qCWarning(lcDragFile) << "remove: the directory holds something else" << directory;
        return false;
    }

    DRAGFILE_HOOK(BeforeFileRemoval, directory);

    if (entries.size() == 1) {
        // Open the entry itself, not what a reparse point points to. No share for
        // delete, so it cannot be renamed or replaced while it is checked.
        Handle file(CreateFileW(wide(native(path)), DELETE | FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE,
            nullptr, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
        if (!file.valid()) {
            qCWarning(lcDragFile) << "remove: cannot open the file" << path << GetLastError();
            return false;
        }
        if (!hasKind(file.get(), false) || !hasOneLink(file.get())
            || !sameFinalPath(finalPath(file.get()), joinFinal(expectedDirectory, name))) {
            qCWarning(lcDragFile) << "remove: not a regular file with one link in the drag directory" << path;
            return false;
        }
        if (!deleteByHandle(file.get())) {
            qCWarning(lcDragFile) << "remove: cannot delete the file" << path << GetLastError();
            return false;
        }
    }

    DRAGFILE_HOOK(BeforeDirectoryRemoval, directory);

    // The pinned handle deletes the directory only while it is empty.
    if (!deleteByHandle(pinned.get()))
        qCWarning(lcDragFile) << "remove: cannot delete the directory" << directory << GetLastError();
    pinned.reset();
    return isGone(directory);
}

#else // !Q_OS_WIN

// Without handles to pin the directory this is the path-based version. The shell
// only ships on Windows, so this keeps the unit's other platforms compiling.
QString create(const QString& root, const QString& name) {
    if (!validName(name))
        return {};

    const auto base = withoutTrailingSlash(root);
    const QFileInfo baseInfo(base);
    if (base.isEmpty() || baseInfo.isSymLink() || !baseInfo.isDir())
        return {};

    for (int attempt = 0; attempt < 4; attempt++) {
        const auto directory = base + QLatin1Char('/') + QLatin1String(dirPrefix)
            + QUuid::createUuid().toString(QUuid::Id128);
        if (!QDir().mkdir(directory))
            continue;

        const auto path = directory + QLatin1Char('/') + name;
        QFile file(path);
        if (!QFileInfo(directory).isSymLink() && file.open(QIODevice::WriteOnly | QIODevice::NewOnly)) {
            file.close();
            return path;
        }
        QDir().rmdir(directory);
        break;
    }
    return {};
}

bool remove(const QString& root, const QString& path) {
    const auto base = withoutTrailingSlash(root);
    const auto prefix = base + QLatin1Char('/') + QLatin1String(dirPrefix);
    if (base.isEmpty() || !path.startsWith(prefix))
        return false;

    const auto match = dirName().match(path.mid(prefix.size()));
    if (!match.hasMatch() || !validName(match.captured(2)))
        return false;

    const auto directory = path.left(prefix.size() + 32);
    const QFileInfo info(directory);
    if (!info.isSymLink() && !info.exists())
        return true;
    if (info.isSymLink() || !info.isDir())
        return false;

    const auto entries = QDir(directory).entryList(QDir::AllEntries | QDir::NoDotAndDotDot | QDir::Hidden | QDir::System);
    if (entries.size() > 1 || (entries.size() == 1 && entries.constFirst() != match.captured(2)))
        return false;
    if (entries.size() == 1) {
        const QFileInfo file(path);
        if (file.isSymLink() || !file.isFile() || !QFile::remove(path))
            return false;
    }
    QDir().rmdir(directory);
    return !QFileInfo::exists(directory);
}

#endif // Q_OS_WIN

} // namespace caelestia::shell::dragfile
