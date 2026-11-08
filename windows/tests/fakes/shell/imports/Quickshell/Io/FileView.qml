import QtQuick
QtObject {
    id: root
    property string path: ""
    property bool watchChanges: false
    property bool printErrors: false
    property bool blockLoading: false
    property bool blockWrites: false
    property bool preload: true
    property bool atomicWrites: false
    // The native view caches the last completed read/save. Mutating
    // Files.contents behind it is exactly a change another process made after
    // the view's last load; text() must keep returning the cached document
    // until reload() completes.
    property string cachedText: ""
    property string pendingText: ""
    property bool prepared: false
    // True while a load or save signal is being delivered. The native view
    // still holds its operation while these run, so a write issued from the
    // handler loses its own completion.
    property bool deliveringLoad: false
    property bool emittingSaved: false
    signal loaded()
    signal loadFailed(var error)
    signal fileChanged()
    signal saved()
    signal saveFailed(var error)
    function text(): string {
        if (!prepared)
            deliverLoad();
        return cachedText;
    }
    function reload(): void {
        prepared = false;
        // The native view is asynchronous after the first load. Tests that
        // exercise that ordering defer deliveries and flush explicitly.
        if (Files.deferReloads) {
            Files.defer(root);
            return;
        }
        deliverLoad();
    }
    function deliverLoad(): void {
        prepared = true;
        deliveringLoad = true;
        if (Files.unreadable[path]) {
            loadFailed(3);
        } else if (Object.prototype.hasOwnProperty.call(Files.contents, path)) {
            cachedText = String(Files.contents[path] ?? "");
            loaded();
        } else {
            cachedText = "";
            loadFailed(2);
        }
        deliveringLoad = false;
    }
    function setText(text): void {
        if (!path)
            return;
        const value = String(text);
        // The native writer drops a value it already holds: state.data after
        // a successful load/save, or the write waiting to run.
        if (cachedText === value || pendingText === value)
            return;
        if (deliveringLoad || emittingSaved) {
            // The writer still runs, but operationFinished no longer belongs
            // to the view, so neither saved() nor saveFailed() arrives.
            if (!Files.saveFailures[path]) {
                Files.contents[path] = value;
                cachedText = value;
            }
            Files.droppedWrites++;
            return;
        }
        if (blockWrites) {
            Files.writeRequests++;
            Files.deliverWrite(root, value);
            return;
        }
        pendingText = value;
        Files.writeRequests++;
        Files.queueWrite(root, value);
    }
    Component.onCompleted: {
        Files.views.push(root);
        if (preload)
            reload();
    }
}
