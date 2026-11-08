pragma ComponentBehavior: Bound

import QtQuick
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
// Files. A capture that was saved is shown from its file. A capture that was
// only copied is shown from a preview file in the OS temp directory, made by
// copying the picker's hand-over file before the picker deletes it. That file
// has the same exact-path scheme as the hand-over files (CUtils.newCaptureTempPath),
// belongs to the preview alone and is deleted when the preview goes away. If a
// viewer holds it open, its path goes on a retry list owned by this scope and
// is tried again on a timer and at the next capture. A shell reload drops that
// list, and a crash can leave one caelestia-clipboard-*.png behind, as it can
// for the picker.
Scope {
    id: root

    // The production host turns this off during smoke.
    property bool interactionEnabled: true
    // Where Save writes: <saveRoot>/Screenshots, or <saveRoot> itself when that
    // folder cannot be created. The picker uses the same rule. Fixtures redirect it.
    property string saveRoot: Paths.pictures
    property var screenList: Screens.screens
    // Needs a local file path. Fixtures replace it with a recorder.
    property var clipboard: Native.Clipboard
    // Opens a file or folder URL with the default application. Fixtures replace
    // it with a recorder so that no test starts a program.
    property var openUrl: url => Qt.openUrlExternally(url)
    property var entries: []
    property int lastId
    // Preview files that could not be deleted yet (a viewer holds them open).
    // Not saved anywhere: a shell reload forgets them.
    property var pendingTemps: []
    property int pendingLimit: 20
    // How many paths were dropped from a full list.
    property int droppedCount
    property int retryInterval: 30000

    readonly property var settings: Logic.settings(GlobalConfig.windows?.capture)
    readonly property bool enabled: settings.enabled
    readonly property int seconds: settings.seconds
    // While the picker is open the panels are hidden and their timeouts wait, so
    // a preview is never on top of a frozen screen it is not part of.
    readonly property bool suspended: CaptureUi.picker?.opened ?? false
    // The panel windows, one per screen that has previews.
    readonly property var windows: panels.instances
    readonly property var activeScreens: Array.from(screenList).filter(screen => entries.some(entry => entry.screen === screen.name))

    // `info` is { screen, width, height, dpr }: the screen name, the saved image
    // size in physical pixels and the screen's device pixel ratio.
    // Both functions return whether a preview was added.
    function addSaved(info: var, path: string): bool {
        retryTemps();
        return add(info, path, "", true);
    }

    // `source` is the picker's hand-over file, which the picker deletes right
    // after the clipboard call. The preview keeps its own copy.
    function addCopy(info: var, source: string): bool {
        retryTemps();
        if (!canAdd(info))
            return false;
        const temp = CUtils.newCaptureTempPath().split("\\").join("/");
        if (!temp)
            return false;
        if (!CUtils.copyFile(FileUrls.fromLocalPath(source), FileUrls.fromLocalPath(temp), true)) {
            deleteTemp(temp);
            return false;
        }
        if (add(info, temp, temp, false))
            return true;
        deleteTemp(temp);
        return false;
    }

    function canAdd(info: var): bool {
        return interactionEnabled && enabled && !!info && Array.from(screenList).some(screen => screen.name === info.screen);
    }

    function add(info: var, path: string, temp: string, saved: bool): bool {
        if (!canAdd(info) || !path)
            return false;
        // At most five previews exist in total, as in the classic tool. The oldest
        // goes first, on whichever screen it is. Each screen still lays out its
        // own previews.
        const doomed = Logic.evictions(entries.map(entry => entry.screen), Logic.MAX_PREVIEWS).map(index => entries[index]);
        const entry = entryComponent.createObject(root, {
            serial: ++lastId,
            screen: info.screen,
            path: path,
            imagePath: path,
            temp: temp,
            saved: saved,
            imageWidth: info.width ?? 0,
            imageHeight: info.height ?? 0,
            dpr: info.dpr > 0 ? info.dpr : 1
        });
        if (!entry)
            return false;
        entries = entries.filter(other => !doomed.includes(other)).concat([entry]);
        for (const old of doomed)
            discard(old);
        return true;
    }

    // Starts the exit animation. The card calls finish() when it is done.
    function close(entry: var): void {
        entry.closing = true;
    }

    function closeAll(): void {
        for (const entry of entries)
            close(entry);
    }

    // Removes a preview and its temporary file at once.
    function finish(entry: var): void {
        if (!entries.includes(entry))
            return;
        entries = entries.filter(other => other !== entry);
        discard(entry);
    }

    function discard(entry: var): void {
        release(entry);
        entry.destroy();
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

    function copyEntry(entry: var): bool {
        if (clipboard.copyImageFile(entry.path))
            return true;
        Toaster.toast(Tr.tr("Screenshot failed"), Tr.tr("The image could not be copied."), "screenshot_region", Toast.Error);
        return false;
    }

    // Writes a copy-only capture to the screenshots folder with the picker's
    // naming, and then shows that file. Returns whether the capture is saved.
    // The thumbnail is on screen, so there is no success toast.
    function saveEntry(entry: var): bool {
        if (entry.saved)
            return true;
        const dest = saveInto(entry.path, saveRoot + "/Screenshots") || saveInto(entry.path, saveRoot);
        if (!dest) {
            Toaster.toast(Tr.tr("Screenshot failed"), Tr.tr("The image could not be saved."), "screenshot_region", Toast.Error);
            return false;
        }
        entry.path = dest;
        entry.saved = true;
        // The card switches to the saved file first. Only then is the preview
        // file released, so it can never be deleted under a card that shows it.
        entry.imagePath = dest;
        release(entry);
        return true;
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
        if (!saveEntry(entry))
            return;
        const folder = entry.path.replace(/\\/g, "/").replace(/\/[^\/]*$/, "");
        if (!openUrl(FileUrls.fromLocalPath(folder)))
            Toaster.toast(Tr.tr("Screenshot failed"), Tr.tr("The folder could not be opened."), "screenshot_region", Toast.Error);
    }

    // The card body opens the image with the default application. The editor
    // does not exist yet; a later change reopens the capture there instead. An
    // image that was only copied opens from its preview file.
    function open(entry: var): void {
        if (!openUrl(FileUrls.fromLocalPath(entry.path)))
            Toaster.toast(Tr.tr("Screenshot failed"), Tr.tr("The image could not be opened."), "screenshot_region", Toast.Error);
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
    }

    Component.onCompleted: CaptureUi.thumbnails = root
    // A shell reload destroys this scope. Every remaining preview file goes.
    Component.onDestruction: {
        if (CaptureUi.thumbnails === root)
            CaptureUi.thumbnails = null;
        // The cards go with this scope, so none of them shows a file any more.
        const gone = entries;
        entries = [];
        for (const entry of gone)
            release(entry);
        retryTemps();
    }

    readonly property alias retrying: retryTimer.running

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
            required property int serial
            required property string screen
            property string path
            // The file the card draws. It is `path` until Save moves the capture,
            // and it changes before the preview file is released.
            property string imagePath
            // The preview file made for a copy-only capture, or "".
            property string temp
            property bool saved
            property int imageWidth
            property int imageHeight
            property real dpr: 1
            property bool closing
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
            readonly property var size: Logic.previewSize(area)
            readonly property var rects: Logic.stackRects(area, stack.length, size)
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
            visible: !root.suspended
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
                    present: win.visible
                }
            }
        }
    }
}
