#pragma once

#include <qdir.h>
#include <qregularexpression.h>
#include <qstring.h>

#include <shlobj.h>

namespace caelestia::shell::windows {

// Normalise a folder path to forward slashes without trailing separators. A
// drive root (X:/) and a UNC share root (//server/share/) keep exactly one,
// because "X:" names the current directory of that drive, not its root.
inline QString normalizeFolderPath(const QString& input) {
    auto path = QDir::fromNativeSeparators(input.trimmed());

    static const QRegularExpression root(QStringLiteral("^(?:[A-Za-z]:|//[^/]+/[^/]+)/+$"));
    if (root.match(path).hasMatch()) {
        while (path.endsWith(u'/'))
            path.chop(1);
        return path + u'/';
    }

    while (path.endsWith(u'/'))
        path.chop(1);
    return path;
}

// Resolve a Windows known folder so redirected folders (OneDrive folder backup
// or Folder Properties) are found where Windows actually keeps them. An
// explicit path from the user's config always wins over the system default.
// KF_FLAG_DONT_VERIFY keeps an offline redirected folder resolvable.
inline QString resolveKnownFolder(REFKNOWNFOLDERID id, const QString& overridePath = {}) {
    if (!overridePath.trimmed().isEmpty())
        return normalizeFolderPath(overridePath);

    // The caller must free the shell buffer, including when the call fails.
    struct CoTaskMemBuffer {
        PWSTR value = nullptr;

        ~CoTaskMemBuffer() { CoTaskMemFree(value); }
    } buffer;

    if (FAILED(SHGetKnownFolderPath(id, KF_FLAG_DONT_VERIFY, nullptr, &buffer.value)) || buffer.value == nullptr) {
        return {};
    }
    return normalizeFolderPath(QString::fromWCharArray(buffer.value));
}

// True when the folder directly contains a file with a wallpaper extension (the
// same set the wallpaper scanner accepts, matched case-insensitively). It is
// not recursive and a folder named like an image does not count. The scan stops
// at the first image.
//
// The enumeration is blocking and may stall on an unavailable network share, so
// callers run it off the GUI thread. FIND_FIRST_EX_ON_DISK_ENTRIES_ONLY keeps
// it from asking a cloud provider (OneDrive) to populate a placeholder folder,
// and FindExInfoBasic skips the short-name lookup.
inline bool folderContainsImages(const QString& path) {
    if (path.trimmed().isEmpty())
        return false;

    auto pattern = QDir::toNativeSeparators(path);
    if (!pattern.endsWith(u'\\'))
        pattern += u'\\';
    pattern += u'*';

    WIN32_FIND_DATAW data;
    const HANDLE find = FindFirstFileExW(reinterpret_cast<LPCWSTR>(pattern.utf16()), FindExInfoBasic, &data,
        FindExSearchNameMatch, nullptr, FIND_FIRST_EX_ON_DISK_ENTRIES_ONLY);
    if (find == INVALID_HANDLE_VALUE)
        return false;

    bool found = false;
    do {
        if (data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)
            continue;
        const auto name = QString::fromWCharArray(data.cFileName);
        const auto dot = name.lastIndexOf(u'.');
        if (dot < 0)
            continue;
        const auto suffix = QStringView(name).mid(dot + 1);
        found = suffix.compare(u"png", Qt::CaseInsensitive) == 0 || suffix.compare(u"jpg", Qt::CaseInsensitive) == 0
            || suffix.compare(u"jpeg", Qt::CaseInsensitive) == 0 || suffix.compare(u"bmp", Qt::CaseInsensitive) == 0
            || suffix.compare(u"webp", Qt::CaseInsensitive) == 0;
    } while (!found && FindNextFileW(find, &data));

    FindClose(find);
    return found;
}

} // namespace caelestia::shell::windows
