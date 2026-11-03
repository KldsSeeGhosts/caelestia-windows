import QtQuick
import Quickshell
import Caelestia.Config
import Caelestia.Windows
import qs.utils

// Offscreen check of the QML contract: Paths reads the Known Folder exposed by
// the plugin, the wallpaper upgrade rule preserves the old profile folder and
// is resolved from background probe answers, and drive and share roots survive
// normalisation.
ShellRoot {
    id: root

    property int assertions: 0
    property int wallsdirChanges: 0
    property var answers: ({})
    property int expectedAnswers: 0
    readonly property string fixtures: Quickshell.env("CAELESTIA_KNOWN_FOLDERS_FIXTURE_ROOT") || ""

    function check(value, description): void {
        assertions++;
        if (!value)
            throw new Error(description);
    }

    function finish(passed, message): void {
        console.log(passed ? "CAELESTIA_KNOWN_FOLDERS_PASS " + assertions : "CAELESTIA_KNOWN_FOLDERS_FAIL " + message);
        if (passed)
            Qt.quit();
        else
            Qt.exit(1);
    }

    function syncChecks(): void {
        check(KnownFolders.pictures.length > 0, "Pictures Known Folder is empty");
        check(Paths.pictures === KnownFolders.pictures, "Paths.pictures does not use the Known Folder");
        check(Paths.videos === KnownFolders.videos, "Paths.videos does not use the Known Folder");

        // Explicit shell.json override wins over the Known Folder.
        GlobalConfig.paths.wallpaperDir = "C:/caelestia-known-folders-test";
        check(Paths.wallsdir === "C:/caelestia-known-folders-test", "configured wallpaperDir did not win");
        GlobalConfig.paths.wallpaperDir = "";

        // A documented ~ path expands instead of being treated literally.
        check(Paths.expandPath("~/Pictures/Wallpapers") === Paths.home + "/Pictures/Wallpapers", "~ did not expand");

        check(root.fixtures.length > 0, "fixture root is missing");
        const knownWith = Paths.normalizePath(root.fixtures + "/known-with");
        const knownEmpty = Paths.normalizePath(root.fixtures + "/known-empty");
        const legacyWith = Paths.normalizePath(root.fixtures + "/legacy-with");
        const legacyEmpty = Paths.normalizePath(root.fixtures + "/legacy-empty");
        const knownWalls = Paths.folderKey(knownWith + "/Wallpapers");
        const legacyWalls = Paths.folderKey(legacyWith + "/Wallpapers");
        const emptyKnownWalls = Paths.folderKey(knownEmpty + "/Wallpapers");

        // 1. The Known Folder wins when it holds images.
        check(Paths.resolveWallpapersDir(knownWith, legacyWith, "", "", { [knownWalls]: true, [legacyWalls]: true }) === knownWith + "/Wallpapers",
            "Known Folder wallpapers were not preferred");

        // 2. An empty Known Folder falls back to the old profile folder.
        check(Paths.resolveWallpapersDir(knownEmpty, legacyWith, "", "", { [emptyKnownWalls]: false, [legacyWalls]: true }) === legacyWith + "/Wallpapers",
            "legacy wallpapers were not found after the upgrade");

        // 3. Neither folder has images: use the new default.
        check(Paths.resolveWallpapersDir(knownEmpty, legacyEmpty, "", "", { [emptyKnownWalls]: false, [Paths.folderKey(legacyEmpty + "/Wallpapers")]: false }) === knownEmpty + "/Wallpapers",
            "new default folder was not used");

        // Until a probe answers, the Known Folder is the answer, and a quick
        // legacy answer cannot switch folders before the Known Folder's.
        check(Paths.resolveWallpapersDir(knownEmpty, legacyWith, "", "", {}) === knownEmpty + "/Wallpapers",
            "an unanswered probe did not resolve to the Known Folder");
        check(Paths.resolveWallpapersDir(knownEmpty, legacyWith, "", "", { [legacyWalls]: true }) === knownEmpty + "/Wallpapers",
            "the legacy folder won before the Known Folder answered");

        // No redirection: the Known Folder is the legacy folder, so the answer
        // needs no probe at all.
        check(Paths.wallpaperProbeTargets(knownWith, knownWith, "", "").length === 0, "an unredirected Pictures folder asked for probes");
        check(Paths.resolveWallpapersDir(knownWith, knownWith, "", "", {}) === knownWith + "/Wallpapers",
            "an unredirected Pictures folder did not settle at once");
        check(Paths.wallpaperProbeTargets(knownEmpty, legacyWith, "", "").length === 2, "a redirected Pictures folder did not ask for probes");

        // 4. An explicit path wins even when both defaults have images, and
        // needs no probe.
        check(Paths.resolveWallpapersDir(knownWith, legacyWith, "C:/explicit/walls", "", {}) === "C:/explicit/walls",
            "explicit wallpaperDir did not win");
        check(Paths.wallpaperProbeTargets(knownWith, legacyWith, "C:/explicit/walls", "").length === 0, "an explicit path asked for probes");

        // 5. The environment override wins over everything.
        check(Paths.resolveWallpapersDir(knownWith, legacyWith, "C:/explicit/walls", "D:/env/walls", {}) === "D:/env/walls",
            "environment wallpaperDir did not win");
        check(Paths.wallpaperProbeTargets(knownWith, legacyWith, "", "D:/env/walls").length === 0, "an environment path asked for probes");

        // 6. The old built-in default serialized into shell.json is not an
        // override; the legacy folder still rescues the wallpapers.
        const oldDefault = (knownEmpty + "/Wallpapers").replace(/\//g, "\\").toUpperCase() + "\\";
        check(Paths.resolveWallpapersDir(knownEmpty, legacyWith, oldDefault, "", { [emptyKnownWalls]: false, [legacyWalls]: true }) === legacyWith + "/Wallpapers",
            "old built-in default was treated as an override");

        // Drive and share roots keep their separator; everything else loses it.
        check(Paths.normalizePath("D:/") === "D:/", "drive root lost its separator");
        check(Paths.normalizePath("D:\\") === "D:/", "native drive root lost its separator");
        check(Paths.normalizePath("D:/walls/") === "D:/walls", "drive folder kept its separator");
        check(Paths.normalizePath("\\\\server\\share\\") === "//server/share/", "share root lost its separator");
        check(Paths.normalizePath("//server/share/walls//") === "//server/share/walls", "share folder kept its separator");
        check(Paths.resolveWallpapersDir(knownWith, legacyWith, "D:/", "", {}) === "D:/", "explicit drive root was altered");
        check(Paths.resolveWallpapersDir(knownWith, legacyWith, "D:\\", "", {}) === "D:/", "explicit native drive root was altered");
        check(Paths.resolveWallpapersDir(knownWith, legacyWith, "", "D:/", {}) === "D:/", "environment drive root was altered");
        check(Paths.resolveWallpapersDir(knownWith, legacyWith, "//server/share/", "", {}) === "//server/share/", "explicit share root was altered");
        check(Paths.joinPath("D:/", "a.png") === "D:/a.png", "joining under a drive root doubled the separator");
        check(Paths.joinPath("D:/walls", "a.png") === "D:/walls/a.png", "joining under a folder lost the separator");
        check(Paths.joinPath("", "a.png") === "a.png", "joining under an empty folder produced a rooted path");
        check(Paths.joinPath("D:", "a.png") === "D:a.png", "joining under a drive-relative folder added a separator");
        check(Paths.joinPath("/", "a.png") === "/a.png", "joining under the root doubled the separator");
        check(Paths.normalizePath("/") === "/", "a bare separator was trimmed away");
        check(Paths.normalizePath("D:") === "D:", "a drive-relative path was altered");
        check(Paths.resolveWallpapersDir("D:/", "D:/", "", "", {}) === "D:/Wallpapers", "a drive-root Pictures folder doubled the separator");
    }

    // The probe delivers its answers on the GUI thread after this returns.
    function probeChecks(): void {
        const withImages = Paths.normalizePath(root.fixtures + "/known-with/Wallpapers");
        const emptyFolder = Paths.normalizePath(root.fixtures + "/known-empty/Wallpapers");
        const nested = Paths.normalizePath(root.fixtures + "/nested-only/Wallpapers");
        const missing = Paths.normalizePath(root.fixtures + "/missing/Wallpapers");

        // The sync checks above changed the configuration on purpose.
        wallsdirChanges = 0;
        expectedAnswers = 4;
        KnownFolders.imagesProbed.connect((path, found) => {
            root.answers[Paths.folderKey(path)] = found;
            if (--root.expectedAnswers > 0)
                return;
            try {
                check(root.answers[Paths.folderKey(withImages)] === true, "a folder with an image was not reported");
                check(root.answers[Paths.folderKey(emptyFolder)] === false, "an empty folder was reported as having images");
                check(root.answers[Paths.folderKey(nested)] === false, "a nested image or image-named folder was reported");
                check(root.answers[Paths.folderKey(missing)] === false, "a missing folder was reported as having images");
                // The singleton settles at most once on its own: a redirected
                // Pictures folder with wallpapers only in the legacy folder
                // changes wallsdir one time, and everything else never does.
                check(root.wallsdirChanges <= 1, "wallsdir changed " + root.wallsdirChanges + " times");
                finish(true, "");
            } catch (e) {
                finish(false, e.message);
            }
        });
        // The call returns before any answer.
        KnownFolders.probeImages(withImages);
        KnownFolders.probeImages(emptyFolder);
        KnownFolders.probeImages(nested);
        KnownFolders.probeImages(missing);
        check(Object.keys(root.answers).length === 0, "probeImages answered synchronously");
    }

    Connections {
        target: Paths
        function onWallsdirChanged(): void {
            root.wallsdirChanges++;
        }
    }

    Component.onCompleted: {
        try {
            syncChecks();
            probeChecks();
        } catch (e) {
            finish(false, e.message);
        }
    }
}
