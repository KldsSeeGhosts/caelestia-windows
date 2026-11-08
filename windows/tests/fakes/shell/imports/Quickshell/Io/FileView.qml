import QtQuick
QtObject {
    id: root
    property string path: ""
    property bool watchChanges: false
    property bool printErrors: false
    property bool blockLoading: false
    property bool atomicWrites: false
    // The native view caches the last completed read/save. Mutating
    // Files.contents behind it is exactly a change another process made after
    // the view's last load; text() must keep returning the cached document
    // until reload() completes.
    property string cachedText: ""
    signal loaded()
    signal loadFailed(var error)
    signal fileChanged()
    signal saved()
    signal saveFailed(var error)
    function text(): string { return cachedText; }
    function reload(): void {
        // The native view is asynchronous after the first load. Tests that
        // exercise that ordering defer deliveries and flush explicitly.
        if (Files.deferReloads) {
            Files.defer(root);
            return;
        }
        deliverLoad();
    }
    function deliverLoad(): void {
        if (Files.unreadable[path]) {
            loadFailed(3);
        } else if (Object.prototype.hasOwnProperty.call(Files.contents, path)) {
            cachedText = String(Files.contents[path] ?? "");
            loaded();
        } else {
            cachedText = "";
            loadFailed(2);
        }
    }
    function setText(text): void {
        if (!path)
            return;
        cachedText = String(text);
        Files.contents[path] = text;
        saved();
        if (watchChanges)
            fileChanged();
    }
    Component.onCompleted: { Files.views.push(root); reload(); }
}
