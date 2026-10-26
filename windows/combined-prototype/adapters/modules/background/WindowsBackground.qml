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

    readonly property bool enabled: Quickshell.env("CAELESTIA_WINDOWS_BACKGROUND") === "1"
    readonly property bool smoke: Quickshell.env("CAELESTIA_SHELL_SMOKE") === "1"
    readonly property int screenIndex: Number(Quickshell.env("CAELESTIA_SHELL_SCREEN") || "0")
    readonly property string desktopIcons: Quickshell.env("CAELESTIA_WINDOWS_DESKTOP_ICONS") || "Behind"

    // Fail closed when Explorer has no desktop host. Never fall back to an
    // ordinary full-screen window over the user's applications.
    screens: enabled && Native.DesktopLayer.active
        ? Screens.screens.filter(s => !smoke
            || Quickshell.env("CAELESTIA_SHELL_LIVE") === "1"
            || s === Quickshell.screens[screenIndex])
        : []

    Component.onCompleted: {
        // DesktopLayer is process-wide. On hard reload the new generation
        // starts before the old wrapper is destroyed, so the new owner sets
        // the mode and the old owner must not disable it during destruction.
        if (enabled) {
            Native.DesktopLayer.aboveIcons = desktopIcons === "Replace" ? ["caelestia-background"] : [];
        }
        Native.DesktopLayer.enabled = enabled;
    }

    function checkReady(screen: ShellScreen): bool {
        const window = instances.find(w => w.modelData === screen);
        const clock = window ? CUtils.findChild(window.contentItem, "desktopClock") : null;
        const wallpaper = window ? CUtils.findChild(window.contentItem, "desktopWallpaper") : null;
        const ready = Native.DesktopLayer.active && window && window.visible
            && clock && clock.width > 0 && clock.height > 0
            && wallpaper && wallpaper.source.length > 0 && wallpaper.transitionProgress >= 1;
        console.log("CAELESTIA_BACKGROUND_STATE", JSON.stringify({
            active: Native.DesktopLayer.active, icons: desktopIcons,
            screens: screens.map(s => s.name), screen: screen.name, ready: !!ready,
            wallpaper: Wallpapers.current, width: window?.width ?? 0, height: window?.height ?? 0
        }));
        return !!ready;
    }
}
