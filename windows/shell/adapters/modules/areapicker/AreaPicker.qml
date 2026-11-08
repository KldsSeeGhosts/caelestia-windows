pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Windows as Native
import Caelestia
import Caelestia.I18n
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
    // to <saveRoot> itself when that folder cannot be created. Fixtures redirect
    // it. The clipboard hand-over files are named and placed by the plugin
    // (CUtils.newCaptureTempPath), in the OS temp directory. A crash while a
    // clipboard save is under way can leave one caelestia-clipboard-*.png there.
    property string saveRoot: Paths.pictures
    // The screens the picker serves. Fixtures replace the list to simulate a
    // monitor being unplugged.
    property var screenList: Screens.screens
    // Longest time a save may take before the picker reports a failure.
    property int saveTimeout: 10000
    // Counts opens and closes. A result carries the number it started with, so
    // one that arrives after the picker closed or reopened is dropped. It only
    // routes results; file names do not use it.
    property int session
    property var openScreenNames: []
    // The hand-over file of the clipboard save in progress, if any. Its name is
    // unique across pickers, reloads and processes, so no one else touches it.
    property string activeTemp: ""
    // Needs a local file path. Fixtures replace it with a recorder so that no
    // test writes the real clipboard.
    property var clipboard: Native.Clipboard
    // Shows the finished capture. Thumbnails.qml registers itself with CaptureUi;
    // fixtures replace it, and without one no thumbnail is shown.
    property var thumbnails: CaptureUi.thumbnails

    readonly property var screenNames: screenList.map(screen => screen.name)
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
        openScreenNames = screenNames;
        session++;
        opened = true;
        return true;
    }

    // Every operation ends here before anything else happens: a result, a
    // failure, the timeout, Esc and a right click all call it first. It
    // invalidates the session, so a result that arrives later is dropped, and
    // clears `saving`, which stops the timeout. The fade that follows is only
    // cosmetic. The operation's hand-over file goes with it.
    function invalidate(): void {
        session++;
        saving = false;
        if (activeTemp) {
            removeTemp(activeTemp);
            activeTemp = "";
        }
    }

    // Esc and a right click land here. Nothing more is saved.
    function cancel(): void {
        if (!opened || closing)
            return;
        invalidate();
        closing = true;
    }

    // Called by a picker when its fade out has finished, or at once when the
    // animation is disabled.
    function finishClose(): void {
        opened = false;
        closing = false;
        invalidate();
    }

    // Deletes one hand-over file. The plugin accepts only the exact path scheme it
    // creates in the temp directory, and refuses everything else.
    function removeTemp(path: string): void {
        CUtils.removeCaptureTemp(path);
    }

    // A new, empty hand-over file for this clipboard save, or "" if none could
    // be created.
    function beginClipboard(): string {
        activeTemp = CUtils.newCaptureTempPath().split("\\").join("/");
        return activeTemp;
    }

    // Results from Picker. Each ignores a result from an earlier session.
    // `info` is { screen, width, height, dpr } for the thumbnail, and null when
    // the caller has none.
    function fileFinished(started: int, path: string, info = null): void {
        if (started !== session)
            return;
        Toaster.toast(Tr.tr("Screenshot taken"), Tr.tr("Saved to %1").arg(path), "screenshot_region");
        if (thumbnails && info)
            thumbnails.addSaved(info, path);
        cancel();
    }

    // copyImageFile reads the whole file before it returns, then decodes and
    // writes the clipboard later with no completion result. A true return
    // therefore means the copy was started, and the toast says so. A write that
    // lands after its session ended deletes its own file and copies nothing.
    // The thumbnail copies the file before it is deleted below, because the
    // hand-over file does not outlive this call.
    function copyFinished(started: int, path: string, info = null): void {
        if (started !== session) {
            removeTemp(path);
            return;
        }
        const accepted = clipboard.copyImageFile(path);
        if (accepted && thumbnails && info)
            thumbnails.addCopy(info, path);
        removeTemp(path);
        activeTemp = "";
        if (accepted) {
            Toaster.toast(Tr.tr("Screenshot taken"), Tr.tr("Copying screenshot to clipboard\u2026"), "screenshot_region");
            cancel();
        } else {
            saveFailed(started, Tr.tr("The image could not be copied."));
        }
    }

    function saveFailed(started: int, message: string): void {
        if (started !== session)
            return;
        Toaster.toast(Tr.tr("Screenshot failed"), message, "screenshot_region", Toast.Error);
        cancel();
    }

    // A monitor was added or removed while open. The frozen frames and the
    // readiness map describe the old layout, so the picker closes at once.
    onScreenNamesChanged: {
        if (!opened || closing || Logic.sameNames(openScreenNames, screenNames))
            return;
        Toaster.toast(Tr.tr("Screenshot cancelled"), Tr.tr("The monitors changed."), "screenshot_region");
        finishClose();
    }

    // A save that never reports back must not leave the screen frozen.
    Timer {
        interval: root.saveTimeout
        running: root.saving && root.opened
        onTriggered: root.saveFailed(root.session, Tr.tr("Saving the screenshot timed out."))
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
        if (activeTemp)
            removeTemp(activeTemp);
    }

    LazyLoader {
        id: loader

        active: root.opened

        Variants {
            model: root.screenList

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
