import QtQuick
import Quickshell
import Quickshell.Io
import qs.services
import qs.modules.dictation
import "services/DictationLogic.js" as Logic

ShellRoot {
    id: root
    settings.watchFiles: false
    property int assertions: 0
    property int step: 0
    property int ticks: 0
    property bool captured: false

    FontLoader {
        id: iconFont
        source: Quickshell.shellPath("assets/material-symbols-rounded/MaterialSymbolsRounded.ttf")
    }

    DictationIndicator {
        id: indicator
        windowSource: Qt.resolvedUrl("OffscreenDictationWindow.qml")
    }
    FileView {
        id: writer
        path: Dictation.statePath
        printErrors: false
        preload: false
        blockWrites: true
    }

    function check(condition, message): void {
        if (!condition)
            throw new Error(message);
        assertions++;
    }
    function publish(state, age): void {
        const now = Date.now() / 1000;
        writer.setText(JSON.stringify({
            state: state, updatedAt: now - (age || 0), startedAt: now - 12,
            screen: "missing-monitor",
            transcript: "SYNTHETIC_PRIVATE_SPEECH",
            error: "SYNTHETIC_PRIVATE_ERROR"
        }));
    }
    function advance(): void { step++; ticks = 0; }
    function pass(): void {
        console.info("CAELESTIA_DICTATION_SMOKE_PASS assertions=" + assertions);
        Qt.quit();
    }
    function logicTests(): void {
        const now = 1000000;
        for (const data of [null, [], 1, "listening", {}, { state: "unknown" },
            { state: "listening" }, { state: "listening", updatedAt: "1000" },
            { state: "listening", updatedAt: NaN }, { state: "processing", updatedAt: Infinity },
            { state: "listening", updatedAt: -1 }, { state: "listening", updatedAt: 1006 },
            { state: "listening", updatedAt: 700 }, { state: "processing", updatedAt: 700 },
            { state: "done", updatedAt: 998.2 }, { state: "error", updatedAt: 997.4 }])
            check(Logic.normalize(data, now).state === "idle", "invalid/expired observation");
        for (const state of ["listening", "processing", "done", "error"]) {
            const result = Logic.normalize({
                state: state, updatedAt: 1000, startedAt: 988, screen: "second",
                transcript: "SYNTHETIC_PRIVATE_SPEECH", error: "SYNTHETIC_PRIVATE_ERROR"
            }, now);
            check(result.state === state && result.startedAt === 988
                && result.screenName === "second", "valid state projection");
            check(Object.keys(result).sort().join(",") === "screenName,startedAt,state,updatedAt",
                "status-only allowlist");
        }
        check(Logic.normalize({ state: "listening", updatedAt: 1000, startedAt: 1001 }, now).startedAt === 0,
            "invalid start time");
        check(Logic.normalize({ state: "listening", updatedAt: 1000, screen: {} }, now).screenName === "",
            "invalid screen");
        check(Logic.normalize({ state: "listening", updatedAt: 1000, screen: "x".repeat(500) }, now).screenName.length === 256,
            "bounded screen");
        check(Logic.normalize({ state: "done", updatedAt: 998.3 }, now).state === "done",
            "unexpired completion");
        const screens = [{ name: "primary" }, { name: "secondary" }];
        check(Logic.targetScreen(screens, "secondary") === screens[1], "named screen");
        check(Logic.targetScreen(screens, "missing") === screens[0], "removed screen fallback");
        check(Logic.targetScreen(screens, "") === screens[0], "default screen");
        check(Logic.targetScreen([], "") === null, "no screens");
    }

    Component.onCompleted: logicTests()
    Timer {
        interval: 50
        repeat: true
        running: true
        onTriggered: {
            try {
                if (++root.ticks > 120)
                    throw new Error("timeout at step " + root.step);
                if (!Dictation.enabled) {
                    if (root.ticks < 5)
                        return;
                    Dictation.applyState({ state: "listening", updatedAt: Date.now() / 1000 });
                    root.check(Dictation.state === "idle" && !indicator.window, "disabled despite populated file");
                    root.pass();
                    return;
                }
                switch (root.step) {
                case 0:
                    if (root.ticks < 5 || iconFont.status !== FontLoader.Ready)
                        return;
                    root.check(Dictation.state === "idle" && !indicator.window, "missing file");
                    root.check(!Dictation.canCancel, "no unsupported cancellation");
                    root.publish("listening", 0);
                    root.advance();
                    break;
                case 1:
                    if (Dictation.state !== "listening" || !indicator.window)
                        return;
                    root.check(Dictation.elapsedSeconds >= 12, "listening elapsed time");
                    root.check(Dictation.screenName === "missing-monitor", "screen projection");
                    root.check(indicator.window.screen === Quickshell.screens[0], "fallback on real screen");
                    root.check(indicator.window.pillWidth >= 112 && indicator.window.pillHeight > 0,
                        "original pill has finite geometry");
                    root.check(typeof Dictation.transcript === "undefined"
                        && typeof Dictation.errorMessage === "undefined", "no speech properties");
                    root.advance();
                    break;
                case 2:
                    // Let the original show animation settle.
                    if (root.ticks < 12)
                        return;
                    root.check(indicator.window.contentItem.opacity > 0.99, "show animation reaches native content");
                    root.check(indicator.window.pill.grabToImage(result => {
                        root.check(result.saveToFile(Quickshell.env("CAELESTIA_DICTATION_SCREENSHOT")),
                            "offscreen pill image saved");
                        root.captured = true;
                    }), "offscreen capture started");
                    root.advance();
                    // Keep this step until the asynchronous grab completes.
                    root.step = 20;
                    break;
                case 20:
                    if (!root.captured)
                        return;
                    root.publish("processing", 0);
                    root.step = 3;
                    root.ticks = 0;
                    break;
                case 3:
                    if (Dictation.state !== "processing")
                        return;
                    root.check(indicator.window !== null && Dictation.elapsedSeconds === 0, "processing pill");
                    writer.setText("{invalid json");
                    root.advance();
                    break;
                case 4:
                    if (Dictation.state !== "idle" || indicator.window)
                        return;
                    root.check(Dictation.screenName === "" && Dictation.updatedAt === 0, "malformed reset");
                    root.publish("listening", 0);
                    root.advance();
                    break;
                case 5:
                    if (Dictation.state !== "listening" || !indicator.window)
                        return;
                    root.check(true, "atomic replacement recovery");
                    root.publish("done", 0);
                    root.advance();
                    break;
                case 6:
                    if (Dictation.state !== "done" || indicator.window)
                        return;
                    root.check(Dictation.active, "completion lifetime without pill");
                    root.advance();
                    break;
                case 7:
                    if (Dictation.state !== "idle")
                        return;
                    root.check(!indicator.window, "completion expires");
                    root.publish("error", 0);
                    root.advance();
                    break;
                case 8:
                    if (Dictation.state !== "error")
                        return;
                    root.check(!indicator.window, "error never shows speech");
                    root.advance();
                    break;
                case 9:
                    if (Dictation.state !== "idle")
                        return;
                    root.check(true, "error expires");
                    // Almost-expired listening must expire without a producer
                    // update; repeated polling must not extend its lifetime.
                    root.publish("listening", 299);
                    root.advance();
                    break;
                case 10:
                    if (Dictation.state !== "listening" || !indicator.window)
                        return;
                    root.check(true, "near-stale activity loaded");
                    root.advance();
                    break;
                case 11:
                    if (Dictation.state !== "idle" || indicator.window)
                        return;
                    root.check(true, "stale producer expires");
                    root.publish("processing", 0);
                    root.advance();
                    break;
                case 12:
                    if (Dictation.state !== "processing" || !indicator.window)
                        return;
                    root.check(true, "fresh producer recovery");
                    root.publish("idle", 0);
                    root.advance();
                    break;
                case 13:
                    if (Dictation.state !== "idle" || indicator.window)
                        return;
                    root.check(Dictation.startedAt === 0 && Dictation.elapsedSeconds === 0, "idle clears state");
                    root.pass();
                    break;
                }
            } catch (error) {
                console.error("CAELESTIA_DICTATION_SMOKE_FAIL " + error);
                Qt.quit();
            }
        }
    }
}
