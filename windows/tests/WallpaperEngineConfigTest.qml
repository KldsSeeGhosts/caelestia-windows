import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Windows as Native
import qs.services
import qs.utils

// A watcher reload of windows.json may read a document another writer is
// replacing (partial JSON) or fail on a transient lock. Neither is evidence
// that the profile opted out: the last successfully loaded document and
// options must stay, because unlocking the file may not raise another change
// event. A missing key still defaults to off, and a missing file clears the
// saved value. The fake FileView queues watcher reloads so the native
// asynchronous delivery is what the fixture exercises.
QtObject {
    id: root

    readonly property string configPath: Quickshell.env("CAELESTIA_CONFIG_DIR") + "/windows.json"

    property int assertions: 0
    function check(value, description): void {
        assertions++;
        if (!value)
            throw new Error(description);
    }
    function guard(step): void {
        try {
            step();
        } catch (error) {
            console.error("CAELESTIA_WALLPAPER_ENGINE_CONFIG_FAIL " + error);
            Qt.exit(1);
        }
    }
    function reload(): void {
        Files.deferReloads = true;
        Files.changed(root.configPath);
        Files.deferReloads = false;
        Files.flushReloads();
    }

    // The saved document the profile starts with. Seeding the fake before the
    // producers exist is the state the real view first reads.
    property bool seeded: {
        Native.FsUtils.existingFiles = ["C:/fixture/assets/wallpaper.webp",
            "C:/walls/windows-default.jpg", root.configPath];
        Quickshell.screens = [{name: "primary"}];
        Files.contents[root.configPath] = JSON.stringify({
            windows: {
                hideTaskbar: true,
                wallpaperEngine: {enabled: true, picker: "both", monitor: "Monitor1"}
            }
        });
        return true;
    }

    Component.onCompleted: Qt.callLater(run)

    function run(): void {
        guard(function() {
            check(WallpaperEngine.enabled, "the saved opt-in was not loaded");
            check(WallpaperEngine.options.picker === "both", "the saved picker was not loaded");
            check(WallpaperEngine.configDocument.windows?.hideTaskbar === true,
                "the saved document was not loaded");

            // 1. A watcher reload that reads malformed JSON is a writer's
            // partial document, not a saved value. The integration stays on
            // and the last good document stays in memory. No further change
            // event is needed to recover.
            Files.contents[root.configPath] = "{\"windows\":{\"wallpaperEngine\":{\"enabled\":true,";
            root.reload();
            check(WallpaperEngine.enabled, "a malformed watcher read disabled the saved setting");
            check(WallpaperEngine.options.picker === "both",
                "a malformed watcher read replaced the saved options");
            check(WallpaperEngine.configDocument.windows?.hideTaskbar === true,
                "a malformed watcher read replaced the last good document");
            check(WallpaperEngine.lastError !== "", "a malformed watcher read was not reported");
            WallpaperEngine.lastError = "";

            // A later readable document is still applied normally.
            const readable = {
                windows: {
                    hideTaskbar: false,
                    wallpaperEngine: {enabled: true, picker: "files", monitor: "Monitor0"}
                }
            };
            Files.contents[root.configPath] = JSON.stringify(readable);
            root.reload();
            check(WallpaperEngine.enabled, "the recovered document did not stay on");
            check(WallpaperEngine.options.picker === "files",
                "the recovered document was not applied");
            check(WallpaperEngine.configDocument.windows?.hideTaskbar === false,
                "the recovered document did not replace the last good one");
            WallpaperEngine.lastError = "";

            // 2. A read failure on an existing file is transient. The value on
            // disk looks off, but it was never read, so the last loaded
            // options stay on and the failed content is not adopted.
            Files.contents[root.configPath] = JSON.stringify({
                windows: {wallpaperEngine: {enabled: false, picker: "both"}}
            });
            Files.unreadable[root.configPath] = FileViewError.PermissionDenied;
            root.reload();
            delete Files.unreadable[root.configPath];
            check(WallpaperEngine.enabled, "a read failure disabled the saved setting");
            check(WallpaperEngine.options.picker === "files",
                "a read failure replaced the saved options");
            check(WallpaperEngine.configDocument.windows?.hideTaskbar === false,
                "a read failure replaced the last good document");
            check(WallpaperEngine.lastError !== "", "a read failure was not reported");
            WallpaperEngine.lastError = "";

            // 3. A successfully loaded document without the key still means
            // off. Only failures preserve the previous setting.
            Files.contents[root.configPath] = JSON.stringify({windows: {hideTaskbar: true}});
            root.reload();
            check(!WallpaperEngine.enabled, "a missing enabled key did not default off");
            check(WallpaperEngine.options.enabled === undefined,
                "a missing enabled key kept the previous value");

            // 4. A missing sidecar clears the saved setting. A later readable
            // document opts in again.
            Files.contents[root.configPath] = JSON.stringify({
                windows: {wallpaperEngine: {enabled: true, picker: "both"}}
            });
            root.reload();
            check(WallpaperEngine.enabled, "a later readable document was not applied");
            delete Files.contents[root.configPath];
            root.reload();
            check(!WallpaperEngine.enabled, "a missing sidecar kept the integration on");

            root.finish();
        });
    }

    function finish(): void {
        console.log("CAELESTIA_WALLPAPER_ENGINE_CONFIG_PASS " + assertions);
        Qt.quit();
    }
}
