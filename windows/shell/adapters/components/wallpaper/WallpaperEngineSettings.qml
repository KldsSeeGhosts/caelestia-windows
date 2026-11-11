import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import Caelestia.I18n
import qs.services
import qs.modules.nexus.common

// Moved unchanged from Services. The facade still owns every config write and
// playback action; this component has no settings of its own.
ColumnLayout {
    id: root

    spacing: Tokens.spacing.extraSmall / 2

    readonly property string engineStatus: {
        if (!WallpaperEngine.enabled)
            return Tr.tr("Off");
        if (!WallpaperEngine.python)
            return Tr.tr("Unavailable");
        if (!WallpaperEngine.detected)
            return Tr.tr("Not installed");
        if (!WallpaperEngine.running)
            return Tr.tr("Installed, not running");
        return Tr.tr("Running");
    }
    readonly property string engineUnavailableHint: {
        if (WallpaperEngine.desktopControlError)
            return WallpaperEngine.desktopControlError;
        if (WallpaperEngine.desktopControlPending)
            return Tr.tr("Updating Wallpaper Engine desktop playback");
        if (!WallpaperEngine.python)
            return Tr.tr("The settings bridge is unavailable; Wallpaper Engine playback cannot be changed.");
        if (!WallpaperEngine.enabled)
            return Tr.tr("Caelestia shows its own wallpaper. Turning this off stops Wallpaper Engine wallpapers without quitting Wallpaper Engine.");
        if (!WallpaperEngine.detected)
            return Tr.tr("Install Wallpaper Engine to use it; Caelestia keeps its own wallpaper.");
        if (!WallpaperEngine.running)
            return Tr.tr("Start Wallpaper Engine to use it; Caelestia keeps its own wallpaper.");
        if (WallpaperEngine.desktopHandedBack)
            return Tr.tr("Wallpaper Engine handed the desktop back; Caelestia shows its own wallpaper while the process keeps running.");
        return Tr.tr("Wallpaper Engine is running and has not handed the desktop back; its wallpaper covers the desktop until it does.");
    }

    SectionHeader {
        text: Tr.tr("Wallpaper Engine")
    }
    ToggleRow {
        objectName: "wallpaperEngineToggle"
        first: true
        text: Tr.tr("Wallpaper Engine wallpapers")
        subtext: Tr.tr("Needs Wallpaper Engine installed and running. Turning this on resumes its wallpapers on all displays")
        checked: WallpaperEngine.enabled
        onToggled: WallpaperEngine.setEnabled(checked)
    }
    InfoRow {
        last: true
        label: Tr.tr("Status")
        subtext: root.engineUnavailableHint
        value: root.engineStatus
    }
}
