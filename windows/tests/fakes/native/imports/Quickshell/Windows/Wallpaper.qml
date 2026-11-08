pragma Singleton
import QtQuick
QtObject {
    property string currentPath: "C:/walls/windows-default.jpg"
    property var calls: []
    property var screenIds: ({primary: "primary-id", secondary: "secondary-id"})
    property var screenPaths: ({primary: "C:/walls/primary.jpg", secondary: "C:/walls/secondary.jpg"})
    property var screenCalls: []
    function currentWallpaper(): string { return currentPath; }
    function screenTargetId(name): string { return screenIds[name] || ""; }
    function currentWallpaperForScreen(name): string { return screenPaths[name] || ""; }
    function setWallpaperForScreen(path, name): bool {
        if (!screenTargetId(name))
            return false;
        screenCalls = screenCalls.concat([{path: path, screen: name}]);
        screenPaths = Object.assign({}, screenPaths, {[name]: path});
        return true;
    }
    function setWallpaper(path, ignored): bool {
        calls.push(path);
        currentPath = path;
        // IDesktopWallpaper::SetWallpaper(nullptr) applies to every monitor.
        const next = {};
        for (const name of Object.keys(screenPaths))
            next[name] = path;
        screenPaths = next;
        return true;
    }
}
