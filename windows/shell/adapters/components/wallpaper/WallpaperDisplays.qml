pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Caelestia.Config
import Caelestia.I18n
import qs.components.controls
import qs.services
import qs.modules.nexus.common

ColumnLayout {
    id: root

    property var targetScreen: undefined
    signal targetSelected(var screen)

    spacing: Tokens.spacing.extraSmall / 2

    Variants {
        id: targets
        model: [{name: "", targetId: ""}, ...Quickshell.screens.map(screen =>
            Wallpapers.captureScreen(screen)).filter(screen => screen !== null)]

        MenuItem {
            required property var modelData
            property var screenTarget: modelData.name ? modelData : undefined
            text: modelData.name || Tr.tr("All displays")
            icon: root.targetScreen?.targetId === modelData.targetId
                || (root.targetScreen === undefined && !modelData.name) ? "check" : ""
            activeIcon: "monitor"
        }
    }

    SelectRow {
        objectName: "wallpaperDisplayTarget"
        first: true
        last: Quickshell.screens.length === 0
        label: Tr.tr("Apply next wallpaper to")
        subtext: Tr.tr("All displays replaces individual wallpapers.")
        menuItems: targets.instances
        active: menuItems.find(item => item.screenTarget?.targetId === root.targetScreen?.targetId) ?? null
        fallbackText: root.targetScreen?.name || Tr.tr("All displays")
        fallbackIcon: "monitor"
        onSelected: item => {
            if (item)
                root.targetSelected(item.screenTarget);
        }
    }

    Repeater {
        model: Quickshell.screens

        InfoRow {
            required property var modelData
            required property int index
            objectName: "wallpaperDisplayCurrent"
            last: index === Quickshell.screens.length - 1
            icon: "monitor"
            label: modelData.name
            subtext: Wallpapers.externalWallpaperActive && !WallpaperEngine.desktopHandedBack
                ? Tr.tr("Wallpaper Engine")
                : Tr.tr("Current wallpaper")
            value: {
                if (Wallpapers.externalWallpaperActive && !WallpaperEngine.desktopHandedBack) {
                    const project = WallpaperEngine.displays[Wallpapers.captureScreen(modelData)?.targetId];
                    return project?.title || project?.path?.split(/[\\/]/).slice(-2, -1)[0]
                        || Tr.tr("Selection unavailable");
                }
                return Wallpapers.currentForScreen(modelData).split(/[\\/]/).pop();
            }
        }
    }
}
