import QtQuick

// Recording stand-in for Quickshell's IpcHandler. The offscreen QML runner
// has no IPC registry, so a handler registers in IpcTargets instead. A fixture
// calls the same target and function names a `qs ipc call` client reaches.
QtObject {
    id: root

    property string target: ""
    property bool enabled: true

    Component.onCompleted: {
        if (root.enabled)
            IpcTargets.register(root);
    }
    Component.onDestruction: IpcTargets.unregister(root)
    onEnabledChanged: {
        if (root.enabled)
            IpcTargets.register(root);
        else
            IpcTargets.unregister(root);
    }
}
