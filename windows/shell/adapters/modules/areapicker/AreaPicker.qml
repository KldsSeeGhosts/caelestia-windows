pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Windows as Native
import Caelestia
import Caelestia.Config
import Caelestia.I18n
import qs.components.containers
import qs.services
import qs.utils
import "CaptureLogic.js" as Logic
import "HistoryLogic.js" as History
import "RecordingLogic.js" as Recording
import "../../utils/FileUrls.js" as FileUrls

// Windows adaptation of upstream modules/areapicker/AreaPicker.qml.
//
// Upstream registers the `picker` IPC target and four shortcuts here. On
// Windows those names stay with services/Glazier.qml and daemons/Shortcuts.qml,
// and every one reaches this scope through CaptureUi.screenshot(). As upstream,
// a loader holds one overlay window per screen.
//
// Differences from upstream:
// - Each window is excluded from capture, so the frozen frame holds the
//   desktop, the bar and the border but never the picker itself.
// - The screen is always frozen first. A Windows ScreencopyView never starts
//   capturing while it is hidden, so upstream's live mode, which hides the view
//   and re-shows it, cannot work. CaptureUi accepts the four upstream names, and
//   open and openFreeze (and the Clip pair) therefore behave the same.
// - A selection goes to an unsaved thumbnail. The thumbnail can open the
//   editor (Editor.qml) on its captured PNG. Without thumbnails, the editor
//   opens directly so Copy and Save are still available.
Scope {
    id: root

    // The production host turns this off during smoke, which must never freeze
    // a real desktop.
    property bool interactionEnabled: true
    property bool opened
    property bool closing
    property bool saving
    property bool recordingMode
    property bool recordingSound
    property var recorder: Recorder
    // Screen name to ScreencopyView.hasContent, and whether all of them have it.
    property var ready: ({})
    property bool allReady
    property double openedAt
    // The editor is open on one screen. `editPlan` is the selection's export
    // plan (CaptureLogic.exportPlan) and `editPicker` the Picker that holds it.
    property bool editing
    property string editScreen
    property var editPlan: null
    property var editPicker: null
    // A reopened capture owns a separate source file until the editor closes.
    property string editPath
    property var editInfo: null
    property int editSerial
    property string editHistoryId
    // The Windows clipboard-history item for the thumbnail this edit came from.
    property string editClipboardId
    property var restoredEdit: null
    property var openedEdit: null
    property var committedEdit: null
    property bool editingSaved
    // The tool state and annotations, shared by every screen's window.
    readonly property EditorState editor: EditorState {}
    // Window stack taken once when the picker opens, topmost first.
    property var stack: []
    // Where files go. Screenshots are written to <saveRoot>/Screenshots, and
    // to <saveRoot> itself when that folder cannot be created. Fixtures redirect
    // it. The clipboard hand-over files are named and placed by the plugin
    // (CUtils.newCaptureTempPath), in the OS temp directory. A crash while a
    // clipboard save is under way can leave one caelestia-clipboard-*.png there.
    property string saveRoot: Paths.pictures
    // The screens the picker serves. Fixtures replace the list to simulate a
    // monitor being unplugged.
    property var screenList: Screens.screens
    // Longest time a save may take before the picker reports a failure.
    property int saveTimeout: 10000
    // Counts opens and closes. A result carries the number it started with, so
    // one that arrives after the picker closed or reopened is dropped. It only
    // routes results; file names do not use it.
    property int session
    property var openScreenNames: []
    // The hand-over file of the clipboard save in progress, if any. Its name is
    // unique across pickers, reloads and processes, so no one else touches it.
    property string activeTemp: ""
    // Needs a local file path. Fixtures replace it with a recorder so that no
    // test writes the real clipboard.
    property var clipboard: Native.ClipboardWriter
    // Windows clipboard history, injectable so fixtures never touch WinRT.
    property var clipboardHistory: ClipboardHistory
    property int copyOperation
    property int copySession
    property var copyInfo: null
    property string copyPreview: ""
    // Mutable handoff for the clipboard-history correlation owned by Thumbnails.
    property var copyTrack: null
    // Detached edited Done copies that cannot use a thumbnail. Each value has
    // the clipboard history item it replaces and whether Thumbnails manages that
    // replacement itself.
    property var detachedImageWrites: ({})
    // Shows the finished capture. Thumbnails.qml registers itself with CaptureUi;
    // fixtures replace it, and without one no thumbnail is shown.
    property var thumbnails: CaptureUi.thumbnails
    property var history: historyStore
    readonly property var captureSettings: History.settings(GlobalConfig.windows?.capture)

    ScreenshotHistory {
        id: historyStore
        enabled: root.interactionEnabled && root.history === historyStore
        onEditRequested: row => {
            if (root.reopenCapture(historyStore.pathFor(row.raw), row.info, 0, row.id, false))
                historyStore.viewing = false;
        }
        onCopyRequested: row => root.thumbnails?.copyOutput(historyStore.pathFor(row.image))
        onExportRequested: row => historyStore.markExported(row.id, root.thumbnails?.exportHistory(historyStore.pathFor(row.image)) ?? "")
    }

    ScreenshotScratch {
        enabled: root.interactionEnabled && root.history === historyStore
    }

    readonly property var screenNames: screenList.map(screen => screen.name)
    readonly property var windows: loader.item ? loader.item.instances : []

    function open(recording = false, sound = false): bool {
        if (!interactionEnabled)
            return false;
        if (opened)
            return true;
        openedAt = Date.now();
        closing = false;
        saving = false;
        recordingMode = recording;
        recordingSound = sound;
        endEditing();
        ready = ({});
        allReady = false;
        // One read-only enumeration for every screen, before any window exists.
        stack = Array.from(Hyprland.windowStack());
        openScreenNames = screenNames;
        session++;
        opened = true;
        return true;
    }

    // Every operation ends here before anything else happens: a result, a
    // failure, the timeout, Esc and a right click all call it first. It
    // invalidates the session, so a result that arrives later is dropped, and
    // clears `saving`, which stops the timeout. The fade that follows is only
    // cosmetic. The operation's hand-over file goes with it.
    function invalidate(): void {
        session++;
        saving = false;
        copyOperation = 0;
        copyInfo = null;
        if (copyPreview) {
            removeTemp(copyPreview);
            copyPreview = "";
        }
        if (activeTemp) {
            removeTemp(activeTemp);
            activeTemp = "";
        }
    }

    function acceptSelection(picker: var, plan: var, releasedAt: double): void {
        if (recordingMode) {
            const region = Recording.region(plan.logical, picker.geometry, picker.dpr);
            if (region && recorder.startRegion(region, Recording.startArgs(region, recordingSound)))
                finishClose();
            else if (region) {
                Toaster.toast(Tr.tr("Recording failed"), recorder.status, "screen_record", Toast.Error);
                cancel();
            }
            return;
        }
        const info = { screen: picker.screen.name, width: plan.crop.width, height: plan.crop.height, dpr: picker.dpr };
        const hasOutput = thumbnails?.canAdd?.(info)
            || (history && thumbnails && (captureSettings.mode !== "preview" || captureSettings.limit));
        if (!hasOutput || !beginClipboard()) {
            startEditing(picker, plan);
            return;
        }
        saving = true;
        // Keep the frozen selection ready as a fallback if staging fails.
        editPicker = picker;
        editPlan = plan;
        picker.stageCapture(activeTemp, plan, info, releasedAt);
    }

    function canPreviewCapture(info: var): bool {
        return history && !captureSettings.openEditor
            && (captureSettings.mode === "copy" || captureSettings.mode === "preview") && thumbnails?.canAdd?.(info);
    }

    function captureActions(entry: var, path: string, info: var, mode: string): void {
        entry.afterReveal = () => {
            entry.historyId = history?.keep("", path, path, info, [], 0) ?? "";
            if (mode === "copy") {
                if (entry.closing || !thumbnails.entries.includes(entry))
                    thumbnails.copyOutput(path);
                else
                    thumbnails.copyEntry(entry);
            }
        };
    }

    function capturePreviewReady(started: int, path: string, info: var, preview: url, releasedAt: double): bool {
        if (started !== session || !canPreviewCapture(info))
            return false;
        const entry = thumbnails.addPendingCapture(info, path, preview, releasedAt);
        if (!entry)
            return false;
        captureActions(entry, path, info, captureSettings.mode);
        activeTemp = "";
        finishClose();
        return true;
    }

    function captureFinished(started: int, path: string, info: var, releasedAt = 0): void {
        if (started !== session) {
            removeTemp(path);
            return;
        }
        const mode = history ? captureSettings.mode : "preview";
        if (history && !captureSettings.openEditor && (mode === "copy" || mode === "preview")
            && thumbnails?.addCapture(info, path)) {
            const entry = thumbnails.entries[thumbnails.entries.length - 1];
            // The card owns the staged PNG now. Its first frame doesn't have
            // to wait for the history index or the clipboard's synchronous
            // file read. The thumbnail scope keeps the file through both.
            entry.captureReleasedAt = releasedAt;
            if (releasedAt)
                thumbnails.logCaptureTiming(entry, "png");
            captureActions(entry, path, info, mode);
            activeTemp = "";
            finishClose();
            return;
        }
        const historyId = history?.keep("", path, path, info, [], 0) ?? "";
        const result = thumbnails?.finishCapture(info, path, historyId, mode);
        if (result?.accepted || historyId) {
            if (result?.saved && historyId)
                history.markExported(historyId, result.path);
            if (result?.transferred)
                activeTemp = "";
            const editSource = result?.path || (historyId ? history.pathFor(history.get(historyId).raw) : "");
            finishClose();
            if (captureSettings.openEditor && editSource)
                Qt.callLater(() => reopenCapture(editSource, info, result?.serial ?? 0, historyId, result?.saved === true));
        } else {
            captureFailed(started, path);
        }
    }

    function captureFailed(started: int, path: string): void {
        if (started !== session) {
            removeTemp(path);
            return;
        }
        const picker = editPicker;
        const plan = editPlan;
        invalidate();
        startEditing(picker, plan);
    }

    function startEditing(picker: var, plan: var): void {
        editor.reset();
        editor.scale = picker.dpr;
        editPlan = plan;
        editPicker = picker;
        editScreen = picker.screen.name;
        editing = true;
    }

    function reopenCapture(path: string, info: var, serial: int, historyId = "", saved = false, clipboardId = ""): bool {
        const screen = screenNames.includes(info.screen) ? info.screen : screenNames[0];
        if (!interactionEnabled || opened || !screen)
            return false;
        const row = historyId ? history?.get(historyId) : null;
        const original = row ? history.pathFor(row.raw) : path;
        const temp = CUtils.newCaptureTempPath().replace(/\\/g, "/");
        if (!temp)
            return false;
        if (!CUtils.copyFile(FileUrls.fromLocalPath(original), FileUrls.fromLocalPath(temp), true)) {
            removeTemp(temp);
            return false;
        }
        session++;
        recordingMode = false;
        stack = [];
        editPath = temp;
        editInfo = Object.assign({}, info, { screen });
        editSerial = serial;
        editHistoryId = historyId;
        editClipboardId = clipboardId;
        restoredEdit = row;
        openedEdit = null;
        editingSaved = saved || !!row?.exportPath;
        editScreen = screen;
        openScreenNames = screenNames;
        editing = true;
        opened = true;
        return true;
    }

    function showHistory(): bool {
        if (!history || !interactionEnabled || opened)
            return false;
        history.show();
        return true;
    }

    function editSourceFailed(): void {
        if (!opened || closing || !editPath)
            return;
        Toaster.toast(Tr.tr("Screenshot failed"), Tr.tr("The image could not be opened."), "screenshot_region", Toast.Error);
        cancel();
    }

    function endEditing(): void {
        editing = false;
        editScreen = "";
        editPlan = null;
        editPicker = null;
        const path = editPath;
        editPath = "";
        editInfo = null;
        editSerial = 0;
        editHistoryId = "";
        editClipboardId = "";
        restoredEdit = null;
        openedEdit = null;
        committedEdit = null;
        editingSaved = false;
        if (path)
            removeTemp(path);
        editor.reset();
    }

    // Esc and a right click land here. Nothing more is saved.
    function cancel(): void {
        if (!opened || closing)
            return;
        invalidate();
        closing = true;
    }

    // Esc first cancels text, closes a popover or flyout and clears a selection,
    // then closes the editor.
    function dismiss(): void {
        if (editing && !saving && editor.escapePressed())
            return;
        cancel();
    }

    // The editor's keys, for any screen's window. Returns whether the key was used.
    function editorKey(key: int, ctrl: bool, shift: bool, alt: bool): bool {
        if (!editing || closing || saving || !editPicker)
            return false;
        if (!ctrl && !alt && !editor.inkOpen && editor.toolMenu < 0 && !editor.textEditing && editPath && history && (key === Qt.Key_Return || key === Qt.Key_Enter)) {
            editPicker.exportEdit("done");
            return true;
        }
        const result = editor.shortcut(key, ctrl, shift, alt);
        if (result === "copy" || result === "save")
            editPicker.exportEdit(result);
        return result !== "";
    }

    // Called by a picker when its fade out has finished, or at once when the
    // animation is disabled.
    function finishClose(): void {
        if (!opened)
            return;
        // LazyLoader deletes its detached item later. Mark the session closed
        // before resetting editing state so those delegates stay hidden and
        // the retiring Variants cannot create a picker on the other monitors.
        opened = false;
        closing = false;
        invalidate();
        endEditing();
    }

    function closeAfterDone(): void {
        // The result is ready. Release input and retire the fullscreen editor
        // in this turn instead of keeping the thumbnail behind its exit fade.
        closing = true;
        finishClose();
    }

    // Deletes one hand-over file. The plugin accepts only the exact path scheme it
    // creates in the temp directory, and refuses everything else.
    function removeTemp(path: string): void {
        CUtils.removeCaptureTemp(path);
    }

    // A new, empty hand-over file for this clipboard save, or "" if none could
    // be created.
    function beginClipboard(): string {
        activeTemp = CUtils.newCaptureTempPath().split("\\").join("/");
        return activeTemp;
    }

    function reopenedExportFinished(started: int, kind: string, path: string, ok: bool, info = editInfo): void {
        if (started !== session)
            return;
        if (ok && kind === "copy") {
            copyFinished(started, path, info);
            return;
        }
        if (ok && kind === "done") {
            if (editUnchanged()) {
                removeTemp(path);
                activeTemp = "";
                closeAfterDone();
                return;
            }
            const id = keepEdited(path, info);
            if (!id) {
                saveFailed(started, Tr.tr("The edit could not be kept."));
                return;
            }
            if (thumbnails?.addCapture(info, path, id, editSerial)) {
                const entry = thumbnails.entryForSerial(thumbnails.lastId);
                if (entry) {
                    // Until the edited copy succeeds, the old item is still the
                    // one this replacement can discard. copyEntry clears and
                    // replaces it after the clipboard write completes.
                    entry.clipboardHistoryId = editClipboardId;
                    entry.replaceClipboardId = editClipboardId;
                    thumbnails.copyEntry(entry);
                }
                activeTemp = "";
                closeAfterDone();
                return;
            }
            if (copyEditedDetached(path, editClipboardId))
                closeAfterDone();
            else
                saveFailed(started, Tr.tr("The image could not be copied."));
            return;
        }
        if (ok) {
            const saved = thumbnails?.saveExport(path, saveRoot);
            if (saved) {
                fileFinished(started, saved, info);
                return;
            }
        }
        saveFailed(started, Tr.tr("The image could not be saved."));
    }

    function keepEdited(path: string, info: var, exported = ""): string {
        if (!history || !editPath || !editPicker)
            return "";
        const id = history.keep(editHistoryId, editPath, path, info, editor.strokes, editPicker.editRegion.width, exported);
        if (id)
            editHistoryId = id;
        return id;
    }

    function sameEdit(left: var, right: var): bool {
        return !!left && !!right && JSON.stringify(left.strokes ?? []) === JSON.stringify(right.strokes ?? []);
    }

    function editUnchanged(): bool {
        return !!editPath && (sameEdit(committedEdit, editor.history) || sameEdit(openedEdit, editor.history));
    }

    function finishUnchanged(): bool {
        if (!editUnchanged())
            return false;
        closeAfterDone();
        return true;
    }

    // Results from the editor's exports. Each ignores a result from an earlier
    // session. `info` is { screen, width, height, dpr } for the thumbnail, and
    // null when the caller has none.
    //
    // The thumbnail is the feedback for a finished capture, so no success toast
    // is shown. The one exception is the classic tool's: a saved file is announced
    // when the thumbnail is switched off, because nothing else would say so.
    // Copying never announces itself.
    function fileFinished(started: int, path: string, info = null): void {
        if (started !== session)
            return;
        const id = keepEdited(path, info, path);
        const changedEdit = editPath && !editUnchanged();
        if (thumbnails && info && thumbnails.addSaved(info, path, id, editPath ? editSerial : -1)) {
            if (editPath)
                editSerial = thumbnails.lastId;
            if (changedEdit) {
                const entry = thumbnails.entryForSerial(thumbnails.lastId);
                if (entry) {
                    if (editClipboardId)
                        entry.replaceClipboardId = editClipboardId;
                    thumbnails.copyEntry(entry, false, id => {
                        if (editPath)
                            editClipboardId = id;
                    });
                }
            }
        }
        if (history || (thumbnails && !thumbnails.enabled))
            Toaster.toast(Tr.tr("Screenshot saved"), Tr.tr("Saved to %1").arg(path), "screenshot_region");
        if (history && editPath) {
            editingSaved = true;
            committedEdit = editor.history;
            invalidate();
        } else {
            cancel();
        }
    }

    // The writer reads the hand-over file before returning an operation id.
    // Keep a separate preview until writeFinished confirms success. Neither a
    // queued write nor a failed write is a finished capture.
    function copyFinished(started: int, path: string, info = null): void {
        if (started !== session) {
            removeTemp(path);
            return;
        }
        if (info && ((thumbnails && thumbnails.enabled) || (history && editPath))) {
            copyPreview = CUtils.newCaptureTempPath().split("\\").join("/");
            if (copyPreview && !CUtils.copyFile(FileUrls.fromLocalPath(path), FileUrls.fromLocalPath(copyPreview), true)) {
                removeTemp(copyPreview);
                copyPreview = "";
            }
        }
        copySession = started;
        copyInfo = info;
        saving = true;
        const replaceClipboardId = editPath && editClipboardId && !editUnchanged() ? editClipboardId : "";
        copyTrack = { serial: 0, replaceClipboardId, managed: false };
        const track = copyTrack;
        copyOperation = clipboard.copyImageFile(path);
        if (copyOperation && thumbnails?.registerClipboardWrite) {
            track.managed = true;
            thumbnails.registerClipboardWrite(copyOperation, null, {
                replaceClipboardId,
                onCorrelated: id => copyClipboardCorrelated(track, id)
            });
        }
        removeTemp(path);
        activeTemp = "";
    }

    // Done must copy even when no thumbnail can present the result. The
    // writer has already opened the hand-over file when it returns, so the
    // editor may close while this detached write finishes.
    function copyEditedDetached(path: string, replaceClipboardId: string): bool {
        const operation = clipboard.copyImageFile(path);
        if (!operation)
            return false;
        const managed = !!thumbnails?.registerClipboardWrite;
        if (managed)
            thumbnails.registerClipboardWrite(operation, null, ({ replaceClipboardId }));
        const writes = Object.assign({}, detachedImageWrites);
        writes[operation] = { replaceClipboardId: replaceClipboardId, managed: managed };
        detachedImageWrites = writes;
        return true;
    }

    function copyClipboardCorrelated(track: var, id: string): void {
        if (!track)
            return;
        if (editPath)
            editClipboardId = id;
        const entry = thumbnails?.entryForSerial?.(track.serial);
        if (entry)
            entry.clipboardHistoryId = id;
    }

    Connections {
        target: root.clipboard || null
        function onWriteFinished(id: int, ok: bool, error: string): void {
            const detachedWrite = root.detachedImageWrites[id];
            if (detachedWrite) {
                const writes = Object.assign({}, root.detachedImageWrites);
                delete writes[id];
                root.detachedImageWrites = writes;
                if (!ok) {
                    Toaster.toast(Tr.tr("Screenshot failed"), Tr.tr("The image could not be copied."), "screenshot_region", Toast.Error);
                    return;
                }
                if (!detachedWrite.managed && detachedWrite.replaceClipboardId)
                    root.clipboardHistory?.remove?.(detachedWrite.replaceClipboardId);
                return;
            }
            if (!root.copyOperation || id !== root.copyOperation || root.copySession !== root.session || !root.opened || root.closing)
                return;
            if (!ok) {
                root.saveFailed(root.copySession, Tr.tr("The image could not be copied."));
                return;
            }
            const unchanged = root.editPath && root.editUnchanged();
            const historyId = !unchanged && root.copyPreview ? root.keepEdited(root.copyPreview, root.copyInfo) : root.editHistoryId;
            if (root.copyTrack?.replaceClipboardId) {
                if (!root.copyTrack.managed)
                    root.clipboardHistory?.remove?.(root.copyTrack.replaceClipboardId);
                if (root.editClipboardId === root.copyTrack.replaceClipboardId)
                    root.editClipboardId = "";
            }
            if (!unchanged && root.thumbnails && root.copyInfo && root.copyPreview
                && root.thumbnails.addCopy(root.copyInfo, root.copyPreview, historyId, root.editPath ? root.editSerial : -1)) {
                if (root.copyTrack) {
                    root.copyTrack.serial = root.thumbnails.lastId;
                    root.thumbnails.updateClipboardWriteSerial?.(root.copyOperation, root.copyTrack.serial);
                }
                if (root.editPath) {
                    root.editSerial = root.thumbnails.lastId;
                    root.committedEdit = root.editor.history;
                }
            }
            if (root.history && root.editPath && !root.captureSettings.closeAfterCopy)
                root.invalidate();
            else
                root.cancel();
        }
    }

    // An export that failed is reported and ends, but the editor stays open with
    // its annotations, as the classic tool's does, so the user can try again.
    // Anything that arrives late for this export is dropped.
    function saveFailed(started: int, message: string): void {
        if (started !== session)
            return;
        Toaster.toast(Tr.tr("Screenshot failed"), message, "screenshot_region", Toast.Error);
        invalidate();
    }

    // A monitor was added or removed while open. The frozen frames and the
    // readiness map describe the old layout, so the picker closes at once.
    onScreenNamesChanged: {
        if (!opened || closing || Logic.sameNames(openScreenNames, screenNames))
            return;
        Toaster.toast(Tr.tr("Screenshot cancelled"), Tr.tr("The monitors changed."), "screenshot_region");
        finishClose();
    }

    // A save that never reports back must not leave the screen frozen.
    Timer {
        interval: root.saveTimeout
        running: root.saving && root.opened
        onTriggered: {
            if (!root.editing && root.editPicker)
                root.captureFailed(root.session, root.activeTemp);
            else
                root.saveFailed(root.session, root.copyOperation
                    ? Tr.tr("Copying the screenshot timed out.") : Tr.tr("Saving the screenshot timed out."));
        }
    }

    // Each ScreencopyView reports here. The tint appears only when every screen
    // has a frame, and the time from open() is logged so the owner can compare it
    // with the 100 ms budget on real hardware.
    function noteContent(name: string, has: bool): void {
        if (!opened)
            return;
        const next = Object.assign({}, ready);
        next[name] = has;
        ready = next;
        const done = Logic.allReady(next, screenNames);
        if (done && !allReady) {
            allReady = true;
            const elapsed = Date.now() - openedAt;
            console.log(`CAELESTIA_CAPTURE_PICKER_FREEZE ms=${elapsed} screens=${screenNames.length}`);
        } else if (!done) {
            allReady = false;
        }
    }

    // A shell reload destroys this scope with the picker open. Nothing is saved.
    Component.onCompleted: CaptureUi.picker = root
    Component.onDestruction: {
        if (CaptureUi.picker === root)
            CaptureUi.picker = null;
        if (activeTemp)
            removeTemp(activeTemp);
        if (copyPreview)
            removeTemp(copyPreview);
        if (editPath)
            removeTemp(editPath);
    }

    LazyLoader {
        id: loader

        active: root.opened

        Variants {
            id: sessionWindows

            property bool retired

            // Snapshot the monitors. A reopened capture only owns one window;
            // clearing editPath at teardown must never widen this model.
            Component.onCompleted: model = Array.from(root.screenList).filter(screen => !root.editPath || screen.name === root.editScreen)

            Connections {
                target: root
                function onOpenedChanged(): void {
                    if (!root.opened)
                        sessionWindows.retired = true;
                }
            }

            StyledWindow {
                id: win

                required property ShellScreen modelData
                readonly property bool sessionOpen: root.opened && !sessionWindows.retired
                readonly property bool acceptsInput: sessionOpen && !root.closing

                screen: modelData
                name: "area-picker"
                visible: sessionOpen
                excludeFromCapture: true
                exclusionMode: ExclusionMode.Ignore
                WlrLayershell.layer: WlrLayer.Overlay
                WlrLayershell.keyboardFocus: acceptsInput ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
                mask: acceptsInput ? null : empty

                anchors.top: true
                anchors.bottom: true
                anchors.left: true
                anchors.right: true

                Region {
                    id: empty
                }

                Picker {
                    owner: root
                    screen: win.modelData
                    sessionOpen: win.sessionOpen
                }
            }
        }
    }

    RecordingOverlay {
        interactionEnabled: root.interactionEnabled
        recorder: root.recorder
    }
}
