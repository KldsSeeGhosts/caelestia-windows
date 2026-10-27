pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import Caelestia.I18n
import qs.components
import qs.services
import qs.modules.nexus.common

// Windows adaptation of modules/nexus/pages/wallandstyle/WallpaperCategory.qml.
//
// Upstream types the repeater model as Caelestia.Models' FileSystemEntry, which
// the portable Windows build excludes. The staged Windows Wallpapers facade
// returns plain entries with the same `name`/`path` fields and its own
// getCategoryFor(), so only the type annotation and the source of the list
// change. The grid, placeholder padding and click path are upstream.
PageBase {
    id: root

    readonly property var categoryWalls: Wallpapers.list.filter(w => Wallpapers.getCategoryFor(w) === root.nState.selectedWallpaperCategory).sort((a, b) => a.name.localeCompare(b.name))

    title: {
        const c = nState.selectedWallpaperCategory || "";
        return c.length > 0 ? c.slice(0, 1).toUpperCase() + c.slice(1) : Tr.tr("Wallpapers");
    }
    isSubPage: true

    GridLayout {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        width: root.cappedWidth

        columns: Config.nexus.wallpapersPerRow
        rowSpacing: Tokens.spacing.medium
        columnSpacing: Tokens.spacing.large

        Repeater {
            model: {
                const walls = [...root.categoryWalls];
                while (walls.length < Config.nexus.wallpapersPerRow)
                    walls.push(null);
                return walls;
            }

            WallItem {
                required property var modelData

                // Empty placeholders for sizing
                opacity: modelData ? 1 : 0
                enabled: modelData

                source: String(modelData?.path ?? "")
                text: modelData?.name ?? ""
                onClicked: {
                    Wallpapers.setWallpaper(modelData.path);
                    root.nState.closeSubPage();
                    root.nState.closeSubPage();
                }
            }
        }
    }
}
