import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Windows as Native
import qs.services

// A malformed worker response must not count as a healthy worker. Two malformed
// responses, each followed by worker exit, must therefore produce exponential
// restart backoff rather than resetting every restart to one second.
QtObject {
    id: root

    readonly property string configPath: Quickshell.env("CAELESTIA_CONFIG_DIR") + "/windows.json"
    property int assertions: 0
    property var scan
    property var restartTimer
    property bool seeded: {
        Quickshell.environment = {CAELESTIA_COMBINED_LIVE: "1",
            CAELESTIA_WE_PYTHON: "C:/fake/python.exe"};
        Files.contents[configPath] = JSON.stringify({windows: {wallpaperEngine: {enabled: false}}});
        return true;
    }

    function check(value, message): void {
        assertions++;
        if (!value)
            throw new Error(message);
    }
    function guard(step): void {
        try { step(); }
        catch (error) {
            console.error("CAELESTIA_WALLPAPER_ENGINE_MALFORMED_FAIL " + error);
            Qt.exit(1);
        }
    }
    function later(step): void {
        Qt.callLater(() => guard(step));
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
    function malformedThenExit(response, expectedAttemptsBeforeExit): void {
        scan.stdout.read(response);
        check(WallpaperEngine.scanRestartAttempts === expectedAttemptsBeforeExit,
            "malformed output changed worker health before validation");
        scan.running = false;
        scan.exited(1);
    }

    Component.onCompleted: later(run)
    function run(): void {
        scan = childNamed(WallpaperEngine, "wallpaperEngineScan");
        restartTimer = childNamed(WallpaperEngine, "wallpaperEngineScanRestart");
        check(scan && scan.running, "startup discovery worker did not start");
        check(restartTimer, "scan restart timer is unavailable");
        check(scan.writes.length === 1, "startup worker did not receive a scan request");

        // A running engine keeps the long-lived worker wanted even when the
        // integration itself is disabled.
        WallpaperEngine.running = true;
        malformedThenExit("this is not discovery json", 0);
        check(WallpaperEngine.scanRestartAttempts === 1, "first worker exit did not record one failure");
        check(restartTimer.interval === 1000, "first worker exit did not use one-second backoff");
        check(restartTimer.running, "first worker exit did not schedule a restart");

        // Deterministically restart the wanted worker without waiting for the
        // production one-second timer, then repeat the malformed-output/exit
        // sequence. The pre-fix code reset attempts on malformed output, so
        // this exit incorrectly returned to 1000 ms.
        restartTimer.stop();
        WallpaperEngine.startScan(false);
        check(scan.running && scan.writes.length === 2, "the replacement worker did not receive a scan request");
        malformedThenExit('{"ok":true,"running":false,"detected":true,"monitors":{},"items":[null]}', 1);
        check(WallpaperEngine.scanRestartAttempts === 2, "second worker exit did not increase failure count");
        check(restartTimer.interval === 2000, "second malformed-output worker exit did not double backoff");
        check(WallpaperEngine.status === "error", "malformed discovery did not surface an error");

        console.log("CAELESTIA_WALLPAPER_ENGINE_MALFORMED_PASS " + assertions);
        Qt.quit();
    }
}
