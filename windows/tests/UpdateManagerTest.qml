import QtQuick
import Quickshell
import Quickshell.Io
import "." as Production

// Unmodified singleton, recording Process/FileView boundaries, no real
// process, task, profile, journal write, installed shell or desktop.
QtObject {
    id: root
    property int assertions: 0
    property string firstId: "11111111111111111111111111111111"
    property string secondId: "22222222222222222222222222222222"
    readonly property var manager: Production.UpdateManager
    function check(value, message): void {
        if (!value) throw new Error(message);
        assertions++;
    }
    function journal(id, phase): void {
        Files.contents[manager.operationFile.path] = JSON.stringify({schema: 1, operationId: id, phase: phase});
        manager.operationFile.reload();
    }
    function acknowledge(id): void {
        manager.process.running = false;
        manager.process.stdout.text = JSON.stringify({operationId: id});
        manager.process.exited(0);
    }
    function fail(error): void {
        console.log("CAELESTIA_UPDATE_MANAGER_FAIL " + error);
        Qt.exit(1);
    }
    function begin(): void {
        try {
            Quickshell.environment = {CAELESTIA_PROFILE_ROOT: "C:/synthetic-profile", CAELESTIA_SHELL_SMOKE: "1"};
            check(manager.operationState === "idle" && !manager.failed, "empty initial file must not report failure");
            manager.request(["smoke-refused"]);
            check(!manager.process.running && !manager.submitted, "smoke request ran");
            Quickshell.environment = {CAELESTIA_PROFILE_ROOT: "C:/synthetic-profile"};
            check(manager.deadline.interval === 600000, "production deadline changed");
            manager.request(["update"], "update");
            check(manager.operationKind === "update" && manager.deadline.interval === 2400000, "update deadline/kind");
            acknowledge(firstId);
            Files.contents[manager.operationFile.path] = JSON.stringify({schema: 1, operationId: firstId,
                phase: "working", kind: "update", step: "verifying"});
            manager.operationFile.reload();
            check(manager.step === "verifying" && manager.submitted, "matched update progress missing");
            for (const sample of [
                {step: "downloading", completed: 0, total: 100, unit: "bytes", expected: 0},
                {step: "downloading", completed: 25, total: 100, unit: "bytes", expected: 0.25},
                {step: "downloading", completed: 100, total: 100, unit: "bytes", expected: 1},
                {step: "verifying", completed: 3, total: 4, unit: "entries", expected: 0.75}
            ]) {
                Files.contents[manager.operationFile.path] = JSON.stringify({schema: 1, operationId: firstId,
                    phase: "working", step: sample.step, progress: sample});
                manager.operationFile.reload();
                check(manager.determinate && manager.progressFraction === sample.expected, "wrong real progress fraction");
            }
            Files.contents[manager.operationFile.path] = JSON.stringify({schema: 1, operationId: secondId,
                phase: "working", step: "downloading", progress: {completed: 1, total: 1, unit: "bytes"}});
            manager.operationFile.reload();
            check(manager.progressFraction === 0.75, "foreign progress applied");
            for (const progress of [null, {}, {completed: -1, total: 2, unit: "bytes"},
                {completed: 3, total: 2, unit: "bytes"}, {completed: 0, total: 0, unit: "bytes"},
                {completed: "1", total: 2, unit: "bytes"}, {completed: 1.5, total: 2, unit: "bytes"},
                {completed: 1, total: 2, unit: "arbitrary"}, {completed: 1, total: Infinity, unit: "bytes"}]) {
                Files.contents[manager.operationFile.path] = JSON.stringify({schema: 1, operationId: firstId,
                    phase: "working", step: "downloading", progress});
                manager.operationFile.reload();
                check(!manager.determinate && manager.progressFraction === 0, "invalid progress fabricated fraction");
                check(manager.submitted && manager.deadline.running, "progress settled request or altered deadline");
            }
            for (const step of ["checking", "installing", "restarting", "unknown"]) {
                Files.contents[manager.operationFile.path] = JSON.stringify({schema: 1, operationId: firstId,
                    phase: "working", step, progress: {completed: 1, total: 2, unit: "bytes"}});
                manager.operationFile.reload();
                check(!manager.determinate, "unmeasurable phase has fabricated progress");
            }
            journal(firstId, "failed");
            check(manager.failed, "update terminal phase not settled");
            manager.operationKind = "rollback";
            manager.deadline.interval = 40;
            manager.request(["first"]);
            check(manager.submitted && !manager.failed, "request was not waiting");
            check(manager.process.running && manager.deadline.running, "queue deadline did not start");
            manager.request(["duplicate"]);
            check(manager.process.command[0] === "first", "duplicate queue request ran");
            manager.process.running = false;
            manager.process.stdout.text = "{}";
            manager.process.exited(0);
            check(manager.failed && !manager.submitted, "missing acknowledgement was accepted");
            check(!manager.deadline.running, "failure retained timer");
            manager.request(["retry"]);
            check(manager.submitted && !manager.failed, "known failure blocked retry");
            acknowledge(firstId);
            check(manager.operationId === firstId, "acknowledgement identity missing");
            check(manager.operationFile.path === "C:/synthetic-profile/state/update-operation.json", "journal path changed");
            journal(secondId, "failed");
            check(manager.submitted && !manager.failed, "foreign operation settled request");
            journal(firstId, "queued");
            check(manager.submitted && manager.deadline.running, "queued journal changed deadline");
            journal(firstId, "working");
            check(manager.submitted && manager.deadline.running, "working journal changed deadline");
            manager.operationFile.loadFailed(3);
            check(manager.submitted && manager.deadline.running, "transient journal failure ended the deadline early");
            afterFirst.start();
        } catch (error) { fail(error); }
    }
    function firstTimeout(): void {
        try {
            check(manager.unconfirmed && !manager.submitted && !manager.failed, "deadline fabricated failure or left busy");
            check(!manager.deadline.running, "deadline repeated");
            check(manager.operationId === firstId, "deadline lost identity");
            manager.request(["duplicate-after-timeout"]);
            check(manager.process.command[0] === "retry", "unknown outcome allowed retry");
            journal(secondId, "complete");
            check(manager.unconfirmed, "foreign completion cleared unknown outcome");
            journal(firstId, "working");
            check(manager.unconfirmed && !manager.deadline.running, "progress reset expired deadline");
            journal(firstId, "failed");
            check(manager.failed && !manager.unconfirmed, "late matched failure did not settle");
            manager.request(["late-ack"]);
            check(manager.submitted && manager.operationId === "", "new request retained old identity");
            check(manager.deadline.running && manager.process.running, "new queue not bounded");
            afterSecond.start();
        } catch (error) { fail(error); }
    }
    function secondTimeout(): void {
        try {
            check(manager.unconfirmed && !manager.failed, "queue startup wait was not bounded");
            check(manager.process.running, "deadline killed unresolved process");
            manager.request(["duplicate-without-ack"]);
            check(manager.process.command[0] === "late-ack", "unacknowledged request duplicated");
            acknowledge(secondId);
            check(manager.unconfirmed && manager.operationId === secondId, "late acknowledgement reset outcome");
            manager.operationFile.loadFailed(3);
            check(manager.unconfirmed && !manager.failed, "missing journal fabricated failure");
            journal(firstId, "failed");
            check(manager.unconfirmed, "stale operation failure applied");
            journal(secondId, "complete");
            check(manager.complete && !manager.unconfirmed && !manager.submitted, "late completion did not settle");
            check(manager.progressFraction === 1, "completed operation did not fill progress");
            check(!manager.deadline.running, "completion retained timer");
            journal(secondId, "failed");
            check(manager.complete, "terminal completion regressed");
            manager.request(["duplicate-after-complete"]);
            check(manager.process.command[0] === "late-ack", "completed rollback duplicated");
            check(assertions >= 32, "assertion floor");
            console.log("CAELESTIA_UPDATE_MANAGER_PASS " + assertions);
            Qt.quit();
        } catch (error) { fail(error); }
    }
    property Timer afterFirst: Timer { interval: 100; onTriggered: root.firstTimeout() }
    property Timer afterSecond: Timer { interval: 100; onTriggered: root.secondTimeout() }
    Component.onCompleted: Qt.callLater(begin)
}
