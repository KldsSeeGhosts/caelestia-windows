import QtQuick
import QtQuick.Window
import Quickshell
import Caelestia
import qs.services
import qs.modules.bar as Bar
import qs.modules.bar.popouts as BarPopouts

ShellRoot {
    id: root
    settings.watchFiles: false
    readonly property string mode: Quickshell.env("CAELESTIA_GROK_TEST_MODE")
    property int ticks: 0
    property bool capturing: false

    FontLoader { source: Quickshell.shellPath("assets/google-sans-flex/GoogleSansFlex-VariableFont_GRAD,ROND,opsz,slnt,wdth,wght.ttf") }
    FontLoader { source: Quickshell.shellPath("assets/material-symbols-rounded/MaterialSymbolsRounded.ttf") }
    FontLoader { source: Quickshell.shellPath("assets/rubik/Rubik.ttf") }

    // Offscreen-only host. Production creates neither a window nor an entry
    // when the snapshot source is unconfigured.
    Window {
        width: 500
        height: 500
        visible: GrokBot.enabled
        color: "#202124"
        Rectangle {
        id: scene
        anchors.fill: parent
        color: "#202124"
        Rectangle {
            x: 65
            y: 65
            width: 400
            height: 350
            radius: 24
            color: Colours.palette.m3surfaceContainer
        }
        Bar.Bar {
            id: bar
            width: 48
            height: 450
            screen: Quickshell.screens[0]
            screenState: ShellState.forScreen(Quickshell.screens[0])
            popouts: rosterPopouts
            fullscreen: false
        }
        BarPopouts.Wrapper {
            id: rosterPopouts
            x: 65
            width: 400
            height: 450
            screen: Quickshell.screens[0]
            offsetScale: 0
        }
        }
    }
    function containsAvatar(item): bool {
        if (item.objectName === "taskbarGrokBot") return true;
        for (const child of item.children || [])
            if (containsAvatar(child)) return true;
        return false;
    }
    function finish(): void {
        if (root.mode === "configured") {
            for (const data of ["{}", "{", JSON.stringify({bots: [], counts: {}, generated_ts: Date.now() / 1000 - 61}),
                    JSON.stringify({bots: [], counts: {}, generated_ts: Date.now() / 1000 + 11})]) {
                GrokBot.accept(data);
                if (GrokBot.status !== "offline" || GrokBot.bots.length !== 0) {
                    console.error("CAELESTIA_GROK_SMOKE_FAIL invalid snapshot");
                    Qt.exit(1);
                    return;
                }
            }
            GrokBot.configure('{"enabled":true,"snapshotPath":"https://example.invalid/secret"}');
            if (GrokBot.enabled || GrokBot.polling || rosterPopouts.hasCurrent) {
                console.error("CAELESTIA_GROK_SMOKE_FAIL disable or URL rejection");
                Qt.exit(1);
                return;
            }
        }
        console.info("CAELESTIA_GROK_SMOKE_PASS " + root.mode);
        Qt.quit();
    }
    Timer {
        running: true
        repeat: true
        interval: 100
        onTriggered: {
            if (root.capturing) return;
            root.ticks++;
            if (root.ticks === 5 && GrokBot.enabled) {
                rosterPopouts.currentName = "grokbot";
                rosterPopouts.hasCurrent = true;
            }
            if (root.ticks < 15) return;
            let ok = false;
            if (root.mode === "unconfigured")
                ok = !GrokBot.enabled && !GrokBot.polling && GrokBot.status === "unconfigured" && GrokBot.bots.length === 0
                    && !root.containsAvatar(bar);
            else if (root.mode === "offline")
                ok = GrokBot.enabled && GrokBot.polling && GrokBot.status === "offline" && GrokBot.bots.length === 0
                    && root.containsAvatar(bar) && rosterPopouts.current !== null;
            else
                ok = GrokBot.enabled && GrokBot.polling && GrokBot.status === "ok" && GrokBot.bots.length === 3
                    && GrokBot.attentionBot.name === "Waiting"
                    && GrokBot.sortedBots[0].name === "Waiting"
                    && GrokBot.faceFor(GrokBot.sortedBots[0]) === "attentive"
                    && GrokBot.faceFor(GrokBot.sortedBots[1]) === "excited"
                    && root.containsAvatar(bar) && rosterPopouts.current !== null;
            if (ok) {
                if (root.mode === "configured") {
                    root.capturing = true;
                    CUtils.saveItem(scene, Qt.resolvedUrl(Quickshell.env("CAELESTIA_GROK_TEST_SCREENSHOT")), () => root.finish(), () => {
                        console.error("CAELESTIA_GROK_SMOKE_FAIL screenshot");
                        Qt.exit(1);
                    });
                } else root.finish();
            } else if (root.ticks > 50) {
                console.error("CAELESTIA_GROK_SMOKE_FAIL " + root.mode + " status=" + GrokBot.status);
                Qt.exit(1);
            }
        }
    }
}
