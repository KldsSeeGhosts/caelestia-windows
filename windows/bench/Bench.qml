// Test-only host. Never staged by the installer or read by production.
import QtQuick
import QtQuick.Window
import Quickshell
import Caelestia.Config
import qs.modules.drawers
import qs.modules.launcher.services
import qs.modules.nexus as Nexus
import qs.windows.services.apps as AppObjects
import qs.services as ServiceObjects

ShellRoot {
    id: root
    settings.watchFiles: false
    readonly property string scenario: Quickshell.env("CAELESTIA_BENCH_SCENARIO")
    readonly property int spinMs: Number(Quickshell.env("CAELESTIA_BENCH_SPIN_MS") || "0")
    property int step: -1
    property int frames: 0
    property real started: 0
    property real sink: 0
    property var events: []
    readonly property var panels: ["launcher", "dashboard", "utilities", "sidebar", "nexus"]
    ElapsedTimer { id: clock }
    ElapsedTimer { id: burn }

    ContentWindow {
        id: win
        screen: Quickshell.screens[0]
        visible: true
        interactionEnabled: false
    }
    // Only generated records reach the production search projection.
    QtObject {
        id: catalog
        property bool scanCompleted: true
        property string scanError: ""
        property var applications: ({values: []})
    }
    AppObjects.AppsService { id: apps; enabled: true; catalog: catalog }
    ServiceObjects.AudioService { id: audio; enabled: true }
    ServiceObjects.PlayersService { id: media; enabled: true }
    Connections {
        target: win.contentItem.Window.window
        function onFrameSwapped(): void {
            root.frames++;
        }
    }
    function closePanels(): void {
        for (const name of ["launcher", "dashboard", "utilities", "sidebar"])
            win.screenState[name] = false;
        Nexus.WindowFactory.closeAll();
    }
    function work(): void {
        if (scenario === "launcher-search") {
            for (let i = 0; i < 100; i++)
                sink += apps.search(["application", "17", "missing", ""][i % 4]).length;
        } else if (scenario === "audio-media") {
            for (let i = 0; i < 100; i++) {
                audio.backend = {ready: true, nodes: {values: [
                    {isSink: true, isStream: false, audio: {volume: i / 100, muted: false}}
                ]}};
                media.backend = {ready: true, players: {values: []}};
                sink += audio.sinks.length + media.list.length;
            }
        } else if (scenario === "panels") {
            closePanels();
            const panel = panels[step % panels.length];
            if (panel === "nexus")
                Nexus.WindowFactory.openPage(3);
            else
                win.screenState[panel] = true;
        }
    }
    function advance(): void {
        try {
            if (step === -1) {
                if (frames < 2) {
                    win.contentItem.Window.window.update();
                    return;
                }
                const entries = [];
                for (let i = 0; i < 256; i++)
                    entries.push({id: "app-" + i, name: "application-" + i, comment: "",
                                  genericName: "", categories: [], keywords: []});
                catalog.applications = {values: entries};
                if (apps.search("").length !== 256 || apps.search("missing").length !== 0)
                    throw new Error("Generated search corpus failed its checks");
                console.log("CAELESTIA_BENCH_READY");
                step = 0;
            }
            if (step >= 8) {
                closePanels();
                console.log("CAELESTIA_BENCH_RESULT " + JSON.stringify({
                    events: events, frames: frames, sink: sink, spinMs: spinMs, completed: step
                }));
                Qt.quit();
                return;
            }
            // Named spans are exploration evidence, not CPU self-time.
            clock.restart();
            work();
            burn.restart();
            while (burn.elapsed() * 1000 < spinMs)
                sink++;
            events.push({name: scenario, ms: clock.elapsed() * 1000});
            win.contentItem.Window.window.update();
            step++;
        } catch (error) {
            console.error("CAELESTIA_BENCH_FAIL " + error);
            Qt.exit(1);
        }
    }
    Timer { interval: 150; running: true; repeat: true; onTriggered: root.advance() }
}
