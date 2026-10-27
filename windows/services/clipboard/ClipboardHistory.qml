pragma Singleton

import QtQuick
import Quickshell
import Caelestia.Config

// Windows clipboard history facade for the Caelestia shell.
//
// The picker is gated by the Windows extension in shell.json:
//
//   { "windows": { "clipboard": { "enabled": false } } }
//
// The key is optional and defaults to enabled. The native backend is not
// constructed at all while the option is disabled, so no clipboard history is
// read and no Windows setting is touched.
//
// Status is one of: "disabled" (this option), "initializing", "loading",
// "ready", "disabled" (Windows clipboard history off), "denied" (Windows
// refused history access) or "error".
Singleton {
    id: root

    // windows.clipboard is part of the free-form Windows extension map that
    // ConfigRoot watches; this facade validates the fields it reads.
    readonly property var profileSettings: JSON.parse(JSON.stringify(GlobalConfig.windows?.clipboard ?? ({})))
    readonly property bool enabled: profileSettings.enabled === undefined ? true : profileSettings.enabled === true

    property var items: []
    property bool historyEnabled: false
    property string backendStatus: "initializing"
    property string lastError: ""

    readonly property bool available: backend.item !== null
    readonly property string status: root.enabled ? backendStatus : "disabled"
    readonly property int count: items.length

    signal imageReady(string id, string url)
    signal pasteReady(string id)
    signal operationFailed(string operation, string message)

    function refresh(): void {
        if (available)
            backend.item.refresh();
    }

    function setActive(active: bool): void {
        if (available)
            backend.item.setActive(active);
    }

    function copy(id: string): void {
        if (available)
            backend.item.copy(id);
    }

    function paste(id: string): void {
        if (available)
            backend.item.paste(id);
    }

    function remove(id: string): void {
        if (available)
            backend.item.remove(id);
    }

    function clear(): void {
        if (available)
            backend.item.clear();
    }

    function openItem(id: string): void {
        if (available)
            backend.item.openItem(id);
    }

    function preview(id: string): void {
        if (available)
            backend.item.requestImage(id);
    }

    // Read-only hand-off to Windows Settings; the shell never enables history.
    function openSettings(): void {
        if (available)
            backend.item.openSettings();
    }

    function syncBackend(): void {
        const service = backend.item;
        if (!service) {
            items = [];
            historyEnabled = false;
            backendStatus = root.enabled ? "initializing" : "disabled";
            return;
        }
        items = service.items;
        historyEnabled = service.historyEnabled;
        backendStatus = service.status;
        lastError = service.lastError;
    }

    readonly property Loader backend: Loader {
        id: backend

        active: root.enabled
        source: Qt.resolvedUrl("NativeClipboardBackend.qml")

        onItemChanged: root.syncBackend()
        onStatusChanged: {
            if (status === Loader.Error) {
                root.backendStatus = "error";
                root.lastError = "The Windows clipboard component failed to load.";
            }
        }
    }

    readonly property Connections backendSignals: Connections {
        target: root.backend.item
        ignoreUnknownSignals: true

        function onItemsChanged(): void {
            root.items = root.backend.item.items;
        }

        function onHistoryEnabledChanged(): void {
            root.historyEnabled = root.backend.item.historyEnabled;
        }

        function onStatusChanged(): void {
            root.backendStatus = root.backend.item.status;
        }

        function onLastErrorChanged(): void {
            root.lastError = root.backend.item.lastError;
        }

        function onImageReady(id, url): void {
            root.imageReady(id, url);
        }

        function onPasteReady(id): void {
            root.pasteReady(id);
        }

        function onOperationFailed(operation, message): void {
            root.lastError = message;
            root.operationFailed(operation, message);
        }

        function onOpenUrl(url): void {
            Qt.openUrlExternally(url);
        }
    }
}
