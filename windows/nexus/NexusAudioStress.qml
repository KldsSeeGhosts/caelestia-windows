// Isolated, read-only native-window stress host for Nexus page teardown.
import QtQuick
import QtQuick.Window
import Quickshell
import Caelestia.Config
import qs.services
import qs.modules.nexus

ShellRoot {
    id: root
    settings.watchFiles: false

    FontLoader { source: Quickshell.shellPath("assets/google-sans-flex/GoogleSansFlex-VariableFont_GRAD,ROND,opsz,slnt,wdth,wght.ttf") }
    FontLoader { source: Quickshell.shellPath("assets/material-symbols-rounded/MaterialSymbolsRounded.ttf") }
    FontLoader { source: Quickshell.shellPath("assets/rubik/Rubik.ttf") }

    property int switches: 0
    property int waits: 0
    property var pages: null
    readonly property var sequence: [1, 2, 3]
    readonly property int targetSwitches: Number(Quickshell.env("NEXUS_AUDIO_STRESS_SWITCHES")) || 600

    function findPages(item): var {
        if (!item)
            return null;
        if (item.currentItem !== undefined && item.nState !== undefined)
            return item;
        for (const child of item.children) {
            const result = findPages(child);
            if (result)
                return result;
        }
        return null;
    }

    Window {
        id: win
        width: 900
        height: 650
        visible: true
        flags: Qt.Tool | Qt.WindowDoesNotAcceptFocus
        title: "Isolated Nexus stress test"
        contentItem.Config.screen: Quickshell.screens[0]?.name ?? ""
        contentItem.Tokens.screen: Quickshell.screens[0]?.name ?? ""

        Nexus {
            id: nexus
            anchors.fill: parent
            nState.screen: Quickshell.screens[0]
            nState.isWindow: true
        }
    }

    Timer {
        interval: 100
        repeat: true
        running: true
        onTriggered: {
            if (!root.pages)
                root.pages = root.findPages(nexus);
            if (!root.pages || !root.pages.currentItem) {
                if (++root.waits > 120) {
                    console.error("NEXUS_AUDIO_STRESS_FAIL page never loaded");
                    Qt.exit(1);
                }
                return;
            }
            if (root.switches > 0) {
                const expected = root.sequence[(root.switches - 1) % root.sequence.length];
                if (root.pages.currentItem.currentItem?.title !== PageRegistry.pages[expected].label) {
                    if (++root.waits > 120) {
                        console.error("NEXUS_AUDIO_STRESS_FAIL page did not settle", expected);
                        Qt.exit(1);
                    }
                    return;
                }
            }
            root.waits = 0;
            if (root.switches === root.targetSwitches) {
                if (!Audio.backendReady || Audio._nodes.length === 0) {
                    console.error("NEXUS_AUDIO_STRESS_FAIL no native audio nodes");
                    Qt.exit(1);
                    return;
                }
                console.warn("NEXUS_AUDIO_STRESS_PASS", root.switches);
                win.visible = false;
                Qt.quit();
                return;
            }
            nexus.nState.currentPageIdx = root.sequence[root.switches % root.sequence.length];
            ++root.switches;
        }
    }
}
