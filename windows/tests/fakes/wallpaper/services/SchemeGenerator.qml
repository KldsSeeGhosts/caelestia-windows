pragma Singleton
import QtQuick
import Quickshell.Io
import qs.utils
QtObject {
    property bool available: true
    property var calls: []
    property int runs: 0
    property var pendingWallpaper: null
    property var previewCalls: []
    signal schemeChanged(var data)
    signal schemeListChanged()
    signal previewReady(int request, var data)
    function refresh(): void {}
    function setScheme(name, image): void {
        runs++;
        Files.contents = {
            [Paths.state + "/scheme.json"]: JSON.stringify({name}),
            [Paths.state + "/wallpaper/path.txt"]: image
        };
        schemeChanged({name, source: image});
    }
    function applyWallpaper(path, smart): void {
        calls.push({path, smart});
        setScheme("dynamic", path);
    }
    function wallpaperRequest(): var { return pendingWallpaper; }
    function previewWallpaper(path, smart, request): void {
        previewCalls = previewCalls.concat([{path, smart, request}]);
    }
    function cancelPreview(): void {}
}
