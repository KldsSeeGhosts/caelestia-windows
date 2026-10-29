pragma Singleton

import QtQuick
import Quickshell
import Caelestia.Config
import qs.components.misc
import qs.services

// Windows facade for the bounded parts of services/Brightness.qml. It preserves
// the original singleton surface for the staged UI: one typed Monitor object per
// Quickshell screen, brightness/setBrightness, getMonitorForScreen/getMonitor,
// increaseBrightness/decreaseBrightness and the route-labelled capability state.
//
// Read-only observation is CAELESTIA_WINDOWS_BRIGHTNESS=1, writes are
// CAELESTIA_WINDOWS_BRIGHTNESS_CONTROLS=1 and software gamma writes additionally
// require CAELESTIA_WINDOWS_BRIGHTNESS_SOFTWARE=1. Native writes also require
// the strict-route backend, feature-detected by the service; the shared gitlink
// predates it, so Interactive is refused and the slider is read-only on this
// build. With brightness disabled the native loader is inactive: no
// NativeBrightnessBackend, no Brightness singleton, no query and no probe. The
// original IPC handler and Linux processes (asdbctl/ddcutil/brightnessctl) are
// not staged; the upstream brightnessUp/brightnessDown GlobalShortcuts are kept
// and still require the controls gate before any native write.
BrightnessService {
    id: root

    enabled: Quickshell.env("CAELESTIA_WINDOWS_BRIGHTNESS") === "1"
    controlsEnabled: enabled && Quickshell.env("CAELESTIA_WINDOWS_BRIGHTNESS_CONTROLS") === "1"
    softwareEnabled: controlsEnabled && Quickshell.env("CAELESTIA_WINDOWS_BRIGHTNESS_SOFTWARE") === "1"
    screens: Quickshell.screens
    backend: nativeLoader.item ?? null
    backendError: nativeLoader.status === Loader.Error
        ? "The Windows brightness backend component failed to load." : ""

    // Observable construction policy: false unless the observation opt-in
    // requests the native facade. The native facade does not probe by itself.
    readonly property bool nativeRequested: nativeLoader.active

    // Upstream compatibility values. Windows has no ddcutil bus map, Apple
    // display helper or Hyprland monitor identity; these cannot become truth.
    readonly property list<var> ddcMonitors: []
    readonly property var ddcMonitorMap: ({})
    readonly property bool appleDisplayPresent: false

    readonly property list<Monitor> monitors: variants.instances

    // Windows has no per-window brightness target. The bar can address the
    // screen that received the action, and the global shortcuts use the
    // focused monitor reported by the Hypr facade; otherwise only a
    // single-monitor desktop has an unambiguous active monitor.
    property ShellScreen activeScreen: null
    readonly property var activeMonitor: {
        const screen = root.activeScreen;
        if (screen)
            return root.monitors.find(monitor => monitor.modelData === screen) ?? null;
        // The Hypr facade exposes one Windows-wide focused monitor. Match it by
        // name because the brightness Monitor wraps a different Screen object.
        const focused = Hypr.focusedMonitor;
        if (focused?.name)
            return root.monitors.find(monitor => monitor.modelData.name === focused.name) ?? null;
        return root.monitors.length === 1 ? root.monitors[0] : null;
    }
    readonly property real brightnessIncrement: GlobalConfig.services.brightnessIncrement

    function getMonitorForScreen(screen): var {
        return root.monitors.find(monitor => monitor.modelData === screen) ?? null;
    }

    // Preserved upstream query forms. "id:" depends on Hyprland workspace ids
    // and cannot be answered on Windows; it returns null rather than guessing.
    function getMonitor(query): var {
        if (typeof query !== "string" || query.length === 0)
            return null;
        if (query === "active")
            return root.activeMonitor;
        if (query.startsWith("model:")) {
            const model = query.slice(6);
            return root.monitors.find(monitor => monitor.modelData.model === model) ?? null;
        }
        if (query.startsWith("serial:")) {
            const serial = query.slice(7);
            return root.monitors.find(monitor => monitor.modelData.serialNumber === serial) ?? null;
        }
        if (query.startsWith("id:"))
            return null;
        return root.monitors.find(monitor => monitor.modelData.name === query) ?? null;
    }

    function increaseBrightness(): void {
        const monitor = root.activeMonitor;
        if (monitor)
            monitor.setBrightness(monitor.brightness + root.brightnessIncrement);
    }

    function decreaseBrightness(): void {
        const monitor = root.activeMonitor;
        if (monitor)
            monitor.setBrightness(monitor.brightness - root.brightnessIncrement);
    }

    // BrightnessService is a plain QtObject and has no default property, so
    // the object generators are held by typed properties like the media facade.
    readonly property Variants _variants: Variants {
        id: variants

        model: Quickshell.screens

        Monitor {}
    }
    component Monitor: QtObject {
        id: monitor

        required property ShellScreen modelData

        readonly property string screenName: modelData?.name ?? ""
        readonly property var record: root.stateFor(screenName)

        readonly property string capability: record?.state ?? "unknown"
        readonly property string route: record?.route ?? ""
        readonly property string routeLabel: root.routeLabel(route)
        readonly property string stateLabel: root.capabilityLabel(capability)
        readonly property string stateReason: root.capabilityReason(screenName)

        readonly property real brightness: record?.brightness ?? 0
        readonly property bool brightnessKnown: record?.brightnessKnown ?? false
        // Bumped by the service after a denied or failed write. A drag removed
        // the slider's value binding, so the host uses this serial to rebind
        // the displayed value to the confirmed level.
        readonly property int resyncSerial: record?.resyncSerial ?? 0
        // interactive keeps the slider usable while a coalesced write is in
        // flight; writable/writeReady additionally require no write pending.
        readonly property bool interactive: root.interactive(screenName)
        readonly property bool writeReady: root.canWrite(screenName)
        readonly property bool writable: writeReady
        readonly property bool latched: record?.latched ?? false
        readonly property string lastOutcome: record?.lastOutcome ?? "none"
        readonly property string lastError: record?.lastError ?? ""

        // Upstream field names kept so original consumers load. Windows uses no
        // I2C bus number and has no Apple display helper.
        readonly property bool isDdc: route === "ddc"
        readonly property string busNum: ""
        readonly property bool isAppleDisplay: false

        function setBrightness(value: real): void {
            root.write(screenName, value);
        }

        function increase(): void {
            root.nudge(screenName, root.brightnessIncrement);
        }

        function decrease(): void {
            root.nudge(screenName, -root.brightnessIncrement);
        }

        // Explicit user action only. Re-detects this monitor's route and clears
        // a route-change latch; it can drop software dimming this process
        // applied earlier.
        function refreshRoute(): void {
            root.queryMonitor(screenName);
        }
    }

    readonly property Loader _nativeLoader: Loader {
        id: nativeLoader

        active: root.enabled
        source: root.enabled ? Qt.resolvedUrl("NativeBrightnessBackend.qml") : ""
    }

    // The original services/Brightness.qml global shortcuts. The facade refuses
    // every write while the controls opt-in is off, so these are inert in
    // read-only observation runs instead of failing the native route.
    readonly property list<QtObject> _shortcuts: [
        CustomShortcut {
            name: "brightnessUp"
            description: "Increase brightness"
            onPressed: root.increaseBrightness()
        },
        CustomShortcut {
            name: "brightnessDown"
            description: "Decrease brightness"
            onPressed: root.decreaseBrightness()
        }
    ]
}
