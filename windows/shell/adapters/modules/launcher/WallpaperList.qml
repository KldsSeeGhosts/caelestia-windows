pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Caelestia.Config
import qs.components
import qs.components.controls
import qs.components.wallpaper
import qs.services
import qs.utils
import "items"

// Keep pointer targets stationary while browsing. Only keyboard navigation
// or scrolling moves the viewport, never a hover.
Item {
    id: root

    required property SearchBar search
    required property var screenState
    required property var panels
    required property var content

    readonly property int itemWidth: Tokens.sizes.launcher.wallpaperWidth * 0.8 + Tokens.padding.medium * 2
    readonly property real headerHeight: folderBar.implicitHeight + keyboardHint.implicitHeight + Tokens.spacing.small * 2
    readonly property alias count: tiles.count
    readonly property var pickerScreen: (QsWindow.window as QsWindow)?.screen
    readonly property bool browsing: visible && enabled && screenState.launcher
    property int hoveredIndex: -1
    readonly property int highlightedIndex: hoveredIndex >= 0 ? hoveredIndex : tiles.currentIndex
    readonly property var highlightedEntry: scriptModel.values[highlightedIndex] ?? null
    property string keyboardPath: ""

    readonly property int numItems: {
        const screen = pickerScreen;
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

        const maxItemsOnScreen = Math.max(1, Math.floor(maxWidth / itemWidth));
        return Math.max(0, Math.min(maxItemsOnScreen, Config.launcher.maxWallpapers, scriptModel.values.length));
    }

    // The folder path has its own row and cannot drive the picker width; the
    // header's action row is its real minimum. With a short list the carousel
    // can be narrower than the actions, so without this the path collapsed to the
    // width of the buttons and disappeared.
    implicitWidth: Math.max(numItems * itemWidth, folderBar.minimumWidth)
    implicitHeight: headerHeight + Tokens.sizes.launcher.wallpaperHeight

    function decrementCurrentIndex(): void {
        step(-1);
    }
    function incrementCurrentIndex(): void {
        step(1);
    }
    function step(delta: int): void {
        if (count < 1)
            return;
        const next = (highlightedIndex + delta + count) % count;
        hoveredIndex = -1;
        selectIndex(next);
    }
    function selectIndex(index: int): void {
        keyboardPath = scriptModel.values[index]?.path ?? "";
        tiles.currentIndex = index;
        if (index >= 0)
            tiles.positionViewAtIndex(index, ListView.Contain);
    }
    function selectInitialItem(): void {
        hoveredIndex = -1;
        const preferred = keyboardPath || (!scriptModel.search ? Wallpapers.actualCurrent : "");
        const index = preferred ? scriptModel.values.findIndex(w => Paths.samePath(w.path, preferred)) : -1;
        selectIndex(scriptModel.values.length ? Math.max(0, index) : -1);
    }
    function pointAt(index: int): void {
        hoveredIndex = index;
    }
    function leave(index: int): void {
        if (hoveredIndex === index)
            hoveredIndex = -1;
    }
    function apply(entry): void {
        if (browsing && entry && Wallpapers.setWallpaper(entry.path, Wallpapers.defaultPickerTarget(pickerScreen)))
            screenState.launcher = false;
    }
    function applyCurrent(): void { apply(highlightedEntry); }
    function updatePreview(): void {
        if (browsing && pickerScreen && highlightedEntry)
            Wallpapers.requestPreview(highlightedEntry, pickerScreen, root);
        else
            Wallpapers.stopPreview(root);
    }
    onHighlightedEntryChanged: updatePreview()
    onBrowsingChanged: updatePreview()
    onPickerScreenChanged: updatePreview()
    Component.onDestruction: Wallpapers.stopPreview(root)

    Timer {
        id: restoreSelection
        interval: 0
        onTriggered: root.selectInitialItem()
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: Tokens.spacing.small

        WallpaperFolder {
            id: folderBar

            objectName: "launcherWallpaperFolder"
            Layout.fillWidth: true
        }

        StyledText {
            id: keyboardHint
            Layout.fillWidth: true
            text: Wallpapers.externalWallpaperActive
                ? "Wallpaper Engine controls the desktop. Click or press Enter to apply."
                : "Hover or use arrow keys. Click or press Enter to apply."
            color: Colours.palette.m3onSurfaceVariant
            font: Tokens.font.label.medium
            elide: Text.ElideRight
        }

        ListView {
            id: tiles
            objectName: "launcherWallpaperCarousel"

            Layout.preferredWidth: root.numItems * root.itemWidth
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredHeight: Tokens.sizes.launcher.wallpaperHeight
            orientation: ListView.Horizontal
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            snapMode: ListView.SnapToItem
            keyNavigationEnabled: false
            reuseItems: true
            cacheBuffer: 0

            model: ScriptModel {
                id: scriptModel

                readonly property string search: root.search.text.split(" ").slice(1).join(" ")
                values: Wallpapers.query(search)
                onValuesChanged: restoreSelection.restart()
            }
            Component.onCompleted: restoreSelection.restart()

            delegate: WallpaperItem {
                id: tile
                required property int index
                width: root.itemWidth
                height: tiles.height
                highlighted: root.highlightedIndex === index
                onPointed: root.pointAt(index)
                onUnpointed: root.leave(index)
                onClicked: root.apply(tile.modelData)
                ListView.onPooled: root.leave(index)
            }

            WheelHandler {
                target: null
                property int accumulated: 0
                onWheel: event => {
                    const delta = event.angleDelta.y;
                    if (delta === 0)
                        return;
                    if (Math.sign(delta) !== Math.sign(accumulated))
                        accumulated = 0;
                    accumulated += delta;
                    if (Math.abs(accumulated) >= 120) {
                        root.step(accumulated > 0 ? -1 : 1);
                        accumulated = 0;
                    }
                }
            }
        }
    }
}
