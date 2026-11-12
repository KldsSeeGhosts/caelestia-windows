pragma Singleton
import QtQuick
QtObject {
    property string currentPath: "C:/walls/windows-default.jpg"
    property var calls: []
    property var screenIds: ({primary: "primary-id", secondary: "secondary-id"})
    property var screenPaths: ({primary: "C:/walls/primary.jpg", secondary: "C:/walls/secondary.jpg"})
    property var screenCalls: []
    property bool asyncOperations: false
    property int generation: 1
    property int nextOperation: 0
    property var pending: []
    property var delayed: []
    // Both generations mutate these same OS paths. Retirement suppresses
    // results, but cannot cancel an execute call already inside the provider.
    signal wallpaperOperationFinished(string operation, string path, string target, bool ok, string reason)
    function currentWallpaper(): string { return currentPath; }
    function screenTargetId(name): string { return screenIds[name] || ""; }
    function currentWallpaperForScreen(name): string { return screenPaths[name] || ""; }
    function setWallpaperForScreen(path, name): bool {
        if (!screenTargetId(name))
            return false;
        screenCalls = screenCalls.concat([{path: path, screen: name}]);
        return submit("setWallpaperForScreen", path, screenTargetId(name), name);
    }
    function setWallpaper(path, ignored): bool {
        calls.push(path);
        return submit("setWallpaper", path, "", "");
    }
    function submit(operation, path, target, name): bool {
        if (pending.some(item => item.generation === generation && !item.retired))
            return false;
        const item = {id: ++nextOperation, generation: generation, operation: operation,
            path: path, target: target, screen: name, retired: false};
        pending = pending.concat([item]);
        if (!asyncOperations)
            finish(item.id, true);
        return true;
    }
    function finish(id, ok): void {
        const item = pending.find(item => item.id === id);
        if (!item)
            throw new Error("Unknown fake wallpaper operation " + id);
        pending = pending.filter(item => item.id !== id);
        if (ok) {
            if (item.screen) {
                screenPaths = Object.assign({}, screenPaths, {[item.screen]: item.path});
            } else {
                currentPath = item.path;
                const next = {};
                for (const name of Object.keys(screenPaths))
                    next[name] = item.path;
                screenPaths = next;
            }
        }
        if (!item.retired)
            wallpaperOperationFinished(item.operation, item.path, item.target, ok, ok ? "" : "provider-refused");
    }
    function finishLater(id, ok, delay): void {
        delayed = delayed.concat([{id: id, ok: ok, at: Date.now() + delay}]);
        delivery.start();
    }
    function replaceWorker(): void {
        const old = pending.filter(item => item.generation === generation);
        generation++;
        for (const item of old) {
            item.retired = true;
            wallpaperOperationFinished(item.operation, item.path, item.target, false, "explorer-restarted");
        }
    }
    property Timer delivery: Timer {
        interval: 5
        repeat: true
        onTriggered: {
            const due = delayed.filter(item => item.at <= Date.now());
            delayed = delayed.filter(item => item.at > Date.now());
            for (const item of due)
                finish(item.id, item.ok);
            if (!delayed.length)
                stop();
        }
    }
}
