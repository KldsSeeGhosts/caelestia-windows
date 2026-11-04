pragma Singleton

import QtQuick

// Test-only stand-in, staged over imports/Caelestia/Services/SessionManager.qml
// by Test-SessionConfirmKeyboard.ps1. CAELESTIA_SESSION_KEYBOARD_STUB
// It implements only the contract the session drawer uses and keeps every
// action in memory, so no run can reach a native session method.
QtObject {
    id: root

    readonly property bool sessionActionGating: true
    readonly property bool allowDetachedFallback: false

    property string pendingAction: ""
    readonly property bool confirmationPending: pendingAction !== ""

    property int execCount: 0
    property int confirmCount: 0
    property int cancelCount: 0
    property var lastCommand: []

    function actionOf(command): string {
        if (!command || typeof command.length !== "number")
            return "";
        const token = String(command[0] ?? "").toLowerCase();
        return token === "poweroff" ? "shutdown" : token;
    }

    function sessionAction(command): var {
        return {
            action: root.actionOf(command),
            available: true,
            dispatchable: true,
            requiresConfirmation: true
        };
    }

    function exec(command): bool {
        root.execCount++;
        root.lastCommand = command;
        root.pendingAction = root.actionOf(command);
        return true;
    }

    function confirm(): bool {
        if (root.pendingAction === "")
            return false;
        root.confirmCount++;
        root.pendingAction = "";
        return true;
    }

    function cancelConfirmation(): bool {
        if (root.pendingAction === "")
            return false;
        root.cancelCount++;
        root.pendingAction = "";
        return true;
    }
}
