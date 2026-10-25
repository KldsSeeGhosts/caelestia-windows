pragma Singleton

import QtQuick
import Quickshell

BatteryService {
    id: root

    // These flags belong only to the child shell process. Importing Battery
    // with power status disabled never resolves/creates the native backend.
    enabled: Quickshell.env("CAELESTIA_WINDOWS_BATTERY") === "1"
    backend: nativeLoader.item ?? null
    backendError: nativeLoader.status === Loader.Error ? "The Windows power backend component failed to load." : ""

    // Profile observation is a second, additive opt-in. It keeps the battery
    // read-only slice intact: no PowerProfiles reference is resolved unless this
    // flag is explicitly set.
    readonly property bool profilesEnabled: enabled
        && Quickshell.env("CAELESTIA_WINDOWS_POWER_PROFILES") === "1"
    // Writes are a third, separate opt-in. Smoke always forces them off, both in
    // the launcher and here, so a staged smoke cannot select a profile.
    readonly property bool profileWritesRequested: profilesEnabled
        && Quickshell.env("CAELESTIA_WINDOWS_POWER_PROFILE_WRITES") === "1"
        && Quickshell.env("CAELESTIA_SHELL_SMOKE") !== "1"

    readonly property PowerProfilesService profiles: PowerProfilesService {
        enabled: root.profilesEnabled
        writesEnabled: root.profileWritesRequested
        backend: profileLoader.item ?? null
        backendError: profileLoader.status === Loader.Error ? "The Windows power profile backend component failed to load." : ""
    }

    // Host wiring for the original components. The selector is shown read-only
    // only while a mapped profile is actually observed; unknown or unsupported
    // observation keeps it hidden and reports the profile as unavailable.
    readonly property bool profileStatusEnabled: profiles.observing
    readonly property bool profileControlsEnabled: profiles.observing
    readonly property bool profileControlsWritable: profiles.writesPermitted

    readonly property Loader _nativeLoader: Loader {
        id: nativeLoader

        active: root.enabled
        source: root.enabled ? Qt.resolvedUrl("NativePowerBackend.qml") : ""
    }

    // Loaded by URL only after the profile opt-in. The facade keeps the
    // PowerProfiles singleton out of read-only battery processes.
    readonly property bool nativeProfilesRequested: profileLoader.active
    readonly property Loader _profileLoader: Loader {
        id: profileLoader

        active: root.profilesEnabled
        source: root.profilesEnabled ? Qt.resolvedUrl("NativePowerProfilesBackend.qml") : ""
    }
}
