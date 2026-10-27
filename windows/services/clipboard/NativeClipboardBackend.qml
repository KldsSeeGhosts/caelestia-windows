import QtQuick
import Quickshell
import Caelestia.Windows

// Loaded by ClipboardHistory only while windows.clipboard.enabled is true, so
// a disabled feature constructs no native type and reads no clipboard data.
//
// Caelestia.Windows.WindowsClipboard is a QML singleton; its first reference
// constructs it. This wrapper exists so the facade's Loader controls that
// construction and so the profile cache directory is bound before any preview
// is requested. The native type writes nowhere outside that directory.
Item {
    id: root

    visible: false
    width: 0
    height: 0

    readonly property var service: WindowsClipboard

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

    Component.onCompleted: service.cacheDirectory = Quickshell.cacheDir + "/clipboard"

    // Destroying this wrapper (for example when windows.clipboard.enabled is
    // set to false) disconnects the singleton callbacks with it.
    Connections {
        target: root.service

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
