import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Windows as Native
import qs.services
import qs.utils

// The Windows shell replaces upstream services/Wallpapers.qml with the adapter
// in windows/shell/adapters. Upstream registers the `wallpaper` IPC target, so
// the adapter must keep it: get() returns the current source, list() returns
// the scanned paths, and set(path) applies a pick through setWallpaper().
//
// This offscreen runner has no Quickshell IPC registry. IpcTargets is the
// recording stand-in: it registers the production adapter's IpcHandler by its
// target and invokes the same function names and arguments a `qs ipc call`
// client reaches. The native facade is faked, so no Windows wallpaper changes.
QtObject {
    id: root

    readonly property string recordPath: Paths.state + "/wallpaper/desktop.json"

    property int assertions: 0
    function check(value, description): void {
        assertions++;
        if (!value)
            throw new Error(description);
    }
    function call(name, args): var {
        return IpcTargets.call("wallpaper", name, args);
    }
    function record(): var {
        return JSON.parse(Files.contents[root.recordPath] ?? "{}");
    }

    Component.onCompleted: Qt.callLater(run)

    function run(): void {
        try {
            // A fresh profile: no provenance marker and no earlier Caelestia
            // state. Only the local scan and the native facade are synthetic.
            Native.FsUtils.existingFiles = ["C:/fixture/assets/wallpaper.webp", "C:/walls/one.png",
                "C:/walls/two.jpg", "C:/walls/picked.jpg", "C:/walls/picked2.jpg"];
            Quickshell.screens = [{name: "primary"}];
            WallpaperEngine.options = {};
            Wallpapers.files = [];

            // 1. The adapter registers the same target as upstream, with the
            // same function names and arity.
            check(IpcTargets.has("wallpaper"), "the wallpaper IPC target is not registered");
            const handler = IpcTargets.find("wallpaper");
            check(handler !== null && handler.target === "wallpaper", "the registered target is not wallpaper");
            check(typeof handler.get === "function" && handler.get.length === 0, "get() is missing or takes arguments");
            check(typeof handler.set === "function" && handler.set.length === 1, "set(path) is missing or has the wrong arity");
            check(typeof handler.list === "function" && handler.list.length === 0, "list() is missing or takes arguments");

            // 2. get() and list() read the adapter's existing state. A fresh
            // profile starts on the bundled asset and an empty scan is empty.
            check(Wallpapers.sourceFresh, "the fixture profile is not fresh");
            check(call("get") === Wallpapers.fallback, "get() did not return the bundled fresh-profile asset");
            check(call("list") === "", "list() returned entries for an empty scan");

            Wallpapers.files = [
                {path: "C:/walls/one.png", relativePath: "one.png", name: "one.png", parentDir: "C:/walls", onDisk: true},
                {path: "C:/walls/two.jpg", relativePath: "two.jpg", name: "two.jpg", parentDir: "C:/walls", onDisk: true}
            ];
            check(call("list") === "C:/walls/one.png\nC:/walls/two.jpg",
                "list() did not return the scanned paths joined by newlines");
            // Upstream lists the scan. An engine picker adds project entries
            // to the picker list, not to the scanned paths.
            WallpaperEngine.detected = true;
            WallpaperEngine.items = [{path: "C:/we/project.json", preview: "C:/we/preview.jpg"}];
            WallpaperEngine.options = {enabled: true, picker: "engine"};
            check(call("list") === "C:/walls/one.png\nC:/walls/two.jpg",
                "list() returned Wallpaper Engine projects instead of the scanned paths");
            WallpaperEngine.options = {};
            WallpaperEngine.items = [];
            WallpaperEngine.detected = false;
            check(call("get") === Wallpapers.actualCurrent, "get() disagrees with actualCurrent");

            // 3. set(path) is the picker path: the native facade is called,
            // the pick is recorded on a fresh profile, and the visible source
            // and get() follow it.
            check(call("set", ["C:/walls/picked.jpg"]) === undefined, "set(path) did not return void");
            check(Native.Wallpaper.calls.length === 1 && Native.Wallpaper.calls[0] === "C:/walls/picked.jpg",
                "set(path) did not apply the image through the native facade");
            check(Native.Wallpaper.screenCalls.length === 0, "set(path) targeted one display instead of the profile");
            check(Wallpapers.profilePick === "C:/walls/picked.jpg", "set(path) did not record the fresh-profile pick");
            check(Wallpapers.current === "C:/walls/picked.jpg", "set(path) did not change the visible wallpaper");
            check(call("get") === "C:/walls/picked.jpg", "get() did not follow set(path)");
            check(call("list") === "C:/walls/one.png\nC:/walls/two.jpg", "set(path) changed the scanned list");
            check(root.record().version === 1 && root.record().wallpaper === "C:/walls/picked.jpg",
                "set(path) did not persist the pick record");
            check(Toaster.calls.some(toast => toast.icon === "wallpaper"),
                "set(path) bypassed the picker's notification path");

            // 4. A second call replaces the pick through the same path, and
            // the IPC surface never grows a second setter.
            check(call("set", ["C:/walls/picked2.jpg"]) === undefined, "a second set(path) did not return void");
            check(Native.Wallpaper.calls.length === 2 && Native.Wallpaper.calls[1] === "C:/walls/picked2.jpg",
                "a second set(path) did not apply the image");
            check(call("get") === "C:/walls/picked2.jpg", "get() did not follow a second set(path)");
            check(root.record().wallpaper === "C:/walls/picked2.jpg", "a second set(path) did not replace the record");

            console.log("CAELESTIA_WALLPAPER_IPC_PASS " + assertions);
            Qt.quit();
        } catch (error) {
            console.error("CAELESTIA_WALLPAPER_IPC_FAIL " + error);
            Qt.exit(1);
        }
    }
}
