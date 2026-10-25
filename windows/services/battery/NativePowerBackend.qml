import QtQuick
import Quickshell.Services.UPower

// Loaded by URL only after Battery.enabled. Referencing the UPower singleton
// performs the backend's initial synchronous GetSystemPowerStatus read and
// starts its own 30-second poll and power notifications; construction makes no
// writes and references no PowerProfiles. The device exposes isAvailable,
// isPresenceKnown and isPercentageKnown, and onBatteryKnown marks whether the
// AC source read succeeded, so failed or unknown reads stay distinct from
// proven battery absence.
QtObject {
    id: root

    // The native singleton has no initialization flag; completing construction
    // means the initial status read has happened.
    readonly property bool ready: true

    readonly property var displayDevice: UPower.displayDevice
    readonly property bool onBattery: UPower.onBattery
    readonly property bool onBatteryKnown: UPower.onBatteryKnown
}
