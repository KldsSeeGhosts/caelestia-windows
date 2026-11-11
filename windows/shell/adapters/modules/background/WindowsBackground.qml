pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Windows as Native
import Caelestia
import Caelestia.Config
import qs.services

// The original module owns wallpaper motion, clock layout and screen lifetimes.
// WorkerW embedding is opt-in and lives entirely in the Windows backend.
Background {
    id: root

    // the shell desktop is the fallback layer, not an alternative to an
    // enabled external wallpaper. A Background panel is a sibling of the external
    // wallpaper window inside the desktop host, and the backend pins every
    // marked Background below the bottom-most visible foreign child before the
    // panel presents (placeDesktopBackgrounds). That layering is what decides
    // visibility, per monitor and with no prediction: a monitor the engine
    // covers is covered by the engine's own window, and a monitor it does not
    // cover keeps showing the shell's wallpaper and clock. So the fallback
    // stays mounted for the whole external era, including before the engine
    // has presented its first frame and while it replaces that frame. This
    // only fills uncovered regions: an opaque external HWND can still paint
    // a placeholder over us. Window presence is not frame readiness.
    // A fresh profile with integration disabled instead keeps the background
    // group above foreign wallpaper children, still below desktop icons.
    // Process liveness, a saved selection, Explorer's host and a successful
    // CLI request never decide that policy here.
    //
    // Only the two states the backend cannot place safely unmount the
    // fallback. A refused SetParent leaves the panel top level, above the
    // desktop host, so it could cover the engine. An older backend without the
    // underlay placement cannot pin the group below a foreign window at all.
    // Both fail closed until the host or the backend changes.
    readonly property bool backgroundRequested: Quickshell.env("CAELESTIA_WINDOWS_BACKGROUND") === "1"
    readonly property bool underlaySupported: "underlayActive" in Native.DesktopLayer
    readonly property bool externalWallpaperEnabled: !Wallpapers.sourceFresh || WallpaperEngine.enabled
    readonly property bool underlayActive: underlaySupported && Native.DesktopLayer.underlayActive
    readonly property bool embedRefused: "embedRefused" in Native.DesktopLayer
        && Native.DesktopLayer.embedRefused
    readonly property bool externalActive: Wallpapers.externalWallpaperActive
    // A handed-back engine can show another wallpaper without restarting
    // wallpaper64.exe. While the process still runs the host must stay in the
    // underlay position, even with Replace icons: the backend only
    // acknowledges an underlay when aboveIcons is empty, so an above-icons
    // embed would hide the returning wallpaper's claim and the handback latch
    // could never clear. Replace resumes once the process stops.
    readonly property bool engineRunning: WallpaperEngine.running
    // The fallback is held beneath the external output, never selected in
    // place of it: keep it mounted through every claim and handback so an
    // absent/hidden external window reveals the own desktop layer and clock
    // rather than whatever Explorer paints underneath. Unmounting is a safety
    // refusal, not a readiness decision, so an unacknowledged process cannot
    // empty the desktop.
    readonly property bool yielded: embedRefused || (externalActive && !underlaySupported)
    readonly property bool enabled: backgroundRequested && !yielded
    readonly property bool smoke: Quickshell.env("CAELESTIA_SHELL_SMOKE") === "1"
    readonly property int screenIndex: Number(Quickshell.env("CAELESTIA_SHELL_SCREEN") || "0")
    readonly property string desktopIcons: Quickshell.env("CAELESTIA_WINDOWS_DESKTOP_ICONS") || "Behind"

    // Fail closed when Explorer has no desktop host. Never fall back to an
    // ordinary full-screen window over the user's applications.
    screens: enabled && Native.DesktopLayer.active
        ? Screens.screens.filter(s => !smoke
            || (Quickshell.env("CAELESTIA_SHELL_LIVE") === "1" && !Quickshell.env("CAELESTIA_SHELL_SCREEN"))
            || s === Quickshell.screens[screenIndex])
        : []

    property string lastUnderlayDecision: ""
    function logUnderlayDecision(): void {
        // Booleans and fixed status values only. No paths, window titles,
        // process/window handles, monitor names or profile identifiers.
        const decision = JSON.stringify({
            integration: WallpaperEngine.enabled, freshProfile: Wallpapers.sourceFresh,
            policy: externalWallpaperEnabled, running: engineRunning,
            snapshotReady: WallpaperEngine.snapshotReady, status: WallpaperEngine.status,
            claimed: WallpaperEngine.desktopClaimed, handedBack: WallpaperEngine.desktopHandedBack,
            requested: backgroundRequested, nativeEnabled: Native.DesktopLayer.enabled,
            active: Native.DesktopLayer.active, underlay: underlayActive,
            refused: embedRefused, aboveIcons: Native.DesktopLayer.aboveIcons.length !== 0
        });
        if (decision !== lastUnderlayDecision) {
            lastUnderlayDecision = decision;
            console.log("CAELESTIA_UNDERLAY_DECISION " + decision);
        }
    }
    property Connections engineDecisionWatcher: Connections {
        target: WallpaperEngine
        function onDesktopHandedBackChanged(): void { Qt.callLater(root.logUnderlayDecision); }
        function onStatusChanged(): void { Qt.callLater(root.logUnderlayDecision); }
    }
    property Connections nativeDecisionWatcher: Connections {
        target: Native.DesktopLayer
        ignoreUnknownSignals: true
        function onActiveChanged(): void { Qt.callLater(root.logUnderlayDecision); }
        function onEmbedRefusedChanged(): void { Qt.callLater(root.logUnderlayDecision); }
    }

    function reconcileDesktop(): void {
        if ("externalWallpaperEnabled" in Native.DesktopLayer)
            Native.DesktopLayer.externalWallpaperEnabled = externalWallpaperEnabled;
        // Keep the host enabled while the backend can still discover WorkerW,
        // even before it reports the underlay. That is what lets the fallback
        // mount beneath the engine from the first claim instead of leaving a
        // gap over the Windows wallpaper.
        if (backgroundRequested && (underlaySupported || !Wallpapers.externalWallpaperActive)) {
            // aboveIcons embeds into the icon host, which would cover the
            // WorkerW underlay and Wallpaper Engine. Never embed while an
            // external wallpaper is active, and stay in the underlay position
            // while the engine process can still show another wallpaper: the
            // backend cannot acknowledge that return through a non-empty
            // aboveIcons, so the shell would never reclaim the desktop.
            Native.DesktopLayer.aboveIcons = desktopIcons === "Replace" && !externalActive && !engineRunning
                ? ["caelestia-background"] : [];
            Native.DesktopLayer.enabled = true;
        } else {
            Native.DesktopLayer.enabled = false;
        }
        Qt.callLater(logUnderlayDecision);
    }
    onBackgroundRequestedChanged: reconcileDesktop()
    onExternalWallpaperEnabledChanged: reconcileDesktop()
    onExternalActiveChanged: reconcileDesktop()
    onDesktopIconsChanged: reconcileDesktop()
    onEngineRunningChanged: reconcileDesktop()
    onUnderlayActiveChanged: {
        Qt.callLater(logUnderlayDecision);
        // The external wallpaper window left the host, so the backend has
        // dropped its acknowledgement. Re-scan now instead of waiting for the
        // idle poll, so a process that really stopped is noticed promptly.
        // WallpaperEngine owns the claim and releases it on a genuine
        // handback.
        if (!underlayActive)
            WallpaperEngine.refresh(false);
    }
    Component.onCompleted: reconcileDesktop()

    function checkReady(screen: ShellScreen): bool {
        if (yielded) {
            // The fallback is only absent because the backend refused to embed
            // it, or cannot place it below external output. Readiness here is
            // only that the unsafe windows are gone; no external frame is
            // acknowledged and there is none to report.
            const released = screens.length === 0 && (!Native.DesktopLayer.active || underlaySupported);
            console.log("CAELESTIA_BACKGROUND_STATE", JSON.stringify({
                active: Native.DesktopLayer.active, ready: released, refused: embedRefused,
                leader: embedRefused ? "embed-refused" : "legacy-backend",
                externalOutputReady: null, clock: false
            }));
            return released;
        }
        const window = instances.find(w => w.modelData === screen);
        const clock = window ? CUtils.findChild(window.contentItem, "desktopClock") : null;
        const wallpaper = window ? CUtils.findChild(window.contentItem, "desktopWallpaper") : null;
        const clockEnabled = GlobalConfig.forScreen(screen.name).background.desktopClock.enabled;
        const clockReady = clockEnabled ? clock && clock.width > 0 && clock.height > 0 : !clock;
        const ready = Native.DesktopLayer.active && window && window.visible
            && clockReady
            && wallpaper && wallpaper.source.length > 0 && wallpaper.transitionProgress >= 1;
        if (underlayActive) {
            // An external window is visible in the host and the backend has
            // pinned this group below it. The ordinary readiness contract
            // still applies, because this same window becomes the visible
            // fallback in any gap between external frames. The acknowledgement
            // is host-wide: it says a visible foreign window exists, not that
            // this screen is covered.
            console.log("CAELESTIA_BACKGROUND_STATE", JSON.stringify({
                active: Native.DesktopLayer.active, icons: desktopIcons,
                underlay: true, underlayScope: "host", screen: screens.indexOf(screen), ready: !!ready,
                owner: WallpaperEngine.running ? "wallpaper-engine-underlay" : "undiscovered-underlay",
                clockEnabled: clockEnabled, clockPresent: !!clock,
                hasWallpaper: String(Wallpapers.current ?? "").length > 0,
                width: window?.width ?? 0, height: window?.height ?? 0
            }));
            return !!ready;
        }
        console.log("CAELESTIA_BACKGROUND_STATE", JSON.stringify({
            active: Native.DesktopLayer.active, icons: desktopIcons, underlay: underlayActive,
            screens: screens.map((_, index) => index), screen: screens.indexOf(screen), ready: !!ready,
            owner: "shell-fallback", externalClaim: externalActive,
            clockEnabled: clockEnabled, clockPresent: !!clock,
            hasWallpaper: String(Wallpapers.current ?? "").length > 0,
            width: window?.width ?? 0, height: window?.height ?? 0
        }));
        return !!ready;
    }
}
