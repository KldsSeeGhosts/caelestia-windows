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

    // Wallpaper Engine owns WorkerW. Disable the entire host (including the
    // clock) until layering above WE has been validated. This is only an
    // ownership guard, not proof that WE has presented on either monitor.
    // Discovery starts fail-closed so startup cannot cover a running engine.
    readonly property bool enabled: Quickshell.env("CAELESTIA_WINDOWS_BACKGROUND") === "1"
        && !Wallpapers.externalWallpaperActive
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
        if (enabled) {
            Native.DesktopLayer.aboveIcons = desktopIcons === "Replace" ? ["caelestia-background"] : [];
            Native.DesktopLayer.enabled = true;
        } else {
            Native.DesktopLayer.enabled = false;
        }
    }
    onEnabledChanged: reconcileDesktop()
    Component.onCompleted: reconcileDesktop()

    function checkReady(screen: ShellScreen): bool {
        if (Wallpapers.externalWallpaperActive) {
            // Host readiness here only means we yielded successfully. There
            // is no backend acknowledgement of external output on this screen.
            const yielded = screens.length === 0 && !Native.DesktopLayer.active;
            console.log("CAELESTIA_BACKGROUND_STATE", JSON.stringify({
                active: Native.DesktopLayer.active, ready: yielded,
                owner: WallpaperEngine.running ? "wallpaper-engine-process" : "undiscovered",
                externalOutputReady: null, clock: false
            }));
            return yielded;
        }
        const window = instances.find(w => w.modelData === screen);
        const clock = window ? CUtils.findChild(window.contentItem, "desktopClock") : null;
        const wallpaper = window ? CUtils.findChild(window.contentItem, "desktopWallpaper") : null;
        const clockEnabled = GlobalConfig.forScreen(screen.name).background.desktopClock.enabled;
        const clockReady = clockEnabled ? clock && clock.width > 0 && clock.height > 0 : !clock;
        const ready = Native.DesktopLayer.active && window && window.visible
            && clockReady
            && wallpaper && wallpaper.source.length > 0 && wallpaper.transitionProgress >= 1;
        console.log("CAELESTIA_BACKGROUND_STATE", JSON.stringify({
            active: Native.DesktopLayer.active, icons: desktopIcons,
            screens: screens.map(s => s.name), screen: screen.name, ready: !!ready,
            clockEnabled: clockEnabled, clockPresent: !!clock,
            wallpaper: Wallpapers.current, width: window?.width ?? 0, height: window?.height ?? 0
        }));
        return !!ready;
    }
}
