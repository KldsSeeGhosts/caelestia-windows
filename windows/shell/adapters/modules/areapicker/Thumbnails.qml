pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls as Controls
import Quickshell
import Quickshell.Wayland
import Quickshell.Windows as Native
import Caelestia
import Caelestia.Config
import Caelestia.I18n
import Caelestia.Windows
import qs.components.containers
import qs.services
import qs.utils
import "CaptureLogic.js" as Capture
import "ThumbnailLogic.js" as Logic
import "../../utils/FileUrls.js" as FileUrls

// The post-capture thumbnail of the QML screenshot picker (windows.capture.ui =
// "shell"). AreaPicker hands it each finished capture. The classic capture tool
// has its own thumbnail and never reaches this file.
//
// One overlay panel per screen that has previews. The panel covers the screen's
// work area, is excluded from capture and takes no keyboard focus. Its input
// mask is one region per card, following the card's drawn position, so every
// other press (including the gaps between cards) passes through to the desktop.
// Up to five previews exist in total, as in the classic tool. Each screen stacks
// its own from the bottom right corner with the newest at the bottom, and a
// sixth preview anywhere pushes out the oldest.
//
// Files. Quick Capture can show a bounded memory preview while its PNG is
// being written. Other cards show their saved or temporary file. The temp file
// has the same exact-path scheme as the hand-over files (CUtils.newCaptureTempPath),
// belongs to the preview alone and is deleted when the preview goes away. If a
// viewer holds it open, its path goes on a retry list owned by this scope and
// is tried again on a timer and at the next capture. A shell reload drops that
// list, and a crash can leave one caelestia-clipboard-*.png behind, as it can
// for the picker.
//
// Drag files. A saved capture is dragged from its saved file. A copy-only capture
// is dragged from a file of its own, made on its first drag in a directory of its
// own, <temp>\caelestia-drag-<uuid>\<screenshot name>.png (CUtils.newDragFile),
// so the target sees a normal name. It is a copy of the preview file; the card and
// the screenshots folder are untouched. The drag outlives the call: a target may
// record the path at drop and open the file later. So the file stays until both
// hold: its card has closed, and `dragGraceMs` (5 minutes) have passed since its
// last drag ended. This scope keeps the exact paths it made in memory and removes
// a due file with CUtils.removeDragFile, on a timer and at every new capture.
// A clean shutdown or reload removes what is left (Component.onDestruction and
// the application's aboutToQuit). A crash can leave a caelestia-drag-<uuid>
// directory with one file in it, as it can leave a hand-over file. So can a
// teardown while a target still holds the file open: teardown cannot block, and
// the retry list dies with this scope. That is an accepted gap, and there is no
// bulk cleanup of unknown caelestia-drag-* directories.
Scope {
    id: root

    // The production host turns this off during smoke.
    property bool interactionEnabled: true
    // Where Save writes: <saveRoot>/Screenshots, or <saveRoot> itself when that
    // folder cannot be created. The picker uses the same rule. Fixtures redirect it.
    property string saveRoot: Paths.pictures
    property var screenList: Screens.screens
    // Needs a local file path. Fixtures replace it with a recorder.
    property var clipboard: Native.ClipboardWriter
    // Windows clipboard history, injectable so fixtures never touch WinRT.
    property var clipboardHistory: ClipboardHistory
    property int copyTimeout: 10000
    // Clipboard History learns about a successful write asynchronously. Writes
    // are correlated only with a changed top image inside this bounded window.
    property int clipboardCorrelationMs: 1500
    property var clipboardWrites: ({})
    property var clipboardCorrelations: []
    // Opens a file or folder URL with the default application. Fixtures replace
    // it with a recorder so that no test starts a program.
    property var openUrl: url => Qt.openUrlExternally(url)
    // Runs the system drag of an image file, offering the file and the image for
    // copy only, and returns once the drag has ended. It gets the file's path and
    // the Item that draws the image, for the drag picture. It returns false when
    // no drag could start. Fixtures replace it with a recorder so that no test
    // starts a real drag.
    property var startDrag: (path, item) => CUtils.startImageDrag(path, item)
    // How far, in device pixels, a press has to move before it becomes a drag:
    // { width, height }. Fixtures replace it.
    property var dragDistance: () => CUtils.dragDistance()
    property var entries: []
    // Retain the file reservation if a card goes away before PNG encoding ends.
    readonly property var pendingCaptures: new Map()
    property var pins: []
    property int lastId
    property int detachedCopy
    // Preview files that could not be deleted yet (a viewer holds them open).
    // Not saved anywhere: a shell reload forgets them.
    property var pendingTemps: []
    property int pendingLimit: 20
    // How many paths were dropped from a full list.
    property int droppedCount
    property int retryInterval: 30000
    // The files made for dragging copy-only captures, newest last. Each is
    // { path, closed, endedAt }: its exact path, whether its card has closed, and
    // when its last drag ended (clock() milliseconds). Not saved anywhere.
    property var dragFiles: []
    // How long a drag file outlives its card and its last drag.
    property int dragGraceMs: 300000
    // How often due drag files are looked for while some card has closed.
    property int dragSweepInterval: 30000
    // The time source for the grace period. Fixtures replace it.
    property var clock: () => Date.now()

    readonly property var settings: Logic.settings(GlobalConfig.windows?.capture)
    readonly property var appearance: Logic.appearance(GlobalConfig.windows?.capture)
    readonly property bool enabled: settings.enabled
    readonly property int seconds: settings.seconds
    // Cards never draw or accept input over the picker. A reopened editor uses
    // an existing PNG, so its thumbnail panel can remain mapped and render a
    // transparent frame instead of re-showing the old contents on return.
    readonly property bool suspended: CaptureUi.picker?.opened ?? false
    readonly property bool editingCapture: suspended && !!CaptureUi.picker?.editPath
    readonly property bool showExportPath: !!CaptureUi.picker?.history
    // The panel windows, one per screen that has previews.
    readonly property var windows: panels.instances
    readonly property var activeScreens: Array.from(screenList).filter(screen => entries.some(entry => entry.screen === screen.name))

    // `info` is { screen, width, height, dpr }: the screen name, the saved image
    // size in physical pixels and the screen's device pixel ratio.
    // Each function returns whether a preview was added.
    function addSaved(info: var, path: string, historyId = "", editorSerial = -1): bool {
        retryTemps();
        sweepDragFiles();
        return add(info, path, "", true, false, historyId, editorSerial);
    }

    // Takes ownership of the picker's staged PNG, but only on success.
    function addCapture(info: var, path: string, historyId = "", editorSerial = -1): bool {
        retryTemps();
        sweepDragFiles();
        return add(info, path, path, false, false, historyId, editorSerial);
    }

    // `source` is the picker's pending preview after confirmed clipboard
    // success. The thumbnail keeps its own copy before the picker deletes it.
    function addCopy(info: var, source: string, historyId = "", editorSerial = -1): bool {
        retryTemps();
        sweepDragFiles();
        if (!canAdd(info))
            return false;
        const temp = CUtils.newCaptureTempPath().split("\\").join("/");
        if (!temp)
            return false;
        if (!CUtils.copyFile(FileUrls.fromLocalPath(source), FileUrls.fromLocalPath(temp), true)) {
            deleteTemp(temp);
            return false;
        }
        if (add(info, temp, temp, false, true, historyId, editorSerial))
            return true;
        deleteTemp(temp);
        return false;
    }

    function canAdd(info: var): bool {
        return interactionEnabled && enabled && !!info && Array.from(screenList).some(screen => screen.name === info.screen);
    }

    function previewBounds(info: var): size {
        const screen = Array.from(screenList).find(screen => screen.name === info.screen);
        const scale = (screen?.devicePixelRatio || info.dpr || 1) * appearance.scale;
        const width = Logic.WIDTH * scale;
        const height = Logic.HEIGHT * scale;
        if (!appearance.cover || !info.width || !info.height)
            return Qt.size(Math.ceil(width), Math.ceil(height));
        // A landscape snip needs more pixels than the box's width to fill its
        // height without upscaling (and vice versa for portrait snips).
        const factor = Math.min(1, 768 / Math.max(info.width, info.height),
            Math.max(width / info.width, height / info.height));
        return Qt.size(Math.max(1, Math.ceil(info.width * factor)), Math.max(1, Math.ceil(info.height * factor)));
    }

    function addPendingCapture(info: var, path: string, preview: url, releasedAt: double): var {
        if (!add(info, path, path, false, false, "", -1, preview, releasedAt))
            return null;
        const entry = entries[entries.length - 1];
        pendingCaptures.set(path, entry);
        return entry;
    }

    function completePendingCapture(path: string, ok: bool): bool {
        const entry = pendingCaptures.get(path);
        if (!entry)
            return false;
        pendingCaptures.delete(path);
        entry.outputPending = false;
        if (!ok) {
            entry.afterReveal = null;
            if (entries.includes(entry))
                finish(entry);
            else
                discard(entry);
            Toaster.toast(Tr.tr("Screenshot failed"), Tr.tr("The image could not be saved."), "screenshot_region", Toast.Error);
            return true;
        }
        logCaptureTiming(entry, "png");
        if (!entries.includes(entry))
            discard(entry);
        else if (entry.previewPresented)
            finishDeferredCapture(entry);
        return true;
    }

    function logCaptureTiming(entry: var, phase: string): void {
        if (!entry.captureReleasedAt)
            return;
        const elapsed = Math.max(0, Date.now() - entry.captureReleasedAt);
        console.log(`CAELESTIA_CAPTURE_HANDOFF id=${entry.serial} phase=${phase} ms=${elapsed} width=${entry.imageWidth} height=${entry.imageHeight} preview=${entry.previewPipeline}`);
    }

    function add(info: var, path: string, temp: string, saved: bool, copied: bool, historyId: string, editorSerial: int, preview = "", releasedAt = 0): bool {
        if (!canAdd(info) || !path)
            return false;
        // -1 means a new capture, and 0 means the editor was opened from
        // history without a card. Otherwise replace its card in a single
        // update, so the stack never grows and collapses during the handoff.
        const previous = entries.find(entry => entry.serial === editorSerial && !entry.dragging);
        const entry = entryComponent.createObject(root, {
            serial: ++lastId,
            screen: info.screen,
            path: path,
            imagePath: path,
            temp: temp,
            saved: saved,
            copied: copied,
            historyId: historyId,
            memorySource: preview,
            previewPipeline: String(preview) ? "memory" : "file",
            outputPending: !!String(preview),
            captureReleasedAt: releasedAt,
            fromEditor: editorSerial >= 0,
            imageWidth: info.width ?? 0,
            imageHeight: info.height ?? 0,
            dpr: info.dpr > 0 ? info.dpr : 1
        });
        if (!entry)
            return false;
        if (previous) {
            // A replacement represents the same capture while an edit is saved
            // or copied. Keep its clipboard identity until a successful edited
            // copy supersedes it.
            if (!entry.clipboardHistoryId)
                entry.clipboardHistoryId = previous.clipboardHistoryId;
            if (!entry.replaceClipboardId)
                entry.replaceClipboardId = previous.replaceClipboardId;
        }
        if (previous?.screen === info.screen) {
            entries = entries.map(other => other === previous ? entry : other);
        } else {
            // Capacity is global. A card being dragged is not evicted, but
            // still counts against the limit.
            const remaining = previous ? entries.filter(other => other !== previous) : entries;
            const idle = remaining.filter(other => !other.dragging);
            const busy = remaining.length - idle.length;
            const doomed = appearance.stack ? Logic.evictions(idle.map(other => other.screen), Logic.MAX_PREVIEWS - busy).map(index => idle[index]) : idle;
            entries = remaining.filter(other => !doomed.includes(other)).concat([entry]);
            for (const old of doomed)
                discard(old);
        }
        if (previous)
            discard(previous);
        return true;
    }

    function finishCapture(info: var, path: string, historyId: string, mode: string): var {
        const saving = mode === "save" || mode === "save-and-copy" || mode === "save-and-copy-path";
        const copyImage = mode === "copy" || mode === "save-and-copy";
        const saved = saving ? saveExport(path, saveRoot) : "";
        if (saving)
            announceSave(saved);
        const shown = saved ? addSaved(info, saved, historyId) : addCapture(info, path, historyId);
        const card = shown ? entries[entries.length - 1] : null;
        let copied = false;
        if (copyImage) {
            if (card) {
                copyEntry(card);
                copied = !!card.copyOperation;
            } else {
                copied = copyOutput(saved || path);
            }
        } else if (saved && mode === "save-and-copy-path") {
            detachedCopy = clipboard.copyText(saved.replace(/\//g, "\\"));
        }
        return { accepted: shown || !!saved || copied, transferred: shown && !saved,
            path: saved || (shown ? path : ""), saved: !!saved, serial: card?.serial ?? 0 };
    }

    function copyOutput(path: string): bool {
        const token = clipboardToken();
        detachedCopy = clipboard.copyImageFile(path);
        if (detachedCopy > 0)
            registerClipboardWrite(detachedCopy, null, ({ token }));
        return detachedCopy > 0;
    }

    function clipboardItems(): var {
        const items = clipboardHistory?.items;
        if (!items)
            return [];
        return Array.isArray(items) ? items : Array.from(items);
    }

    function topClipboardImage(): var {
        const items = clipboardItems();
        if (!items.length)
            return null;
        const top = items[0];
        const kind = String(top?.kind ?? top?.type ?? "");
        return kind === "image" && String(top?.id ?? "") ? top : null;
    }

    function clipboardToken(): var {
        const known = ({});
        for (const item of clipboardItems()) {
            const id = String(item?.id ?? "");
            if (id)
                known[id] = true;
        }
        return { knownIds: known, previousTop: String(topClipboardImage()?.id ?? ""), started: Date.now() };
    }

    function removeClipboardItem(id: string): void {
        if (id && clipboardHistory?.remove)
            clipboardHistory.remove(id);
    }

    function entryForSerial(serial: int): var {
        return serial > 0 ? entries.find(entry => entry.serial === serial) ?? null : null;
    }

    // Records one clipboard operation before it starts. The record lives apart
    // from the card so an explicit discard can still remove a history item that
    // appears after the card object has been retired.
    function registerClipboardWrite(operation: int, entry: var, options = ({})): void {
        if (operation <= 0)
            return;
        const write = {
            operation: operation,
            token: options.token ?? clipboardToken(),
            serial: entry?.serial ?? 0,
            discardOnSuccess: false,
            replaceClipboardId: String(options.replaceClipboardId ?? ""),
            onCorrelated: options.onCorrelated ?? null
        };
        const writes = Object.assign({}, clipboardWrites);
        writes[operation] = write;
        clipboardWrites = writes;
    }

    // Picker-managed copies learn their replacement card's serial only after the
    // write has already started. Keep the live write record in step so discard
    // before correlation can still match that card.
    function updateClipboardWriteSerial(operation: int, serial: int): void {
        if (operation <= 0 || serial <= 0)
            return;
        const current = clipboardWrites[operation];
        if (current && current.serial !== serial) {
            const writes = Object.assign({}, clipboardWrites);
            writes[operation] = Object.assign({}, current, { serial: serial });
            clipboardWrites = writes;
        }
        let changed = false;
        const correlations = clipboardCorrelations.map(write => {
            if (write.operation !== operation || write.serial === serial)
                return write;
            changed = true;
            return Object.assign({}, write, { serial: serial });
        });
        if (changed)
            clipboardCorrelations = correlations;
    }

    function completeClipboardWrite(operation: int, ok: bool): var {
        const write = clipboardWrites[operation];
        if (!write)
            return null;
        const writes = Object.assign({}, clipboardWrites);
        delete writes[operation];
        clipboardWrites = writes;
        if (!ok)
            return write;
        if (write.replaceClipboardId) {
            removeClipboardItem(write.replaceClipboardId);
            const entry = entryForSerial(write.serial);
            if (entry?.clipboardHistoryId === write.replaceClipboardId)
                entry.clipboardHistoryId = "";
            if (entry?.replaceClipboardId === write.replaceClipboardId)
                entry.replaceClipboardId = "";
        }
        if (clipboardHistory?.retain) {
            clipboardHistory.retain();
            write.retained = true;
        }
        write.token.started = Date.now();
        clipboardCorrelations = clipboardCorrelations.concat([write]);
        Qt.callLater(processClipboardCorrelations);
        return write;
    }

    function releaseClipboardCorrelation(write: var): void {
        if (!write?.retained)
            return;
        write.retained = false;
        clipboardHistory?.release?.();
    }

    function markClipboardDiscard(entry: var): void {
        const operation = entry.copyOperation;
        if (operation && clipboardWrites[operation]) {
            const writes = Object.assign({}, clipboardWrites);
            writes[operation] = Object.assign({}, writes[operation], { discardOnSuccess: true });
            clipboardWrites = writes;
        }
        let changed = false;
        const pending = clipboardCorrelations.map(write => {
            if (write.serial !== entry.serial || write.discardOnSuccess)
                return write;
            changed = true;
            return Object.assign({}, write, { discardOnSuccess: true });
        });
        if (changed)
            clipboardCorrelations = pending;
    }

    function processClipboardCorrelations(): void {
        if (!clipboardCorrelations.length)
            return;
        const now = Date.now();
        const remaining = [];
        const claimed = ({});
        for (const write of clipboardCorrelations) {
            const top = topClipboardImage();
            const id = String(top?.id ?? "");
            const isNewOrPromoted = id && (!write.token.knownIds[id] || write.token.previousTop !== id);
            // Windows timestamps the clipboard update itself, while the token is
            // stamped when its write completion reaches the shell. A newer top
            // item belongs to a later unrelated copy and must not be claimed for
            // this write. The margin covers Windows' asynchronous history ingestion;
            // items without a timestamp keep the older ID heuristic.
            const stamp = Date.parse(String(top?.timestamp ?? ""));
            const newerThanWrite = Number.isFinite(stamp) && stamp > write.token.started + 1000;
            if (id && !claimed[id] && isNewOrPromoted && !newerThanWrite) {
                claimed[id] = true;
                const entry = entryForSerial(write.serial);
                if (write.discardOnSuccess || entry?.explicitlyDiscarded) {
                    removeClipboardItem(id);
                } else {
                    if (entry)
                        entry.clipboardHistoryId = id;
                    if (write.onCorrelated)
                        write.onCorrelated(id);
                }
                releaseClipboardCorrelation(write);
            } else if (now - write.token.started < clipboardCorrelationMs) {
                remaining.push(write);
            } else {
                releaseClipboardCorrelation(write);
            }
        }
        clipboardCorrelations = remaining;
    }

    // The X button is an explicit discard: unlike a passive dismissal it cancels
    // a deferred capture, removes saved history and removes the tracked Windows
    // clipboard-history item. A copy still in flight is marked here and its late
    // correlation removes the edited image when Windows publishes it.
    function discardEntry(entry: var): void {
        if (!entry)
            return;
        entry.explicitlyDiscarded = true;
        entry.afterReveal = null;
        markClipboardDiscard(entry);
        if (entry.historyId)
            CaptureUi.picker?.history?.removeEntry(entry.historyId);
        if (entry.clipboardHistoryId)
            removeClipboardItem(entry.clipboardHistoryId);
        close(entry);
    }

    // Starts the exit animation. The card calls finish() when it is done. A
    // preview that is being dragged stays as it is, because the target may still
    // be reading its file, and closes as soon as the drag has ended.
    function close(entry: var): void {
        entry.copyOperation = 0;
        if (entry.dragging) {
            entry.closeAfterDrag = true;
            return;
        }
        entry.closing = true;
    }

    function closeAll(): void {
        for (const entry of entries)
            close(entry);
    }

    // Removes a preview and its temporary file at once. A preview that is being
    // dragged is removed when the drag ends (see drag()).
    function finish(entry: var): void {
        if (!entries.includes(entry))
            return;
        if (entry.dragging) {
            entry.closeAfterDrag = true;
            return;
        }
        entries = entries.filter(other => other !== entry);
        discard(entry);
    }

    function discard(entry: var): void {
        releaseMemoryPreview(entry);
        if (entry.outputPending)
            return;
        finishDeferredCapture(entry);
        release(entry);
        // The card is gone. Its drag file, if it made one, now only waits out the
        // grace period since its last drag.
        const record = dragRecord(entry.dragFile);
        if (record) {
            record.closed = true;
            dragFiles = dragFiles.slice();
            sweepDragFiles();
        }
        entry.destroy();
    }

    function releaseMemoryPreview(entry: var): void {
        const url = entry.memorySource;
        if (!url.toString())
            return;
        // The card is leaving. Keep the stale URL on the retiring delegate so
        // its Image never switches to a not-yet-written file.
        CUtils.releaseCapturePreview(url);
    }

    function finishDeferredCapture(entry: var): void {
        if (entry?.outputPending)
            return;
        const complete = entry?.afterReveal;
        if (!complete)
            return;
        entry.afterReveal = null;
        complete();
    }

    function dragRecord(path: string): var {
        return path ? dragFiles.find(record => record.path === path) ?? null : null;
    }

    // Removes one drag file and its directory. True when the directory is gone.
    // The plugin refuses everything that is not exactly such a file.
    function removeDragFile(path: string): bool {
        return CUtils.removeDragFile(path);
    }

    // Removes the drag files that are due: the card has closed and the last drag
    // ended `dragGraceMs` ago or earlier. A file that cannot be removed yet (a
    // target holds it open) stays and is tried again by the next sweep.
    function sweepDragFiles(): void {
        if (dragFiles.length === 0)
            return;
        const at = clock();
        const left = dragFiles.filter(record => !(record.closed && at - record.endedAt >= dragGraceMs && removeDragFile(record.path)));
        if (left.length !== dragFiles.length)
            dragFiles = left;
    }

    // Removes every drag file at once, whatever its age. A shutdown does this.
    function removeAllDragFiles(): void {
        if (dragFiles.length === 0)
            return;
        dragFiles = dragFiles.filter(record => !removeDragFile(record.path));
    }

    // The file that a drag of this preview offers. A saved capture offers its
    // saved file. A copy-only capture offers a file of its own, with a normal
    // screenshot name, made on the first drag and offered again by later drags for
    // as long as it exists. Returns "" when none can be made.
    function dragSource(entry: var): string {
        if (entry.saved)
            return entry.path;
        const known = dragRecord(entry.dragFile);
        if (known && WindowsFiles.isFile(known.path))
            return known.path;
        if (known) {
            // Someone deleted the file. Drop the record and its empty directory.
            removeDragFile(known.path);
            dragFiles = dragFiles.filter(record => record !== known);
            entry.dragFile = "";
        }
        const path = CUtils.newDragFile(Capture.fileStem(new Date(), "") + ".png").split("\\").join("/");
        if (!path)
            return "";
        if (!CUtils.copyFile(FileUrls.fromLocalPath(entry.path), FileUrls.fromLocalPath(path), true)) {
            removeDragFile(path);
            return "";
        }
        dragFiles = dragFiles.concat([{ path: path, closed: false, endedAt: clock() }]);
        entry.dragFile = path;
        return path;
    }

    // Deletes the entry's own preview file. Only an exact capture temp path is
    // ever removed (the plugin refuses everything else), and a saved capture has
    // no temp path, so a file the user keeps is never touched.
    // A file a live card is showing is never released: Save points the card at the
    // saved file first, and a discarded entry has left `entries` before this runs.
    // So a path on the retry list is never one that a card could reload.
    function release(entry: var): void {
        if (!entry.temp || isShown(entry.temp))
            return;
        const path = entry.temp;
        entry.temp = "";
        deleteTemp(path);
    }

    // Whether a live card draws this file.
    function isShown(path: string): bool {
        return entries.some(entry => entry.imagePath === path);
    }

    // Deletes one preview file. A viewer can hold it open without delete sharing,
    // so a file that is still there is put on the retry list, which this scope
    // owns and which outlives the entry. The list holds at most `pendingLimit`
    // paths. When it is full the oldest path is dropped and logged once. That
    // file stays in the temp directory, as one left by a crash does.
    function deleteTemp(path: string): void {
        if (tryRemove(path) || pendingTemps.includes(path))
            return;
        const list = pendingTemps.concat([path]);
        while (list.length > pendingLimit) {
            const dropped = list.shift();
            droppedCount++;
            console.warn("Thumbnail preview file left in the temp directory (retry list full):", dropped);
        }
        pendingTemps = list;
    }

    function tryRemove(path: string): bool {
        CUtils.removeCaptureTemp(path);
        return !WindowsFiles.isFile(path);
    }

    // Tries every file on the retry list again. It runs on a timer while the list
    // is not empty and whenever a new capture arrives. A shell reload drops the
    // list, so a file still locked at that moment stays in the temp directory.
    function retryTemps(): void {
        if (pendingTemps.length === 0)
            return;
        pendingTemps = pendingTemps.filter(path => !tryRemove(path));
    }

    function copyEntry(entry: var, dismiss = false, onCorrelated = null): void {
        if (!entries.includes(entry) || entry.closing || entry.outputPending)
            return;
        finishDeferredCapture(entry);
        if (entry.copyOperation) {
            if (dismiss)
                entry.dismissAfterCopy = true;
            return;
        }
        entry.copied = false;
        entry.dismissAfterCopy = dismiss;
        entry.copyStarted = Date.now();
        const token = clipboardToken();
        entry.copyOperation = clipboard.copyImageFile(entry.path);
        if (entry.copyOperation)
            registerClipboardWrite(entry.copyOperation, entry,
                ({ token, replaceClipboardId: entry.replaceClipboardId, onCorrelated }));
        else
            copyResult(entry, false);
    }

    function copyResult(entry: var, ok: bool): void {
        entry.copyOperation = 0;
        entry.copied = ok;
        if (!ok) {
            // Keep the card for retry/save instead of letting its timeout remove
            // the only remaining copy of an unsaved capture.
            entry.copyFailed = true;
            Toaster.toast(Tr.tr("Screenshot failed"), Tr.tr("The image could not be copied."), "screenshot_region", Toast.Error);
        } else {
            entry.copyFailed = false;
            if (entry.replaceClipboardId) {
                removeClipboardItem(entry.replaceClipboardId);
                if (entry.clipboardHistoryId === entry.replaceClipboardId)
                    entry.clipboardHistoryId = "";
                entry.replaceClipboardId = "";
            }
            if (entry.dismissAfterCopy)
                close(entry);
        }
        entry.dismissAfterCopy = false;
    }

    Connections {
        target: root.clipboard
        function onWriteFinished(id: int, ok: bool, error: string): void {
            const write = root.completeClipboardWrite(id, ok);
            if (id === root.detachedCopy && id > 0) {
                root.detachedCopy = 0;
                if (!ok)
                    Toaster.toast(Tr.tr("Screenshot failed"), Tr.tr("The clipboard could not be updated."), "screenshot_region", Toast.Error);
                return;
            }
            const entry = root.entries.find(item => item.copyOperation === id && !item.closing);
            if (entry && !write?.discardOnSuccess)
                root.copyResult(entry, ok);
            else if (entry)
                entry.copyOperation = 0;
        }
    }

    Timer {
        interval: 50
        repeat: true
        running: root.clipboardCorrelations.length > 0
        onTriggered: root.processClipboardCorrelations()
    }

    Timer {
        interval: Math.max(1, Math.min(root.copyTimeout, 250))
        repeat: true
        running: root.entries.some(entry => entry.copyOperation > 0)
        onTriggered: {
            for (const entry of root.entries) {
                if (entry.copyOperation && Date.now() - entry.copyStarted >= root.copyTimeout)
                    root.copyResult(entry, false);
            }
        }
    }

    // Writes a copy-only capture to the screenshots folder with the picker's
    // naming, and then shows that file. Returns whether the capture is saved.
    // The thumbnail is on screen, so there is no success toast.
    function saveEntry(entry: var, announce = false): bool {
        if (entry.outputPending)
            return false;
        finishDeferredCapture(entry);
        if (entry.saved) {
            if (announce)
                announceSave(entry.path);
            return true;
        }
        const dest = saveExport(entry.path, saveRoot);
        if (!dest) {
            Toaster.toast(Tr.tr("Screenshot failed"), Tr.tr("The image could not be saved."), "screenshot_region", Toast.Error);
            return false;
        }
        entry.path = dest;
        entry.saved = true;
        entry.copyFailed = false;
        // The card switches to the saved file first. Only then is the preview
        // file released, so it can never be deleted under a card that shows it.
        entry.imagePath = dest;
        release(entry);
        if (entry.historyId)
            CaptureUi.picker?.history?.markExported(entry.historyId, dest);
        if (announce)
            announceSave(dest);
        return true;
    }

    function saveExport(source: string, pictures: string): string {
        const configured = GlobalConfig.windows?.capture?.saveDirectory;
        if (typeof configured === "string" && configured.trim()) {
            const directory = configured.trim().replace(/\\/g, "/");
            return FileUrls.fromLocalPath(directory) ? saveInto(source, directory) : "";
        }
        return saveInto(source, pictures + "/Screenshots") || saveInto(source, pictures);
    }

    function announceSave(path: string): void {
        if (path)
            Toaster.toast(Tr.tr("Screenshot saved"), path.replace(/\//g, "\\"), "screenshot_region");
        else
            Toaster.toast(Tr.tr("Screenshot failed"), Tr.tr("Could not write to the screenshot folder."), "screenshot_region", Toast.Error);
    }

    function exportHistory(path: string): string {
        const saved = saveExport(path, saveRoot);
        announceSave(saved);
        return saved;
    }

    function saveInto(source: string, directory: string): string {
        if (!Native.FsUtils.makePath(directory))
            return "";
        const stem = Capture.fileStem(new Date(), "");
        const dest = Capture.uniquePath(directory, stem, candidate => WindowsFiles.isFile(candidate));
        return CUtils.copyFile(FileUrls.fromLocalPath(source), FileUrls.fromLocalPath(dest), false) ? dest : "";
    }

    // Opens the folder that holds the image. A capture that was only copied is
    // saved first, as the classic tool does.
    function reveal(entry: var): void {
        if (!saveEntry(entry, showExportPath))
            return;
        const folder = entry.path.replace(/\\/g, "/").replace(/\/[^\/]*$/, "");
        if (!openUrl(FileUrls.fromLocalPath(folder)))
            Toaster.toast(Tr.tr("Screenshot failed"), Tr.tr("The folder could not be opened."), "screenshot_region", Toast.Error);
    }

    function saveAs(entry: var): void {
        if (entry.outputPending)
            return;
        if (CaptureUi.picker?.history?.saveImageAs(entry.path, entry.historyId))
            close(entry);
    }

    // Open image in the context menu uses the default application.
    function open(entry: var): void {
        if (entry.outputPending)
            return;
        if (!openUrl(FileUrls.fromLocalPath(entry.path)))
            Toaster.toast(Tr.tr("Screenshot failed"), Tr.tr("The image could not be opened."), "screenshot_region", Toast.Error);
    }

    function edit(entry: var): void {
        if (!entries.includes(entry) || entry.closing || entry.dragging || entry.outputPending || suspended || !CaptureUi.picker)
            return;
        finishDeferredCapture(entry);
        const info = { screen: entry.screen, width: entry.imageWidth, height: entry.imageHeight, dpr: entry.dpr };
        if (!CaptureUi.picker.reopenCapture(entry.path, info, entry.serial, entry.historyId, entry.saved, entry.clipboardHistoryId))
            Toaster.toast(Tr.tr("Screenshot failed"), Tr.tr("The image could not be opened."), "screenshot_region", Toast.Error);
    }

    function pin(entry: var): void {
        if (!entries.includes(entry) || entry.closing || entry.dragging || entry.outputPending)
            return;
        const screen = Array.from(screenList).find(screen => screen.name === entry.screen);
        if (!screen)
            return;
        const path = CUtils.newCaptureTempPath().replace(/\\/g, "/");
        if (!path || !CUtils.copyFile(FileUrls.fromLocalPath(entry.path), FileUrls.fromLocalPath(path), true)) {
            if (path)
                deleteTemp(path);
            Toaster.toast(Tr.tr("Screenshot failed"), Tr.tr("The image could not be pinned."), "push_pin", Toast.Error);
            return;
        }
        const pin = { path, screen, width: entry.imageWidth, height: entry.imageHeight, dpr: entry.dpr };
        pins = pins.concat([pin]);
        while (pins.length > Logic.MAX_PREVIEWS)
            unpin(pins[0]);
        close(entry);
    }

    function unpin(pin: var): void {
        pins = pins.filter(other => other.path !== pin.path);
        deleteTemp(pin.path);
    }

    // The card body was pulled past the drag distance: drags the image out of the
    // shell. `item` is the Item that draws the image, for the drag picture. A
    // saved capture drags its saved file. A copy-only capture drags a file of its
    // own in the temp directory (see dragSource), made on its first drag, with a
    // normal screenshot name; the preview file the card draws is not offered. A
    // drag never saves a copy-only capture and writes nothing to the screenshots
    // folder. Returns whether a drag ran. Dropping nowhere or cancelling with Esc
    // is a drag that ran and changes nothing.
    // While the drag runs the preview cannot close, be pushed out or lose its
    // file. A close that arrives meanwhile happens when the drag has ended. After
    // that the drag file is kept for `dragGraceMs` more, because a target can open
    // the path after the drop (see the note at the top).
    function drag(entry: var, item: Item): bool {
        if (entry.dragging || entry.outputPending || !entries.includes(entry))
            return false;
        const file = WindowsFiles.isFile(entry.path) ? dragSource(entry) : "";
        if (!file) {
            Toaster.toast(Tr.tr("Screenshot failed"), Tr.tr("The image could not be dragged."), "screenshot_region", Toast.Error);
            return false;
        }
        let ran = false;
        entry.dragging = true;
        try {
            ran = startDrag(file, item) === true;
        } finally {
            // A shell reload destroys the preview while its drag runs.
            if (entries.includes(entry))
                entry.dragging = false;
            const record = dragRecord(file);
            if (record)
                record.endedAt = clock();
        }
        if (!entries.includes(entry))
            return ran;
        if (!ran)
            Toaster.toast(Tr.tr("Screenshot failed"), Tr.tr("The image could not be dragged."), "screenshot_region", Toast.Error);
        if (entry.closeAfterDrag) {
            entry.closeAfterDrag = false;
            // A preview whose screen went away during the drag has no panel to
            // run its exit.
            if (Array.from(screenList).some(screen => screen.name === entry.screen))
                close(entry);
            else
                finish(entry);
        }
        return ran;
    }

    // Turning the thumbnail off closes the ones on screen.
    onEnabledChanged: {
        if (!enabled)
            closeAll();
    }

    // A monitor was removed or its layout changed. Previews on a screen that is
    // gone have no panel to finish them.
    onScreenListChanged: {
        const names = Array.from(screenList).map(screen => screen.name);
        for (const entry of entries.slice()) {
            if (!names.includes(entry.screen))
                finish(entry);
        }
        for (const pin of pins.slice()) {
            if (!names.includes(pin.screen.name))
                unpin(pin);
        }
    }

    Component.onCompleted: CaptureUi.thumbnails = root
    // A shell reload destroys this scope. Every remaining preview file goes.
    Component.onDestruction: {
        if (CaptureUi.thumbnails === root)
            CaptureUi.thumbnails = null;
        // The cards go with this scope, so none of them shows a file any more.
        const gone = entries;
        entries = [];
        for (const entry of gone) {
            releaseMemoryPreview(entry);
            if (!entry.outputPending)
                release(entry);
        }
        for (const write of clipboardCorrelations)
            releaseClipboardCorrelation(write);
        clipboardCorrelations = [];
        // The native capture owns any unfinished file until completion.
        pendingCaptures.clear();
        for (const pin of pins)
            deleteTemp(pin.path);
        retryTemps();
        // Nothing is dragged any more, so no drag file has to wait.
        removeAllDragFiles();
    }

    // The application is quitting, which may not destroy this scope in order.
    Connections {
        target: Qt.application

        function onAboutToQuit(): void {
            root.removeAllDragFiles();
        }
    }

    readonly property alias retrying: retryTimer.running
    // Whether some drag file is waiting out its grace period.
    readonly property alias sweeping: dragTimer.running

    Timer {
        id: dragTimer

        interval: root.dragSweepInterval
        repeat: true
        running: root.dragFiles.some(record => record.closed)
        onTriggered: root.sweepDragFiles()
    }

    Timer {
        id: retryTimer

        interval: root.retryInterval
        repeat: true
        running: root.pendingTemps.length > 0
        onTriggered: root.retryTemps()
    }

    Component {
        id: entryComponent

        QtObject {
            id: captureEntry

            required property int serial
            required property string screen
            property string path
            // The file the card draws. It is `path` until Save moves the capture,
            // and it changes before the preview file is released.
            property string imagePath
            property url memorySource
            property string previewPipeline
            property bool outputPending
            property double captureReleasedAt
            property bool previewPresented
            // The preview file made for a copy-only capture, or "".
            property string temp
            // The file made for dragging this copy-only capture, or "". The
            // owner's dragFiles list tracks it and outlives the entry.
            property string dragFile
            property bool saved
            property string historyId
            // Windows clipboard history item for the image currently represented
            // by this card. replaceClipboardId is the unedited item superseded
            // by a copy that is still being written.
            property string clipboardHistoryId
            property string replaceClipboardId
            property bool explicitlyDiscarded
            property var afterReveal: null
            property bool fromEditor
            // An operation belongs to this entry, never to a replacement card.
            // Closing, completion and timeout clear it before accepting results.
            property int copyOperation
            property bool dismissAfterCopy
            property double copyStarted
            property bool copied
            // Keep a failed copy available until retry, save or explicit close.
            property bool copyFailed
            property int imageWidth
            property int imageHeight
            property real dpr: 1
            property bool closing
            // The system drag of this preview's file is running.
            property bool dragging
            // A close came in while it ran.
            property bool closeAfterDrag

            // If an overlay is hidden or the scene graph isn't presenting,
            // automatic output must still happen, and only once.
            property Timer revealDeadline: Timer {
                interval: 180
                running: !!captureEntry.afterReveal && !captureEntry.outputPending
                onTriggered: root.finishDeferredCapture(captureEntry)
            }
        }
    }

    Variants {
        model: root.pins

        StyledWindow {
            id: pinned

            required property var modelData
            readonly property real imageWidth: Math.max(1, modelData.width) / modelData.dpr
            readonly property real imageHeight: Math.max(1, modelData.height) / modelData.dpr
            readonly property real fit: Math.min(1, screen.width * 0.6 / imageWidth, screen.height * 0.6 / imageHeight)

            screen: modelData.screen
            name: "capture-pin"
            anchors { top: true; left: true }
            margins.left: Math.round((screen.width - implicitWidth) / 2)
            margins.top: Math.round((screen.height - implicitHeight) / 2)
            implicitWidth: Math.max(48, Math.round(imageWidth * fit))
            implicitHeight: Math.max(48, Math.round(imageHeight * fit))
            exclusionMode: ExclusionMode.Normal
            exclusiveZone: 0
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            excludeFromCapture: true
            visible: !root.suspended

            Image {
                anchors.fill: parent
                source: FileUrls.fromLocalPath(pinned.modelData.path)
                sourceSize: Qt.size(Math.ceil(pinned.width * pinned.screen.devicePixelRatio),
                    Math.ceil(pinned.height * pinned.screen.devicePixelRatio))
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                cache: false
            }

            MouseArea {
                id: move
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                property point origin
                property point start
                onPressed: mouse => {
                    origin = mapToGlobal(mouse.x, mouse.y);
                    start = Qt.point(pinned.margins.left, pinned.margins.top);
                }
                onPositionChanged: mouse => {
                    if (!pressed)
                        return;
                    const at = mapToGlobal(mouse.x, mouse.y);
                    pinned.margins.left = Math.max(0, Math.min(pinned.screen.width - pinned.width, Math.round(start.x + at.x - origin.x)));
                    pinned.margins.top = Math.max(0, Math.min(pinned.screen.height - pinned.height, Math.round(start.y + at.y - origin.y)));
                }
                onDoubleClicked: root.unpin(pinned.modelData)
            }

            Controls.ToolButton {
                anchors.top: parent.top
                anchors.right: parent.right
                visible: move.containsMouse || hovered
                text: "×"
                Accessible.name: Tr.tr("Unpin screenshot")
                onClicked: root.unpin(pinned.modelData)
            }
        }
    }

    Variants {
        id: panels

        model: root.activeScreens

        StyledWindow {
            id: win

            required property ShellScreen modelData

            readonly property var stack: root.entries.filter(entry => entry.screen === modelData.name)
            readonly property var area: ({ width: width, height: height })
            readonly property var size: Logic.previewSize(area, root.appearance.scale)
            readonly property var rects: Logic.stackRects(area, stack.length, size, root.appearance.corner)
            // The cards that exist, for the input mask.
            property var cardItems: []

            screen: modelData
            name: "capture-thumbnail"
            excludeFromCapture: true
            // No reserved space and no fixed size: anchored on every side, the
            // panel is exactly the work area, which the stack is placed in.
            exclusionMode: ExclusionMode.Normal
            exclusiveZone: 0
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            visible: !root.suspended || root.editingCapture
            // Only the cards take presses. One region per card, so the gaps
            // between cards and the rest of the work area reach the windows below.
            mask: Region {
                regions: maskRegions.instances
            }

            anchors.top: true
            anchors.bottom: true
            anchors.left: true
            anchors.right: true

            Variants {
                id: maskRegions

                model: win.cardItems

                // Each card's mask item follows the card's drawn rectangle,
                // including the slide, which a Region does not notice by itself.
                Region {
                    required property var modelData

                    item: modelData.maskItem
                }
            }

            Repeater {
                model: ScriptModel {
                    values: win.stack
                }

                onItemAdded: (index, item) => win.cardItems = win.cardItems.concat([item])
                onItemRemoved: (index, item) => win.cardItems = win.cardItems.filter(card => card !== item)

                ThumbnailCard {
                    required property var modelData

                    owner: root
                    entry: modelData
                    slot: win.rects[win.stack.indexOf(modelData)] ?? ({ x: 0, y: 0, width: 0, height: 0 })
                    present: win.visible && !root.suspended
                }
            }
        }
    }
}
