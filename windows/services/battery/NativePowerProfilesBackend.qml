import Quickshell.Services.UPower

// Loaded only after the profile observation opt-in. Construction reads and
// registers notifications; only an explicit service request can submit a write.
PowerProfilesBackend {
    source: PowerProfiles
}
