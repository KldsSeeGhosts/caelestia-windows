pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Windows as Native
import qs.components.containers
import qs.services
import qs.utils
import "CaptureLogic.js" as Logic

// Windows adaptation of upstream modules/areapicker/AreaPicker.qml.
//
// Upstream registers the `picker` IPC target and four shortcuts here. On
// Windows those names stay with services/Glazier.qml and daemons/Shortcuts.qml,
// and every one of them reaches this scope through CaptureUi.screenshot(), which
// picks the classic tool or this picker from `windows.capture.ui`. This file
// keeps upstream's structure: a loader holds one overlay window per screen.
//
// Differences from upstream:
// - Each window is excluded from capture, so the frozen frame holds the
//   desktop, the bar and the border but never the picker itself.
// - The screen is always frozen first. A Windows ScreencopyView never starts
//   capturing while it is hidden, so upstream's live mode, which hides the view
//   and re-shows it, cannot work. CaptureUi accepts the four upstream names, and
//   open and openFreeze (and the Clip pair) therefore behave the same.
// - Output goes to Pictures\Screenshots or the clipboard, not swappy or wl-copy.
Scope {
    id: root

    // The production host turns this off during smoke, which must never freeze
    // a real desktop.
    property bool interactionEnabled: true
    property bool clipboardOnly
    property bool opened
    property bool closing
    property bool saving
    // Screen name to ScreencopyView.hasContent, and whether all of them have it.
    property var ready: ({})
    property bool allReady
    property double openedAt
    // Window stack taken once when the picker opens, topmost first.
    property var stack: []
    // Where files go. Screenshots are written to <saveRoot>/Screenshots, and
    // to <saveRoot> itself when that folder cannot be created. The temporary
    // clipboard image lives under the shell state folder. Fixtures redirect both.
    property string saveRoot: Paths.pictures
    property string tempDirectory: Paths.state + "/capture"
    // Needs a local file path. Fixtures replace it with a recorder so that no
    // test writes the real clipboard.
    property var clipboard: Native.Clipboard

    readonly property var screenNames: Screens.screens.map(screen => screen.name)
    readonly property var windows: loader.item ? loader.item.instances : []

    function open(toClipboard: bool): bool {
        if (!interactionEnabled)
            return false;
        if (opened)
            return true;
        openedAt = Date.now();
        clipboardOnly = toClipboard;
        closing = false;
        saving = false;
        ready = ({});
        allReady = false;
        // One read-only enumeration for every screen, before any window exists.
        stack = Array.from(Hyprland.windowStack());
        opened = true;
        return true;
    }

    // Esc and a right click land here. Nothing is saved.
    function cancel(): void {
        if (!opened || closing)
            return;
        closing = true;
    }

    // Called by a picker when its fade out has finished, or at once when the
    // animation is disabled.
    function finishClose(): void {
        opened = false;
        closing = false;
        saving = false;
    }

    // Each ScreencopyView reports here. The tint appears only when every screen
    // has a frame, and the time from open() is logged so the owner can compare it
    // with the 100 ms budget on real hardware.
    function noteContent(name: string, has: bool): void {
        if (!opened)
            return;
        const next = Object.assign({}, ready);
        next[name] = has;
        ready = next;
        const done = Logic.allReady(next, screenNames);
        if (done && !allReady) {
            allReady = true;
            const elapsed = Date.now() - openedAt;
            console.log(`CAELESTIA_CAPTURE_PICKER_FREEZE ms=${elapsed} screens=${screenNames.length}`);
        } else if (!done) {
            allReady = false;
        }
    }

    // A shell reload destroys this scope with the picker open. Nothing is saved.
    Component.onCompleted: CaptureUi.picker = root
    Component.onDestruction: {
        if (CaptureUi.picker === root)
            CaptureUi.picker = null;
    }

    LazyLoader {
        id: loader

        active: root.opened

        Variants {
            model: Screens.screens

            StyledWindow {
                id: win

                required property ShellScreen modelData

                screen: modelData
                name: "area-picker"
                excludeFromCapture: true
                exclusionMode: ExclusionMode.Ignore
                WlrLayershell.layer: WlrLayer.Overlay
                WlrLayershell.keyboardFocus: root.closing ? WlrKeyboardFocus.None : WlrKeyboardFocus.Exclusive
                mask: root.closing ? empty : null

                anchors.top: true
                anchors.bottom: true
                anchors.left: true
                anchors.right: true

                Region {
                    id: empty
                }

                Picker {
                    owner: root
                    screen: win.modelData
                }
            }
        }
    }
}
