pragma Singleton

import QtQuick

// Test-only stand-in, staged over imports/Caelestia/Services/SessionManager.qml
// by Test-AccessibilitySession.ps1. CAELESTIA_SESSION_KEYBOARD_STUB
// It implements only the contract the session drawer uses and keeps every
// action in memory, so no run can reach a native session method. execCount and
// lastCommand are the fake backend record: one increment per dispatched
// command, so a test can prove a destructive button dispatched immediately.
QtObject {
    id: root

    readonly property bool sessionActionGating: true
    readonly property bool allowDetachedFallback: false

    property int execCount: 0
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
            destructive: true
        };
    }

    function exec(command): bool {
        root.execCount++;
        root.lastCommand = command;
        return true;
    }
}
