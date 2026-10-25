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
    // exposing: ready (bool), displayDevice (UPowerDevice-like), onBattery
    // (bool), onBatteryKnown (bool). The device exposes the matched capability
    // fields isAvailable, isPresenceKnown and isPercentageKnown so a failed or
    // unknown native read is not mistaken for an absent battery.
    property var backend: null
    property bool enabled: false

    // A loader can supply a known component failure. Native UPower read
    // failures are exposed as capability fields, not as proven absence.
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

    // A successful platform read is separate from what the read proved.
    readonly property bool nativeReadAvailable: backendReady && displayDevice?.isAvailable === true
    readonly property bool presenceKnown: nativeReadAvailable && displayDevice?.isPresenceKnown === true

    // observationAvailable means battery presence is trustworthy: the read
    // succeeded and Windows returned a known presence flag. present and absent
    // are the two proven outcomes; neither covers a failed or unknown read.
    readonly property bool observationAvailable: presenceKnown
    readonly property bool present: presenceKnown && displayDevice?.isPresent === true
    readonly property bool absent: observationAvailable && !present

    // Truthful presence: hasBattery matches upstream's display gating (a
    // battery-type power supply).
    readonly property bool laptopBattery: present && displayDevice?.isLaptopBattery === true
    readonly property bool hasBattery: present && laptopBattery

    // 255 (BATTERY_PERCENTAGE_UNKNOWN) is not 0%. A known level is required
    // before any percentage is projected.
    readonly property bool percentageKnown: present && displayDevice?.isPercentageKnown === true
        && Number.isFinite(displayDevice?.percentage)
        && displayDevice.percentage >= 0 && displayDevice.percentage <= 1

    // Guards reject nonfinite and out-of-range native values instead of
    // propagating them. Presence and capability gate every device projection:
    // the backend clears these fields when the status read fails, and a stale
    // device object can never report a level, estimate, state, or icon for a
    // system with no present battery. Consumers must still gate display on
    // hasBattery, never on the number alone.
    readonly property real percentage: {
        if (!percentageKnown)
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

    // AC/battery source observation. A stale onBattery value from a failed
    // native read is rejected through onBatteryKnown.
    readonly property bool onBatteryKnown: nativeReadAvailable && backend?.onBatteryKnown === true
    readonly property bool onBattery: onBatteryKnown && backend?.onBattery === true

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
        if (!observationAvailable)
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
        if (!nativeReadAvailable)
            return "Windows power status could not be read; battery presence is unknown.";
        if (!presenceKnown)
            return "Windows returned an unknown battery presence state.";
        if (!present)
            return "No battery detected on this system.";
        if (!percentageKnown)
            return "Windows reported a battery, but no valid charge level.";
        return "Windows power status is observable. Profile selection and power-plan writes stay unavailable in this slice.";
    }
}
