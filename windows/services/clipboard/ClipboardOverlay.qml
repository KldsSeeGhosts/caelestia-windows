// Caelestia's Material 3 clipboard history picker, backed by Windows' native
// clipboard history. The presentation and motion are adapted from the user's
// Linux overlay, which derives from Omarchy (MIT); see upstream/SOURCE.md.
//
// Windows adaptation:
// - Items come from ClipboardHistory (Caelestia.Windows.WindowsClipboard),
//   not from a local capture file. Password-manager exclusions, pinned items,
//   size limits and sync remain Windows' decisions.
// - Paste, copy and open dispatch to the native type instead of shell scripts.
// - The card is a per-screen PanelWindow overlay. Only the selected screen's
//   window exists while open.
// - A WindowsFocusGuard returns focus to the previous application on close.

pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Windows as Native
import Caelestia
import Caelestia.Config
import Caelestia.Windows
import qs.components
import qs.components.containers
import qs.components.controls
import qs.components.misc
import qs.services
import "ClipboardHistory.js" as ClipboardRows

Scope {
    id: root

    // The production host disables interaction during smoke, when no Windows
    // clipboard history may be read.
    property bool interactionEnabled: true
    property bool opened
    property bool clearConfirmOpen
    property var targetScreen: null
    property int selectedIndex: -1
    // One preview request per item per open session; a failed request is not
    // retried on every search keystroke.
    property var requestedPreviews: ({})
    property real openAnimProg: opened ? 1 : 0
    // Set on first open and kept, so the picker tree is only built once.
    property bool pickerBuilt: false
    readonly property Item searchBar: pickerLoader.item ? pickerLoader.item.searchBar : null
    readonly property ListView resultList: pickerLoader.item ? pickerLoader.item.resultList : null

    readonly property int historyLimit: 60
    readonly property bool historyOff: ClipboardHistory.status === "disabled"
    readonly property bool accessDenied: ClipboardHistory.status === "denied"
    readonly property bool failed: ClipboardHistory.status === "error"

    Behavior on openAnimProg {
        // Opacity must not use an overshooting spatial/spring curve. The
        // window does not animate its own surface.
        NumberAnimation {
            duration: root.opened ? 160 : 100
            easing.type: root.opened ? Easing.OutCubic : Easing.InCubic
        }
    }

    function chooseActiveScreen(): void {
        for (const candidate of Quickshell.screens) {
            if (Hypr.monitorFor(candidate) === Hypr.focusedMonitor) {
                targetScreen = candidate;
                return;
            }
        }
        if (Quickshell.screens.length > 0)
            targetScreen = Quickshell.screens[0];
    }

    function open(): void {
        if (!root.interactionEnabled || !ClipboardHistory.enabled)
            return;
        chooseActiveScreen();
        clearConfirmOpen = false;
        pickerBuilt = true;
        if (searchBar)
            searchBar.text = "";
        requestedPreviews = ({});
        // Capture the paste destination before this panel becomes visible and
        // takes focus. setActive(true) also cancels any previous paste.
        ClipboardHistory.setActive(true);
        opened = true;
    }

    function close(): void {
        clearConfirmOpen = false;
        opened = false;
    }

    function toggle(): void {
        if (opened)
            close();
        else
            open();
    }

    function rebuildDisplay(): void {
        const previousIndex = selectedIndex;
        // A refresh can insert or remove entries above the selection. Keeping
        // the row index would move the selection to a different entry (and
        // Delete would remove the wrong one), so the selected item id is the
        // anchor; index is only the fallback when that entry is gone.
        const previousId = previousIndex >= 0 && previousIndex < displayModel.count
            ? String(displayModel.get(previousIndex).itemId ?? "")
            : "";
        const rows = ClipboardRows.displayRows(ClipboardHistory.items, searchBar?.text ?? "", root.historyLimit);

        // Update roles in place: clearing destroys visible delegates, their
        // textures, and the preview on every search keystroke.
        for (let i = 0; i < rows.length; i++) {
            const row = rows[i];
            const values = {
                itemId: row.itemId,
                entryType: row.entryType,
                title: row.title,
                subtitle: row.subtitle,
                fullText: row.fullText,
                previewText: row.previewText,
                previewImage: row.previewImage,
                path: row.path,
                formats: row.formats,
                timestamp: row.timestamp,
                timestampLabel: row.timestampLabel,
                charCount: row.charCount,
                lineCount: row.lineCount,
                isCode: row.isCode,
                isUrl: row.isUrl,
                isColor: row.isColor,
                colorValue: row.colorValue,
                historyIndex: row.index
            };
            if (i < displayModel.count)
                displayModel.set(i, values);
            else
                displayModel.append(values);
        }
        if (displayModel.count > rows.length)
            displayModel.remove(rows.length, displayModel.count - rows.length);

        if (displayModel.count === 0)
            selectedIndex = -1;
        else
            selectedIndex = ClipboardRows.selectionIndex(previousId, previousIndex, rows);
        if (resultList)
            resultList.currentIndex = selectedIndex;

        // Thumbnails are fetched only while the picker is open and only for
        // items that are actually in the current list. The native type caches
        // them under the instance's own Quickshell cache directory.
        for (let i = 0; i < displayModel.count; i++) {
            const row = displayModel.get(i);
            if (row.entryType !== "image" || row.previewImage.length > 0
                    || root.requestedPreviews[row.itemId])
                continue;
            root.requestedPreviews[row.itemId] = true;
            ClipboardHistory.preview(row.itemId);
        }

        if (selectedIndex >= 0)
            Qt.callLater(() => resultList?.positionViewAtIndex(selectedIndex, ListView.Contain));
    }

    function moveSelection(delta: int): void {
        if (displayModel.count === 0)
            return;
        if (selectedIndex < 0)
            selectedIndex = delta < 0 ? displayModel.count - 1 : 0;
        else
            selectedIndex = (selectedIndex + delta + displayModel.count) % displayModel.count;
        if (resultList) {
            resultList.currentIndex = selectedIndex;
            resultList.positionViewAtIndex(selectedIndex, ListView.Contain);
        }
    }

    function activate(index: int, action: string): void {
        if (index < 0 || index >= displayModel.count)
            return;
        const itemId = displayModel.get(index).itemId;
        if (!itemId)
            return;
        close();
        if (action === "paste")
            ClipboardHistory.paste(itemId);
        else if (action === "copy")
            ClipboardHistory.copy(itemId);
        else
            ClipboardHistory.openItem(itemId);
    }

    function removeSelected(): void {
        if (selectedIndex < 0 || selectedIndex >= displayModel.count)
            return;
        const itemId = displayModel.get(selectedIndex).itemId;
        if (!itemId)
            return;
        // Windows deletes the history entry; the next snapshot removes the row.
        ClipboardHistory.remove(itemId);
    }

    function clearHistory(): void {
        clearConfirmOpen = false;
        selectedIndex = -1;
        // Windows owns what ClearHistory removes, including pinned items.
        ClipboardHistory.clear();
        Qt.callLater(() => searchBar?.forceActiveFocus());
    }

    function emptyMessage(): string {
        if (!ClipboardHistory.enabled)
            return qsTr("Clipboard history is disabled in shell.json");
        if (root.historyOff)
            return qsTr("Clipboard history is off in Windows");
        if (root.accessDenied)
            return qsTr("Windows denied access to clipboard history");
        if (root.failed)
            return qsTr("Clipboard history is unavailable");
        if (ClipboardHistory.items.length === 0)
            return qsTr("Clipboard is empty");
        return qsTr("No matching entries");
    }

    onOpenedChanged: {
        // Opening already called setActive(true) before the panel showed, so
        // the destination is captured before this window takes focus.
        if (!opened) {
            ClipboardHistory.setActive(false);
            return;
        }
        ClipboardHistory.refresh();
        Qt.callLater(root.rebuildDisplay);
        focusTimer.restart();
    }

    Connections {
        function onItemsChanged(): void {
            if (root.opened)
                Qt.callLater(root.rebuildDisplay);
        }

        function onPasteReady(id): void {
            root.close();
        }

        // The item is already on the clipboard, but focus, destination or a
        // held modifier prevented the synthetic Ctrl+V. Say so instead of
        // cancelling invisibly.
        function onPasteDeferred(message): void {
            Toaster.toast(qsTr("Clipboard"), message, "content_paste", Toast.Info);
        }

        // Copy, paste, delete and clear failures can arrive after the picker
        // closed (the overlay closes before dispatching the action), so the
        // native error is surfaced on the shell's own toast surface.
        function onOperationFailed(operation, message): void {
            // The native message is fixed operation copy plus a numeric
            // HRESULT. Never add provider text here; the toast speaks to the
            // user, the log only records which operation failed.
            console.warn("Clipboard operation failed:", operation);
            Toaster.toast(qsTr("Clipboard"), message, "content_paste", Toast.Error);
        }

        // Live-disabling windows.clipboard unloads the native service; the
        // open picker must not stay on screen with no backend.
        function onEnabledChanged(): void {
            if (!ClipboardHistory.enabled)
                root.close();
        }

        target: ClipboardHistory
    }

    Timer {
        id: focusTimer

        interval: 80
        onTriggered: {
            if (root.opened)
                root.searchBar?.forceActiveFocus();
        }
    }

    ListModel {
        id: displayModel
    }

    // Exposed for the native smoke, which drives rebuildDisplay() with
    // synthetic entries instead of opening the picker over real history.
    readonly property alias display: displayModel

    // One full-screen panel that follows the screen chosen when the picker
    // opens. Keeping it in this scope (rather than a Variants delegate) leaves
    // the search field and list ids addressable by open(), close() and the
    // display rebuild. It is hidden, and therefore has no native window, while
    // the picker is closed.
    StyledWindow {
        id: window

        readonly property ShellScreen screenTarget: root.targetScreen
            ?? Quickshell.screens[0] ?? null

        screen: window.screenTarget
        name: "clipboard"
        visible: window.screenTarget !== null && (root.opened || root.openAnimProg > 0.001)
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

        anchors.top: true
        anchors.bottom: true
        anchors.left: true
        anchors.right: true

        // Returns focus to the previously focused application after close.
        // The native paste also re-checks focus before injecting Ctrl+V.
        WindowsFocusGuard {
            target: window.contentItem
            foregroundSource: Native.Foreground
            active: root.opened
            onDismissRequested: root.close()
        }

        // The picker tree is built on first open, not at shell startup.
        Loader {
            id: pickerLoader

            anchors.fill: parent
            active: root.pickerBuilt

            sourceComponent: Item {
                readonly property Item searchBar: search
                readonly property ListView resultList: results

                Rectangle {
                    anchors.fill: parent
                    color: Qt.alpha(Colours.palette.m3scrim, 0.28)
                    opacity: root.openAnimProg

                    MouseArea {
                        anchors.fill: parent
                        onClicked: root.close()
                    }
                }

                StyledRect {
                    id: card

                    anchors.centerIn: parent
                    implicitWidth: Math.min(940, window.width - Tokens.padding.large * 4)
                    implicitHeight: Math.min(620, window.height - Tokens.padding.large * 4)
                    color: Colours.palette.m3surface
                    radius: Tokens.rounding.extraLarge
                    border.color: Qt.alpha(Colours.palette.m3outlineVariant, 0.35)
                    border.width: 1

                    opacity: root.openAnimProg
                    transform: Translate {
                        y: (1 - root.openAnimProg) * 8
                    }

                    // Only the static silhouette needs an offscreen shadow texture,
                    // not the whole changing list and text preview on every frame.
                    Rectangle {
                        anchors.fill: parent
                        radius: card.radius
                        color: card.color
                        z: -1
                        layer.enabled: true
                        layer.effect: MultiEffect {
                            shadowEnabled: true
                            blurMax: 24
                            shadowColor: Qt.alpha(Colours.palette.m3shadow, 0.35)
                            shadowVerticalOffset: 6
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        onClicked: {}
                    }

                    Column {
                        anchors.fill: parent
                        anchors.margins: Tokens.padding.large
                        spacing: Tokens.spacing.medium

                        // Search and top actions
                        Row {
                            width: parent.width
                            spacing: Tokens.spacing.medium

                            SearchBar {
                                id: search

                                width: parent.width - clearButton.width - parent.spacing
                                placeholderText: qsTr("Search clipboard history…")
                                readOnly: root.clearConfirmOpen
                                onTextChanged: {
                                    if (root.opened)
                                        Qt.callLater(root.rebuildDisplay);
                                }

                                Keys.onUpPressed: if (!root.clearConfirmOpen) root.moveSelection(-1)
                                Keys.onDownPressed: if (!root.clearConfirmOpen) root.moveSelection(1)
                                Keys.onEscapePressed: {
                                    if (root.clearConfirmOpen)
                                        root.clearConfirmOpen = false;
                                    else if (text)
                                        clear();
                                    else
                                        root.close();
                                }
                                Keys.onPressed: event => {
                                    if (root.clearConfirmOpen) {
                                        if (event.key === Qt.Key_Escape || event.key === Qt.Key_N) {
                                            root.clearConfirmOpen = false;
                                            event.accepted = true;
                                        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Y) {
                                            root.clearHistory();
                                            event.accepted = true;
                                        }
                                        return;
                                    }

                                    if (event.key === Qt.Key_Delete) {
                                        if (event.modifiers & Qt.ShiftModifier)
                                            root.clearConfirmOpen = ClipboardHistory.items.length > 0;
                                        else
                                            root.removeSelected();
                                        event.accepted = true;
                                    } else if (event.key === Qt.Key_PageUp) {
                                        root.moveSelection(-6);
                                        event.accepted = true;
                                    } else if (event.key === Qt.Key_PageDown) {
                                        root.moveSelection(6);
                                        event.accepted = true;
                                    } else if (event.key === Qt.Key_Home) {
                                        root.selectedIndex = displayModel.count > 0 ? 0 : -1;
                                        results.currentIndex = root.selectedIndex;
                                        event.accepted = true;
                                    } else if (event.key === Qt.Key_End) {
                                        root.selectedIndex = displayModel.count - 1;
                                        results.currentIndex = root.selectedIndex;
                                        event.accepted = true;
                                    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                                        if (event.modifiers & Qt.AltModifier)
                                            root.activate(root.selectedIndex, "open");
                                        else if (event.modifiers & Qt.ShiftModifier)
                                            root.activate(root.selectedIndex, "copy");
                                        else
                                            root.activate(root.selectedIndex, "paste");
                                        event.accepted = true;
                                    }
                                }
                            }

                            IconButton {
                                id: clearButton

                                icon: "delete_sweep"
                                type: IconButton.Text
                                enabled: ClipboardHistory.items.length > 0
                                stateLayer.hoverEnabled: enabled
                                onClicked: {
                                    root.clearConfirmOpen = true;
                                    root.searchBar?.forceActiveFocus();
                                }
                            }
                        }

                        // Middle split: history list and preview box
                        Row {
                            id: mainRow

                            width: parent.width
                            height: parent.height - search.height - footerBar.height - parent.spacing * 2
                            spacing: Tokens.spacing.medium

                            Item {
                                width: Math.round((parent.width - parent.spacing) * 0.44)
                                height: parent.height

                                StyledListView {
                                    id: results

                                    anchors.fill: parent
                                    model: displayModel
                                    spacing: Tokens.spacing.extraSmall
                                    clip: true
                                    boundsBehavior: Flickable.StopAtBounds
                                    reuseItems: true

                                    StyledScrollBar.vertical: StyledScrollBar {
                                        flickable: results
                                    }

                                    delegate: StyledRect {
                                        id: row

                                        required property int index
                                        required property string itemId
                                        required property string entryType
                                        required property string title
                                        required property string subtitle
                                        required property string previewText
                                        required property string previewImage
                                        required property bool isCode
                                        required property bool isUrl
                                        required property bool isColor
                                        required property string colorValue
                                        required property int lineCount
                                        required property int charCount

                                        readonly property bool isSelected: index === root.selectedIndex

                                        width: ListView.view.width - (results.contentHeight > results.height ? Tokens.padding.small : 0)
                                        implicitHeight: Math.max(54, itemRow.implicitHeight + Tokens.padding.small * 2)
                                        radius: Tokens.rounding.large
                                        color: isSelected ? Colours.palette.m3primaryContainer : (itemMouse.containsMouse ? Colours.palette.m3surfaceContainerHigh : "transparent")

                                        Behavior on color {
                                            CAnim {
                                                duration: Tokens.anim.durations.small
                                            }
                                        }

                                        Row {
                                            id: itemRow

                                            anchors.left: parent.left
                                            anchors.right: parent.right
                                            anchors.verticalCenter: parent.verticalCenter
                                            anchors.margins: Tokens.padding.small
                                            anchors.leftMargin: Tokens.padding.medium
                                            anchors.rightMargin: Tokens.padding.medium
                                            spacing: Tokens.spacing.medium

                                            // Thumbnail or icon badge
                                            Item {
                                                width: 36
                                                height: 36
                                                anchors.verticalCenter: parent.verticalCenter

                                                StyledRect {
                                                    anchors.fill: parent
                                                    radius: Tokens.rounding.medium
                                                    clip: true
                                                    color: Colours.palette.m3surfaceContainerHigh

                                                    Image {
                                                        anchors.fill: parent
                                                        visible: row.previewImage.length > 0
                                                        source: row.previewImage
                                                        fillMode: Image.PreserveAspectCrop
                                                        sourceSize: Qt.size(72, 72)
                                                        asynchronous: true
                                                        smooth: true
                                                    }

                                                    StyledRect {
                                                        anchors.fill: parent
                                                        visible: row.isColor
                                                        radius: Tokens.rounding.medium
                                                        color: row.colorValue || "transparent"
                                                        border.width: 1
                                                        border.color: Qt.alpha(Colours.palette.m3outline, 0.4)
                                                    }

                                                    MaterialIcon {
                                                        anchors.centerIn: parent
                                                        visible: row.previewImage.length === 0 && !row.isColor
                                                        text: {
                                                            if (row.entryType === "image") return "image";
                                                            if (row.entryType === "other") return "content_paste_go";
                                                            if (row.entryType === "file") return "draft";
                                                            if (row.isUrl) return "link";
                                                            if (row.isCode) return "code";
                                                            return "content_paste";
                                                        }
                                                        color: row.isSelected ? Colours.palette.m3onPrimaryContainer : Colours.palette.m3onSurfaceVariant
                                                        fontStyle: Tokens.font.icon.small
                                                    }
                                                }
                                            }

                                            // Titles
                                            Column {
                                                width: parent.width - 36 - parent.spacing
                                                anchors.verticalCenter: parent.verticalCenter
                                                spacing: 2

                                                StyledText {
                                                    width: parent.width
                                                    text: row.title || row.previewText || qsTr("Untitled")
                                                    textFormat: Text.PlainText
                                                    color: row.isSelected ? Colours.palette.m3onPrimaryContainer : Colours.palette.m3onSurface
                                                    font: Tokens.font.body.medium
                                                    elide: Text.ElideRight
                                                    maximumLineCount: 1
                                                }

                                                StyledText {
                                                    width: parent.width
                                                    text: {
                                                        if (row.subtitle) return row.subtitle;
                                                        if (row.lineCount > 1) return qsTr("%1 lines • %2 chars").arg(row.lineCount).arg(row.charCount);
                                                        if (row.charCount > 0) return qsTr("%1 chars").arg(row.charCount);
                                                        return row.previewText;
                                                    }
                                                    textFormat: Text.PlainText
                                                    color: row.isSelected ? Qt.alpha(Colours.palette.m3onPrimaryContainer, 0.75) : Colours.palette.m3onSurfaceVariant
                                                    font: Tokens.font.body.small
                                                    elide: Text.ElideRight
                                                    maximumLineCount: 1
                                                }
                                            }
                                        }

                                        MouseArea {
                                            id: itemMouse

                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onEntered: {
                                                root.selectedIndex = row.index;
                                                results.currentIndex = row.index;
                                            }
                                            onClicked: root.activate(row.index, "paste")
                                        }
                                    }
                                }

                                Column {
                                    anchors.centerIn: parent
                                    width: parent.width - Tokens.padding.large * 2
                                    visible: displayModel.count === 0
                                    spacing: Tokens.spacing.medium

                                    StyledText {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        width: parent.width
                                        horizontalAlignment: Text.AlignHCenter
                                        text: root.emptyMessage()
                                        color: Colours.palette.m3onSurfaceVariant
                                        font: Tokens.font.body.medium
                                        wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                                    }

                                    TextButton {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        visible: root.historyOff
                                        text: qsTr("Open Windows clipboard settings")
                                        onClicked: ClipboardHistory.openSettings()
                                    }

                                    StyledText {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        width: parent.width
                                        visible: root.historyOff
                                        horizontalAlignment: Text.AlignHCenter
                                        text: qsTr("Caelestia does not turn clipboard history on for you.")
                                        color: Qt.alpha(Colours.palette.m3onSurfaceVariant, 0.75)
                                        font: Tokens.font.body.small
                                        wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                                    }
                                }
                            }

                            // Divider
                            Rectangle {
                                width: 1
                                height: parent.height
                                color: Qt.alpha(Colours.palette.m3outlineVariant, 0.35)
                            }

                            // Preview container
                            StyledRect {
                                id: previewBox

                                width: parent.width - Math.round((parent.width - parent.spacing) * 0.44) - parent.spacing * 2 - 1
                                height: parent.height
                                color: Colours.tPalette.m3surfaceContainerLow
                                radius: Tokens.rounding.large
                                border.color: Qt.alpha(Colours.palette.m3outlineVariant, 0.35)
                                border.width: 1
                                clip: true

                                readonly property var activeRow: root.selectedIndex >= 0 && root.selectedIndex < displayModel.count ? displayModel.get(root.selectedIndex) : null
                                readonly property string previewText: activeRow?.fullText ?? ""
                                onPreviewTextChanged: textFlickable.contentY = 0

                                // Preview header
                                StyledRect {
                                    id: previewHeader

                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.top: parent.top
                                    height: 44
                                    color: Colours.tPalette.m3surfaceContainer
                                    radius: Tokens.rounding.large
                                    bottomLeftRadius: 0
                                    bottomRightRadius: 0

                                    Row {
                                        anchors.left: parent.left
                                        anchors.verticalCenter: parent.verticalCenter
                                        anchors.leftMargin: Tokens.padding.medium
                                        spacing: Tokens.spacing.small

                                        MaterialIcon {
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: {
                                                if (!previewBox.activeRow) return "content_paste";
                                                if (previewBox.activeRow.previewImage) return "image";
                                                if (previewBox.activeRow.isColor) return "palette";
                                                if (previewBox.activeRow.entryType === "other") return "content_paste_go";
                                                if (previewBox.activeRow.entryType === "file") return "draft";
                                                if (previewBox.activeRow.isUrl) return "link";
                                                if (previewBox.activeRow.isCode) return "code";
                                                return "text_snippet";
                                            }
                                            color: Colours.palette.m3primary
                                            fontStyle: Tokens.font.icon.small
                                        }

                                        StyledText {
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: {
                                                if (!previewBox.activeRow) return qsTr("Preview");
                                                if (previewBox.activeRow.previewImage) return qsTr("Image");
                                                if (previewBox.activeRow.isColor) return qsTr("Color Code");
                                                if (previewBox.activeRow.entryType === "other") return qsTr("Windows Item");
                                                if (previewBox.activeRow.entryType === "file") return qsTr("File Reference");
                                                if (previewBox.activeRow.isUrl) return qsTr("Web Link");
                                                if (previewBox.activeRow.isCode) return qsTr("Code Snippet");
                                                return qsTr("Text");
                                            }
                                            font: Tokens.font.title.small
                                            color: Colours.palette.m3onSurface
                                        }

                                        StyledText {
                                            anchors.verticalCenter: parent.verticalCenter
                                            visible: (previewBox.activeRow?.charCount ?? 0) > 0
                                            text: qsTr("• %1 lines, %2 chars").arg(previewBox.activeRow?.lineCount ?? 0).arg(previewBox.activeRow?.charCount ?? 0)
                                            font: Tokens.font.body.small
                                            color: Colours.palette.m3onSurfaceVariant
                                        }
                                    }

                                    // Header quick actions
                                    Row {
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        anchors.rightMargin: Tokens.padding.small
                                        spacing: Tokens.spacing.extraSmall
                                        visible: previewBox.activeRow !== null

                                        IconButton {
                                            icon: "open_in_new"
                                            type: IconButton.Text
                                            visible: (previewBox.activeRow?.isUrl ?? false) || previewBox.activeRow?.entryType === "file" || ((previewBox.activeRow?.previewImage?.length ?? 0) > 0)
                                            onClicked: root.activate(root.selectedIndex, "open")
                                        }

                                        IconButton {
                                            icon: "content_copy"
                                            type: IconButton.Text
                                            onClicked: root.activate(root.selectedIndex, "copy")
                                        }

                                        IconButton {
                                            icon: "keyboard_return"
                                            type: IconButton.Text
                                            onClicked: root.activate(root.selectedIndex, "paste")
                                        }

                                        IconButton {
                                            icon: "delete_outline"
                                            type: IconButton.Text
                                            onClicked: root.removeSelected()
                                        }
                                    }

                                    Rectangle {
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.bottom: parent.bottom
                                        height: 1
                                        color: Qt.alpha(Colours.palette.m3outlineVariant, 0.35)
                                    }
                                }

                                // Preview body
                                Item {
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.top: previewHeader.bottom
                                    anchors.bottom: parent.bottom
                                    clip: true

                                    Column {
                                        anchors.centerIn: parent
                                        visible: !previewBox.activeRow
                                        spacing: Tokens.spacing.medium
                                        opacity: 0.5

                                        MaterialIcon {
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            text: "content_paste_off"
                                            fontStyle: Tokens.font.icon.builders.extraLarge.scale(2).build()
                                            color: Colours.palette.m3onSurfaceVariant
                                        }

                                        StyledText {
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            text: qsTr("Select an item to view preview")
                                            font: Tokens.font.body.medium
                                            color: Colours.palette.m3onSurfaceVariant
                                        }
                                    }

                                    // Text, code, link, file and Windows-item preview
                                    StyledFlickable {
                                        id: textFlickable

                                        anchors.fill: parent
                                        visible: previewBox.activeRow && !previewBox.activeRow.previewImage && !previewBox.activeRow.isColor
                                        contentWidth: width
                                        contentHeight: previewContentText.implicitHeight + Tokens.padding.large * 2
                                        clip: true
                                        boundsBehavior: Flickable.StopAtBounds

                                        StyledScrollBar.vertical: StyledScrollBar {
                                            flickable: textFlickable
                                        }

                                        StyledText {
                                            id: previewContentText

                                            x: Tokens.padding.large
                                            y: Tokens.padding.large
                                            width: textFlickable.width - Tokens.padding.large * 2

                                            text: previewBox.previewText
                                            textFormat: Text.PlainText
                                            color: Colours.palette.m3onSurface
                                            font: previewBox.activeRow?.isCode ? Tokens.font.mono.small : Tokens.font.body.medium
                                            lineHeight: previewBox.activeRow?.isCode ? 1.4 : 1.35
                                            wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                                        }
                                    }

                                    // Color swatch
                                    Column {
                                        anchors.centerIn: parent
                                        visible: previewBox.activeRow?.isColor ?? false
                                        spacing: Tokens.spacing.large

                                        StyledRect {
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            width: 140
                                            height: 140
                                            radius: Tokens.rounding.large
                                            color: previewBox.activeRow?.colorValue || "transparent"
                                            border.width: 2
                                            border.color: Colours.palette.m3outline

                                            layer.enabled: true
                                            layer.effect: MultiEffect {
                                                shadowEnabled: true
                                                blurMax: 16
                                                shadowColor: Qt.alpha(Colours.palette.m3shadow, 0.3)
                                            }
                                        }

                                        StyledText {
                                            anchors.horizontalCenter: parent.horizontalCenter
                                            text: previewBox.activeRow?.colorValue ?? ""
                                            font: Tokens.font.title.medium
                                            color: Colours.palette.m3onSurface
                                        }
                                    }

                                    // Image preview
                                    Item {
                                        anchors.fill: parent
                                        anchors.margins: Tokens.padding.medium
                                        visible: (previewBox.activeRow?.previewImage?.length ?? 0) > 0

                                        Image {
                                            anchors.fill: parent
                                            source: previewBox.activeRow?.previewImage ?? ""
                                            fillMode: Image.PreserveAspectFit
                                            sourceSize: Qt.size(960, 960)
                                            asynchronous: true
                                            smooth: true
                                        }
                                    }
                                }
                            }
                        }

                        // Footer keyboard shortcuts
                        Row {
                            id: footerBar

                            width: parent.width
                            height: 28
                            spacing: Tokens.spacing.large
                            layoutDirection: Qt.LeftToRight

                            Item {
                                width: 1
                                height: parent.height
                            }

                            component ShortcutPill: Row {
                                property string keyLabel
                                property string actionLabel

                                spacing: Tokens.spacing.extraSmall
                                anchors.verticalCenter: parent?.verticalCenter

                                StyledRect {
                                    anchors.verticalCenter: parent.verticalCenter
                                    implicitWidth: keyText.implicitWidth + Tokens.padding.small * 1.5
                                    implicitHeight: 20
                                    radius: Tokens.rounding.small
                                    color: Colours.tPalette.m3surfaceContainerHigh
                                    border.color: Qt.alpha(Colours.palette.m3outlineVariant, 0.4)
                                    border.width: 1

                                    StyledText {
                                        id: keyText

                                        anchors.centerIn: parent
                                        text: parent.parent.keyLabel
                                        font: Tokens.font.label.small
                                        color: Colours.palette.m3onSurface
                                    }
                                }

                                StyledText {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: parent.actionLabel
                                    font: Tokens.font.body.small
                                    color: Colours.palette.m3onSurfaceVariant
                                }
                            }

                            ShortcutPill {
                                keyLabel: "↵"
                                actionLabel: qsTr("Paste")
                            }

                            ShortcutPill {
                                keyLabel: "⇧↵"
                                actionLabel: qsTr("Copy")
                            }

                            ShortcutPill {
                                keyLabel: "⌥↵"
                                actionLabel: qsTr("Open")
                            }

                            ShortcutPill {
                                keyLabel: "Del"
                                actionLabel: qsTr("Delete")
                            }

                            ShortcutPill {
                                keyLabel: "⇧Del"
                                actionLabel: qsTr("Clear All")
                            }

                            ShortcutPill {
                                keyLabel: "Esc"
                                actionLabel: qsTr("Close")
                            }
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        visible: root.clearConfirmOpen
                        z: 9
                        onClicked: {}
                        onWheel: wheel => wheel.accepted = true
                    }

                    // Clear confirmation
                    StyledRect {
                        anchors.centerIn: parent
                        visible: root.clearConfirmOpen
                        implicitWidth: Math.min(440, card.width - Tokens.padding.large * 4)
                        implicitHeight: confirmColumn.implicitHeight + Tokens.padding.large * 2
                        color: Colours.palette.m3surfaceContainerHigh
                        radius: Tokens.rounding.extraLarge
                        border.color: Colours.palette.m3outline
                        border.width: 1
                        z: 10

                        layer.enabled: true
                        layer.effect: MultiEffect {
                            shadowEnabled: true
                            blurMax: 32
                            shadowColor: Qt.alpha(Colours.palette.m3shadow, 0.6)
                        }

                        Column {
                            id: confirmColumn

                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.margins: Tokens.padding.large
                            spacing: Tokens.spacing.medium

                            StyledText {
                                width: parent.width
                                text: qsTr("Delete entire clipboard history?")
                                color: Colours.palette.m3onSurface
                                font: Tokens.font.title.medium
                                horizontalAlignment: Text.AlignHCenter
                            }

                            StyledText {
                                width: parent.width
                                text: qsTr("Windows deletes its clipboard history entries. Pinned items remain Windows' decision.")
                                color: Colours.palette.m3onSurfaceVariant
                                font: Tokens.font.body.small
                                horizontalAlignment: Text.AlignHCenter
                                wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                            }

                            Row {
                                anchors.horizontalCenter: parent.horizontalCenter
                                spacing: Tokens.spacing.medium

                                TextButton {
                                    text: qsTr("Cancel (Esc)")
                                    onClicked: {
                                        root.clearConfirmOpen = false;
                                        root.searchBar?.forceActiveFocus();
                                    }
                                }

                                TextButton {
                                    text: qsTr("Delete All (Enter)")
                                    onClicked: root.clearHistory()
                                }
                            }
                        }
                    }

                    StyledText {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        anchors.leftMargin: Tokens.padding.large
                        anchors.rightMargin: Tokens.padding.large
                        anchors.bottomMargin: Tokens.padding.extraSmall
                        visible: ClipboardHistory.lastError.length > 0
                        text: ClipboardHistory.lastError
                        color: Colours.palette.m3error
                        font: Tokens.font.body.small
                        elide: Text.ElideRight
                    }
                }
            }
        }
    }

    IpcHandler {
        function open(): void {
            root.open();
        }

        function close(): void {
            root.close();
        }

        function toggle(): void {
            root.toggle();
        }

        function state(): string {
            return JSON.stringify({
                opened: root.opened,
                enabled: ClipboardHistory.enabled,
                status: ClipboardHistory.status,
                historyEnabled: ClipboardHistory.historyEnabled,
                entries: ClipboardHistory.items.length
            });
        }

        target: "clipboard"
    }

    CustomShortcut {
        name: "clipboard"
        description: "Open clipboard history"
        onPressed: {
            if (root.interactionEnabled)
                root.toggle();
        }
    }
}
