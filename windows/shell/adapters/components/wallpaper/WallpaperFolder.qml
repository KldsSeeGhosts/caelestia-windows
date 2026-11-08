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
// pickers scan, and gives both surfaces the same actions.
//
// Folder creation and copying are delegated to the WallpaperFolderService
// singleton, which runs them in a process instead of the GUI thread, because
// the native file dialog outlives the launcher picker that pressed the button
// and a large or cloud-backed file can stall the shell. The path has its own
// row so the buttons cannot squeeze it to zero width.
ColumnLayout {
    id: root

    readonly property string folderPath: Paths.wallsdir
    // Paths.wallsdir uses forward slashes; show the Windows form the user
    // recognizes, including a UNC path.
    readonly property string folderLabel: folderPath.replace(/\//g, "\\")
    readonly property string folderAccessibleName: Tr.tr("Wallpapers folder: %1").arg(folderLabel)
    // The picker sizes itself from this. The path row takes the remaining
    // width and elides; a long path never forces the launcher off-screen.
    readonly property real minimumWidth: Math.max(actionsRow.implicitWidth, 280)
    readonly property bool busy: WallpaperFolderService.busy
    readonly property bool enginePicker: WallpaperFolderService.enginePickerActive
    readonly property bool localSourceShown: WallpaperFolderService.localSourceShown
    // A folder job owns this component's Explorer launch. The service keeps
    // working if the picker closes, so only a live waiter reacts.
    property bool waitingForFolder: false

    // Opening is injected so offscreen fixtures can record the call instead of
    // launching Explorer.
    property var openFolder: path => Qt.openUrlExternally(Paths.absolutePath(String(path)))

    // A picker opening rescans the folder, so images copied in through Explorer
    // while it was closed appear without a restart.
    Component.onCompleted: WallpaperFolderService.reloadWallpapers();

    function openWallpapersFolder(): bool {
        if (root.waitingForFolder || WallpaperFolderService.busy)
            return false;
        root.waitingForFolder = true;
        if (!WallpaperFolderService.ensureFolder(root.folderPath))
            root.waitingForFolder = false;
        return root.waitingForFolder;
    }

    function chooseFile(): void {
        if (!WallpaperFolderService.busy)
            WallpaperFolderService.chooseAndAdd();
    }

    function refreshWallpapers(): void {
        if (!WallpaperFolderService.busy)
            WallpaperFolderService.refreshLocal();
    }

    function toggleSource(): void {
        if (!WallpaperFolderService.busy)
            WallpaperFolderService.toggleLocalSource();
    }

    // Stops a running copy or folder job. The service also stops one on its
    // own after its deadline, so this is the immediate option.
    function cancelJob(): void {
        WallpaperFolderService.cancelJob("cancel");
    }

    Connections {
        target: WallpaperFolderService

        function onFolderFinished(ok) {
            if (!root.waitingForFolder)
                return;
            root.waitingForFolder = false;
            if (!ok)
                return;
            if (root.openFolder(root.folderPath) !== true)
                WallpaperFolderService.notify(Tr.tr("Could not open the wallpapers folder"));
        }
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
            id: pathLabel

            objectName: "wallpaperFolderPath"
            // The path always gets the width of this row. The actions live on
            // their own row, so this text can no longer be squeezed to 0 px by
            // two wide buttons.
            Layout.fillWidth: true
            // Let a long path shrink into the row's width and elide instead of
            // forcing the picker wider than the carousel.
            Layout.minimumWidth: 0
            Layout.preferredWidth: 0
            text: root.folderLabel
            elide: Text.ElideMiddle
            wrapMode: Text.NoWrap
            font: Tokens.font.body.small
            color: Colours.palette.m3onSurfaceVariant

            Accessible.role: Accessible.StaticText
            Accessible.name: root.folderAccessibleName
        }

        IconButton {
            id: refreshButton

            objectName: "wallpaperRefreshButton"
            icon: "refresh"
            type: IconButton.Text
            enabled: !root.busy
            disabled: root.busy
            activeFocusOnTab: true
            Keys.onPressed: event => {
                if (root.busy)
                    return;
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                    event.accepted = true;
                    if (!event.isAutoRepeat) {
                        stateLayer.press(width / 2, height / 2);
                        root.refreshWallpapers();
                    }
                }
            }
            Accessible.role: Accessible.Button
            Accessible.name: Tr.tr("Refresh wallpapers")
            Accessible.onPressAction: root.refreshWallpapers()
            onClicked: root.refreshWallpapers()

            FocusRing {
                objectName: "refreshFocusRing"
                showing: refreshButton.activeFocus
                radius: refreshButton.radius
            }
        }
    }

    RowLayout {
        id: actionsRow

        Layout.fillWidth: true
        spacing: Tokens.spacing.small

        TextButton {
            id: openButton

            objectName: "wallpaperOpenFolderButton"
            text: Tr.tr("Open wallpapers folder")
            type: TextButton.Tonal
            enabled: !root.busy
            disabled: root.busy

            // Windows port: the button is in the Tab chain and activates with
            // the keyboard, like the bar's StateLayer buttons.
            readonly property bool focusVisible: activeFocus
            activeFocusOnTab: true
            Keys.onPressed: event => {
                if (root.busy)
                    return;
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
            enabled: !root.busy
            disabled: root.busy

            readonly property bool focusVisible: activeFocus
            activeFocusOnTab: true
            Keys.onPressed: event => {
                if (root.busy)
                    return;
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

        // A local-source selection that appears only while the engine picker is
        // active and there is something local to show. Choosing engine again
        // returns to the configured source; neither choice is saved.
        TextButton {
            id: sourceButton

            objectName: "wallpaperSourceButton"
            visible: root.enginePicker && (root.localSourceShown || Wallpapers.files.length > 0)
            text: root.localSourceShown ? Tr.tr("Show Wallpaper Engine") : Tr.tr("Show local wallpapers")
            type: TextButton.Text
            enabled: !root.busy
            disabled: root.busy

            readonly property bool focusVisible: activeFocus
            activeFocusOnTab: true
            Keys.onPressed: event => {
                if (root.busy)
                    return;
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                    event.accepted = true;
                    if (!event.isAutoRepeat) {
                        stateLayer.press(width / 2, height / 2);
                        root.toggleSource();
                    }
                }
            }
            Accessible.role: Accessible.Button
            Accessible.name: sourceButton.text
            Accessible.onPressAction: root.toggleSource()
            onClicked: root.toggleSource()

            FocusRing {
                objectName: "sourceFocusRing"
                showing: sourceButton.activeFocus
                radius: sourceButton.radius
            }
        }

        // The only enabled action while a job runs. A stalled destination would
        // otherwise keep every folder action disabled until its deadline.
        IconButton {
            id: cancelButton

            objectName: "wallpaperCancelButton"
            icon: "close"
            type: IconButton.Text
            visible: root.busy
            activeFocusOnTab: true
            Keys.onPressed: event => {
                if (event.key !== Qt.Key_Return && event.key !== Qt.Key_Enter && event.key !== Qt.Key_Space)
                    return;
                event.accepted = true;
                if (!event.isAutoRepeat) {
                    stateLayer.press(width / 2, height / 2);
                    root.cancelJob();
                }
            }
            Accessible.role: Accessible.Button
            Accessible.name: Tr.tr("Cancel the wallpaper folder job")
            Accessible.onPressAction: root.cancelJob()
            onClicked: root.cancelJob()

            FocusRing {
                objectName: "cancelFocusRing"
                showing: cancelButton.activeFocus
                radius: cancelButton.radius
            }
        }
    }
}
