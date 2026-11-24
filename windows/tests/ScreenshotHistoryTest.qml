import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Windows as Native
import Caelestia
import Caelestia.Config
import Caelestia.Windows
import qs.modules.areapicker
import qs.services

ShellRoot {
    id: root

    Tokens.screen: Quickshell.screens[0]?.name ?? ""
    property int assertions
    property int retries
    property var condition: null
    property var next: null
    property string captureId
    property string original
    property string exported
    property bool publishedBeforeCopy
    property var retiringEditor: null
    property int safeEditorCloses
    property string waitingFor
    property bool dismissPendingCapture
    property string dismissedPath
    property string originalClipboardId
    property string editedClipboardId
    property int unchangedCopyCount
    readonly property string exportFolder: Quickshell.stateDir.replace(/\\/g, "/") + "/user-exports"

    // Records the Windows clipboard-history entries the shell would see. The
    // fixture publishes one image item for every successful clipboard write.
    QtObject {
        id: clipboardHistoryRecorder
        property var items: []
        property var removed: []
        property int serial
        property int retained
        property int retains
        property int releases
        function retain(): void {
            retained++;
            retains++;
        }
        function release(): void {
            retained = Math.max(0, retained - 1);
            releases++;
        }
        function publishImage(): void {
            serial++;
            items = [{ id: "clip-" + serial, kind: "image" }].concat(items);
        }
        function remove(id: string): void {
            removed = removed.concat([id]);
            items = items.filter(item => item.id !== id);
        }
    }

    QtObject {
        id: clipboardRecorder
        property var images: []
        property var paths: []
        property int serial
        signal writeFinished(int id, bool ok, string error)
        function copyImageFile(path: string): int {
            if (!images.length)
                root.publishedBeforeCopy = !picker.opened && thumbs.entries.some(entry => entry.path === path);
            images = images.concat([{path, exists: WindowsFiles.isFile(path)}]);
            const id = ++serial;
            Qt.callLater(() => {
                writeFinished(id, true, "");
                clipboardHistoryRecorder.publishImage();
            });
            return id;
        }
        function copyText(path: string): int {
            paths = paths.concat([path]);
            const id = ++serial;
            Qt.callLater(() => writeFinished(id, true, ""));
            return id;
        }
    }

    AreaPicker {
        id: picker
        clipboard: clipboardRecorder
        clipboardHistory: clipboardHistoryRecorder
    }

    Thumbnails {
        id: thumbs
        clipboard: clipboardRecorder
        clipboardHistory: clipboardHistoryRecorder
    }

    Connections {
        target: picker

        function onOpenedChanged(): void {
            if (picker.opened || !root.dismissPendingCapture)
                return;
            root.step(() => {
                root.dismissPendingCapture = false;
                const entry = thumbs.entries[thumbs.entries.length - 1];
                root.check(entry?.outputPending, "the picker closes before the full PNG is ready");
                root.check(entry.memorySource.toString().startsWith("image://caelestia-capture-preview/"),
                    "the card already has an in-memory preview");
                root.check(!thumbs.saveEntry(entry), "save cannot use a partial PNG");
                root.dismissedPath = entry.path;
                thumbs.finish(entry);
                root.check(!thumbs.entries.includes(entry) && thumbs.pendingCaptures.has(entry.path),
                    "early dismissal removes the card and retains the output reservation");
            });
        }

        function onClosingChanged(): void {
            if (!root.retiringEditor)
                return;
            if (picker.closing) {
                Qt.callLater(() => root.step(() => {
                    root.check(!picker.opened, "Done does not wait for the fullscreen exit animation");
                }));
                return;
            }
            if (picker.opened)
                return;
            root.step(() => {
                // LazyLoader detaches its item before its deferred deletion.
                // Resetting the session must not show or refocus the old HWND.
                root.check(!root.retiringEditor.visible, "Done hides the old editor before resetting its session");
                root.check(root.retiringEditor.WlrLayershell.keyboardFocus === WlrKeyboardFocus.None,
                    "a retiring editor never takes keyboard focus again");
                root.safeEditorCloses++;
                root.retiringEditor = null;
            });
        }
    }

    Component {
        id: reload
        ScreenshotHistory {}
    }

    Timer {
        interval: 35
        repeat: true
        running: root.condition !== null
        onTriggered: root.step(() => {
            if (root.condition()) {
                const run = root.next;
                root.condition = null;
                run();
            } else {
                if (--root.retries <= 0)
                    throw new Error(`timed out waiting for ${root.waitingFor}: opened=${picker.opened} closing=${picker.closing} editing=${picker.editing} saving=${picker.saving} picker=${!!picker.editPicker} windows=${picker.windows.length} image=${root.child(picker.windows[0]?.contentItem, "captureEditorSource")?.status}`);
            }
        })
    }

    function check(ok, message): void {
        assertions++;
        if (!ok)
            throw new Error(message);
    }

    function step(run): void {
        try {
            run();
        } catch (error) {
            console.error("CAELESTIA_SCREENSHOT_HISTORY_FAIL " + error);
            Qt.exit(1);
        }
    }

    function waitFor(test, run, label = "capture state"): void {
        retries = 250;
        waitingFor = label;
        next = run;
        condition = test;
    }

    function child(item, name): var {
        if (item?.objectName === name)
            return item;
        for (const node of item?.children ?? []) {
            const found = child(node, name);
            if (found)
                return found;
        }
        return null;
    }

    function selectCapture(run): void {
        check(picker.open(), "picker opens");
        waitFor(() => !!picker.windows[0]?.contentItem, () => {
            for (const screen of picker.screenNames)
                picker.noteContent(screen, true);
            const area = child(picker.windows[0].contentItem, "areaPicker");
            check(!!area, "picker window is loaded");
            area.pressAt(Qt.LeftButton, 20, 30);
            area.moveTo(86, 85);
            area.releaseAt(Qt.LeftButton, 86, 85);
            check(!picker.editing && picker.saving, "a selection goes straight to capture");
            waitFor(() => !picker.opened, run);
        });
    }

    function editCard(run): void {
        thumbs.edit(thumbs.entries[thumbs.entries.length - 1]);
        waitFor(() => picker.editPicker && child(picker.editPicker, "captureEditorSource")?.status === Image.Ready, run, "editor image");
    }

    Component.onCompleted: Qt.callLater(() => step(() => {
        GlobalConfig.windows = { capture: { thumbnailSeconds: 0, saveDirectory: exportFolder } };
        selectCapture(() => {
            waitFor(() => clipboardRecorder.images.length > 0 && thumbs.entries[0]?.clipboardHistoryId,
                checkInitialCapture, "automatic copy");
        });
    }))

    function checkInitialCapture(): void {
        check(clipboardRecorder.images.length === 1 && clipboardRecorder.images[0].exists, "Quick Capture copies an existing image by default");
        check(publishedBeforeCopy, "the card is published and the picker is closed before automatic copy");
        check(Native.FsUtils.classify(exportFolder) === "invalid", "copy does not export a PNG");
        check(picker.history.rows.length === 1 && thumbs.entries.length === 1, "one history entry and thumbnail");
        const row = picker.history.rows[0];
        captureId = row.id;
        original = picker.history.pathFor(row.raw);
        check(row.raw === row.image && row.strokes.length === 0 && WindowsFiles.isFile(original), "an unedited capture stores only one PNG");
        originalClipboardId = thumbs.entries[0].clipboardHistoryId;
        check(originalClipboardId === "clip-1" && clipboardHistoryRecorder.items[0]?.id === originalClipboardId,
            "the automatic copy is tracked in clipboard history");
        editCard(() => {
            const panel = thumbs.windows[0];
            const hiddenCard = child(panel?.contentItem, "captureThumbnail");
            check(panel?.visible && !hiddenCard?.visible && hiddenCard?.maskItem.width === 0,
                "the thumbnail panel stays mapped but its card doesn't draw or take input during editing");
            picker.editor.pressAt(10, 10);
            picker.editor.moveTo(30, 25);
            picker.editor.releaseAt();
            check(!!child(picker.editPicker, "editor-done")?.visible, "Done is a visible editor action");
            retiringEditor = picker.windows[0];
            child(picker.editPicker, "editor-done").clicked();
            waitFor(() => !picker.opened && clipboardRecorder.images.length === 2
                && thumbs.entries[0]?.clipboardHistoryId && thumbs.entries[0].clipboardHistoryId !== originalClipboardId,
                checkDone, "first Done");
        });
    }

    function checkDone(): void {
        check(safeEditorCloses === 1 && picker.windows.length === 0, "Done retires the editor without recreating a picker");
        const row = picker.history.get(captureId);
        check(picker.history.rows.length === 1 && row.strokes.length === 1 && row.raw !== row.image, "Done updates one history entry with a rendered preview and editable stroke");
        check(Native.FsUtils.classify(exportFolder) === "invalid" && clipboardRecorder.images.length === 2,
            "Done copies edited pixels without exporting a file");
        editedClipboardId = thumbs.entries[0].clipboardHistoryId;
        check(clipboardHistoryRecorder.removed.includes(originalClipboardId) && editedClipboardId !== originalClipboardId,
            "the edited copy replaces the unedited clipboard-history entry");
        check(clipboardHistoryRecorder.items.length === 1 && clipboardHistoryRecorder.items[0].id === editedClipboardId,
            "clipboard history has one clean edited image entry");
        check(thumbs.entries.length === 1 && thumbs.entries[0].historyId === captureId, "Done replaces the same thumbnail");

        const card = () => child(thumbs.windows[0]?.contentItem, "captureThumbnail");
        waitFor(() => card()?.entry === thumbs.entries[0] && card().visible, () => {
            const visibleCard = card();
            check(child(visibleCard, "captureThumbnailImage")?.status === Image.Ready, "the returned card appears with decoded pixels");
            check(visibleCard.fade === 1 && visibleCard.slide === 1 && visibleCard.maskItem.x === visibleCard.x,
                "Done reveals the card at its final opacity and position");
            reopenAfterDone();
        }, "finished thumbnail");
    }

    function reopenAfterDone(): void {
        const again = reload.createObject(root, {directory: picker.history.directory});
        check(again.ensureLoaded() && again.get(captureId)?.strokes.length === 1, "annotations survive loading history from disk");
        again.destroy();

        editCard(() => {
            check(picker.editor.canUndo && picker.editor.strokes.length === 1, "reopen restores the vector stroke");
            picker.editor.undo();
            check(picker.editor.strokes.length === 0 && picker.editor.canRedo, "the first stroke is still editable");
            picker.editor.redo();
            picker.editor.pressAt(35, 35);
            picker.editor.moveTo(45, 45);
            picker.editor.releaseAt();
            check(picker.editor.strokes.length === 2, "the reopened edit accepts another stroke");
            picker.editPicker.exportEdit("copy");
            waitFor(() => picker.editing && !picker.saving && !!thumbs.entries[0]?.clipboardHistoryId
                && thumbs.entries[0].clipboardHistoryId !== editedClipboardId, () => {
                check(clipboardRecorder.images.length === 3 && clipboardRecorder.images[2].exists, "Copy exports edited pixels and leaves the editor open");
                check(clipboardHistoryRecorder.removed.includes(editedClipboardId), "Copy removes the superseded edited clipboard entry");
                editedClipboardId = thumbs.entries[0].clipboardHistoryId;
                picker.editor.pressAt(50, 50);
                picker.editor.moveTo(55, 55);
                picker.editor.releaseAt();
                check(picker.editor.strokes.length === 3, "a further edit makes Save export new pixels");
                picker.editPicker.exportEdit("save");
                waitFor(() => picker.editing && !picker.saving && clipboardRecorder.images.length === 4
                    && thumbs.entries[0]?.clipboardHistoryId && thumbs.entries[0].clipboardHistoryId !== editedClipboardId, () => {
                    check(clipboardHistoryRecorder.removed.includes(editedClipboardId), "Save copies the edited image and removes the superseded clipboard entry");
                    editedClipboardId = thumbs.entries[0].clipboardHistoryId;
                    check(picker.editingSaved, "Save keeps the editor open and marks the export");
                    check(child(picker.editPicker, "editor-save").Accessible.name === "Save a copy", "the next export is labeled Save a copy");
                    retiringEditor = picker.windows[0];
                    unchangedCopyCount = clipboardRecorder.images.length;
                    picker.editPicker.exportEdit("done");
                    waitFor(() => !picker.opened, checkSave, "Done after Save");
                }, "editor Save");
            }, "editor Copy");
        });
    }

    function checkSave(): void {
        check(safeEditorCloses === 2, "Done without further changes uses the same safe teardown");
        const card = thumbs.entries.find(entry => entry.saved);
        exported = card?.path ?? "";
        check(exported.startsWith(exportFolder + "/") && WindowsFiles.isFile(exported), "Save writes the configured export folder");
        check(picker.history.rows.length === 1 && picker.history.get(captureId)?.strokes.length === 3
            && picker.history.get(captureId).exportPath === exported, "Save updates the same history item and tracks the export separately");
        check(clipboardRecorder.images.length === unchangedCopyCount, "Done without further edits does not re-copy");
        check(!clipboardHistoryRecorder.removed.includes(editedClipboardId), "and does not delete the existing clipboard entry");
        const clipboardId = card.clipboardHistoryId;
        check(clipboardId && clipboardId === editedClipboardId, "the replacement thumbnail keeps the edited clipboard-history ID");
        thumbs.discardEntry(card);
        thumbs.finish(card);
        check(picker.history.rows.length === 0 && !picker.history.get(captureId), "the X button removes the capture from screenshot history");
        check(clipboardHistoryRecorder.removed.includes(clipboardId) && !clipboardHistoryRecorder.items.some(item => item.id === clipboardId),
            "the X button removes the edited clipboard-history entry");
        check(CaptureUi.showHistory() && picker.history.viewing, "history can be opened");
        picker.history.viewing = false;
        check(picker.history.clear(), "clear history");
        check(!WindowsFiles.isFile(original) && WindowsFiles.isFile(exported), "Clear removes history data and preserves exported PNGs");
        GlobalConfig.windows = { capture: { quickCapture: "save-and-copy-path", historyLimit: 0, thumbnail: false, saveDirectory: exportFolder } };
        selectCapture(() => {
            check(clipboardRecorder.paths.length === 1 && WindowsFiles.isFile(clipboardRecorder.paths[0]), "Quick Capture can save and copy the pathname without a thumbnail");
            check(picker.history.rows.length === 0 && clipboardRecorder.images.length === 4, "disabled history does not retain the capture");
            if (Quickshell.env("CAELESTIA_SCRATCH_FIXTURE") === "1") {
                const temp = Quickshell.env("TEMP").replace(/\\/g, "/");
                const old = temp + "/caelestia-clipboard-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.png";
                const drag = temp + "/caelestia-drag-cccccccccccccccccccccccccccccccc";
                waitFor(() => !WindowsFiles.isFile(old) && Native.FsUtils.classify(drag) === "invalid", () => {
                    check(WindowsFiles.isFile(temp + "/caelestia-clipboard-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.png"), "the startup sweep keeps recent files");
                    check(WindowsFiles.isFile(temp + "/caelestia-clipboard-someone-elses.png"), "the startup sweep ignores unowned names");
                    checkEarlyDismiss();
                });
            } else {
                checkEarlyDismiss();
            }
        });
    }

    function checkEarlyDismiss(): void {
        // The same flow can be run against a pre-preview plugin to cover the
        // compatibility fallback. Only that runtime skips the pending case.
        if (typeof CUtils.saveCaptureWithPreview !== "function") {
            finish();
            return;
        }
        for (const entry of thumbs.entries)
            thumbs.finish(entry);
        GlobalConfig.windows = { capture: { thumbnailSeconds: 0, saveDirectory: exportFolder } };
        dismissPendingCapture = true;
        selectCapture(() => {
            waitFor(() => clipboardRecorder.images.length === 5, () => {
                check(clipboardRecorder.images[4].path === dismissedPath && clipboardRecorder.images[4].exists,
                    "automatic copy reads the completed PNG even after dismissal");
                check(thumbs.entries.length === 0 && !thumbs.pendingCaptures.has(dismissedPath) && !WindowsFiles.isFile(dismissedPath),
                    "the dismissed card leaves no pending file or entry");
                const row = picker.history.rows[0];
                check(picker.history.rows.length === 1 && WindowsFiles.isFile(picker.history.pathFor(row.raw)),
                    "early dismissal preserves the completed screenshot in history");
                checkFailedCapture();
            }, "dismissed capture output");
        });
    }

    function checkFailedCapture(): void {
        const path = CUtils.newCaptureTempPath().replace(/\\/g, "/");
        const info = { screen: Quickshell.screens[0].name, width: 60, height: 40, dpr: 1 };
        // Remove this entry before Qt Quick creates a delegate. This exercises
        // the failure path without trying to load a nonexistent provider key.
        const entry = thumbs.addPendingCapture(info, path, "image://caelestia-capture-preview/fixture", 0);
        let ran = false;
        entry.afterReveal = () => ran = true;
        check(thumbs.completePendingCapture(path, false), "a write failure reaches the pending entry");
        check(!ran && !thumbs.entries.includes(entry) && !WindowsFiles.isFile(path), "a failed write removes the provisional card and skips output actions");
        finish();
    }

    function finish(): void {
        console.log("CAELESTIA_SCREENSHOT_HISTORY_PASS " + assertions);
        Qt.quit();
    }
}
