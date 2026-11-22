pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs as Dialogs
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Windows as Native
import Caelestia
import Caelestia.Config
import Caelestia.I18n
import Caelestia.Windows
import qs.services
import qs.utils
import "HistoryLogic.js" as Logic
import "../../utils/FileUrls.js" as FileUrls

Scope {
    id: root

    property bool enabled: true
    property string directory: Paths.state + "/screenshot-history"
    readonly property var settings: Logic.settings(GlobalConfig.windows?.capture)
    property var rows: []
    property bool loaded
    property bool viewing
    property bool writeFailed
    property int sweepRequest
    property bool confirmClear
    property string saveAsSource
    property string saveAsId
    readonly property var modes: [
        { id: "copy", label: Tr.tr("Copy to clipboard") },
        { id: "save", label: Tr.tr("Save to file") },
        { id: "save-and-copy", label: Tr.tr("Save and copy image") },
        { id: "save-and-copy-path", label: Tr.tr("Save and copy file path") },
        { id: "preview", label: Tr.tr("No automatic export") }
    ]
    readonly property string outputFolder: GlobalConfig.windows?.capture?.saveDirectory || Paths.pictures + "/Screenshots"

    signal editRequested(var row)
    signal copyRequested(var row)
    signal exportRequested(var row)

    function localKey(path): string {
        return path.replace(/\\/g, "/").toLowerCase();
    }

    function safeDirectory(): bool {
        return localKey(Native.FsUtils.canonicalPath(directory)) === localKey(directory);
    }

    function pathFor(name: string): string {
        return Logic.fileName(name) ? directory + "/" + name : "";
    }

    function remove(name: string): void {
        const path = pathFor(name);
        // QFile removes a final symlink itself, and we never recurse or
        // accept a directory or a path from the index.
        if (path && safeDirectory() && WindowsFiles.isFile(path))
            CUtils.deleteFile(FileUrls.fromLocalPath(path));
    }

    function sweep(): void {
        if (!sweepRequest && loaded && safeDirectory() && Native.FsUtils.classify(directory) === "dir")
            sweepRequest = Native.FsUtils.listDirAsync(directory);
    }

    Connections {
        target: Native.FsUtils
        function onListDirFinished(request, path, entries): void {
            if (request !== root.sweepRequest)
                return;
            root.sweepRequest = 0;
            const kept = Logic.ownedFiles(root.rows);
            for (const entry of entries) {
                if (!kept.has(entry.name))
                    root.remove(entry.name);
            }
        }
    }

    function ensureLoaded(): bool {
        if (!enabled || !safeDirectory())
            return false;
        if (loaded)
            return true;
        if (WindowsFiles.isFile(index.path)) {
            if (localKey(Native.FsUtils.canonicalPath(index.path)) !== localKey(index.path))
                return false;
            const data = Logic.decode(index.text());
            // A damaged index does not authorize deletion of anything.
            if (!data)
                return false;
            rows = data.filter(row => WindowsFiles.isFile(pathFor(row.raw)) && WindowsFiles.isFile(pathFor(row.image)));
        }
        loaded = true;
        trim();
        sweep();
        return true;
    }

    function publish(next: var): bool {
        if (!safeDirectory() || !Native.FsUtils.makePath(directory))
            return false;
        const data = JSON.stringify({ version: 1, rows: next });
        if (data.length > Logic.MAX_INDEX)
            return false;
        const previous = Logic.ownedFiles(rows);
        writeFailed = false;
        index.setText(data);
        if (writeFailed)
            return false;
        rows = next;
        const kept = Logic.ownedFiles(next);
        for (const name of previous) {
            if (!kept.has(name))
                remove(name);
        }
        return true;
    }

    function trim(): void {
        if (!loaded)
            return;
        const next = Logic.bounded(rows, settings.limit, settings.bytes);
        if (next.length !== rows.length)
            publish(next);
    }

    onSettingsChanged: trim()

    function get(id: string): var {
        return ensureLoaded() ? rows.find(row => row.id === id) ?? null : null;
    }

    function uniqueName(): string {
        // Reuse the platform's random identifier source without using the
        // allocated OS temp file as a durable path.
        const temp = CUtils.newCaptureTempPath();
        if (!temp)
            return "";
        const name = temp.slice(-36);
        CUtils.removeCaptureTemp(temp);
        return Logic.fileName(name) ? name : "";
    }

    function keep(id: string, source: string, image: string, info: var, strokes: var, canvasWidth: real, exported = ""): string {
        if (!settings.limit || !Logic.dimensions(info) || !ensureLoaded())
            return "";
        const old = rows.find(row => row.id === id);
        const raw = old?.raw ?? uniqueName();
        if (!raw)
            return "";
        const rendered = strokes.length ? uniqueName() : raw;
        if (!rendered)
            return "";
        const now = Date.now();
        const row = { id: old?.id ?? raw.slice(0, -4), raw, image: rendered, info, strokes,
            canvasWidth, updated: now, created: old?.created ?? now, exportPath: exported || old?.exportPath || "" };
        const next = Logic.bounded([row].concat(rows.filter(entry => entry.id !== row.id)), settings.limit, settings.bytes);
        if (!next.length || !Native.FsUtils.makePath(directory))
            return "";
        const copy = (from, name) => CUtils.copyFile(FileUrls.fromLocalPath(from), FileUrls.fromLocalPath(pathFor(name)), false);
        const newRaw = !old && copy(source, raw);
        if (!old && !newRaw)
            return "";
        const newRender = rendered !== raw && copy(image, rendered);
        if ((rendered === raw || newRender) && publish(next))
            return row.id;
        if (newRender)
            remove(rendered);
        if (newRaw)
            remove(raw);
        return "";
    }

    function markExported(id: string, path: string): void {
        if (!id || !path || !ensureLoaded())
            return;
        const row = rows.find(entry => entry.id === id);
        if (row && row.exportPath !== path)
            publish(rows.map(entry => entry === row ? Object.assign({}, row, { exportPath: path }) : entry));
    }

    function clear(): bool {
        return ensureLoaded() && (!rows.length || publish([]));
    }

    function removeEntry(id: string): void {
        if (ensureLoaded() && !publish(rows.filter(row => row.id !== id)))
            Toaster.toast(Tr.tr("Screenshot history"), Tr.tr("The capture could not be removed from history."), "history", Toast.Error);
    }

    function show(): void {
        ensureLoaded();
        confirmClear = false;
        viewing = true;
    }

    function setOption(key: string, value: var): void {
        const windows = Object.assign({}, GlobalConfig.windows);
        windows.capture = Object.assign({}, windows.capture, { [key]: value });
        GlobalConfig.windows = windows;
    }

    Dialogs.FolderDialog {
        id: folderDialog
        title: Tr.tr("Choose a screenshot save folder")
        onAccepted: {
            const selected = FileUrls.toLocalPath(selectedFolder);
            if (selected && root.outsideHistory(selected))
                root.setOption("saveDirectory", selected);
        }
    }

    function outsideHistory(path: string): bool {
        const target = localKey(Native.FsUtils.canonicalPath(path));
        const cache = localKey(Native.FsUtils.canonicalPath(directory));
        return target !== cache && !target.startsWith(cache + "/");
    }

    Dialogs.FileDialog {
        id: saveDialog
        title: Tr.tr("Save screenshot as")
        fileMode: Dialogs.FileDialog.SaveFile
        defaultSuffix: "png"
        nameFilters: ["PNG images (*.png)"]
        onAccepted: {
            const path = FileUrls.toLocalPath(selectedFile);
            const source = root.saveAsSource;
            // Qt's native Save dialog confirms existing paths. Never let an
            // export land in the app-owned cache that Clear history removes.
            const dir = path?.replace(/\/[^/]+$/, "") ?? "";
            if (dir && root.outsideHistory(dir) && CUtils.copyFile(FileUrls.fromLocalPath(source), selectedFile, true)) {
                root.markExported(root.saveAsId, path);
                Toaster.toast(Tr.tr("Screenshot saved"), path.replace(/\//g, "\\"), "screenshot_region");
            } else {
                Toaster.toast(Tr.tr("Screenshot failed"), Tr.tr("Choose a writable folder outside screenshot history."), "screenshot_region", Toast.Error);
            }
            root.releaseSaveAs();
        }
        onRejected: root.releaseSaveAs()
    }

    function saveAs(row: var): void {
        if (row)
            saveImageAs(pathFor(row.image), row.id);
    }

    function saveImageAs(source: string, id: string): bool {
        if (saveAsSource)
            return false;
        const temp = CUtils.newCaptureTempPath().replace(/\\/g, "/");
        if (!temp || !CUtils.copyFile(FileUrls.fromLocalPath(source), FileUrls.fromLocalPath(temp), true)) {
            if (temp)
                CUtils.removeCaptureTemp(temp);
            Toaster.toast(Tr.tr("Screenshot failed"), Tr.tr("Could not prepare the screenshot for saving."), "screenshot_region", Toast.Error);
            return false;
        }
        saveAsSource = temp;
        saveAsId = id;
        saveDialog.currentFolder = FileUrls.fromLocalPath(outputFolder);
        saveDialog.open();
        return true;
    }

    function releaseSaveAs(): void {
        if (saveAsSource)
            CUtils.removeCaptureTemp(saveAsSource);
        saveAsSource = "";
        saveAsId = "";
    }

    Component.onDestruction: releaseSaveAs()

    FileView {
        id: index
        path: root.directory + "/index.json"
        preload: false
        blockLoading: true
        blockWrites: true
        atomicWrites: true
        printErrors: false
        onSaveFailed: root.writeFailed = true
    }

    // Retire abandoned revisions even if the user doesn't take a screenshot
    // this session. No disk access in the smoke shell.
    Timer {
        interval: 2500
        running: root.enabled
        onTriggered: {
            if (Native.FsUtils.classify(root.directory) === "dir")
                root.ensureLoaded();
        }
    }

    LazyLoader {
        active: root.viewing

        FloatingWindow {
            title: Tr.tr("Screenshot history")
            implicitWidth: 570
            implicitHeight: 540
            visible: true
            onClosed: root.viewing = false

            Rectangle {
                anchors.fill: parent
                color: Colours.palette.m3surface

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 18
                    spacing: 10

                    RowLayout {
                        Layout.fillWidth: true
                        Label {
                            Layout.fillWidth: true
                            text: Tr.tr("Screenshot history")
                            color: Colours.palette.m3onSurface
                            font.pixelSize: 22
                        }
                        Button {
                            text: root.confirmClear ? Tr.tr("Confirm clear") : Tr.tr("Clear history")
                            enabled: root.rows.length > 0
                            onClicked: {
                                if (root.confirmClear) {
                                    root.confirmClear = false;
                                    if (!root.clear())
                                        Toaster.toast(Tr.tr("Screenshot history"), Tr.tr("History could not be cleared."), "history", Toast.Error);
                                } else {
                                    root.confirmClear = true;
                                }
                            }
                        }
                    }

                    Label {
                        Layout.fillWidth: true
                        text: Tr.tr("%1 of %2 captures • Clears history only, not exported files").arg(root.rows.length).arg(root.settings.limit)
                        color: Colours.palette.m3onSurfaceVariant
                        wrapMode: Text.Wrap
                    }
                    Label {
                        Layout.fillWidth: true
                        text: root.directory.replace(/\//g, "\\")
                        elide: Text.ElideMiddle
                        color: Colours.palette.m3onSurfaceVariant
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        Label { text: Tr.tr("Quick Capture"); color: Colours.palette.m3onSurface }
                        ComboBox {
                            Layout.fillWidth: true
                            model: root.modes
                            textRole: "label"
                            currentIndex: root.modes.findIndex(mode => mode.id === root.settings.mode)
                            onActivated: index => root.setOption("quickCapture", root.modes[index].id)
                        }
                        Label { text: Tr.tr("Keep"); color: Colours.palette.m3onSurface }
                        SpinBox {
                            from: 0
                            to: 50
                            value: root.settings.limit
                            onValueModified: root.setOption("historyLimit", value)
                            Accessible.name: Tr.tr("Screenshots to keep in history")
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        Label {
                            Layout.fillWidth: true
                            text: Tr.tr("Save to %1").arg(root.outputFolder.replace(/\//g, "\\"))
                            elide: Text.ElideMiddle
                            color: Colours.palette.m3onSurfaceVariant
                        }
                        Button {
                            text: Tr.tr("Change folder")
                            onClicked: {
                                folderDialog.currentFolder = FileUrls.fromLocalPath(root.outputFolder);
                                folderDialog.open();
                            }
                        }
                    }

                    ListView {
                        id: list
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        clip: true
                        spacing: 8
                        model: root.rows
                        ScrollBar.vertical: ScrollBar {}

                        delegate: Rectangle {
                            id: item
                            required property var modelData
                            width: list.width
                            height: 68
                            radius: Tokens.rounding.medium
                            color: Colours.palette.m3surfaceContainer
                            RowLayout {
                                anchors.fill: parent
                                anchors.margins: 8
                                spacing: 8
                                Image {
                                    Layout.preferredWidth: 80
                                    Layout.fillHeight: true
                                    source: FileUrls.fromLocalPath(root.pathFor(item.modelData.image))
                                    sourceSize: Qt.size(160, 104)
                                    fillMode: Image.PreserveAspectFit
                                    asynchronous: true
                                    cache: false
                                }
                                Label {
                                    Layout.fillWidth: true
                                    text: Qt.formatDateTime(new Date(item.modelData.created), Qt.DefaultLocaleShortDate)
                                    color: Colours.palette.m3onSurface
                                    elide: Text.ElideRight
                                }
                                Button { text: Tr.tr("Edit"); onClicked: root.editRequested(item.modelData) }
                                Button { text: Tr.tr("Copy"); onClicked: root.copyRequested(item.modelData) }
                                Button {
                                    text: item.modelData.exportPath ? Tr.tr("Save a copy") : Tr.tr("Save")
                                    onClicked: root.exportRequested(item.modelData)
                                }
                                Button { text: Tr.tr("Save as…"); onClicked: root.saveAs(item.modelData) }
                                ToolButton {
                                    text: "×"
                                    Accessible.name: Tr.tr("Remove from history")
                                    ToolTip.visible: hovered
                                    ToolTip.text: Accessible.name
                                    onClicked: root.removeEntry(item.modelData.id)
                                }
                            }
                        }

                        Label {
                            anchors.centerIn: parent
                            visible: root.rows.length === 0
                            text: root.settings.limit ? Tr.tr("New screenshots will appear here.") : Tr.tr("Screenshot history is disabled.")
                            color: Colours.palette.m3onSurfaceVariant
                        }
                    }
                }
            }
        }
    }
}
