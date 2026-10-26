pragma Singleton

import QtQuick

// The original modules/bar/components/ActiveWindow.qml declares
// `required property Brightness.Monitor monitor` but never reads it. The
// portable Windows build excludes the upstream services/Brightness.qml, which
// starts ddcutil/asdbctl processes and imports Quickshell.Io. This adapter
// supplies the nested Monitor type and unavailable values so the original
// component loads unchanged. It implements no brightness read or write and is
// staged only by the hypr prototype.
QtObject {
    id: root

    readonly property var monitors: []
    readonly property bool appleDisplayPresent: false
    readonly property var ddcMonitors: []

    // Mirrors the upstream nested type enough for static type resolution and
    // property declarations. No Windows display is enumerated.
    component Monitor: QtObject {
        property var modelData: null
        property real brightness: 0

        function setBrightness(value): void {
        }
    }

    function getMonitorForScreen(screen): var {
        return null;
    }

    function getMonitor(query): var {
        return null;
    }

    function increaseBrightness(): void {
    }

    function decreaseBrightness(): void {
    }
}
