pragma ComponentBehavior: Bound

import "items"
import QtQuick
import QtQuick.Layouts
import Quickshell
import Caelestia.Config
import qs.components.controls
import qs.components.wallpaper
import qs.services

// Windows adaptation of modules/launcher/WallpaperList.qml.
//
// The upstream view is the PathView itself. The Windows picker also has to
// name the scanned folder and offer Open wallpapers folder / Add wallpaper…,
// so the view moves inside a column with a header. ContentList still reads the
// picker through `count`, `currentItem` and the current-index functions, so
// those are forwarded to the PathView.
Item {
    id: root

    required property SearchBar search
    required property var screenState
    required property var panels
    required property var content

    readonly property int itemWidth: Tokens.sizes.launcher.wallpaperWidth * 0.8 + Tokens.padding.medium * 2
    // The gap between the folder bar and the carousel belongs to the header, so
    // ContentList can reserve the whole block without squeezing the tiles.
    readonly property real headerHeight: folderBar.implicitHeight + Tokens.spacing.small
    readonly property alias count: pathView.count
    readonly property alias currentItem: pathView.currentItem

    readonly property int numItems: {
        const screen = (QsWindow.window as QsWindow)?.screen;
        if (!screen)
            return 0;

        // Screen width - 4x outer rounding - 2x max side thickness (cause centered)
        const barMargins = Math.max(Config.border.thickness, panels.bar.implicitWidth);
        let outerMargins = 0;
        if (panels.popouts.hasCurrent && panels.popouts.currentCenter + panels.popouts.nonAnimHeight / 2 > screen.height - content.implicitHeight - Config.border.thickness * 2)
            outerMargins = panels.popouts.nonAnimWidth;
        if ((screenState.utilities || screenState.sidebar) && panels.utilities.implicitWidth > outerMargins)
            outerMargins = panels.utilities.implicitWidth;
        const maxWidth = screen.width - Config.border.rounding * 4 - (barMargins + outerMargins) * 2;

        if (maxWidth <= 0)
            return 0;

        const maxItemsOnScreen = Math.floor(maxWidth / itemWidth);
        const visible = Math.min(maxItemsOnScreen, Config.launcher.maxWallpapers, scriptModel.values.length);

        if (visible === 2)
            return 1;
        if (visible > 1 && visible % 2 === 0)
            return visible - 1;
        return visible;
    }

    implicitWidth: Math.max(pathView.implicitWidth, folderBar.implicitWidth)
    implicitHeight: headerHeight + Tokens.sizes.launcher.wallpaperHeight

    function decrementCurrentIndex(): void {
        pathView.decrementCurrentIndex();
    }
    function incrementCurrentIndex(): void {
        pathView.incrementCurrentIndex();
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: Tokens.spacing.small

        WallpaperFolder {
            id: folderBar

            objectName: "launcherWallpaperFolder"
            Layout.fillWidth: true
        }

        PathView {
            id: pathView

            Layout.fillWidth: true
            Layout.preferredHeight: Tokens.sizes.launcher.wallpaperHeight

            model: ScriptModel {
                id: scriptModel

                readonly property string search: root.search.text.split(" ").slice(1).join(" ")

                values: Wallpapers.query(search)
                onValuesChanged: pathView.currentIndex = search ? 0 : values.findIndex(w => w.path === Wallpapers.actualCurrent)
            }

            Component.onCompleted: currentIndex = Wallpapers.list.findIndex(w => w.path === Wallpapers.actualCurrent)
            Component.onDestruction: Wallpapers.stopPreview()

            // Windows port: focusing a cloud placeholder must not preview it.
            // The tile already stays blank; this keeps the desktop renderer off
            // that path too, and drops whatever preview was showing before.
            onCurrentItemChanged: {
                const item = currentItem as WallpaperItem;
                if (item)
                    // Windows scopes the preview to this launcher's display.
                    Wallpapers.previewEntry(item.modelData, root.QsWindow.window?.screen);
            }

            implicitWidth: Math.min(numItems, count) * itemWidth
            pathItemCount: numItems
            cacheItemCount: 4

            snapMode: PathView.SnapToItem
            preferredHighlightBegin: 0.5
            preferredHighlightEnd: 0.5
            highlightRangeMode: PathView.StrictlyEnforceRange

            delegate: WallpaperItem {
                screenState: root.screenState
            }

            path: Path {
                startY: pathView.height / 2

                PathAttribute {
                    name: "z"
                    value: 0
                }
                PathLine {
                    x: pathView.width / 2
                    relativeY: 0
                }
                PathAttribute {
                    name: "z"
                    value: 1
                }
                PathLine {
                    x: pathView.width
                    relativeY: 0
                }
            }

            CustomMouseArea {
                function onWheel(event: WheelEvent): void {
                    if (event.angleDelta.y > 0)
                        pathView.decrementCurrentIndex();
                    else if (event.angleDelta.y < 0)
                        pathView.incrementCurrentIndex();
                }

                anchors.fill: parent
            }
        }
    }
}
