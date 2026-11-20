pragma ComponentBehavior: Bound

import "items"
import QtQuick
import QtQuick.Layouts
import Quickshell
import Caelestia.Config
import qs.components.controls
import qs.components.wallpaper
import qs.services
import qs.utils

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
    readonly property int selectedItemWidth: Tokens.sizes.launcher.wallpaperWidth + Tokens.padding.medium * 2
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

        const maxItemsOnScreen = 1 + Math.floor((maxWidth - selectedItemWidth) / itemWidth);
        return Math.max(0, Math.min(maxItemsOnScreen, Config.launcher.maxWallpapers, scriptModel.values.length));
    }

    // The folder path has its own row and cannot drive the picker width; the
    // header's action row is its real minimum. With a short list the carousel
    // can be narrower than the actions, so without this the path collapsed to the
    // width of the buttons and disappeared.
    implicitWidth: Math.max(pathView.implicitWidth, folderBar.minimumWidth)
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
            objectName: "launcherWallpaperCarousel"

            Layout.fillWidth: true
            Layout.preferredHeight: Tokens.sizes.launcher.wallpaperHeight
            readonly property real pathWidth: Math.min(width, root.numItems * root.itemWidth)
            // Odd counts highlight the middle slot. Even counts highlight the
            // slot just left of centre, so all tile centres stay off the ends.
            readonly property real highlightPosition: root.numItems > 0
                ? (Math.floor((root.numItems - 1) / 2) + 0.5) / root.numItems : 0.5

            function selectInitialItem(): void {
                const actual = scriptModel.search ? -1
                    : scriptModel.values.findIndex(w => Paths.samePath(w.path, Wallpapers.actualCurrent));
                currentIndex = scriptModel.values.length ? Math.max(0, actual) : -1;
            }

            model: ScriptModel {
                id: scriptModel

                readonly property string search: root.search.text.split(" ").slice(1).join(" ")

                values: Wallpapers.query(search)
                onValuesChanged: pathView.selectInitialItem()
            }

            Component.onCompleted: selectInitialItem()
            Component.onDestruction: Wallpapers.stopPreview()

            // Windows port: focusing a cloud placeholder must not preview it.
            // The tile already stays blank; this keeps the desktop renderer off
            // that path too, and drops whatever preview was showing before.
            onCurrentItemChanged: {
                const item = currentItem as WallpaperItem;
                if (item && root.screenState.launcher)
                    // Windows scopes the preview to this launcher's display.
                    Wallpapers.previewEntry(item.modelData, root.QsWindow.window?.screen);
                else
                    Wallpapers.stopPreview();
            }

            implicitWidth: root.numItems > 0 ? root.selectedItemWidth + (root.numItems - 1) * root.itemWidth : 0
            pathItemCount: root.numItems
            cacheItemCount: 4

            snapMode: PathView.SnapToItem
            preferredHighlightBegin: highlightPosition
            preferredHighlightEnd: highlightPosition
            highlightRangeMode: PathView.StrictlyEnforceRange

            delegate: WallpaperItem {
                screenState: root.screenState
            }

            path: Path {
                startX: (pathView.width - pathView.pathWidth) / 2
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
                    x: (pathView.width + pathView.pathWidth) / 2
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
