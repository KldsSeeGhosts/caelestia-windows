pragma Singleton

import QtQuick
import Quickshell
import Caelestia
import Caelestia.Config
import qs.services
import "../modules/areapicker/CaptureLogic.js" as Logic

// Windows: the one place that decides which screenshot UI runs.
//
// `windows.capture.ui` in shell.json is "classic" (default), which starts the
// bundled Rust capture tool through Glazier.qml exactly as before, or "shell",
// which opens the QML picker in modules/areapicker. A legacy glazier.exe
// override has no shell integration, so it always stays classic. Recording is
// not routed here and stays classic.
//
// Every entry point calls screenshot(): PrintScreen and Win+Shift+S
// (daemons/Shortcuts.qml), the launcher Screenshot action, IPC
// `screenshot capture` and the `picker` IPC functions (services/Glazier.qml).
Singleton {
    id: root

    // Kept as providers so the routing can be tested offscreen with a recorder.
    property var glazierProvider: Glazier
    // Set by the AreaPicker instance in shell.qml, cleared when it goes away.
    property var picker: null
    property var pending: null
    property double pendingSince

    readonly property string setting: {
        const value = GlobalConfig.windows?.capture?.ui;
        return typeof value === "string" ? value : "classic";
    }
    // Until Glazier has read glazier.json, a legacy override is not ruled out,
    // so the classic path (which asks the user to retry) handles the press.
    readonly property string route: glazierProvider?.ready
        ? Logic.captureRoute(setting, glazierProvider.executable) : "classic"
    readonly property bool shellAvailable: route === "shell" && picker !== null

    // `name` is the upstream picker function: open, openFreeze, openClip or
    // openFreezeClip. The classic tool treats all four alike. The return value
    // means accepted, as Glazier.capture() does.
    function screenshot(name = "open"): bool {
        if (route !== "shell")
            return glazierProvider.capture();
        const options = Logic.pickerOptions(name);
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
        // Close open panels first, as the classic path does, so a half-closed
        // launcher is not frozen into the image. With nothing open this
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
                picker.open(options.clipboardOnly);
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
