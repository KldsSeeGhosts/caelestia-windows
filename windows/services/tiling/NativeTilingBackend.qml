import QtQuick
import Quickshell.Windows

// Loaded by URL only after CAELESTIA_WINDOWS_TILING=observe|interactive.
// Referencing the Quickshell.Windows `Tiling` singleton constructs
// TilingManager::instance(), which starts its timers, registers the
// aboutToQuit unpark hook and runs rescueParked() immediately
// (tiling.cpp:237-257). Construction leaves `enabled` false, but the rescue
// can move windows a previous run parked off-screen, so this file must only
// resolve behind the explicit opt-in. `off` never loads it.
//
// The shared build pins the backend WITHOUT the M3 allowlist and telemetry
// members (`included`, `lastError`, `managedCount`, `failedCount`,
// `enableRefused`, `windowTilingFailed` exist only on the
// windows/m3-windows-stack fork branch cd170acf). Every new member is
// feature-detected with typeof: on the pinned build the allowlist reports
// unsupported, telemetry reports defaults, and the signal forwarding stays
// disconnected. The service layer never writes `Tiling.enabled` directly;
// requestEnable() is the only path.
QtObject {
    id: root

    readonly property bool initialized: true

    // `included` arrives as a QStringList (typeof "object") on the fork;
    // the pinned build has no such property (typeof "undefined").
    readonly property bool supportsIncluded: typeof Tiling.included === "object"

    // The telemetry surface is only trusted when both signals and the error
    // string exist; a partial backend reports unsupported.
    readonly property bool supportsTelemetry: typeof Tiling.lastError === "string"
        && typeof Tiling.enableRefused === "function"
        && typeof Tiling.windowTilingFailed === "function"

    readonly property bool enabled: Tiling.enabled
    readonly property string lastError: root.supportsTelemetry ? Tiling.lastError : ""
    readonly property int managedCount: root.supportsTelemetry
        && typeof Tiling.managedCount === "number" ? Tiling.managedCount : 0
    readonly property int failedCount: root.supportsTelemetry
        && typeof Tiling.failedCount === "number" ? Tiling.failedCount : 0

    signal enableRefused(string reason)
    signal windowTilingFailed(string address, string reason)

    // QtObject has no default property, so the forwarding lives in a property.
    readonly property Connections _telemetry: Connections {
        target: root.supportsTelemetry ? Tiling : null

        function onEnableRefused(reason): void {
            root.enableRefused(reason);
        }
        function onWindowTilingFailed(address, reason): void {
            root.windowTilingFailed(address, reason);
        }
    }

    // The service owns the policy; the wrapper applies what the pinned
    // backend accepts. An unsupported `included` list is dropped here, which
    // the service has already refused interactive enabling for.
    function applyOptions(excluded, included): void {
        Tiling.excluded = excluded;
        if (root.supportsIncluded)
            Tiling.included = included;
    }

    function requestEnable(): void {
        Tiling.enabled = true;
    }

    Component.onCompleted: {
        console.info("CAELESTIA_TILING_BACKEND_READY supportsIncluded="
            + (root.supportsIncluded ? 1 : 0) + " supportsTelemetry="
            + (root.supportsTelemetry ? 1 : 0));
    }
}
