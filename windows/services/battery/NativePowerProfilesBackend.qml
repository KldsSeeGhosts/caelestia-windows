import QtQuick
import Quickshell.Services.UPower

// Thin facade over the pinned Quickshell PowerProfiles singleton. Loaded by URL
// only after the CAELESTIA_WINDOWS_POWER_PROFILES opt-in, so constructing it
// registers the backend's effective-power-mode notification and performs its
// initial read-only PowerGetEffectiveOverlayScheme refresh. It never writes
// during construction and never writes unless PowerProfilesService sends an
// explicitly opted-in request.
//
// Read verification: powerprofiles.cpp refresh() only logs a failed
// PowerGetEffectiveOverlayScheme read and leaves bProfile at its
// zero-initialized PowerSaver value (Qt 6.11.2 qproperty.h:73). The singleton
// exposes no read-success property. This host performs no write before
// observation, so a Balanced/Performance value can only come from a successful
// refresh and proves the read. PowerSaver is ambiguous: it may be a real overlay
// or a failed read, and is reported unknown. A profileChanged notification also
// proves that the property is live. A backend fork should expose an explicit
// read-success flag; see windows/battery-prototype/README.md.
QtObject {
    id: root

    // PowerProfiles construction is synchronous and completes its initial
    // refresh before this facade exists; there is no separate ready flag.
    readonly property bool ready: true

    // Raw singleton value. PowerProfilesService projects it only when
    // profileKnown is true.
    readonly property int profile: PowerProfiles.profile

    property bool _liveRead: false
    readonly property bool profileKnown: _liveRead
        || (profile !== PowerProfile.PowerSaver)

    // Explicit overlay GUID mapping reviewed at powerprofiles.cpp:50-62:
    // PowerSaver -> 961cc777, Performance -> ded574b5, Balanced -> zero GUID.
    // PowerProfiles.hasPerformanceProfile is hard-coded true and is not evidence
    // of platform support, so it never extends this set. Actual acceptance of a
    // Performance write remains unverified until an observed transition.
    readonly property var mappedProfiles: [
        PowerProfile.PowerSaver, PowerProfile.Balanced, PowerProfile.Performance
    ]
    // Diagnostic only: the raw hard-coded native claim.
    readonly property bool performanceClaim: PowerProfiles.hasPerformanceProfile
    // The pinned backend logs a failed PowerSetActiveOverlayScheme and exposes
    // no public write result.
    readonly property bool writeResultAvailable: false
    // PowerProfiles exposes no read/write error text.
    readonly property string lastError: ""

    onProfileChanged: _liveRead = true

    function setProfile(target): bool {
        if (target !== PowerProfile.PowerSaver && target !== PowerProfile.Balanced
                && target !== PowerProfile.Performance) {
            return false;
        }
        PowerProfiles.profile = target;
        // True only means the request was submitted. The service confirms by
        // observing the profile transition, because a native failure only logs.
        return true;
    }
}
