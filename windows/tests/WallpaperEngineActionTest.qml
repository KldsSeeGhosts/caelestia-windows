import QtQuick
import Quickshell
import qs.services

// The action Process mirrors the scan process's failure handling: a helper that
// fails to start or never returns must clear its claim so a later selection is
// accepted. The fake Process records `running`; clearing it models
// FailedToStart (which emits no exited), and the watchdog is exercised through
// a short actionTimeout rather than a real 20-second wait.
QtObject {
    id: root

    property int assertions: 0

    function check(value, description): void {
        assertions++;
        if (!value)
            throw new Error(description);
    }
    function guard(step): void {
        try {
            step();
        } catch (error) {
            console.error("CAELESTIA_WALLPAPER_ENGINE_ACTION_FAIL " + error);
            Qt.exit(1);
        }
    }
    function childNamed(parent, name) {
        for (const child of (parent.data ?? parent.children ?? [])) {
            if (child.objectName === name)
                return child;
            const found = childNamed(child, name);
            if (found)
                return found;
        }
        return null;
    }
    function select(action): void {
        check(WallpaperEngine.open("C:/we/project.json",
            {name: "primary", targetId: "primary-id"}), "selection was not accepted");
        check(action.running, "accepted selection did not start the fake action");
        check(WallpaperEngine.actionPending, "accepted selection did not arm the action watchdog");
        check(action.command[2] === "open"
            && action.command[4] === "C:/we/project.json"
            && action.command[5] === "--screen-target"
            && action.command[6] === "primary-id", "selection command was retargeted");
    }

    property bool seeded: {
        Quickshell.environment = {
            CAELESTIA_COMBINED_LIVE: "1",
            CAELESTIA_WE_PYTHON: "C:/fake/python.exe"
        };
        Quickshell.screens = [{name: "primary"}];
        return true;
    }

    Component.onCompleted: Qt.callLater(run)

    function run(): void {
        guard(function() {
            WallpaperEngine.options = {enabled: true};
            WallpaperEngine.detected = true;
            WallpaperEngine.running = true;
            WallpaperEngine.snapshotReady = true;
            WallpaperEngine.items = [{path: "C:/we/project.json"}];
            const action = childNamed(WallpaperEngine, "wallpaperEngineAction");
            check(action !== null, "the real action Process was not staged");

            select(action);
            // FailedToStart clears running without emitting exited.
            action.running = false;
            Qt.callLater(() => guard(function() {
                check(WallpaperEngine.lastError.includes("failed to start"),
                    "an action start failure was not reported");
                check(!action.running && !WallpaperEngine.actionPending,
                    "an action start failure kept the next selection blocked");

                WallpaperEngine.lastError = "";
                WallpaperEngine.actionTimeout = 30;
                select(action);
                waitForWatchdog.start();
            }));
        });
    }

    property Timer waitForWatchdog: Timer {
        interval: 150
        onTriggered: guard(function() {
            const action = childNamed(WallpaperEngine, "wallpaperEngineAction");
            check(!action.running && !WallpaperEngine.actionPending,
                "the action watchdog did not clear the hung action");
            check(WallpaperEngine.lastError.includes("timed out"),
                "the action watchdog was not reported");

            // The timeout must release the claim, not leave a permanent error.
            WallpaperEngine.lastError = "";
            WallpaperEngine.actionTimeout = 20000;
            select(action);
            action.running = false;
            action.exited(0);
            check(!WallpaperEngine.actionPending,
                "a completed action kept its pending claim");
            WallpaperEngine.options = {enabled: true, monitor: "Monitor9"};
            check(WallpaperEngine.open("C:/we/project.json"), "all-display selection was rejected");
            check(action.command.length === 6 && action.command[5] === "--all-displays",
                "default engine pick used the configured single monitor");
            check(WallpaperEngine.actionAllDisplays && !WallpaperEngine.actionScreenTarget,
                "default engine pick retained a previous explicit target");
            action.running = false;
            action.exited(0);
            console.log("CAELESTIA_WALLPAPER_ENGINE_ACTION_PASS " + assertions);
            Qt.quit();
        })
    }
}
