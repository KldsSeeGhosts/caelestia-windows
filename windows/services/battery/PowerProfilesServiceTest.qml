pragma ComponentBehavior: Bound

import QtQuick

// Standalone fixture for the pure PowerProfiles state object. Imports no
// Quickshell/native UPower/configuration module, reads no environment or
// hardware, never constructs Battery.qml and never calls a native PowerProfiles
// singleton. The injected fake records every submitted profile request.
// Intended runner: powershell -NoProfile -File windows/scripts/Test-BatteryService.ps1 -QtPrefix <Windows Qt prefix>
QtObject {
    id: test

    component FakeBackend: QtObject {
        property bool ready: true
        property bool profileKnown: true
        property int profile: 1
        property var mappedProfiles: [0, 1, 2]
        property bool performanceClaim: true
        property bool writeResultAvailable: false
        property string lastError: ""
        property bool acceptWrites: true
        property int setCalls: 0
        property int lastRequested: -1

        function setProfile(target): bool {
            setCalls++;
            lastRequested = target;
            return acceptWrites;
        }
    }

    readonly property PowerProfilesService service: PowerProfilesService {}
    readonly property FakeBackend fake: FakeBackend {}

    property int assertions: 0
    property bool phaseTimedOut: false

    function check(condition, message): void {
        assertions++;
        if (!condition)
            throw new Error(message);
    }

    function resetFake(): void {
        fake.ready = true;
        fake.profileKnown = true;
        fake.profile = 1;
        fake.mappedProfiles = [0, 1, 2];
        fake.performanceClaim = true;
        fake.writeResultAvailable = false;
        fake.lastError = "";
        fake.acceptWrites = true;
        fake.setCalls = 0;
        fake.lastRequested = -1;
    }

    function start(): void {
        check(service.enabled === false && service.backend === null && service.backendError === "",
            "safe construction defaults");
        check(service.state === "disabled" && service.reason.length > 0, "explicit disabled profile state");
        check(!service.backendReady && !service.observing && !service.profileKnown, "disabled capabilities");
        check(service.profile === -1 && service.profileName === "Unknown", "disabled profile is unknown");
        check(service.availableProfiles.length === 0 && !service.performanceMapped,
            "disabled availability is empty");
        check(!service.writesPermitted && !service.writePending && service.writeState === "idle",
            "disabled writes");
        check(service.writeError === "" && service.writeReason.length > 0, "disabled write reason");
        check(service.requestProfile(1) === false && service.writeState === "rejected"
            && service.rejectedWrites === 1, "disabled write is rejected");

        service.enabled = true;
        check(service.state === "initializing" && !service.backendReady, "missing backend initializes");
        check(service.availableProfiles.length === 0 && service.profile === -1, "initializing projects nothing");
        check(service.requestProfile(1) === false, "initializing write is rejected");

        service.backendError = "Fixture profile backend failed";
        check(service.state === "unsupported" && service.reason === service.backendError,
            "known backend failure is unsupported");
        service.backendError = "";

        service.backend = fake;
        service.writeState = "idle";
        check(service.state === "observing" && service.backendReady && service.profileKnown,
            "verified balanced profile is observed");
        check(service.profile === 1 && service.profileName === "Balanced", "current profile projection");
        check(JSON.stringify(service.availableProfiles) === "[0,1,2]", "explicit mapped profile set");
        check(service.performanceMapped, "performance mapping is exposed");
        check(service.performanceClaim === true, "hard-coded native performance claim is diagnostic");
        check(service.writeResultAvailable === false, "pinned backend has no write result");
        check(!service.writesPermitted && service.writeState === "idle", "observation alone permits no writes");

        // Observation without the separate write opt-in must not call the
        // backend at all.
        const callsBefore = fake.setCalls;
        check(service.requestProfile(2) === false && service.writeState === "rejected",
            "write without opt-in is refused");
        check(fake.setCalls === callsBefore && fake.lastRequested === -1, "refused write never reaches the backend");
        check(service.writeError.indexOf("disabled") >= 0 && service.rejectedWrites >= 2, "refusal reason");

        service.writesEnabled = true;
        check(service.writesPermitted, "separate write opt-in permits mapped profiles");

        for (const invalid of [3, -1, 1.5, "1", NaN, Infinity, null, undefined, {}]) {
            service.writeState = "idle";
            check(service.requestProfile(invalid) === false, "invalid profile " + String(invalid) + " is rejected");
            check(service.writeState === "rejected", "invalid profile " + String(invalid) + " stays rejected");
        }
        check(fake.setCalls === callsBefore, "invalid writes never reach the backend");

        // The native hasPerformanceProfile flag is hard-coded true and must not
        // add an unmapped profile. Only the explicit mapping is authoritative.
        fake.mappedProfiles = [0, 1];
        check(JSON.stringify(service.availableProfiles) === "[0,1]", "mapped subset");
        check(!service.performanceMapped, "unmapped performance is unavailable");
        check(service.performanceClaim === true, "performance claim remains diagnostic");
        service.writeState = "idle";
        check(service.requestProfile(2) === false && service.writeState === "rejected",
            "unmapped performance write is rejected");
        check(fake.setCalls === callsBefore, "unmapped write never reaches the backend");

        fake.mappedProfiles = [2, 2, 0, 1, 3, -1, "2", null, undefined];
        check(JSON.stringify(service.availableProfiles) === "[2,0,1]",
            "duplicate and invalid mappings are dropped");
        fake.mappedProfiles = null;
        check(service.availableProfiles.length === 0 && service.state === "unknown",
            "missing mapping set is unknown");
        check(!service.writesPermitted, "missing mapping set permits no writes");
        service.writeState = "idle";
        check(service.requestProfile(1) === false, "write without a mapping is rejected");
        fake.mappedProfiles = "012";
        check(service.availableProfiles.length === 0, "string mapping is not a profile set");
        fake.mappedProfiles = [0, 1, 2];

        // A verified read of a profile the backend cannot represent is not
        // projected as that profile.
        fake.profile = 2;
        fake.mappedProfiles = [0, 1];
        check(service.profileKnown && service.rawBackendProfile === 2, "raw verified profile retained");
        check(service.profile === -1 && service.state === "unknown", "unrepresentable profile is unknown");
        fake.mappedProfiles = [0, 1, 2];
        check(service.profile === 2 && service.state === "observing", "representable profile returns");

        // A stale value with an unverified read must not be projected, and a
        // request from an unknown baseline can still be confirmed by an observed
        // transition.
        fake.profileKnown = false;
        fake.profile = 2;
        check(service.state === "unknown" && service.profile === -1
            && service.rawBackendProfile === -1, "unverified read rejects the stale value");
        check(service.reason.indexOf("not verified") >= 0, "unverified read reason");
        check(service.writesPermitted, "write opt-in remains available with an unknown read");
        check(service.requestProfile(1) === true && service.writeState === "pending",
            "unknown baseline starts a pending write");
        check(fake.setCalls === callsBefore + 1 && fake.lastRequested === 1, "pending write reaches the backend");
        fake.profileKnown = true;
        fake.profile = 1;
        check(service.writeState === "confirmed" && service.confirmedWrites === 1,
            "observed transition confirms the write");
        check(service.profile === 1 && service.profileName === "Balanced", "confirmed profile projection");

        // Selecting the observed profile is a no-op, not a native write.
        const noopCalls = fake.setCalls;
        service.writeState = "idle";
        check(service.requestProfile(1) === true && service.writeState === "confirmed",
            "selecting the current profile is confirmed");
        check(service.lastWriteNoop && fake.setCalls === noopCalls, "current-profile selection sends no write");

        // A write that observes a different overlay transition must not be
        // confirmed. It expires as unconfirmed after the bounded timeout.
        service.writeTimeoutMs = 120;
        service.writeState = "idle";
        check(service.requestProfile(2) === true && service.writeState === "pending", "timeout write is pending");
        check(service.writePending && service.requestedProfile === 2, "pending request is recorded");
        const pendingCalls = fake.setCalls;
        check(service.requestProfile(0) === false && service.writeState === "pending",
            "a concurrent request is refused without cancelling the pending write");
        check(service.writeError.indexOf("already pending") >= 0, "concurrent request reason");
        check(fake.setCalls === pendingCalls, "concurrent request never reaches the backend");
        fake.profile = 1;
        check(service.profile === 1 && service.writeState === "pending",
            "an unrelated overlay transition does not confirm the write");
        phaseTimedOut = false;
        wait.start();
    }

    function afterTimeout(): void {
        check(service.writeState === "unconfirmed" && service.writeFailed, "timeout is unconfirmed");
        check(service.unconfirmedWrites === 1, "timeout counter");
        check(service.writeError.indexOf("No overlay change") >= 0, "timeout reason");
        check(service.profile === 1, "unrelated observed profile stays truthful");
        check(service.writePending === false, "timeout clears pending");

        // A later write is still possible and confirms from its own transition.
        service.writeState = "idle";
        fake.profile = 0;
        check(service.requestProfile(2) === true && service.writeState === "pending", "later write is pending");
        fake.profile = 2;
        check(service.writeState === "confirmed" && service.confirmedWrites === 3,
            "later observed transition confirms the write");
        check(service.profile === 2 && service.profileName === "Performance", "performance projection");

        // A rejected native submission fails immediately instead of waiting.
        fake.acceptWrites = false;
        service.writeState = "idle";
        check(service.requestProfile(1) === false && service.writeState === "unconfirmed",
            "native rejection is unconfirmed");
        check(service.writeError.indexOf("did not accept") >= 0, "native rejection reason");
        fake.acceptWrites = true;

        // A pending write fails when the backend becomes unavailable.
        service.writeState = "idle";
        fake.profile = 1;
        check(service.requestProfile(2) === true && service.writeState === "pending", "pending before backend loss");
        fake.ready = false;
        check(service.state === "unsupported" && service.writeState === "unconfirmed",
            "backend loss fails the pending write");
        check(service.writeError.indexOf("became unavailable") >= 0, "backend loss reason");
        check(service.profile === -1 && service.availableProfiles.length === 0, "backend loss clears projections");
        fake.ready = true;
        check(service.state === "observing" && service.profile === 1, "backend recovery restores observation");

        // A loader-supplied error fails a pending write as well.
        service.writeState = "idle";
        check(service.requestProfile(2) === true && service.writeState === "pending", "pending before denied load");
        service.backendError = "Fixture access denied";
        check(service.state === "unsupported" && service.writeState === "unconfirmed",
            "backend error fails the pending write");
        service.backendError = "";

        // Revoking the write opt-in while pending fails instead of confirming.
        service.writeState = "idle";
        fake.profile = 1;
        check(service.requestProfile(2) === true && service.writeState === "pending", "pending before opt-in loss");
        service.writesEnabled = false;
        check(service.writeState === "unconfirmed" && !service.writesPermitted,
            "write opt-in removal fails the pending write");
        service.writeState = "idle";
        check(service.requestProfile(2) === false && service.writeState === "rejected",
            "removed write opt-in refuses further requests");

        // Disabling observation resets the write lifecycle and all projections.
        service.writesEnabled = true;
        service.enabled = false;
        check(service.state === "disabled" && service.writeState === "idle" && service.profile === -1,
            "disabling resets profiles and writes");
        check(service.availableProfiles.length === 0 && !service.writesPermitted, "disabling clears availability");

        service.enabled = true;
        resetFake();
        check(service.state === "observing" && service.profile === 1, "re-enabling restores observation");
        fake.writeResultAvailable = true;
        check(service.writeResultAvailable, "write result capability propagates when a backend supplies one");

        // Invalid verified values and missing capabilities fail closed.
        fake.profile = 7;
        check(!service.profileKnown && service.profile === -1 && service.state === "unknown",
            "invalid verified value is unknown");
        fake.profile = 1;
        fake.profileKnown = false;
        check(service.state === "unknown" && service.profile === -1, "missing read capability is unknown");

        console.log("CAELESTIA_POWER_PROFILES_FIXTURE_PASS " + JSON.stringify({ assertions: assertions }));
        Qt.quit();
    }

    readonly property Timer wait: Timer {
        interval: 350
        repeat: false
        onTriggered: {
            try {
                test.afterTimeout();
            } catch (error) {
                console.error("CAELESTIA_POWER_PROFILES_FIXTURE_FAIL " + error.message);
                Qt.exit(1);
            }
        }
    }

    Component.onCompleted: Qt.callLater(() => {
        try {
            test.start();
        } catch (error) {
            console.error("CAELESTIA_POWER_PROFILES_FIXTURE_FAIL " + error.message);
            Qt.exit(1);
        }
    })
}
