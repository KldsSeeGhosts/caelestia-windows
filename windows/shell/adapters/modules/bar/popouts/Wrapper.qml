pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import Caelestia.Config
import qs.components
import qs.services as Services
import qs.modules.bar.popouts
import qs.modules.nexus
import qs.modules.windowinfo as WindowInfoModule

// Platform boundary derived from upstream modules/bar/popouts/Wrapper.qml.
// The combined prototype keeps the original popout state, content loader and
// open/close animation. The Wayland HyprlandFocusGrab and in-overlay detached
// winfo mode stay out because they have no Windows equivalent. A winfo detach
// instead opens the reviewed floating WindowInfo window and closes the popout,
// so ContentWindow never dims the shell for an empty detached overlay.
// close() still restores the attached state.
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
    required property var focusWindow

    readonly property alias content: content

    readonly property real nonAnimWidth: children.find(c => c.shouldBeActive)?.implicitWidth ?? content.implicitWidth
    readonly property real nonAnimHeight: children.find(c => c.shouldBeActive)?.implicitHeight ?? content.implicitHeight
    readonly property Item current: (content.item as Content)?.current ?? null
    readonly property bool isDetached: detachedMode.length > 0

    property alias currentName: popoutState.currentName
    property alias hasCurrent: popoutState.hasCurrent
    property real currentCenter
    // Set by the running-apps strip when a popout is opened on purpose (right
    // click or keyboard). It makes the card-sized focus companion focusable
    // below, so Escape and the arrow keys reach the popout. A hover-opened
    // popout never sets it and so never takes focus from the user's app.
    property bool pinned: false
    readonly property real slideOffset: (-implicitWidth - 5) * offsetScale
    readonly property bool usesFocusWindow: _usesFocusWindow
    readonly property bool inFocusWindow: usesFocusWindow && focusWindow?.surface === "popouts"
    property bool _usesFocusWindow: false

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

    function detach(mode: string, client: var): void {
        setAnims(true);
        if (mode === "winfo") {
            setAnims(false);
            const target = client ?? Services.Hypr.activeToplevel;
            if (target)
                WindowInfoModule.WindowInfoFactory.openForClient(target);
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
    width: implicitWidth
    height: implicitHeight

    // Upstream's wrapper takes focus while a popout is open, so Escape reaches
    // it. Windows has no credential-collecting network popout, so the upstream
    // password-dialog forwarding has no target and Escape just closes.
    focus: hasCurrent
    Keys.onEscapePressed: root.close()

    // A pin lasts only while its popout is open. Keep using the companion
    // until the slide-off finishes even though the pin itself releases now.
    onOffsetScaleChanged: {
        if (!hasCurrent && offsetScale >= 1)
            _usesFocusWindow = false;
    }
    onHasCurrentChanged: {
        if (!hasCurrent)
            pinned = false;
        else
            _usesFocusWindow = pinned;
    }
    onPinnedChanged: {
        if (pinned && hasCurrent)
            _usesFocusWindow = true;
        else if (hasCurrent)
            _usesFocusWindow = false;
    }
    onCurrentNameChanged: {
        if (currentName !== "activewindow")
            pinned = false;
    }

    // Only the card-sized companion becomes focusable while a popout is
    // pinned. The monitor-sized drawers window stays at None so Wallpaper
    // Engine never sees it as a foreground fullscreen window.
    Binding {
        when: root.pinned

        target: root.focusWindow
        property: "WlrLayershell.keyboardFocus"
        value: WlrKeyboardFocus.OnDemand
    }

    // OnDemand only permits focus. The grab asks for it, on the right-click
    // that pinned the popout (a click is a documented foreground right, so
    // there is no AttachThreadInput escalation), and an outside click or
    // another app's foreground clears it, which closes the popout.
    HyprlandFocusGrab {
        active: root.pinned
        windows: root.focusWindow ? [root.focusWindow] : []
        onCleared: root.close()
    }

    PopoutState {
        id: popoutState

        onDetachRequested: (mode, client) => root.detach(mode, client)
    }

    Comp {
        id: content

        shouldBeActive: root.hasCurrent && !root.detachedMode
        parent: root.inFocusWindow ? root.focusWindow.contentHost : root
        x: root.inFocusWindow ? root.slideOffset : 0
        y: 0
        width: root.inFocusWindow ? root.nonAnimWidth : root.width
        height: root.inFocusWindow ? root.nonAnimHeight : root.height

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
