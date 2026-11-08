import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Windows as Native
import qs.services
import qs.utils

// A failed pick-record write must not be treated as a saved choice. The
// proposed text stays pending, an identical retry is attempted, saved() plus
// an independent read-back confirms it, and a persistent failure stays visible
// instead of silently dropping the user's wallpaper.
QtObject {
    id: root

    readonly property string recordPath: Paths.state + "/wallpaper/desktop.json"
    readonly property string recordDir: Paths.state + "/wallpaper"
    property int assertions: 0
    property int makePathsBefore: 0
    property int writesBeforeCommit: 0
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
                "C:/walls/windows-default.jpg", "C:/walls/primary.jpg",
                "C:/walls/secondary.jpg", "C:/walls/picked.jpg",
                "C:/walls/other.jpg", "C:/walls/third.jpg"];
            Native.FsUtils.existingDirs = [];
            Quickshell.screens = [{name: "primary"}, {name: "secondary"}];
            Wallpapers.sourceRecordRetryInterval = 1;

            check(Wallpapers.sourceInitialized, "the fresh source resolved");
            check(Wallpapers.sourceFresh, "the profile resolved as an upgrade");
            check(Wallpapers.sourceRecordHealth === "missing", "an empty profile found a pick");
            check(Wallpapers.sourceRecordPending === "", "a start without a pick proposed a write");
            check(Files.contents[root.recordPath] === undefined,
                "a start without a pick wrote a record");

            // The first pick fails. Nothing is confirmed and the record does
            // not exist on disk.
            Files.saveFailures[root.recordPath] = 3;
            check(Wallpapers.setWallpaper("C:/walls/picked.jpg"), "the pick was rejected");
            Files.flushWrites();
            check(Wallpapers.sourceRecordPending !== "", "the picked record was not proposed");
            check(Wallpapers.sourceRecordFailures === 1, "the failed write was not counted");
            check(Wallpapers.sourceRecordConfirmed === "", "the failed write was confirmed");
            check(Wallpapers.sourceRecordError !== "", "the failed write was not reported");
            check(Wallpapers.sourceRecordDirty, "the failed write was dropped instead of retried");
            check(record().wallpaper === undefined, "the failed write reached the file");

            // The same pending text is retried after the failure, and the
            // retry repairs a record directory that disappeared while the
            // write was failing.
            delete Files.saveFailures[root.recordPath];
            Native.FsUtils.existingDirs = [];
            root.makePathsBefore = Native.FsUtils.makePathCalls;
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
            check(record().wallpaper === "C:/walls/picked.jpg", "the retried record was not written");
            check(Files.writeRequests >= 2, "only one write was attempted");
            check(Native.FsUtils.makePathCalls > root.makePathsBefore,
                "the retry did not repair the missing record directory");
            check(Native.FsUtils.existingDirs.includes(root.recordDir),
                "the record directory was not recreated");

            // A persistent failure must keep the work pending and visible.
            Files.saveFailures[root.recordPath] = 3;
            check(Wallpapers.setWallpaper("C:/walls/other.jpg", {name: "primary"}),
                "the display pick was rejected");
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
            check(record().monitors["primary-id"] === "C:/walls/other.jpg",
                "the recovered per-display pick was lost");
            check(record().wallpaper === "C:/walls/picked.jpg",
                "the recovered rewrite dropped the profile-wide pick");
            check(Files.writeRequests >= 4, "the failed work was not retried");

            // saved() is emitted even when the atomic commit fails on the
            // pinned backend (issue #28). The read-back must reject that, and
            // the retry must write again even though the writer cached the
            // attempted bytes.
            Files.commitFailures[root.recordPath] = true;
            check(Wallpapers.setWallpaper("C:/walls/third.jpg", {name: "secondary"}),
                "the commit-failure pick was rejected");
            root.writesBeforeCommit = Files.writeRequests;
            Files.flushWrites();
            check(Wallpapers.sourceRecordFailures === 1, "a failed commit was not treated as a failure");
            check(Wallpapers.sourceRecordConfirmed !== Wallpapers.sourceRecordPending,
                "a failed commit was confirmed");
            check(Wallpapers.sourceRecordError !== "", "a failed commit was silent");
            check(record().monitors["secondary-id"] === undefined, "a failed commit reached the file");
            delete Files.commitFailures[root.recordPath];
            root.later(afterCommitRetry);
        });
    }

    function afterCommitRetry(): void {
        guard(function() {
            Files.flushWrites();
            check(Files.writeRequests > root.writesBeforeCommit,
                "the commit retry did not write again");
            check(Wallpapers.sourceRecordConfirmed === Wallpapers.sourceRecordPending,
                "the commit retry was not confirmed");
            check(Wallpapers.sourceRecordError === "", "the commit retry kept its error");
            check(record().monitors["secondary-id"] === "C:/walls/third.jpg",
                "the commit retry was not written");

            console.log("CAELESTIA_WALLPAPER_RECORD_RETRY_PASS " + assertions);
            Qt.quit();
        });
    }
}
