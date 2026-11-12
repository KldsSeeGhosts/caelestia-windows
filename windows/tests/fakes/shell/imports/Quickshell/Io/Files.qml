pragma Singleton
import QtQuick
QtObject {
    property var contents: ({})
    property var views: []
    // Paths whose read must fail with a non-missing error.
    property var unreadable: ({})
    // Paths whose next write must fail, with the FileViewError value to emit.
    property var saveFailures: ({})
    // Paths whose atomic commit fails. The destination and cached committed
    // bytes stay unchanged, and FileView emits saveFailed, never saved.
    property var commitFailures: ({})
    // When set, setText queues completion instead of delivering saved() from
    // inside the call. The native view writes on a worker thread and reports
    // later; tests pump it with flushWrites().
    property bool asyncWrites: false
    property var pendingWrites: []
    // The pinned backend detaches operations before completion callbacks.
    property int droppedWrites: 0
    // Counts writes handed to a FileView, including failed and retried ones.
    property int writeRequests: 0
    // When set, reload() queues its completion, matching the native
    // FileView's asynchronous reload on an already loaded path.
    property bool deferReloads: false
    property var pendingReloads: []
    function changed(path): void {
        for (const view of views)
            if (view.path === path && view.watchChanges)
                view.fileChanged();
    }
    function defer(view): void {
        if (!pendingReloads.includes(view))
            pendingReloads = pendingReloads.concat([view]);
    }
    function flushReloads(): void {
        const queue = pendingReloads;
        pendingReloads = [];
        for (const view of queue)
            view.deliverLoad();
    }
    function hasPendingWrite(view): bool {
        return pendingWrites.some(write => write.view === view);
    }
    function queueWrite(view, text): void {
        if (!asyncWrites) {
            deliverWrite(view, text);
            return;
        }
        pendingWrites = pendingWrites.concat([{view: view, text: String(text)}]);
    }
    function deliverWrite(view, text): void {
        view.pendingText = "";
        const value = String(text);
        if (saveFailures[view.path] || commitFailures[view.path]) {
            view.writeFailed = true;
            view.saveFailed(saveFailures[view.path] || 1);
            return;
        }
        contents[view.path] = value;
        view.cachedText = value;
        view.writeFailed = false;
        view.saved();
        if (view.watchChanges)
            view.fileChanged();
    }
    function flushWrites(): void {
        const queue = pendingWrites;
        pendingWrites = [];
        for (const write of queue)
            deliverWrite(write.view, write.text);
    }
}
