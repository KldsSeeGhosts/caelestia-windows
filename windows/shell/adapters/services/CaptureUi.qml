pragma Singleton

import QtQuick
import Quickshell
import Caelestia
import qs.services
import "../modules/areapicker/CaptureLogic.js" as Logic

// Windows: screenshots and region recording both use the shell picker.
//
// Every entry point calls screenshot(): PrintScreen and Win+Shift+S
// (daemons/Shortcuts.qml), the launcher Screenshot action, IPC
// `screenshot capture` and the `picker` IPC functions (services/Glazier.qml).
// Launcher Record and the record shortcut call record() too.
Singleton {
    id: root

    // The provider dismisses panels before the freeze; it does not start capture.
    property var glazierProvider: Glazier
    // Set by the AreaPicker instance in shell.qml, cleared when it goes away.
    property var picker: null
    // Set by the Thumbnails instance in shell.qml. The picker hands it each
    // finished capture.
    property var thumbnails: null
    property var pending: null
    property double pendingSince

    readonly property bool shellAvailable: picker !== null

    // `name` is the upstream picker function: open, openFreeze, openClip or
    // openFreezeClip. All four open the editor, whose Copy and Save decide the
    // output. The return value means accepted, not completed.
    function screenshot(name = "open"): bool {
        return request(name);
    }

    function record(sound = false): bool {
        return request("record", sound);
    }

    // Screenshot and recording entry points share the same routing decision.
    function request(name, sound = false): bool {
        const options = name === "record" ? { recording: true, sound } : Logic.pickerOptions(name);
        if (!options)
            return false;
        if (!picker) {
            Toaster.toast("Screenshot", "The screenshot picker is not ready. Try again.", "screenshot_region");
            return false;
        }
        if (!picker.interactionEnabled)
            return false;
        if (picker.opened || pending)
            return true;
        pending = options;
        pendingSince = Date.now();
        // Close open panels first so a half-closed launcher is not frozen
        // into the image. With nothing open this
        // resolves at once and adds no delay.
        glazierProvider.dismiss();
        poll();
        if (pending)
            wait.restart();
        return true;
    }

    function poll(): void {
        if (!pending)
            return;
        if (glazierProvider.surfacesHidden()) {
            const options = pending;
            pending = null;
            wait.stop();
            if (picker)
                picker.open(options.recording === true, options.sound === true);
        } else if (Date.now() - pendingSince > glazierProvider.hiddenTimeout) {
            pending = null;
            wait.stop();
            Toaster.toast("Screenshot", "The screenshot is not ready. The shell is still on screen.", "screenshot_region");
        }
    }

    Timer {
        id: wait

        interval: 16
        repeat: true
        onTriggered: root.poll()
    }
}
