pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import Caelestia.I18n
import qs.components
import qs.components.controls
import qs.services
import qs.utils

// Windows adaptation: names the folder the launcher and Nexus wallpaper
// pickers scan, and gives both surfaces the same two actions.
//
// Opening the folder is synchronous. Adding an image is delegated to the
// WallpaperFolderService singleton, because the native file dialog outlives
// the launcher picker that pressed the button.
ColumnLayout {
    id: root

    readonly property string folderPath: Paths.wallsdir
    // Paths.wallsdir uses forward slashes; show the Windows form the user
    // recognizes, including a UNC path.
    readonly property string folderLabel: folderPath.replace(/\//g, "\\")
    readonly property string folderAccessibleName: Tr.tr("Wallpapers folder: %1").arg(folderLabel)

    // Opening is injected so offscreen fixtures can record the call instead of
    // launching Explorer.
    property var openFolder: path => Qt.openUrlExternally(Paths.absolutePath(String(path)))

    function openWallpapersFolder(): bool {
        if (!WallpaperFolderService.makeFolder(root.folderPath)) {
            WallpaperFolderService.notify(Tr.tr("Could not create the wallpapers folder"));
            return false;
        }
        if (root.openFolder(root.folderPath) !== true) {
            WallpaperFolderService.notify(Tr.tr("Could not open the wallpapers folder"));
            return false;
        }
        return true;
    }

    function chooseFile(): void {
        WallpaperFolderService.chooseAndAdd();
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: Tokens.spacing.small

        MaterialIcon {
            Layout.alignment: Qt.AlignVCenter
            text: "folder"
            color: Colours.palette.m3onSurfaceVariant
            fontStyle: Tokens.font.icon.small
        }

        StyledText {
            objectName: "wallpaperFolderPath"
            Layout.fillWidth: true
            // A long path must not force the two actions off the header; the
            // label takes the remaining width and elides instead.
            Layout.preferredWidth: 0
            text: root.folderLabel
            elide: Text.ElideMiddle
            font: Tokens.font.body.small
            color: Colours.palette.m3onSurfaceVariant

            Accessible.role: Accessible.StaticText
            Accessible.name: root.folderAccessibleName
        }

        TextButton {
            id: openButton

            objectName: "wallpaperOpenFolderButton"
            text: Tr.tr("Open wallpapers folder")
            type: TextButton.Tonal

            // Windows port: the button is in the Tab chain and activates with
            // the keyboard, like the bar's StateLayer buttons.
            readonly property bool focusVisible: activeFocus
            activeFocusOnTab: true
            Keys.onPressed: event => {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                    event.accepted = true;
                    if (!event.isAutoRepeat) {
                        stateLayer.press(width / 2, height / 2);
                        root.openWallpapersFolder();
                    }
                }
            }
            Accessible.role: Accessible.Button
            Accessible.name: Tr.tr("Open wallpapers folder")
            Accessible.onPressAction: root.openWallpapersFolder()
            onClicked: root.openWallpapersFolder()

            FocusRing {
                objectName: "openFolderFocusRing"
                showing: openButton.focusVisible
                radius: openButton.radius
            }
        }

        TextButton {
            id: addButton

            objectName: "wallpaperAddButton"
            text: Tr.tr("Add wallpaper…")

            readonly property bool focusVisible: activeFocus
            activeFocusOnTab: true
            Keys.onPressed: event => {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                    event.accepted = true;
                    if (!event.isAutoRepeat) {
                        stateLayer.press(width / 2, height / 2);
                        root.chooseFile();
                    }
                }
            }
            Accessible.role: Accessible.Button
            Accessible.name: Tr.tr("Add wallpaper…")
            Accessible.onPressAction: root.chooseFile()
            onClicked: root.chooseFile()

            FocusRing {
                objectName: "addWallpaperFocusRing"
                showing: addButton.focusVisible
                radius: addButton.radius
            }
        }
    }
}
