pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import Caelestia.Config
import qs.components.containers
import qs.services
import qs.utils
import "RecordingLogic.js" as Logic

// The helper returns its region and UI mode with status, so reload can restore
// these controls without starting, stopping or adopting a recording locally.
Scope {
    id: root
    property bool interactionEnabled: true
    required property var recorder
    property var screenList: Screens.screens
    readonly property bool active: interactionEnabled && recorder.running && recorder.shellRegion !== null
    readonly property var displays: loader.item ? loader.item.instances : []

    LazyLoader {
        id: loader
        active: root.active
        Variants {
            model: root.screenList
            Scope {
                id: display
                required property ShellScreen modelData
                readonly property alias borderWindow: borderWindow
                readonly property alias controlsWindow: controls
                readonly property var selection: Logic.localRegion(root.recorder.shellRegion, modelData, modelData.devicePixelRatio)

                StyledWindow {
                    id: borderWindow
                    screen: display.modelData
                    name: "recording-border"
                    visible: display.selection !== null
                    anchors { top: true; bottom: true; left: true; right: true }
                    exclusionMode: ExclusionMode.Ignore
                    excludeFromCapture: true
                    WlrLayershell.layer: WlrLayer.Overlay
                    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
                    mask: Region {}
                    Rectangle {
                        readonly property var r: display.selection ?? { x: 0, y: 0, width: 0, height: 0 }
                        x: r.x
                        y: r.y
                        width: r.width
                        height: r.height
                        color: "transparent"
                        border.width: 2 / display.modelData.devicePixelRatio
                        border.color: Colours.palette.m3primary
                    }
                }
                StyledWindow {
                    id: controls
                    screen: display.modelData
                    name: "recording-controls"
                    visible: display.selection !== null
                    anchors { top: true; bottom: true; left: true; right: true }
                    exclusionMode: ExclusionMode.Ignore
                    excludeFromCapture: true
                    WlrLayershell.layer: WlrLayer.Overlay
                    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
                    mask: Region { item: bar }
                    RecordingBar {
                        id: bar
                        readonly property real dpr: display.modelData.devicePixelRatio
                        readonly property var r: display.selection ?? { x: 0, y: 0, width: 0, height: 0 }
                        recorder: root.recorder
                        width: Math.ceil(implicitWidth * dpr) / dpr
                        height: Math.ceil(implicitHeight * dpr) / dpr
                        x: Math.round(Math.max(Tokens.spacing.small,
                            Math.min(controls.width - width - Tokens.spacing.small, r.x + (r.width - width) / 2)) * dpr) / dpr
                        y: Math.round(Math.max(Tokens.spacing.small, Math.min(controls.height - height - Tokens.spacing.small,
                            r.y + r.height + height + Tokens.spacing.small <= controls.height
                                ? r.y + r.height + Tokens.spacing.small : r.y - height - Tokens.spacing.small)) * dpr) / dpr
                    }
                }
            }
        }
    }
}
