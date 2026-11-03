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

    // Wallpaper Engine owns WorkerW. Host the clock and wallpaper as the
    // underlay beneath it when the backend sees the external wallpaper window
    // in the host; otherwise yield the desktop rather than cover a running
    // engine. Discovery starts fail-closed so startup cannot cover a running
    // engine. The acknowledgement drops when that window leaves the host
    // (#220), which is the handback signal for the ownership guard.
    readonly property bool backgroundRequested: Quickshell.env("CAELESTIA_WINDOWS_BACKGROUND") === "1"
    readonly property bool underlaySupported: "underlayActive" in Native.DesktopLayer
    readonly property bool underlayActive: underlaySupported && Native.DesktopLayer.underlayActive
    // A refused SetParent withdraws the underlay acknowledgement while the
    // host stays active and the refused panel stays top level. That is not a
    // handback: mounting there would leave a full-screen window over the
    // applications, so it must fail closed.
    readonly property bool embedRefused: "embedRefused" in Native.DesktopLayer
        && Native.DesktopLayer.embedRefused
    readonly property bool externalActive: Wallpapers.externalWallpaperActive
    // A detected wallpaper process is an ownership claim, not proof of
    // ownership. The backend's underlay acknowledgement proves the claim by
    // finding a visible wallpaper window in the desktop host. Wallpaper Engine
    // keeps running after its wallpaper is closed, though: the window leaves
    // the host while wallpaper64.exe stays alive, and the process scan alone
    // would keep yielding a desktop nobody owns (#214). Once the desktop has
    // been acknowledged, keep the Caelestia background mounted when that
    // window leaves. A later process start has no claim and is fail-closed
    // until the underlay proves it. An embedding failure is never a handback.
    property bool desktopClaimed: false
    readonly property bool yielded: embedRefused
        || (externalActive && !underlayActive && !desktopClaimed)
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
            // external wallpaper is active.
            Native.DesktopLayer.aboveIcons = desktopIcons === "Replace" && !externalActive ? ["caelestia-background"] : [];
            Native.DesktopLayer.enabled = true;
        } else {
            Native.DesktopLayer.enabled = false;
        }
    }
    onBackgroundRequestedChanged: reconcileDesktop()
    onExternalActiveChanged: {
        // A new engine process starts fail-closed unless the backend already
        // acknowledges its wallpaper window as the underlay.
        if (!underlayActive)
            desktopClaimed = false;
        reconcileDesktop();
    }
    onDesktopIconsChanged: reconcileDesktop()
    onUnderlayActiveChanged: {
        if (underlayActive) {
            // The backend proved the engine's wallpaper window is in the
            // host. From here the Caelestia background stays mounted on this
            // desktop when the window leaves while the process keeps running
            // (#214).
            desktopClaimed = true;
        } else if (embedRefused || Native.DesktopLayer.aboveIcons.length > 0) {
            // A refused embed or an above-icons embed is ours, not the engine
            // handing the desktop back, so it must fail closed.
            desktopClaimed = false;
        }
        // The external wallpaper window left the host, so the backend has
        // dropped its acknowledgement. Re-scan now instead of waiting for the
        // idle poll, so a process that really stopped is noticed promptly.
        if (!underlayActive && externalActive)
            WallpaperEngine.refresh(false);
    }
    onEmbedRefusedChanged: {
        // A refusal can arrive while the acknowledgement is already
        // withdrawn (a recreated panel after a handback). Never keep a stale
        // claim through it; only a fresh acknowledgement restores the claim.
        if (embedRefused)
            desktopClaimed = false;
        else if (underlayActive)
            desktopClaimed = true;
    }
    Component.onCompleted: {
        // A QML reload keeps the native host and its acknowledgement; start
        // claimed so a handback after the reload is not mistaken for startup.
        desktopClaimed = underlayActive;
        reconcileDesktop();
    }

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
