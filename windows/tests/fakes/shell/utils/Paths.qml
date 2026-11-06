pragma Singleton
import QtQuick
QtObject {
    property string state: "C:/fixture/state"
    property string wallsdir: "C:/walls"
    function samePath(a, b): bool {
        return String(a ?? "").replace(/\\/g, "/").toLowerCase() === String(b ?? "").replace(/\\/g, "/").toLowerCase();
    }
    function joinPath(a, b): string { return a + "/" + b; }
}
