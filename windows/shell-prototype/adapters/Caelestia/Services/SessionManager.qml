pragma Singleton

import QtQuick

// This staged QML module replaces the excluded native Services plugin.
QtObject {
    readonly property bool available: false

    function exec(command: list<string>): bool {
        console.log("CAELESTIA_SESSION_UNAVAILABLE: request consumed without executing a command.");
        // Original session/Content.qml falls back to an external command on
        // false. Always consume every request, including an empty command.
        return true;
    }
}
