pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Caelestia.Config
import qs.components
import qs.modules.bar.popouts
import qs.modules.nexus

// Platform boundary derived from upstream modules/bar/popouts/Wrapper.qml.
// The combined prototype keeps the original popout state, content loader and
// open/close animation. The detached winfo overlay and the Wayland
// HyprlandFocusGrab stay out because no reviewed Windows facade exists for
// them, so a winfo detach closes the popout instead of leaving a detached state
// with nothing on screen (ContentWindow dims the shell while detachedMode is
// set). close() still restores the attached state.
//
// The two other detach targets in the staged UI (the audio and Bluetooth
// popouts) used to be dropped here. Since modules/nexus is staged, they now use
// the upstream equivalent on Windows: the standalone Nexus FloatingWindow,
// opened on the page the popout asked for (upstream's inline overlay did the
// same through NexusState.currentPageIdx). The keyboard-focus binding for the
// wireless password dialog stays out for the same reason it was inert before:
// the Windows network facade collects no credentials.
Item {
    id: root

    required property ShellScreen screen
    required property real offsetScale

    readonly property alias content: content

    readonly property real nonAnimWidth: children.find(c => c.shouldBeActive)?.implicitWidth ?? content.implicitWidth
    readonly property real nonAnimHeight: children.find(c => c.shouldBeActive)?.implicitHeight ?? content.implicitHeight
    readonly property Item current: (content.item as Content)?.current ?? null
    readonly property bool isDetached: detachedMode.length > 0

    property alias currentName: popoutState.currentName
    property alias hasCurrent: popoutState.hasCurrent
    property real currentCenter

    property string detachedMode
    property string queuedMode

    // Same page order the upstream overlay used: appearance, network,
    // Bluetooth, audio.
    readonly property list<string> detachedPages: ["appearance", "network", "bluetooth", "audio"]

    // Dummy object so Tokens attached prop resolves to global config
    // Anim configs are not per-monitor
    readonly property QtObject dummy: QtObject {}
    property int animLength: dummy.Tokens.anim.durations.expressiveDefaultSpatial
    property var animCurve: dummy.Tokens.anim.expressiveDefaultSpatial // The easingCurve type is Qt 6.11+ so we gotta use var for now

    function setAnims(detach: bool): void {
        const type = `expressive${detach ? "Slow" : "Default"}Spatial`;
        animLength = dummy.Tokens.anim.durations[type];
        animCurve = dummy.Tokens.anim[type];
    }

    function detach(mode: string): void {
        setAnims(true);
        if (mode === "winfo") {
            // modules/windowinfo is not staged: the original detached window
            // inspector has no Windows client model. Closing the popout is the
            // truthful outcome; leaving detachedMode set would dim the whole
            // shell (ContentWindow reads it) with nothing on screen.
            setAnims(false);
            root.close();
            return;
        }
        const page = root.detachedPages.indexOf(mode);
        setAnims(false);
        WindowFactory.openPage(page >= 0 ? page : 0);
        root.hasCurrent = false;
        detachedMode = "";
    }

    function close(): void {
        hasCurrent = false;
        detachedMode = "";
    }

    implicitWidth: nonAnimWidth
    implicitHeight: nonAnimHeight

    // Upstream's wrapper takes focus while a popout is open, so Escape reaches
    // it. Windows has no credential-collecting network popout, so the upstream
    // password-dialog forwarding has no target and Escape just closes.
    focus: hasCurrent
    Keys.onEscapePressed: root.close()

    PopoutState {
        id: popoutState

        onDetachRequested: mode => root.detach(mode)
    }

    Comp {
        id: content

        shouldBeActive: root.hasCurrent && !root.detachedMode
        anchors.fill: parent

        sourceComponent: Content {
            popouts: popoutState
        }
    }

    Behavior on implicitWidth {
        Anim {
            duration: root.animLength
            easing: root.animCurve
        }
    }

    Behavior on implicitHeight {
        enabled: root.offsetScale < 1

        Anim {
            duration: root.animLength
            easing: root.animCurve
        }
    }

    component Comp: Loader {
        id: comp

        property bool shouldBeActive

        active: false
        opacity: 0

        // Makes the loader load on the same frame shouldBeActive becomes true, which ensures size is set
        states: State {
            name: "active"
            when: comp.shouldBeActive

            PropertyChanges {
                comp.opacity: 1
                comp.active: true
            }
        }

        transitions: [
            Transition {
                from: ""
                to: "active"

                SequentialAnimation {
                    PropertyAction {
                        property: "active"
                    }
                    Anim {
                        type: Anim.DefaultEffects
                        property: "opacity"
                    }
                }
            },
            Transition {
                from: "active"
                to: ""

                SequentialAnimation {
                    Anim {
                        type: Anim.DefaultEffects
                        property: "opacity"
                    }
                    PropertyAction {
                        property: "active"
                    }
                }
            }
        ]
    }
}
