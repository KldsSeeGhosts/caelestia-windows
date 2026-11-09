#include "dragfile.hpp"

#include <qdir.h>
#include <qfile.h>
#include <qfileinfo.h>
#include <qloggingcategory.h>
#include <qregularexpression.h>
#include <quuid.h>

#ifdef Q_OS_WIN
#include <qt_windows.h>
#endif

namespace {

Q_LOGGING_CATEGORY(lcDragFile, "caelestia.dragfile", QtInfoMsg)

constexpr auto dirPrefix = "caelestia-drag-";
constexpr int maxNameLength = 120;

enum class Kind { Missing, Reparse, Directory, File, Other, Unknown };

// What `path` is, without following a link. Anything that cannot be inspected is
// Unknown, which callers treat as a refusal.
Kind inspect(const QString& path) {
#ifdef Q_OS_WIN
    const auto attributes = GetFileAttributesW(reinterpret_cast<LPCWSTR>(QDir::toNativeSeparators(path).utf16()));
    if (attributes == INVALID_FILE_ATTRIBUTES) {
        const auto error = GetLastError();
        return error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND ? Kind::Missing : Kind::Unknown;
    }
    if (attributes & FILE_ATTRIBUTE_REPARSE_POINT)
        return Kind::Reparse;
    return (attributes & FILE_ATTRIBUTE_DIRECTORY) ? Kind::Directory : Kind::File;
#else
    const QFileInfo info(path);
    if (info.isSymLink())
        return Kind::Reparse;
    if (!info.exists())
        return Kind::Missing;
    if (info.isDir())
        return Kind::Directory;
    return info.isFile() ? Kind::File : Kind::Other;
#endif
}

QString withoutTrailingSlash(QString root) {
    while (root.size() > 1 && root.endsWith(QLatin1Char('/')))
        root.chop(1);
    return root;
}

bool sameName(const QString& a, const QString& b) {
#ifdef Q_OS_WIN
    return a.compare(b, Qt::CaseInsensitive) == 0;
#else
    return a == b;
#endif
}

const QRegularExpression& dirName() {
    static const QRegularExpression name(QStringLiteral("^([0-9a-f]{32})/([^/\\\\]+)\\z"));
    return name;
}

} // namespace

namespace caelestia::shell::dragfile {

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

QString create(const QString& root, const QString& name) {
    if (!validName(name)) {
        qCWarning(lcDragFile) << "create: not a usable file name" << name;
        return {};
    }

    const auto base = withoutTrailingSlash(root);
    if (base.isEmpty() || inspect(base) != Kind::Directory) {
        qCWarning(lcDragFile) << "create: the temp directory is not usable" << root;
        return {};
    }

    // A random 128-bit name, and mkdir fails when it exists, so a directory of
    // another card, reload or process can never be reused.
    for (int attempt = 0; attempt < 4; attempt++) {
        const auto directory = base + QLatin1Char('/') + QLatin1String(dirPrefix)
            + QUuid::createUuid().toString(QUuid::Id128);
        if (!QDir().mkdir(directory))
            continue;

        const auto path = directory + QLatin1Char('/') + name;
        if (inspect(directory) == Kind::Directory) {
            QFile file(path);
            if (file.open(QIODevice::WriteOnly | QIODevice::NewOnly)) {
                file.close();
                if (inspect(path) == Kind::File)
                    return path;
            }
        }

        // Undo only what this call made.
        QFile::remove(path);
        QDir().rmdir(directory);
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

    switch (inspect(directory)) {
    case Kind::Missing:
        return true;
    case Kind::Directory:
        break;
    default:
        qCWarning(lcDragFile) << "remove: not a plain directory" << directory;
        return false;
    }

    // At most the one expected file. Hidden and system entries count too.
    const auto entries =
        QDir(directory).entryList(QDir::AllEntries | QDir::NoDotAndDotDot | QDir::Hidden | QDir::System);
    if (entries.size() > 1 || (entries.size() == 1 && !sameName(entries.constFirst(), name))) {
        qCWarning(lcDragFile) << "remove: the directory holds something else" << directory;
        return false;
    }

    if (entries.size() == 1) {
        if (inspect(path) != Kind::File) {
            qCWarning(lcDragFile) << "remove: not a regular file" << path;
            return false;
        }
        if (!QFile::remove(path))
            return false;
    }

    // rmdir never removes a directory that still has entries.
    QDir().rmdir(directory);
    return inspect(directory) == Kind::Missing;
}

} // namespace caelestia::shell::dragfile
