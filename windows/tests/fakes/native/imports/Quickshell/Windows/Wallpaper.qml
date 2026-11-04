pragma Singleton
import QtQuick
QtObject {
    property string currentPath: "C:/walls/windows-default.jpg"
    property var calls: []
    function currentWallpaper(): string { return currentPath; }
    function setWallpaper(path, ignored): bool {
        calls.push(path);
        currentPath = path;
        return true;
    }
}
