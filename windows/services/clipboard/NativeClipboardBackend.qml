import QtQuick
import Quickshell
import Caelestia.Windows

// Loaded by ClipboardHistory only while windows.clipboard.enabled is true, so
// a disabled feature constructs no native type and reads no clipboard data.
//
// Caelestia.Windows.WindowsClipboard is a regular QML element, not a
// singleton: this wrapper owns the native instance, so destroying the wrapper
// (for example when the option is disabled) destroys the worker thread, its
// WinRT event subscriptions, retained history, preview ownership and any
// pending paste timer. Nothing can fire after the feature is disabled.
Item {
    id: root

    visible: false
    width: 0
    height: 0

    WindowsClipboard {
        id: service

        // Bound at construction. The native type writes nowhere outside this
        // profile cache directory.
        cacheDirectory: Quickshell.cacheDir + "/clipboard"
    }

    // Explicit reset before QML destroys this wrapper. QML does eventually
    // destroy the native object with the wrapper, but the worker must stop,
    // events must be revoked and a pending paste must be cancelled even if
    // deletion is deferred; shutdown() also gives the smoke a deterministic
    // reset to observe.
    Component.onDestruction: service.shutdown()

    // Exposed so the smoke can observe the native instance's lifetime; the
    // facade proxies everything else.
    readonly property var nativeInstance: service

    readonly property var items: service.items
    readonly property bool historyEnabled: service.historyEnabled
    readonly property string status: service.status
    readonly property string lastError: service.lastError

    signal imageReady(string id, string url)
    signal pasteReady(string id)
    signal operationFailed(string operation, string message)
    signal openUrl(string url)

    function refresh(): void {
        service.refresh();
    }

    function setActive(active: bool): void {
        service.setActive(active);
    }

    function copy(id: string): void {
        service.copy(id);
    }

    function paste(id: string): void {
        service.paste(id);
    }

    function remove(id: string): void {
        service.remove(id);
    }

    function clear(): void {
        service.clear();
    }

    function openItem(id: string): void {
        service.openItem(id);
    }

    function requestImage(id: string): void {
        service.requestImage(id);
    }

    function openSettings(): void {
        service.openSettings();
    }

    Connections {
        target: root.nativeInstance

        function onImageReady(id, url): void {
            root.imageReady(id, url);
        }

        function onPasteReady(id): void {
            root.pasteReady(id);
        }

        function onOperationFailed(operation, message): void {
            root.operationFailed(operation, message);
        }

        function onOpenUrl(url): void {
            root.openUrl(url);
        }
    }
}
