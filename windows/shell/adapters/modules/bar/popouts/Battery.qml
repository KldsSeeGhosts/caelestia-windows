import QtQuick
import qs.services

// Windows combined host wiring for the original battery popout, matching the
// bounded battery prototype host. The facade singleton is staged as
// WindowsBattery so its name never shadows this Battery component type that
// the original popouts Content instantiates directly. Profile observation
// follows the facade's separate PowerProfiles opt-in, profile writes are
// refused by the facade without CAELESTIA_WINDOWS_POWER_PROFILE_WRITES, and
// unknown observations use the original unavailable styling instead of a
// guessed value.
BatteryContent {
    profileStatusEnabled: WindowsBattery.profileStatusEnabled
    profileControlsEnabled: WindowsBattery.profileControlsEnabled
    profileWritesEnabled: WindowsBattery.profiles.writesPermitted
    availableProfiles: WindowsBattery.profiles.availableProfiles
    selectProfile: profile => WindowsBattery.profiles.requestProfile(profile)
    observationAvailable: WindowsBattery.observationAvailable
    percentageKnown: WindowsBattery.percentageKnown
    powerSourceKnown: WindowsBattery.onBatteryKnown
    timeToFullSupported: false
}
