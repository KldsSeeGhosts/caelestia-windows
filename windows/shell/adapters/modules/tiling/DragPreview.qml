pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import Caelestia.Config
import qs.components
import qs.components.containers
import qs.services

// Windows-only preview of where a dragged tiled window will land. The tiler
// plans the drop from the cursor on every move of the window and publishes
// the result on `Tiling` (TilingService.qml); this draws exactly that: the
// plate where the dragged window lands and, when exactly one other tile moves,
// a ghost where that one goes. A drop that changes nothing draws nothing.
//
// One click-through overlay per screen, because screens can differ in DPI.
// It is created on the first drag on its screen, kept afterwards, and is a
// hidden 1x1 window between drags.
Scope {
    id: root

    // Older backends have no drop plan; tiling off has no drags.
    readonly property bool supported: Tiling.backendEnabled && typeof Tiling.dragActive === "boolean"
    readonly property alias screens: perScreen

    Variants {
        id: perScreen

        model: root.supported ? Quickshell.screens : []

        Scope {
            id: screenScope

            required property ShellScreen modelData
            readonly property bool here: Tiling.dragActive && Tiling.dragScreen === modelData.name
            readonly property var window: loader.item
            property bool used: false

            onHereChanged: if (here) used = true

            LazyLoader {
                id: loader

                active: screenScope.used

                StyledWindow {
                    id: win

                    readonly property bool drawing: screenScope.here
                        && (Tiling.dragMode === "swap" || Tiling.dragMode === "insert")
                        && Tiling.dragLanding.width > 0
                    readonly property bool ghostDrawn: drawing && Tiling.dragDisplaced.width > 0
                    property rect landing
                    property rect displaced
                    property bool hasGhost

                    screen: screenScope.modelData
                    name: "tiling-drop-preview"
                    visible: drawing || drops.opacity > 0
                    mask: Region {}
                    exclusionMode: ExclusionMode.Ignore
                    WlrLayershell.layer: WlrLayer.Overlay
                    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

                    // Full screen only while it draws; 1x1 when hidden.
                    anchors.top: visible
                    anchors.bottom: visible
                    anchors.left: visible
                    anchors.right: visible
                    implicitWidth: 1
                    implicitHeight: 1

                    // Hold the last plan through the fade after a release.
                    Binding on landing {
                        when: win.drawing
                        value: Tiling.dragLanding
                        restoreMode: Binding.RestoreNone
                    }
                    Binding on displaced {
                        when: win.ghostDrawn
                        value: Tiling.dragDisplaced
                        restoreMode: Binding.RestoreNone
                    }
                    Binding on hasGhost {
                        when: win.drawing
                        value: win.ghostDrawn
                        restoreMode: Binding.RestoreNone
                    }

                    // Started from the change handler, which runs after the drag
                    // state settled, so a release always gets the slower fade.
                    function fadeTo(shown: bool): void {
                        fader.stop();
                        fader.type = shown || Tiling.dragActive ? Anim.FastEffects : Anim.DefaultEffects;
                        fader.to = shown ? 1 : 0;
                        fader.start();
                    }

                    onDrawingChanged: fadeTo(drawing)
                    Component.onCompleted: if (drawing) fadeTo(true)

                    Anim {
                        id: fader

                        target: drops
                        property: "opacity"
                    }

                    Item {
                        id: drops

                        anchors.fill: parent
                        opacity: 0

                        Rectangle {
                            objectName: "tilingDropGhost"
                            x: win.displaced.x
                            y: win.displaced.y
                            width: win.displaced.width
                            height: win.displaced.height
                            visible: win.hasGhost
                            color: "transparent"
                            radius: Tokens.rounding.medium
                            border.width: 1.5
                            border.color: Qt.alpha(Colours.palette.m3onSurfaceVariant, 0.5)

                            Behavior on x { enabled: drops.opacity > 0; Anim { type: Anim.EmphasizedSmall } }
                            Behavior on y { enabled: drops.opacity > 0; Anim { type: Anim.EmphasizedSmall } }
                            Behavior on width { enabled: drops.opacity > 0; Anim { type: Anim.EmphasizedSmall } }
                            Behavior on height { enabled: drops.opacity > 0; Anim { type: Anim.EmphasizedSmall } }
                        }

                        Rectangle {
                            objectName: "tilingDropPlate"
                            x: win.landing.x
                            y: win.landing.y
                            width: win.landing.width
                            height: win.landing.height
                            color: Qt.alpha(Colours.palette.m3primary, 0.14)
                            radius: Tokens.rounding.medium
                            border.width: 2
                            border.color: Qt.alpha(Colours.palette.m3primary, 0.9)

                            Behavior on x { enabled: drops.opacity > 0; Anim { type: Anim.EmphasizedSmall } }
                            Behavior on y { enabled: drops.opacity > 0; Anim { type: Anim.EmphasizedSmall } }
                            Behavior on width { enabled: drops.opacity > 0; Anim { type: Anim.EmphasizedSmall } }
                            Behavior on height { enabled: drops.opacity > 0; Anim { type: Anim.EmphasizedSmall } }
                        }
                    }
                }
            }
        }
    }
}
