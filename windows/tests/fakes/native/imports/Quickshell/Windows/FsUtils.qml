pragma Singleton
import QtQuick
QtObject {
    property var existingFiles: ["C:/fixture/assets/wallpaper.webp", "C:/walls/windows-default.jpg"]
    property int requests: 0
    property var madePaths: []
    signal listDirFinished(int request, string path, var entries)
    function classify(path): string { return existingFiles.includes(String(path).replace(/\\/g, "/")) ? "file" : "invalid"; }
    function makePath(path): bool { madePaths = madePaths.concat([String(path)]); return true; }
    function listDirAsync(path): int { return ++requests; }
}
