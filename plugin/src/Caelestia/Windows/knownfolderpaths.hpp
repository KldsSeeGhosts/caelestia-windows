#pragma once

#include <qdir.h>
#include <qstring.h>

#include <shlobj.h>

namespace caelestia::shell::windows {

// Resolve a Windows known folder so redirected folders (OneDrive folder backup
// or Folder Properties) are found where Windows actually keeps them. An
// explicit path from the user's config always wins over the system default.
// KF_FLAG_DONT_VERIFY keeps an offline redirected folder resolvable.
inline QString resolveKnownFolder(REFKNOWNFOLDERID id, const QString& overridePath = {}) {
    auto path = overridePath.trimmed();
    if (!path.isEmpty()) {
        path = QDir::fromNativeSeparators(path);
    } else {
        // The caller must free the shell buffer, including when the call fails.
        struct CoTaskMemBuffer {
            PWSTR value = nullptr;

            ~CoTaskMemBuffer() { CoTaskMemFree(value); }
        } buffer;

        if (FAILED(SHGetKnownFolderPath(id, KF_FLAG_DONT_VERIFY, nullptr, &buffer.value)) || buffer.value == nullptr) {
            return {};
        }
        path = QDir::fromNativeSeparators(QString::fromWCharArray(buffer.value));
    }

    while (path.size() > 3 && path.endsWith(u'/'))
        path.chop(1);
    return path;
}

} // namespace caelestia::shell::windows
