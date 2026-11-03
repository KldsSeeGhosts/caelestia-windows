// Reproduction for #214: the Windows background host is recreated when the
// desktop is re-embedded after Wallpaper Engine hands it back. The backend
// keeps the QML item tree and moves it from the old QQuickWindow to the new
// one (two setParentItem calls), exactly as this fixture does below.
//
// The background clock's blur capture used to be an inline MultiEffect.source
// value, so it had no visual parent and leaked a window reference on the
// wallpaper. The wallpaper then stayed on the dead window and Qt warned
// "Cannot use same item on different windows at the same time" before crashing
// in QQuickWindowPrivate::dirtyItem.
//
// The fake host mirrors WindowsBackground's underlay state machine. At
// handback the backend drops the underlay acknowledgement, but wallpaper64.exe
// keeps running with its wallpaper closed (#214). The acknowledged desktop
// claim keeps the host enabled, so the failure here is the reparent, not a
// screens flip.
import QtQuick
import QtQuick.Window
import Quickshell
import Quickshell.Windows as Native
import Caelestia.Config
import qs.services
import qs.modules.background

ShellRoot {
    id: root

    settings.watchFiles: false

    // Mirrors the WindowsDesktopLayer shape consumed by WindowsBackground.
    // underlayActive also needs the external wallpaper window inside the host;
    // when it leaves, the backend drops the acknowledgement but keeps the
    // host enabled (#220). A plain property updated from the inputs models the
    // backend getter and avoids a false binding loop when the ownership guard
    // reconciles the adapter from underlayActiveChanged.
    property QtObject desktopLayer: QtObject {
        property bool active: true
        property bool coveredByForeign: true
        property bool underlayActive: false
        property bool enabled: true
        property bool embedRefused: false
        property var aboveIcons: []
        function updateUnderlay(): void {
            underlayActive = enabled && !embedRefused && aboveIcons.length === 0 && coveredByForeign;
        }
        onEnabledChanged: updateUnderlay()
        onEmbedRefusedChanged: updateUnderlay()
        onAboveIconsChanged: updateUnderlay()
        onCoveredByForeignChanged: updateUnderlay()
        Component.onCompleted: updateUnderlay()
    }
    property QtObject wallpaperEngine: QtObject {
        property bool running: true
        property bool snapshotReady: true
        property int scans: 0
        function refresh(deep): void { scans++ }
        // WINDOWS_BACKGROUND_OWNERSHIP
        Component.onCompleted: seedDesktopClaim()
    }
    property QtObject wallpapers: QtObject {
        property bool externalWallpaperActive: root.wallpaperEngine.ownsDesktop
        property string fileCurrent: "file:///own-wallpaper.png"
        property string current: root.wallpaperEngine.ownsDesktop ? "file:///we-preview.png" : fileCurrent
    }
    readonly property bool backgroundRequested: true
    readonly property bool underlaySupported: "underlayActive" in desktopLayer
    readonly property bool externalActive: wallpapers.externalWallpaperActive
    // WindowsBackground.yielded, kept in step with the adapter by review.
    // The ownership claim itself is the spliced WallpaperEngine block. The
    // claim keeps the host mounted while the backend withdraws the
    // acknowledgement and the guard releases it, so no window is recreated
    // twice on a handback.
    readonly property bool yielded: desktopLayer.embedRefused
        || (externalActive && !desktopLayer.underlayActive
            && (!wallpaperEngine.desktopClaimed || desktopLayer.aboveIcons.length > 0))
    // WindowsBackground.enabled, kept in step with the adapter by review.
    readonly property bool hostEnabled: backgroundRequested && !yielded

    property Item desktopClock: null
    property int assertions: 0

    FontLoader { source: Quickshell.shellPath("assets/google-sans-flex/GoogleSansFlex-VariableFont_GRAD,ROND,opsz,slnt,wdth,wght.ttf") }
    FontLoader { source: Quickshell.shellPath("assets/material-symbols-rounded/MaterialSymbolsRounded.ttf") }
    FontLoader { source: Quickshell.shellPath("assets/rubik/Rubik.ttf") }

    function check(value, description): void {
        assertions++;
        if (!value)
            throw new Error(description);
    }
    function wn(item): string {
        if (!item)
            return "none";
        const window = item.Window.window;
        return window === winA ? "A" : window === winB ? "B" : window === null ? "null" : "other";
    }

    Window {
        id: winA
        width: 640; height: 400; visible: true
        Item {
            id: contentA
            anchors.fill: parent
            Item {
                id: behindClock
                anchors.fill: parent
                Rectangle { anchors.fill: parent; color: "red" }
            }
            Loader {
                id: clockLoader
                asynchronous: true
                anchors.fill: parent
                active: root.hostEnabled
                sourceComponent: DesktopClock {
                    wallpaper: behindClock
                    absX: 0
                    absY: 0
                }
                onLoaded: root.desktopClock = item
            }
        }
    }
    Window { id: winB; width: 640; height: 400; visible: true }

    // True once every active Loader under the clock, including the nested
    // asynchronous blur Loader that owns the capture, has finished loading.
    function loadersReady(item): bool {
        for (const child of item.children) {
            if ("sourceComponent" in child && "status" in child
                    && child.active && child.status !== Loader.Ready)
                return false;
            if (!loadersReady(child))
                return false;
        }
        return true;
    }
    function fail(error): void {
        console.error("CAELESTIA_BACKGROUND_HANDBACK_FAIL " + error);
        Qt.exit(1);
    }

    // Wait for the capture to exist instead of a fixed delay, so a slow load
    // cannot reparent before the defective capture is created.
    property int waitedMs: 0
    Timer {
        interval: 100; running: true; repeat: true
        onTriggered: {
            root.waitedMs += interval;
            if (!(root.desktopClock && root.loadersReady(root.desktopClock))) {
                if (root.waitedMs >= 10000) {
                    stop();
                    root.fail("the desktop clock and its blur capture did not load");
                }
                return;
            }
            stop();
            try {
                check(root.desktopLayer.underlayActive, "the backend acknowledges the external wallpaper window");
                check(root.hostEnabled, "the underlay keeps the background host mounted");
                check(root.desktopClock.blurEnabled, "the desktop clock blur is active for this fixture");
                check(wn(behindClock) === "A", "the desktop clock starts on the first window");

                // Wallpaper Engine's control command closes the wallpaper but
                // leaves wallpaper64.exe running. The backend drops the
                // underlay acknowledgement; the ownership guard releases the
                // external claim, so the shell's own wallpaper and clock stay
                // mounted instead of a black external-owned WorkerW (#214).
                root.desktopLayer.coveredByForeign = false;
                check(!root.desktopLayer.underlayActive, "the handback drops the underlay acknowledgement");
                check(root.wallpaperEngine.running, "the engine process still runs after the handback");
                check(!root.wallpapers.externalWallpaperActive, "the handback releases the external claim");
                check(root.wallpapers.current === root.wallpapers.fileCurrent,
                    "the handback shows the shell's own wallpaper, not the external preview");
                check(root.hostEnabled, "the handback keeps the background host mounted");
                check(root.desktopClock !== null, "the handback keeps its own background instance");
                contentA.parent = null;
                contentA.parent = winB.contentItem;

                check(wn(behindClock) === "B", "the wallpaper follows the recreated window");
                check(wn(root.desktopClock) === "B", "the desktop clock follows the recreated window");

                // A refused embed is not a handback: the refused panel stays
                // top level, so the adapter must unmount rather than keep a
                // full-screen background over applications.
                root.desktopLayer.embedRefused = true;
                check(!root.hostEnabled, "a refused embed after the handback fails closed");
                root.desktopLayer.embedRefused = false;
                check(!root.hostEnabled, "clearing the refusal without a fresh acknowledgement stays fail-closed");
                root.wallpaperEngine.running = false;
                check(root.hostEnabled, "the stopped process restores the own desktop");
                settle.start();
            } catch (error) {
                root.fail(error);
            }
        }
    }
    // Let the moved tree go through an event-loop and render turn before
    // passing, so deferred failures surface too.
    Timer {
        id: settle
        interval: 300
        onTriggered: {
            try {
                check(wn(behindClock) === "B", "the wallpaper stays on the recreated window after a render turn");
                console.log("CAELESTIA_BACKGROUND_HANDBACK_PASS " + assertions);
                Qt.quit();
            } catch (error) {
                root.fail(error);
            }
        }
    }
}
