pragma Singleton

import QtQuick
import Quickshell

// Windows stand-in for services/Hypr.qml, staged at services/Hypr.qml only by
// the hypr prototype. It keeps the property/function surface that the original
// Caelestia modules consume while replacing the Hyprland IPC singleton with the
// bounded HyprService state object. The Quickshell.Hyprland import lives only
// in NativeHyprBackend.qml, which this facade loads through a Loader after the
// CAELESTIA_WINDOWS_HYPR=1 observation opt-in. With neither opt-in the facade
// resolves no native type, loads no component and performs no dispatch.
//
// Dispatch needs the separate CAELESTIA_WINDOWS_HYPR_DISPATCH=1 opt-in. The
// allowlist and its refusals are implemented and fixture-tested in
// HyprService.qml.
//
// Keyboard fields (capsLock, numLock, kbLayout, ...) and HyprExtras/options are
// not supplied by the pinned Windows backend. They are present with truthful
// unavailable defaults so consumers that statically reference them still load;
// no Windows keyboard or Hyprland configuration state is measured. `extras` is
// a no-op object because there is no Hyprland configuration socket to message.
HyprService {
    id: root

    enabled: Quickshell.env("CAELESTIA_WINDOWS_HYPR") === "1"
    dispatchEnabled: enabled && Quickshell.env("CAELESTIA_WINDOWS_HYPR_DISPATCH") === "1"
    backend: nativeLoader.item ?? null
    backendError: nativeLoader.status === Loader.Error
        ? "The Windows Hyprland observation backend component failed to load." : ""

    // Observable construction policy: false unless the observation opt-in
    // requests the native facade. The facade is what constructs Hyprland.
    readonly property bool nativeRequested: nativeLoader.active

    readonly property Loader _nativeLoader: Loader {
        id: nativeLoader

        active: root.enabled
        source: root.enabled ? Qt.resolvedUrl("NativeHyprBackend.qml") : ""
    }

    // Upstream services/Hypr.qml:35-37, currently unreachable from the staged
    // bar components. Picker/Colours are replaced by adapters in the prototype.
    readonly property QtObject extras: QtObject {
        readonly property var options: ({})
        function refreshOptions(): void {
        }
        function batchMessage(messages): void {
        }
    }
    readonly property var options: root.extras.options
    readonly property var devices: ({
        keyboards: []
    })
    readonly property var keyboard: null
    readonly property bool capsLock: false
    readonly property bool numLock: false
    readonly property string defaultKbLayout: "??"
    readonly property string kbLayoutFull: ""
    readonly property string kbLayout: "??"
    readonly property var kbMap: new Map()

    property string lastSpecialWorkspace: ""
    property bool statusLogged: false

    // Upstream emits this when Hyprland reports configreloaded. The pinned
    // Windows backend never emits that event, so this signal is present for
    // consumers and never fired.
    signal configReloaded

    // Printed once by the prototype host so the launch log proves which opt-ins
    // the child process observed.
    function logStartupStatus(): void {
        if (root.statusLogged)
            return;
        root.statusLogged = true;
        console.log("CAELESTIA_HYPR_STATUS hypr=" + (root.enabled ? 1 : 0)
            + " dispatch=" + (root.dispatchEnabled ? 1 : 0));
    }
}
