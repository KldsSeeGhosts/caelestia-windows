import QtQuick
import qs.services

// Windows combined host wiring for the original battery status icon, matching
// the bounded battery prototype host. The facade singleton is staged as
// WindowsBattery (see the battery popout adapter). The profile hook stays
// disabled unless the separate PowerProfiles observation opt-in is set, and
// unknown reads keep the original unavailable icon instead of a guessed
// level.
BatteryStatusContent {
    profileStatusEnabled: WindowsBattery.profileStatusEnabled
    observationAvailable: WindowsBattery.observationAvailable
    percentageKnown: WindowsBattery.percentageKnown
}
