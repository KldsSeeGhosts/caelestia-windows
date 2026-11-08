import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Windows as Native
import qs.services

// A failed record write must not be treated as a saved decision. The proposed
// text stays pending, an identical retry is attempted, saved() alone confirms
// it, and a persistent failure stays visible instead of silently dropping the
// user's choice.
QtObject {
    id: root

    readonly property string recordPath: "C:/fixture/state/wallpaper/desktop.json"
    property int assertions: 0
    property var nextStep: null

    function check(value, description): void {
        assertions++;
        if (!value)
            throw new Error(description);
    }
    function record(): var {
        return JSON.parse(Files.contents[root.recordPath] ?? "{}");
    }
    function later(step): void {
        root.nextStep = step;
        tick.restart();
    }
    function guard(step): void {
        try {
            step();
        } catch (error) {
            console.error("CAELESTIA_WALLPAPER_RECORD_RETRY_FAIL " + error);
            Qt.exit(1);
        }
    }

    property Timer tick: Timer {
        interval: 5
        repeat: false
        onTriggered: {
            const step = root.nextStep;
            root.nextStep = null;
            if (step)
                root.guard(step);
        }
    }

    Component.onCompleted: Qt.callLater(run)

    function run(): void {
        guard(function() {
            Files.asyncWrites = true;
            Native.FsUtils.existingFiles = ["C:/fixture/assets/wallpaper.webp",
                "C:/walls/windows-default.jpg", "C:/walls/primary.jpg"];
            Files.saveFailures[root.recordPath] = 3;
            Quickshell.screens = [{name: "primary"}];

            check(Wallpapers.sourceInitialized, "the fresh source resolved");
            check(Wallpapers.sourceRecordPending !== "", "the initial record was not proposed");
            check(Wallpapers.sourceRecordConfirmed === "", "an unwritten record was confirmed");
            check(Wallpapers.sourceRecordDirty, "the pending record was not dirty");
            Wallpapers.sourceRecordRetryInterval = 1;
            Files.flushWrites();
            check(Wallpapers.sourceRecordFailures === 1, "the failed write was not counted");
            check(Wallpapers.sourceRecordConfirmed === "", "the failed write was confirmed");
            check(Wallpapers.sourceRecordError !== "", "the failed write was not reported");
            check(Wallpapers.sourceRecordDirty, "the failed write was dropped instead of retried");
            check(record().source === undefined, "the failed write reached the file");

            // The same pending text must be retried after the failure.
            delete Files.saveFailures[root.recordPath];
            root.later(afterRetry);
        });
    }

    function afterRetry(): void {
        guard(function() {
            Files.flushWrites();
            check(Wallpapers.sourceRecordConfirmed === Wallpapers.sourceRecordPending,
                "the identical retry was skipped");
            check(!Wallpapers.sourceRecordDirty, "the confirmed retry stayed dirty");
            check(Wallpapers.sourceRecordError === "", "the recovered write kept its error");
            check(record().source === "default", "the retried record was not written");
            check(Files.writeRequests >= 2, "only one write was attempted");

            // A persistent failure must keep the work pending and visible.
            Files.saveFailures[root.recordPath] = 3;
            Wallpapers.sourceMonitors = {"extra-id": "user"};
            Wallpapers.persistSourceChoice(true);
            Files.flushWrites();
            check(Wallpapers.sourceRecordFailures === 1, "the new failure was not counted");
            root.later(afterSecondFailure);
        });
    }

    function afterSecondFailure(): void {
        guard(function() {
            Files.flushWrites();
            check(Wallpapers.sourceRecordFailures === 2, "the retry did not run");
            root.later(afterThirdFailure);
        });
    }

    function afterThirdFailure(): void {
        guard(function() {
            Files.flushWrites();
            check(Wallpapers.sourceRecordFailures === 3, "the persistent failure was not counted");
            check(Wallpapers.sourceRecordConfirmed !== Wallpapers.sourceRecordPending,
                "a persistent failure was confirmed");
            check(Wallpapers.sourceRecordError !== "", "a persistent failure was silent");
            check(Wallpapers.sourceRecordDirty, "a persistent failure discarded the work");
            delete Files.saveFailures[root.recordPath];
            root.later(afterRecovery);
        });
    }

    function afterRecovery(): void {
        guard(function() {
            Files.flushWrites();
            check(Wallpapers.sourceRecordConfirmed === Wallpapers.sourceRecordPending,
                "the persistent failure never recovered");
            check(Wallpapers.sourceRecordError === "", "the recovered write kept its error");
            check(!Wallpapers.sourceRecordDirty, "the recovered write stayed dirty");
            check(record().monitors["extra-id"] === "user", "the recovered choice was lost");
            check(Files.writeRequests >= 4, "the failed work was not retried");

            console.log("CAELESTIA_WALLPAPER_RECORD_RETRY_PASS " + assertions);
            Qt.quit();
        });
    }
}
