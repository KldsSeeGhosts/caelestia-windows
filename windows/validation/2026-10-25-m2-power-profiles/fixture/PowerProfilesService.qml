import QtQuick

// Windows adaptation of the PowerProfiles capability consumed by the original
// battery status/popout components. This object has no native imports: the thin
// NativePowerProfilesBackend.qml facade supplies the pinned Quickshell
// singleton, and fixtures inject a fake backend directly.
//
// Injected backend contract:
//   ready (bool)              facade constructed
//   profileKnown (bool)       the effective overlay read is verified; a raw
//                             profile value alone is not proof
//   profile (int)             PowerProfile enum value
//   mappedProfiles (var[])    profile ids the wrapper can truthfully map
//   performanceClaim (bool)   raw native hasPerformanceProfile, diagnostics
//                             only; never used to extend availability
//   writeResultAvailable bool whether the backend supplies a synchronous write
//                             result
//   lastError (string)
//   setProfile(profile)       submits one request; true means accepted, not
//                             confirmed
//
// The pinned backend has no read-success or write-result signal. The wrapper
// verifies a non-default observation and this object confirms a write only from
// an observed overlay-mapped profile transition within writeTimeoutMs. Backend
// gaps and a fork fix outline are recorded in
// windows/battery-prototype/README.md.
QtObject {
    id: root

    property var backend: null
    property bool enabled: false
    // Observation and writes are separate opt-ins. Observation alone never
    // calls setProfile.
    property bool writesEnabled: false
    property string backendError: ""
    // Bounded wait for the overlay-mapped profile to change after a request.
    property int writeTimeoutMs: 4000

    readonly property int profileSaver: 0
    readonly property int profileBalanced: 1
    readonly property int profilePerformance: 2
    readonly property int profileUnknown: -1

    readonly property bool backendReady: enabled && !backendError && backend?.ready === true
    readonly property bool profileKnown: backendReady && backend?.profileKnown === true
        && isValidProfile(backend?.profile)
    // Verified raw backend value, before the representable-profile filter. A
    // stale value when the read is unverified is rejected here.
    readonly property int rawBackendProfile: profileKnown ? backend.profile : profileUnknown
    // A stale, unknown or unrepresentable native value is never projected as the
    // current profile. -1 means unknown.
    readonly property int profile: profileKnown
        && availableProfiles.indexOf(rawBackendProfile) >= 0 ? rawBackendProfile : profileUnknown

    // Only explicit backend mappings are exposed. Duplicate or invalid native
    // values are dropped. The hard-coded Performance availability claim is not
    // used to add a profile here.
    readonly property var availableProfiles: {
        if (!backendReady)
            return [];
        const reported = backend?.mappedProfiles;
        if (!reported || typeof reported.length !== "number")
            return [];
        const result = [];
        for (let i = 0; i < reported.length; i++) {
            const value = reported[i];
            if (isValidProfile(value) && result.indexOf(value) < 0)
                result.push(value);
        }
        return result;
    }
    readonly property bool performanceMapped: availableProfiles.indexOf(profilePerformance) >= 0
    // Diagnostic only. powerprofiles.cpp hard-codes this true; availability is
    // derived from the explicit GUID mapping in mappedProfiles instead.
    readonly property bool performanceClaim: backend?.performanceClaim === true
    readonly property bool writeResultAvailable: backend?.writeResultAvailable === true

    // disabled -> no opt-in; initializing -> waiting for the facade;
    // unsupported -> known backend failure/unready; unknown -> the effective
    // overlay read is unverified; observing -> a mapped profile is verified.
    readonly property string state: {
        if (!enabled)
            return "disabled";
        if (backendError)
            return "unsupported";
        if (!backend)
            return "initializing";
        if (!backendReady)
            return "unsupported";
        if (!profileKnown)
            return "unknown";
        if (availableProfiles.indexOf(profile) < 0)
            return "unknown";
        return "observing";
    }
    readonly property bool observing: state === "observing"
    readonly property bool writesPermitted: enabled && writesEnabled && backendReady
        && availableProfiles.length > 0

    readonly property string profileName: profileNameFor(profile)
    readonly property string reason: {
        if (!enabled)
            return "Windows power profile observation is disabled.";
        if (backendError)
            return backendError;
        if (!backend)
            return "Waiting for the Windows power profile backend.";
        if (!backendReady)
            return "The Windows power profile backend is unavailable; PowerProfiles initialization or the overlay API failed, and native error details are not exposed.";
        if (!profileKnown)
            return "The effective overlay scheme is not verified, so the current power profile is unknown. The pinned backend reports neither read success nor read failure.";
        if (availableProfiles.indexOf(profile) < 0)
            return "The effective overlay scheme mapped to a profile this backend cannot represent.";
        if (!writesEnabled)
            return "The effective overlay scheme is observable as " + profileName + ". Power profile writes are disabled; observation is read-only.";
        return "The effective overlay scheme is observable as " + profileName + ". Power profile writes are enabled for the mapped profiles.";
    }

    // idle -> no request; pending -> waiting for an observed transition;
    // confirmed -> the requested profile was observed (or was already current);
    // unconfirmed -> no observed transition within writeTimeoutMs or a rejected
    // native submission; rejected -> the request never reached the backend.
    property string writeState: "idle"
    property int requestedProfile: profileUnknown
    property string writeError: ""
    property bool lastWriteNoop: false
    property int writeAttempts: 0
    property int confirmedWrites: 0
    property int unconfirmedWrites: 0
    property int rejectedWrites: 0

    readonly property bool writePending: writeState === "pending"
    readonly property bool writeFailed: writeState === "unconfirmed"
    readonly property int effectiveWriteTimeoutMs: Number.isFinite(writeTimeoutMs)
        && writeTimeoutMs > 0 ? writeTimeoutMs : 4000
    readonly property string writeReason: {
        if (!enabled)
            return "Power profile writes are disabled.";
        if (!writesEnabled)
            return "Power profile writes are disabled; observation is read-only.";
        if (writeState === "pending")
            return "Waiting for the overlay to report " + profileNameFor(requestedProfile) + ".";
        if (writeState === "confirmed")
            return lastWriteNoop
                ? "The requested profile was already observed; no write was sent."
                : "The overlay reported the requested profile.";
        if (writeState === "unconfirmed" || writeState === "rejected")
            return writeError;
        return "";
    }

    function isValidProfile(value): bool {
        return Number.isInteger(value) && value >= profileSaver && value <= profilePerformance;
    }

    function profileNameFor(value): string {
        switch (value) {
        case profileSaver:
            return "PowerSaver";
        case profileBalanced:
            return "Balanced";
        case profilePerformance:
            return "Performance";
        default:
            return "Unknown";
        }
    }

    // The only mutating entry point. It is a no-op unless writes are separately
    // enabled and the backend maps the target profile. A true result means the
    // request was accepted or already satisfied, not that Windows accepted it;
    // writeState carries the outcome.
    function requestProfile(target): bool {
        if (!enabled)
            return rejectWrite("Windows power profiles are disabled.");
        if (!writesEnabled)
            return rejectWrite("Power profile writes are disabled; observation is read-only.");
        if (backendError)
            return rejectWrite(backendError);
        if (!backend || backend.ready !== true)
            return rejectWrite("The Windows power profile backend is not ready.");
        if (!isValidProfile(target) || availableProfiles.indexOf(target) < 0)
            return rejectWrite("The Windows power profile backend cannot map that profile.");
        if (writeState === "pending") {
            writeError = "A power profile request is already pending.";
            rejectedWrites++;
            return false;
        }

        requestedProfile = target;
        lastWriteNoop = false;
        writeError = "";

        if (profileKnown && profile === target) {
            // Selecting the observed profile is a real no-op: no native write
            // and no confirmation timeout.
            writeTimer.stop();
            lastWriteNoop = true;
            writeState = "confirmed";
            confirmedWrites++;
            return true;
        }

        writeState = "pending";
        writeAttempts++;
        writeTimer.restart();

        const submitted = typeof backend.setProfile === "function" ? backend.setProfile(target) : false;
        if (submitted !== true && writeState === "pending") {
            failWrite("The native backend did not accept the power profile request.");
            return false;
        }
        return true;
    }

    function rejectWrite(message): bool {
        rejectedWrites++;
        writeError = message;
        if (writeState !== "pending")
            writeState = "rejected";
        return false;
    }

    function confirmWrite(): void {
        writeTimer.stop();
        writeState = "confirmed";
        writeError = "";
        confirmedWrites++;
    }

    function failWrite(message): void {
        writeTimer.stop();
        writeState = "unconfirmed";
        writeError = message;
        unconfirmedWrites++;
    }

    onRawBackendProfileChanged: {
        // Read the backend value directly: dependent bindings such as profile
        // are not guaranteed to have re-evaluated when this signal handler runs.
        if (writeState === "pending" && backendReady && backend?.profileKnown === true
                && backend?.profile === requestedProfile)
            confirmWrite();
    }

    onBackendReadyChanged: {
        if (!backendReady && writeState === "pending")
            failWrite("The Windows power profile backend became unavailable before the overlay changed.");
    }

    onWritesEnabledChanged: {
        if (!writesEnabled && writeState === "pending")
            failWrite("Power profile writes were disabled before the overlay changed.");
    }

    onEnabledChanged: {
        if (!enabled) {
            writeTimer.stop();
            writeState = "idle";
            requestedProfile = profileUnknown;
            lastWriteNoop = false;
            writeError = "";
        }
    }

    readonly property Timer writeTimer: Timer {
        interval: root.effectiveWriteTimeoutMs
        repeat: false
        onTriggered: root.failWrite("No overlay change was observed within "
            + root.effectiveWriteTimeoutMs + " ms.")
    }
}
