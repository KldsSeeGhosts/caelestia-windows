pragma Singleton

import QtQuick

// Future-backend launch result surface for the apps fixture. The production
// catalog feature-detects shellActionFinished, so this fake can verify both
// the connection and request correlation without the pinned Windows backend.
QtObject {
    signal shellActionFinished(string requestId, string status, string error)
    property var reply: ({status: "notSupported"})
    property var lastSpec: null
    property int launches: 0

    function launchShellAction(spec, parentWindow): var {
        launches++;
        lastSpec = spec;
        return reply;
    }

    function emitFinished(requestId, status, error): void {
        shellActionFinished(requestId, status, error);
    }
}
