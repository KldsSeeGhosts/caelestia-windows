import QtQuick
import Quickshell.Services.UPower

// Loaded by URL only after Battery.enabled. Referencing the UPower singleton
// performs the backend's initial synchronous GetSystemPowerStatus read and
// starts its own 30-second poll and power notifications; construction makes no
// writes and references no PowerProfiles. A failed native read maps to
// isPresent=false, which the adapter reports as truthful battery absence.
QtObject {
    id: root

    // The native singleton has no initialization flag; completing construction
    // means the initial status read has happened.
    readonly property bool ready: true

    readonly property var displayDevice: UPower.displayDevice
    readonly property bool onBattery: UPower.onBattery
}
