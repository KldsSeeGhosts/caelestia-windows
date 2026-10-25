import QtQuick

// Windows adaptation of the read-only parts of the UPower contract consumed by
// modules/bar/components/status/BatteryStatus.qml and
// modules/bar/popouts/Battery.qml. This object has no native imports, timers,
// IPC, or process calls, and it exposes no mutating methods at all: this slice
// must never select a PowerProfile, write a power plan, or change IdlePower
// settings. Backends may be injected in tests.
QtObject {
    id: root

    // The injected backend is the NativePowerBackend facade (or a test fake)
    // exposing: ready (bool), displayDevice (UPowerDevice-like), onBattery (bool).
    property var backend: null
    property bool enabled: false

    // A loader can supply a known component failure. Native UPower read
    // failures are not exposed by the backend; they map to isPresent=false.
    property string backendError: ""

    readonly property bool backendReady: enabled && !backendError && !!backend?.ready

    // Null whenever the backend is missing, not ready, or stale. All device
    // projections below are null-safe against this value.
    readonly property var displayDevice: backendReady ? (backend?.displayDevice ?? null) : null

    // UPowerDeviceState numeric values from Quickshell.Services.UPower.
    readonly property int stateUnknown: 0
    readonly property int stateCharging: 1
    readonly property int stateDischarging: 2
    readonly property int stateEmpty: 3
    readonly property int stateFullyCharged: 4
    readonly property int statePendingCharge: 5
    readonly property int statePendingDischarge: 6

    // Truthful absence: a failed native read maps to isPresent=false, and
    // percentage/state never become a fake battery. hasBattery matches
    // upstream's display gating (a battery-type power supply).
    readonly property bool present: !!displayDevice && displayDevice.isPresent === true
    readonly property bool laptopBattery: present && displayDevice?.isLaptopBattery === true
    readonly property bool hasBattery: present && laptopBattery

    // Guards reject nonfinite and out-of-range native values instead of
    // propagating them. Absence gates every device projection: the backend
    // zeroes these fields when the status read fails, and a stale device
    // object can never report a level, estimate, state, or icon for a system
    // with no present battery. Consumers must still gate display on
    // hasBattery, never on the number alone.
    readonly property real percentage: {
        if (!present)
            return 0;
        const value = displayDevice?.percentage;
        return Number.isFinite(value) ? Math.max(0, Math.min(1, value)) : 0;
    }
    readonly property int state: {
        if (!present)
            return stateUnknown;
        const value = displayDevice?.state;
        return Number.isInteger(value) && value >= stateUnknown && value <= statePendingDischarge
            ? value : stateUnknown;
    }
    readonly property real timeToEmpty: {
        if (!present)
            return 0;
        const value = displayDevice?.timeToEmpty;
        return Number.isFinite(value) && value > 0 ? value : 0;
    }
    readonly property string iconName: {
        if (!present)
            return "";
        const value = displayDevice?.iconName;
        return typeof value === "string" ? value : "";
    }

    // Charging follows upstream's BatteryStatus icon gating: Charging,
    // FullyCharged and PendingCharge all count as "charging".
    readonly property bool charging: [stateCharging, stateFullyCharged, statePendingCharge].includes(state)

    // AC/battery source observation. With no battery the Windows API reports
    // line power or an unknown source; neither is "on battery".
    readonly property bool onBattery: backendReady && backend?.onBattery === true

    readonly property bool ready: status === "ready"
    readonly property string status: {
        if (!enabled)
            return "disabled";
        if (backendError)
            return "unavailable";
        if (!backend)
            return "initializing";
        if (!backendReady)
            return "unavailable";
        return "ready";
    }
    readonly property string reason: {
        if (!enabled)
            return "Windows power status is disabled.";
        if (backendError)
            return backendError;
        if (!backend)
            return "Waiting for the Windows power backend.";
        if (!backendReady)
            return "The Windows power backend is not ready; initialization may have failed. Native error details are not exposed.";
        if (!hasBattery)
            return "No battery detected on this system.";
        return "Windows power status is observable. Profile selection and power-plan writes stay unavailable in this slice.";
    }
}
