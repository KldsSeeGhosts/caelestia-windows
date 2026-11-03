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

    // Wallpaper Engine owns WorkerW while the backend acknowledges its
    // wallpaper window in the host. Host the clock and wallpaper as the
    // underlay beneath it; otherwise yield the desktop rather than cover a
    // running engine. Discovery starts fail-closed so startup cannot cover a
    // running engine. The ownership claim lives in WallpaperEngine, so a
    // genuine handback releases it and this adapter mounts the shell's own
    // desktop again (#214). A refused embed is not a handback and still fails
    // closed: mounting there would leave a full-screen window over the
    // applications.
    readonly property bool backgroundRequested: Quickshell.env("CAELESTIA_WINDOWS_BACKGROUND") === "1"
    readonly property bool underlaySupported: "underlayActive" in Native.DesktopLayer
    readonly property bool underlayActive: underlaySupported && Native.DesktopLayer.underlayActive
    readonly property bool embedRefused: "embedRefused" in Native.DesktopLayer
        && Native.DesktopLayer.embedRefused
    readonly property bool externalActive: Wallpapers.externalWallpaperActive
    // A handed-back engine can show another wallpaper without restarting
    // wallpaper64.exe. While the process still runs the host must stay in the
    // underlay position, even with Replace icons: the backend only
    // acknowledges an underlay when aboveIcons is empty, so an above-icons
    // embed would hide the returning wallpaper's claim and the handback latch
    // could never clear (#214). Replace resumes once the process stops.
    readonly property bool engineRunning: WallpaperEngine.running
    // Keep the host mounted across the handback: the backend withdraws the
    // acknowledgement before WallpaperEngine releases the claim, and a
    // transient yield there would recreate every background window. An
    // above-icons embed is our own and must still fail closed.
    readonly property bool yielded: embedRefused
        || (externalActive && !underlayActive
            && (!WallpaperEngine.desktopClaimed || Native.DesktopLayer.aboveIcons.length > 0))
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

    function reconcileDesktop(): void {
        // Keep the host enabled while the backend can still discover WorkerW,
        // even before it reports the underlay. That is what turns a fail-closed
        // external wallpaper into an acknowledged underlay instead of a gap.
        if (backgroundRequested && (underlaySupported || !Wallpapers.externalWallpaperActive)) {
            // aboveIcons embeds into the icon host, which would cover the
            // WorkerW underlay and Wallpaper Engine. Never embed while an
            // external wallpaper is active, and stay in the underlay position
            // while the engine process can still show another wallpaper: the
            // backend cannot acknowledge that return through a non-empty
            // aboveIcons, so the shell would never reclaim the desktop (#214).
            Native.DesktopLayer.aboveIcons = desktopIcons === "Replace" && !externalActive && !engineRunning
                ? ["caelestia-background"] : [];
            Native.DesktopLayer.enabled = true;
        } else {
            Native.DesktopLayer.enabled = false;
        }
    }
    onBackgroundRequestedChanged: reconcileDesktop()
    onExternalActiveChanged: reconcileDesktop()
    onDesktopIconsChanged: reconcileDesktop()
    onEngineRunningChanged: reconcileDesktop()
    onUnderlayActiveChanged: {
        // The external wallpaper window left the host, so the backend has
        // dropped its acknowledgement. Re-scan now instead of waiting for the
        // idle poll, so a process that really stopped is noticed promptly.
        // WallpaperEngine owns the claim and releases it on a genuine
        // handback (#214).
        if (!underlayActive)
            WallpaperEngine.refresh(false);
    }
    Component.onCompleted: reconcileDesktop()

    function checkReady(screen: ShellScreen): bool {
        if (yielded) {
            // Host readiness here only means we yielded successfully. There
            // is no backend acknowledgement of external output on this screen.
            const released = screens.length === 0 && (!Native.DesktopLayer.active || underlaySupported);
            console.log("CAELESTIA_BACKGROUND_STATE", JSON.stringify({
                active: Native.DesktopLayer.active, ready: released, refused: embedRefused,
                owner: WallpaperEngine.running ? "wallpaper-engine-process" : "undiscovered",
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
            // Wallpaper Engine owns the desktop, but the backend embedded this
            // window beneath it. The ordinary readiness contract still applies:
            // the underlay must present before the handoff exposes it.
            console.log("CAELESTIA_BACKGROUND_STATE", JSON.stringify({
                active: Native.DesktopLayer.active, icons: desktopIcons,
                underlay: true, screen: screens.indexOf(screen), ready: !!ready,
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
            clockEnabled: clockEnabled, clockPresent: !!clock,
            hasWallpaper: String(Wallpapers.current ?? "").length > 0,
            width: window?.width ?? 0, height: window?.height ?? 0
        }));
        return !!ready;
    }
}
