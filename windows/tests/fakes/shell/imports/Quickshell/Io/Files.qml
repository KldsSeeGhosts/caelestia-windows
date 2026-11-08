pragma Singleton
import QtQuick
QtObject {
    property var contents: ({})
    property var views: []
    // Paths whose read must fail with a non-missing error.
    property var unreadable: ({})
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
}
