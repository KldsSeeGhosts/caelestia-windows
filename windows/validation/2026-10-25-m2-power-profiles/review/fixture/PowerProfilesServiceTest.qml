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
        property bool writeResultAvailable: true
        property string lastError: ""
        property bool acceptWrites: true
        property int setCalls: 0
        property int lastRequested: -1
        property bool synchronousResult: false
        property bool resultOk: true
        signal profileWriteResult(int requestedProfile, bool ok, string error)

        function setProfile(target): bool {
            setCalls++;
            lastRequested = target;
            if (synchronousResult)
                profileWriteResult(target, resultOk, resultOk ? "" : "Fixture access denied");
            return acceptWrites;
        }
    }

    readonly property PowerProfilesService service: PowerProfilesService {}
    readonly property FakeBackend fake: FakeBackend {}
    // Actual native API shapes, projected through the same pure facade loaded
    // by NativePowerProfilesBackend. The legacy shape has no result signal.
    component LegacyNative: QtObject {
        property int profile: 1
        property bool hasPerformanceProfile: true
    }
    component ResultNative: LegacyNative {
        property bool profileKnown: true
        property string rawOverlayGuid: "{00000000-0000-0000-0000-000000000000}"
        property string lastError: ""
        property bool writeSupported: true
        property bool observing: true
        signal profileWriteResult(int requestedProfile, bool ok, string error)
    }
    readonly property LegacyNative legacy: LegacyNative {}
    readonly property ResultNative current: ResultNative {}
    readonly property PowerProfilesBackend facade: PowerProfilesBackend { source: test.current }
    readonly property PowerProfilesService projected: PowerProfilesService {
        backend: test.facade
        enabled: true
        writesEnabled: true
    }
    readonly property LegacySubmission legacySubmission: LegacySubmission {}
    component LegacySubmission: QtObject {
        property bool ready: true
        property bool profileKnown: true
        property int profile: 0
        property var mappedProfiles: [0, 1, 2]
        function setProfile(target): bool {
            profile = target; // Old optimistic setter must never confirm.
            return true;
        }
    }
    readonly property PowerProfilesService oldService: PowerProfilesService {
        backend: test.legacySubmission
        enabled: true
        writesEnabled: true
        writeTimeoutMs: 120
    }
    readonly property QtObject selector: QtObject {
        property var selectProfile: profile => test.service.requestProfile(profile)
    }

    property int assertions: 0

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
        fake.writeResultAvailable = true;
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
        check(service.writeResultAvailable === true, "result-capable backend exposes the result signal");
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
        // request from an unknown baseline needs an explicit successful result.
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
        check(service.writeState === "pending" && service.confirmedWrites === 0,
            "matching local setter transition never confirms");
        fake.profileWriteResult(2, true, "");
        check(service.writeState === "pending", "result for another target is ignored");
        fake.profileWriteResult(1, true, "");
        check(service.writeState === "confirmed" && service.confirmedWrites === 1,
            "matching successful result confirms the write");
        check(service.profile === 1 && service.profileName === "Balanced", "confirmed profile projection");

        // Selecting the observed profile is a no-op, not a native write.
        const noopCalls = fake.setCalls;
        const noopAttempts = service.writeAttempts;
        service.writeState = "idle";
        const noopConfirmed = service.confirmedWrites;
        check(selector.selectProfile(1) === true && service.writeState === "idle",
            "injected selector routes a current-profile selection through the service");
        check(service.lastWriteNoop && fake.setCalls === noopCalls, "current-profile selection sends no write");
        check(service.confirmedWrites === noopConfirmed && service.writeAttempts === noopAttempts
            && !service.writePending,
            "no-op is not counted as a confirmed write");

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
        fake.profile = 2;
        check(service.writeState === "pending", "matching transition without a result still waits");
        fake.profile = 1;
        check(oldService.requestProfile(2) && oldService.writeState === "pending",
            "backend without result signal reports submission");
        check(!oldService.writeResultAvailable && oldService.confirmedWrites === 0,
            "legacy optimistic setter cannot confirm");
        check(oldService.writeReason.indexOf("submitted") >= 0, "legacy submission reason");
        wait.start();
    }

    function afterTimeout(): void {
        check(service.writeState === "unconfirmed" && service.writeFailed, "timeout is unconfirmed");
        check(service.unconfirmedWrites === 1, "timeout counter");
        check(service.writeError.indexOf("No power profile result") >= 0, "timeout reason");
        check(service.profile === 1, "unrelated observed profile stays truthful");
        check(service.writePending === false, "timeout clears pending");
        check(oldService.writeState === "unconfirmed" && oldService.confirmedWrites === 0,
            "legacy submission expires as unconfirmed");
        fake.profileWriteResult(2, true, "");
        check(service.writeState === "unconfirmed", "late result does not confirm expired request");

        // A later write is still possible and needs its own successful result.
        service.writeState = "idle";
        fake.profile = 0;
        check(service.requestProfile(2) === true && service.writeState === "pending", "later write is pending");
        fake.profile = 2;
        check(service.writeState === "pending", "later transition still needs its result");
        fake.profileWriteResult(2, true, "");
        check(service.writeState === "confirmed" && service.confirmedWrites === 2,
            "later successful result confirms the write");
        check(service.profile === 2 && service.profileName === "Performance", "performance projection");

        // A rejected native submission fails immediately instead of waiting.
        fake.acceptWrites = false;
        service.writeState = "idle";
        check(service.requestProfile(1) === false && service.writeState === "rejected",
            "refused submission is rejected");
        check(service.writeError.indexOf("did not accept") >= 0, "native rejection reason");
        fake.acceptWrites = true;
        service.writeState = "idle";
        check(selector.selectProfile(1) && fake.lastRequested === 1 && service.writePending,
            "injected selector sends a changed profile through requestProfile");
        const rejectedBefore = service.rejectedWrites;
        fake.profileWriteResult(1, false, "Fixture set failed: 5");
        check(service.writeState === "rejected" && service.writeError === "Fixture set failed: 5"
            && service.rejectedWrites === rejectedBefore + 1, "failed native result preserves its error");
        fake.synchronousResult = true;
        check(service.requestProfile(1) && service.writeState === "confirmed",
            "synchronous native success is handled during submission");
        fake.resultOk = false;
        check(service.requestProfile(1) && service.writeState === "rejected"
            && service.writeError === "Fixture access denied", "synchronous native failure is rejected");
        fake.synchronousResult = false;

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

        checkFacade();
        console.log("CAELESTIA_POWER_PROFILES_FIXTURE_PASS " + JSON.stringify({ assertions: assertions }));
        Qt.quit();
    }

    function checkFacade(): void {
        check(facade.profileKnown && facade.profile === 1 && projected.profile === 1,
            "explicit known Balanced read is projected");
        check(facade.writeResultAvailable && facade.observing, "new native capabilities detected");
        check(JSON.stringify(facade.mappedProfiles) === "[0,1,2]", "set API exposes mapped profiles");
        current.hasPerformanceProfile = false;
        check(JSON.stringify(facade.mappedProfiles) === "[0,1]", "performance capability limits availability");
        current.writeSupported = false;
        check(facade.mappedProfiles.length === 0 && !projected.writesPermitted,
            "missing set API disables available write targets");
        current.writeSupported = true;
        current.hasPerformanceProfile = true;

        current.profileKnown = false;
        current.rawOverlayGuid = "{11111111-2222-3333-0102-030405060708}";
        check(facade.profile === -1 && projected.profile === -1 && projected.state === "unknown",
            "unknown GUID with legacy Balanced value is never Balanced");
        check(projected.reason.indexOf("unknown") >= 0, "unknown GUID has a short reason");
        current.profileKnown = true;
        current.profile = 2;
        check(projected.profile === 2, "known read restores observation");
        current.lastError = "PowerGetEffectiveOverlayScheme failed: 5";
        current.profileKnown = false;
        current.rawOverlayGuid = "";
        check(facade.profile === -1 && projected.rawBackendProfile === -1 && projected.profile === -1,
            "failed read invalidates previously known cached values");
        check(projected.reason === current.lastError, "native read failure reason is preserved");
        current.profileKnown = true;
        current.lastError = "";
        check(projected.requestProfile(0) && projected.writePending, "facade submits a fake write");
        check(current.profile === 0 && projected.writePending, "facade setter alone never confirms");
        current.profileWriteResult(0, true, "");
        check(projected.writeState === "confirmed", "native result forwarded through facade confirms");
        check(projected.requestProfile(1), "facade submits second fake write");
        current.profileWriteResult(1, false, "Fixture overlay mismatch");
        check(projected.writeState === "rejected" && projected.writeError === "Fixture overlay mismatch",
            "native failure forwarded through facade rejects");
        facade.source = legacy;
        for (const value of [0, 1, 2]) {
            legacy.profile = value;
            check(!facade.profileKnown && facade.profile === -1 && projected.profile === -1,
                "old pin cannot verify profile " + value);
        }
        check(!facade.writeResultAvailable && !facade.writeSupported && !facade.observing,
            "absent old-pin members fail closed");
        check(facade.mappedProfiles.length === 0 && !projected.writesPermitted,
            "hard-coded legacy performance flag grants no write targets");
        check(projected.reason.indexOf("cannot verify") >= 0, "old pin explains missing verification");
        check(!facade.setProfile(1), "old-pin facade refuses native submission");
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
