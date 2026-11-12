pragma Singleton
import QtQuick
QtObject {
    property var existingFiles: ["C:/fixture/assets/wallpaper.webp", "C:/walls/windows-default.jpg"]
    property var existingDirs: []
    property int requests: 0
    property int makePathCalls: 0
    signal listDirFinished(int request, string path, var entries)
    function canonicalPath(path): string { return String(path).replace(/\\/g, "/"); }
    function classify(path): string {
        const value = String(path).replace(/\\/g, "/");
        if (existingDirs.includes(value))
            return "dir";
        return existingFiles.includes(value) ? "file" : "invalid";
    }
    function makePath(path): bool {
        makePathCalls++;
        const value = String(path).replace(/\\/g, "/");
        if (!existingDirs.includes(value))
            existingDirs = existingDirs.concat([value]);
        return true;
    }
    function listDirAsync(path): int { return ++requests; }
}
