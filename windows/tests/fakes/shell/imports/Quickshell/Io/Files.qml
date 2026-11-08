pragma Singleton
import QtQuick
QtObject {
    property var contents: ({})
    property var views: []
    // Paths whose read must fail with a non-missing error.
    property var unreadable: ({})
    // Paths whose next write must fail, with the FileViewError value to emit.
    property var saveFailures: ({})
    // When set, setText queues completion instead of delivering saved() from
    // inside the call. The native view writes on a worker thread and reports
    // later; tests pump it with flushWrites().
    property bool asyncWrites: false
    property var pendingWrites: []
    // A write issued from inside a load/save callback loses its completion in
    // the native view: the operation runs, but saved() is never delivered.
    // Counted so a regression can assert that a deferred write was not dropped.
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
        if (saveFailures[view.path]) {
            view.saveFailed(saveFailures[view.path]);
            return;
        }
        contents[view.path] = String(text);
        view.cachedText = String(text);
        view.emittingSaved = true;
        view.saved();
        view.emittingSaved = false;
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
