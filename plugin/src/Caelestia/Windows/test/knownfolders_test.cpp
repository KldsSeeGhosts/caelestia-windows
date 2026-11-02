#include <qdir.h>
#include <qfileinfo.h>
#include <qstring.h>
#include <qtemporarydir.h>
#include <qtest.h>

#include <shlobj.h>

#include "../knownfolders.hpp"

namespace {

QString apiPath(REFKNOWNFOLDERID id) {
    PWSTR raw = nullptr;
    if (FAILED(SHGetKnownFolderPath(id, KF_FLAG_DONT_VERIFY, nullptr, &raw)) || raw == nullptr)
        return {};
    auto path = QDir::fromNativeSeparators(QString::fromWCharArray(raw));
    CoTaskMemFree(raw);
    return path;
}

} // namespace

class KnownFoldersTest: public QObject {
    Q_OBJECT

private slots:
    void picturesAndVideosMatchKnownFolderApi() {
        const auto pictures = apiPath(FOLDERID_Pictures);
        const auto videos = apiPath(FOLDERID_Videos);
        QVERIFY2(!pictures.isEmpty(), "Pictures Known Folder did not resolve");
        QVERIFY2(!videos.isEmpty(), "Videos Known Folder did not resolve");

        caelestia::shell::windows::KnownFolders folders;
        QVERIFY2(folders.pictures() == pictures, "Pictures does not come from SHGetKnownFolderPath");
        QVERIFY2(folders.videos() == videos, "Videos does not come from SHGetKnownFolderPath");
        QVERIFY2(QFileInfo(folders.pictures()).isAbsolute(), "Pictures is not an absolute path");
        QVERIFY2(QFileInfo(folders.videos()).isAbsolute(), "Videos is not an absolute path");
    }

    void startMenuMatchesKnownFolderApi() {
        const auto programs = apiPath(FOLDERID_Programs);
        const auto commonPrograms = apiPath(FOLDERID_CommonPrograms);
        QVERIFY2(!programs.isEmpty(), "Programs Known Folder did not resolve");
        QVERIFY2(!commonPrograms.isEmpty(), "CommonPrograms Known Folder did not resolve");

        caelestia::shell::windows::KnownFolders folders;
        QVERIFY2(folders.programs() == programs, "Programs does not come from SHGetKnownFolderPath");
        QVERIFY2(
            folders.commonPrograms() == commonPrograms,
            "CommonPrograms does not come from SHGetKnownFolderPath"
        );
    }

    void auditedFoldersMatchKnownFolderApi() {
        caelestia::shell::windows::KnownFolders folders;
        QVERIFY2(folders.desktop() == apiPath(FOLDERID_Desktop), "Desktop does not come from SHGetKnownFolderPath");
        QVERIFY2(
            folders.documents() == apiPath(FOLDERID_Documents),
            "Documents does not come from SHGetKnownFolderPath"
        );
        QVERIFY2(
            folders.downloads() == apiPath(FOLDERID_Downloads),
            "Downloads does not come from SHGetKnownFolderPath"
        );
        QVERIFY2(folders.music() == apiPath(FOLDERID_Music), "Music does not come from SHGetKnownFolderPath");
    }

    void explicitOverrideWins() {
        QTemporaryDir dir;
        QVERIFY(dir.isValid());
        const auto configured = QDir::fromNativeSeparators(dir.path());
        QVERIFY2(configured != apiPath(FOLDERID_Pictures), "the override does not differ from the system default");

        using caelestia::shell::windows::resolveKnownFolder;
        QVERIFY2(
            resolveKnownFolder(FOLDERID_Pictures, configured) == configured,
            "a configured path did not win over the Known Folder"
        );
        QVERIFY2(
            resolveKnownFolder(FOLDERID_Pictures, QDir::toNativeSeparators(dir.path())) == configured,
            "a native configured path did not win over the Known Folder"
        );
        QVERIFY2(
            resolveKnownFolder(FOLDERID_Pictures, configured + u'/') == configured,
            "a trailing slash was not normalized"
        );
        QVERIFY2(
            resolveKnownFolder(FOLDERID_Pictures) == apiPath(FOLDERID_Pictures),
            "an absent override did not fall back to the Known Folder"
        );
    }
};

QTEST_GUILESS_MAIN(KnownFoldersTest)

#include "knownfolders_test.moc"
