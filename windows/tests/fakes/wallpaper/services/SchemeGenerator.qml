pragma Singleton
import QtQuick
import Quickshell.Io
import qs.utils
QtObject {
    property bool available: true
    property var calls: []
    property int runs: 0
    signal schemeChanged()
    signal schemeListChanged()
    function setScheme(name, image): void {
        runs++;
        Files.contents = {
            [Paths.state + "/scheme.json"]: JSON.stringify({name}),
            [Paths.state + "/wallpaper/path.txt"]: image
        };
        schemeChanged();
    }
    function applyWallpaper(path, smart): void {
        calls.push({path, smart});
        setScheme("dynamic", path);
    }
}
