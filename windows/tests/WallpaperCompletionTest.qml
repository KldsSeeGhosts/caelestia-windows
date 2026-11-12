import QtQuick
import Quickshell
import Quickshell.Windows as Native
import qs.services

// Only fakes touch OS state. Two worker generations share screenPaths, just
// as an abandoned COM call and its replacement still affect the same desktop.
QtObject {
    id: root
    property int assertions: 0
    property var nextStep: null
    property int oldOperation: 0
    property int newOperation: 0
    property int callsBeforeRepair: 0
    property int globalCallsBefore: 0
    readonly property var primary: ({name: "primary", targetId: "primary-id"})
    property WallpaperCompletion tracker: WallpaperCompletion {
        completionTimeout: 180
        recoveryDelays: [100, 300, 600]
    }
    property Timer stepTimer: Timer {
        repeat: false
        onTriggered: root.guard(root.nextStep)
    }
    function check(value, description): void {
        assertions++;
        if (!value)
            throw new Error(description);
    }
    function later(delay, step): void {
        nextStep = step;
        stepTimer.interval = delay;
        stepTimer.restart();
    }
    function guard(step): void {
        try { step(); } catch (error) {
            console.error("CAELESTIA_WALLPAPER_COMPLETION_FAIL " + error);
            Qt.exit(1);
        }
    }
    function state(): var { return tracker.targets["primary-id"]; }
    function latestOperation(): int { return Native.Wallpaper.nextOperation; }
    Component.onCompleted: Qt.callLater(() => guard(run))

    function run(): void {
        Quickshell.screens = [{name: "primary"}, {name: "secondary"}];
        Native.FsUtils.existingFiles = [Wallpapers.fallback, "C:/walls/a.jpg", "C:/walls/b.jpg"];
        Native.Wallpaper.asyncOperations = true;
        check(Wallpapers.sourceFresh, "the integration profile is not fresh");
        check(Wallpapers.setWallpaper("C:/walls/a.jpg", primary), "the delayed pick was rejected");
        check(Wallpapers.windowsTargets["primary-id"].outcome === "pending", "acceptance claimed success");
        check(Wallpapers.windowsTargets["primary-id"].desired === "C:/walls/a.jpg", "desired path missing");
        check(Wallpapers.windowsStatusText(primary) === "Applying wallpaper", "pending wording missing");
        check(Wallpapers.currentForScreen(primary) === "C:/walls/a.jpg", "desired shell image was not shown");
        check(Toaster.calls.length === 0, "acceptance toasted before completion");
        Native.Wallpaper.finishLater(latestOperation(), true, 160);
        later(230, afterDelayedSuccess);
    }
    function afterDelayedSuccess(): void {
        check(Wallpapers.windowsTargets["primary-id"].outcome === "applied", "late success was not applied");
        check(Toaster.calls.filter(item => item.body.startsWith("Desktop wallpaper changed")).length === 1, "completion did not toast success once");
        check(Wallpapers.setWallpaper("C:/walls/b.jpg", primary), "late-failure pick was rejected");
        check(Wallpapers.windowsTargets["primary-id"].outcome === "pending", "late failure started as completed");
        Native.Wallpaper.finishLater(latestOperation(), false, 140);
        later(200, afterLateFailure);
    }
    function afterLateFailure(): void {
        check(Wallpapers.windowsTargets["primary-id"].outcome === "failed", "late failure was lost");
        check(Wallpapers.windowsTargets["primary-id"].desired === "C:/walls/b.jpg", "failure erased desired image");
        check(Wallpapers.currentForScreen(primary) === "C:/walls/b.jpg", "failure adopted the Windows image");
        check(Native.Wallpaper.screenPaths.primary === "C:/walls/a.jpg", "failure mutated fake OS state");
        check(Toaster.calls.some(item => item.body === "Windows could not apply the wallpaper."), "late failure was silent");

        check(tracker.request("C:/walls/queued-a.jpg", primary), "first queued request failed");
        oldOperation = latestOperation();
        check(tracker.request("C:/walls/queued-b.jpg", primary), "newer desired pick was rejected");
        check(latestOperation() === oldOperation, "newer pick overlapped the active native call");
        check(state().requestId === 2 && state().outcome === "pending", "newer request state missing");
        Native.Wallpaper.finishLater(oldOperation, false, 20);
        later(60, afterSupersededFailure);
    }
    function afterSupersededFailure(): void {
        check(state().desired === "C:/walls/queued-b.jpg", "old failure overwrote desired pick");
        check(state().outcome === "pending", "old failure overwrote newer outcome");
        check(latestOperation() > oldOperation, "newer queued request was not dispatched");
        Native.Wallpaper.finishLater(latestOperation(), true, 20);
        later(50, startMissingResult);
    }
    function startMissingResult(): void {
        check(state().outcome === "applied", "queued newer request did not complete");
        tracker.request("C:/walls/no-result.jpg", primary);
        oldOperation = latestOperation();
        later(300, afterMissingResult);
    }
    function afterMissingResult(): void {
        check(state().outcome === "unknown", "missing result stayed pending or claimed success");
        check(state().desired === "C:/walls/no-result.jpg", "missing result lost desired state");
        // Retain the unanswered tuple. An identical new pick cannot safely
        // receive this old result in an API without request ids.
        tracker.request("C:/walls/no-result.jpg", primary);
        check(latestOperation() === oldOperation, "ambiguous identical tuple was resubmitted");
        check(state().outcome === "unknown", "ambiguous request claimed completion");
        Native.Wallpaper.finishLater(oldOperation, true, 10);
        later(40, startWorkerReplacement);
    }
    function startWorkerReplacement(): void {
        check(state().outcome === "unknown", "old success completed an identical newer request");
        tracker.request("C:/walls/old-generation.jpg", primary);
        oldOperation = latestOperation();
        Native.Wallpaper.replaceWorker();
        check(state().outcome === "unknown", "worker retirement was reported as a definite failure");
        tracker.request("C:/walls/new-generation.jpg", primary);
        newOperation = latestOperation();
        check(newOperation > oldOperation, "replacement worker did not accept a newer pick");
        check(Native.Wallpaper.pending.find(item => item.id === oldOperation).generation
            !== Native.Wallpaper.pending.find(item => item.id === newOperation).generation,
            "the test did not model two generations");
        Native.Wallpaper.finishLater(newOperation, true, 15);
        later(45, newerFinishesFirst);
    }
    function newerFinishesFirst(): void {
        check(state().outcome === "applied", "replacement completion was not observed");
        check(Native.Wallpaper.screenPaths.primary === "C:/walls/new-generation.jpg", "replacement did not mutate shared OS");
        // Retirement drops the old result, not its eventual mutation.
        Native.Wallpaper.finishLater(oldOperation, true, 10);
        later(50, olderFinishesLast);
    }
    function olderFinishesLast(): void {
        check(state().desired === "C:/walls/new-generation.jpg", "old mutation replaced desired state");
        check(Native.Wallpaper.screenPaths.primary === "C:/walls/old-generation.jpg", "old provider did not land last");
        callsBeforeRepair = Native.Wallpaper.screenCalls.length;
        Native.DesktopLayer.wallpaperChanged();
        check(state().repairUsed, "recovery did not schedule its bounded repair");
        check(state().outcome === "pending", "repair did not report applying");
        check(Native.Wallpaper.screenCalls.length === callsBeforeRepair + 1, "recovery did not reapply exactly once");
        Native.Wallpaper.finishLater(latestOperation(), true, 10);
        later(40, afterRepair);
    }
    function afterRepair(): void {
        check(Native.Wallpaper.screenPaths.primary === state().desired, "repair did not restore desired OS path");
        check(state().outcome === "applied", "repair completion was not observed");
        callsBeforeRepair = Native.Wallpaper.screenCalls.length;
        Native.Wallpaper.screenPaths = Object.assign({}, Native.Wallpaper.screenPaths,
            {primary: "C:/walls/old-generation.jpg"});
        Native.DesktopLayer.wallpaperChanged();
        Native.DesktopLayer.wallpaperChanged();
        check(state().outcome === "unknown", "a post-repair mismatch still claimed success");
        check(Native.Wallpaper.screenCalls.length === callsBeforeRepair, "repair entered a mutation loop");
        check(Wallpapers.profilePick === "", "readback imported a foreign global pick");
        check(Wallpapers.monitorPicks["primary-id"] === "C:/walls/b.jpg", "readback imported a foreign monitor pick");
        later(750, finish);
    }
    function finish(): void {
        check(Native.Wallpaper.screenCalls.length === callsBeforeRepair, "recovery timers repeated the repair");
        check(state().outcome === "unknown", "cached readback promoted an unknown result");
        tracker.release(null);
        check(tracker.request("C:/walls/global.jpg", null), "global request was rejected");
        check(tracker.targets["secondary-id"].desired === "C:/walls/global.jpg", "global desired target missing");
        Native.Wallpaper.finishLater(latestOperation(), true, 10);
        later(40, afterGlobal);
    }
    function afterGlobal(): void {
        check(tracker.targets["primary-id"].outcome === "applied", "global success with a matching readback was not applied");
        check(tracker.targets["secondary-id"].outcome === "applied", "global success with a matching readback was not applied");
        check(tracker.targets["secondary-id"].observed === "C:/walls/global.jpg", "global readback was not recorded");
        tracker.request("C:/walls/final-primary.jpg", primary);
        Native.Wallpaper.finishLater(latestOperation(), false, 10);
        later(40, afterIndependentFailure);
    }
    function afterIndependentFailure(): void {
        check(state().outcome === "failed", "targeted failure was not recorded");
        check(tracker.targets["secondary-id"].desired === "C:/walls/global.jpg", "primary failure changed secondary desire");
        check(tracker.targets["secondary-id"].outcome === "applied", "primary failure changed secondary outcome");
        tracker.release(primary);
        check(tracker.targets["primary-id"] === undefined, "engine handoff retained static desired state");
        check(tracker.targets["secondary-id"] !== undefined, "targeted handoff released every monitor");
        tracker.release(null);
        tracker.request("C:/walls/blocking.jpg", primary);
        oldOperation = latestOperation();
        globalCallsBefore = Native.Wallpaper.calls.length;
        tracker.request("C:/walls/queued-global.jpg", null);
        tracker.request("C:/walls/newer-primary.jpg", primary);
        Native.Wallpaper.finishLater(oldOperation, true, 10);
        later(40, afterPartialSupersession);
    }
    function afterPartialSupersession(): void {
        check(Native.Wallpaper.calls.length === globalCallsBefore, "partially superseded global work used a global setter");
        check(Native.Wallpaper.pending[0].screen === "secondary", "remaining global work targeted the newer display pick");
        check(state().desired === "C:/walls/newer-primary.jpg", "older global work overwrote the newer primary desire");
        callsBeforeRepair = Native.Wallpaper.screenCalls.length;
        Native.Wallpaper.screenIds = {primary: "replacement-id", secondary: "secondary-id"};
        Native.Wallpaper.finishLater(latestOperation(), true, 10);
        later(40, afterQueuedTopologyChange);
    }
    function afterQueuedTopologyChange(): void {
        check(state().outcome === "failed", "a queued target replacement was accepted");
        check(Native.Wallpaper.screenCalls.length === callsBeforeRepair, "queued work retargeted a replacement monitor");
        check(tracker.targets["secondary-id"].outcome === "applied", "partial global work did not complete on the retained monitor");
        check(Native.Wallpaper.screenPaths.secondary === "C:/walls/queued-global.jpg", "retained display did not get its desired image");
        console.log("CAELESTIA_WALLPAPER_COMPLETION_PASS " + assertions);
        Qt.quit();
    }
}
