pragma Singleton

import QtQuick
import Caelestia.Config

// Windows focus-follows-mouse facade for the Caelestia shell.
//
// The option lives in the free-form Windows extension map and is validated
// here, like windows.tiling:
//
//   { "windows": { "focusFollowsMouse": {
//       "enabled": false, "delay": 100, "raise": false } } }
//
// While enabled, the loader-owned native object applies Windows' X-Mouse
// values with SystemParametersInfoW. The plugin keeps one process-wide baseline
// and one live-controller list, so a reload's new generation reuses the
// baseline instead of capturing the old generation's applied values, and the
// old generation's teardown does not restore while the new one is live. The
// baseline and the applied values are saved to the profile runtime directory
// before the first write and restored when the option is disabled or the shell
// exits cleanly. After a crash the saved baseline is used only while the system
// still holds the recorded applied values; a user change in between discards it.
// Writes never set SPIF_UPDATEINIFILE, so the stored Windows preference is
// untouched and the next logon restores it after a crash.
//
// The native object is not constructed at all while the option is disabled,
// so a user who turns on X-Mouse in Windows keeps that setting.
QtObject {
    id: root

    readonly property var profileSettings: JSON.parse(
        JSON.stringify(GlobalConfig.windows.focusFollowsMouse ?? ({})))

    property bool enabled: false
    property int delay: 100
    property bool raise: false
    property bool applied: false
    property string status: "disabled"
    property string lastError: ""
    property string lastApplied: ""
    property bool configReady: false
    property bool startupLogged: false

    function normalizeDelay(value): int {
        if (typeof value !== "number" || !isFinite(value))
            return 100;
        return Math.max(0, Math.min(5000, Math.round(value)));
    }

    function applyNative(): void {
        const item = root.nativeLoader.item;
        if (!item)
            return;
        const nativeInstance = item.nativeInstance;
        if (!root.enabled) {
            nativeInstance.restore();
            return;
        }

        const signature = root.delay + ":" + (root.raise ? 1 : 0);
        if (nativeInstance.applied && signature === root.lastApplied)
            return;

        const ok = nativeInstance.apply(true, root.delay, root.raise);
        root.applied = nativeInstance.applied;
        root.status = nativeInstance.status;
        root.lastError = nativeInstance.lastError;

        if (ok) {
            root.lastApplied = signature;
            console.log("CAELESTIA_FOCUS_FOLLOWS_MOUSE enabled=1 delay=" + root.delay
                + " raise=" + (root.raise ? 1 : 0) + " status=" + root.status);
        } else {
            root.lastApplied = "";
            console.log("CAELESTIA_FOCUS_FOLLOWS_MOUSE_ERROR " + root.lastError);
        }
    }

    function applyConfiguration(): void {
        const settings = root.profileSettings;
        const enabled = settings.enabled === true;
        const delay = root.normalizeDelay(settings.delay);
        const raise = settings.raise === true;
        const changed = enabled !== root.enabled || delay !== root.delay || raise !== root.raise;

        root.enabled = enabled;
        root.delay = delay;
        root.raise = raise;

        if (!enabled) {
            if (root.nativeLoader.item) {
                const nativeInstance = root.nativeLoader.item.nativeInstance;
                nativeInstance.restore();
                root.applied = nativeInstance.applied;
                root.status = nativeInstance.status;
                root.lastError = nativeInstance.lastError;
                if (root.status === "error") {
                    root.lastApplied = "";
                    console.log("CAELESTIA_FOCUS_FOLLOWS_MOUSE_ERROR " + root.lastError);
                    return;
                }
            }
            root.applied = false;
            root.status = "disabled";
            root.lastError = "";
            root.lastApplied = "";
            if (changed)
                console.log("CAELESTIA_FOCUS_FOLLOWS_MOUSE enabled=0 status=disabled");
            return;
        }

        if (root.nativeLoader.item)
            root.applyNative();
        else
            root.status = "loading";
    }

    onProfileSettingsChanged: if (root.configReady) root.applyConfiguration()

    readonly property Loader nativeLoader: Loader {
        id: loader

        active: root.enabled
        source: root.enabled ? Qt.resolvedUrl("NativeFocusFollowsMouse.qml") : ""

        onLoaded: root.applyNative()
        onStatusChanged: {
            if (loader.status === Loader.Error) {
                root.applied = false;
                root.status = "error";
                root.lastError = "The Windows focus-follows-mouse component failed to load.";
            }
        }
    }

    readonly property Connections nativeSignals: Connections {
        target: root.nativeLoader.item ? root.nativeLoader.item.nativeInstance : null

        function onStateChanged(): void {
            root.applied = target.applied;
            root.status = target.status;
            root.lastError = target.lastError;
        }
    }

    Component.onCompleted: {
        root.configReady = true;
        root.applyConfiguration();
    }

    function logStartupStatus(): void {
        if (root.startupLogged)
            return;
        root.startupLogged = true;
        console.log("CAELESTIA_FOCUS_FOLLOWS_MOUSE_STARTUP enabled="
            + (root.enabled ? 1 : 0) + " delay=" + root.delay
            + " raise=" + (root.raise ? 1 : 0) + " status=" + root.status);
    }
}
