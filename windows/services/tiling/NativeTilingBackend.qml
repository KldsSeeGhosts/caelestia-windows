import QtQuick
import Quickshell.Windows
import qs.services

// Loaded by URL only after CAELESTIA_WINDOWS_TILING=observe|interactive.
// Referencing the Quickshell.Windows `Tiling` singleton constructs
// TilingManager::instance(), which starts its timers, registers the
// aboutToQuit unpark hook and runs rescueParked() immediately
// (tiling.cpp:237-257). Construction leaves `enabled` false, but the rescue
// can move windows a previous run parked off-screen, so this file must only
// resolve behind the explicit opt-in. `off` never loads it.
//
// Older builds lack the M3 allowlist/telemetry or typed-selector capability.
// Each capability is feature-detected: on old builds the allowlist reports
// unsupported, telemetry reports defaults, and the signal forwarding stays
// disconnected. The service layer never writes `Tiling.enabled` directly;
// requestEnable() is the only path.
QtObject {
    id: root

    readonly property bool initialized: true

    // `included` arrives as a QStringList (typeof "object") on the fork;
    // the pinned build has no such property (typeof "undefined").
    readonly property bool supportsIncluded: typeof Tiling.included === "object"
    readonly property bool supportsScopedRules: typeof Tiling.supportsScopedRules === "boolean"
        && Tiling.supportsScopedRules

    // Allowlist entries the backend accepted after validation; -1 on a build
    // that cannot report it. The service refuses to enable an allowlist that
    // is configured but left empty by validation.
    readonly property int includedRuleCount: root.supportsIncluded
        && typeof Tiling.includedRuleCount === "number" ? Tiling.includedRuleCount : -1

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

    // The drop a dragged tiled window would make now, for DragPreview.qml.
    // Rectangles are logical and local to the screen named by dragScreen.
    readonly property bool supportsDragPreview: typeof Tiling.dragActive === "boolean"
    readonly property bool dragActive: root.supportsDragPreview && Tiling.dragActive
    readonly property string dragMode: root.supportsDragPreview ? Tiling.dragMode : ""
    readonly property string dragScreen: root.supportsDragPreview ? Tiling.dragScreen : ""
    readonly property rect dragLanding: root.supportsDragPreview ? Tiling.dragLanding : Qt.rect(0, 0, 0, 0)
    readonly property rect dragDisplaced: root.supportsDragPreview ? Tiling.dragDisplaced : Qt.rect(0, 0, 0, 0)

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
    function applyOptions(excluded, included, gapsIn, gapsOut, singleWindowGapsOut, borderColours): void {
        Tiling.excluded = excluded;
        if (root.supportsIncluded)
            Tiling.included = included;
        Tiling.gapsIn = gapsIn;
        Tiling.gapsOut = gapsOut;
        Tiling.singleWindowGapsOut = singleWindowGapsOut;
        Tiling.borderColours = borderColours;
        console.info("CAELESTIA_TILING_OPTIONS gapsIn=" + Tiling.gapsIn
            + " gapsOut=" + Tiling.gapsOut
            + " singleWindowGapsOut=" + Tiling.singleWindowGapsOut
            + " borderColours=" + Tiling.borderColours);
    }

    // Incremental per-field setters. A live option change writes only the field
    // that changed instead of stopping the session, so the wrapper maps each
    // service option onto the pinned `Tiling` property it already exposes. The
    // manager's setters mark their windows dirty and arm one shared sync timer,
    // so a batch of related rule writes still syncs once.
    function setExcluded(excluded): void {
        Tiling.excluded = excluded;
    }
    function setIncluded(included): void {
        if (root.supportsIncluded)
            Tiling.included = included;
    }
    function setGapsIn(gaps): void {
        Tiling.gapsIn = gaps;
    }
    function setGapsOut(gaps): void {
        Tiling.gapsOut = gaps;
    }
    function setSingleWindowGapsOut(gaps): void {
        Tiling.singleWindowGapsOut = gaps;
    }
    function setBorderColours(enabled): void {
        Tiling.borderColours = enabled;
    }

    // DWM accepts opaque COLORREFs. Match Hyprland's 0xe6 / 0x11
    // scheme borders by compositing against the scheme surface.
    function blend(foreground, surface, alpha): color {
        return Qt.rgba(foreground.r * alpha + surface.r * (1 - alpha),
            foreground.g * alpha + surface.g * (1 - alpha),
            foreground.b * alpha + surface.b * (1 - alpha), 1);
    }

    readonly property Binding _activeBorder: Binding {
        target: Tiling
        property: "activeBorderColour"
        value: root.blend(Colours.palette.m3primary, Colours.palette.m3surface, 230 / 255)
    }
    readonly property Binding _inactiveBorder: Binding {
        target: Tiling
        property: "inactiveBorderColour"
        value: root.blend(Colours.palette.m3onSurfaceVariant, Colours.palette.m3surface, 17 / 255)
    }

    function requestEnable(): void {
        Tiling.enabled = true;
    }

    function requestDisable(): void {
        Tiling.enabled = false;
    }

    // Safe under a reload: the shared manager accepts this write only from the
    // newest engine's lease, so a retiring wrapper cannot stop the session its
    // replacement claimed (tiling.cpp, TilingLease).
    Component.onDestruction: root.requestDisable()

    Component.onCompleted: {
        console.info("CAELESTIA_TILING_BACKEND_READY supportsIncluded="
            + (root.supportsIncluded ? 1 : 0) + " supportsTelemetry="
            + (root.supportsTelemetry ? 1 : 0));
    }
}
