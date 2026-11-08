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
// mask is only the stack of previews, so every other press passes through to
// the desktop. Up to five previews stack upward from the bottom right corner
// with the newest at the bottom, and a sixth pushes out the oldest.
//
// Files. A capture that was saved is shown from its file. A capture that was
// only copied is shown from a preview file in the OS temp directory, made by
// copying the picker's hand-over file before the picker deletes it. That file
// has the same exact-path scheme as the hand-over files (CUtils.newCaptureTempPath),
// belongs to the preview alone and is deleted when the preview goes away.
// A crash can leave one caelestia-clipboard-*.png behind, as it can for the
// picker.
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
        return add(info, path, "", true);
    }

    // `source` is the picker's hand-over file, which the picker deletes right
    // after the clipboard call. The preview keeps its own copy.
    function addCopy(info: var, source: string): bool {
        if (!canAdd(info))
            return false;
        const temp = CUtils.newCaptureTempPath().split("\\").join("/");
        if (!temp)
            return false;
        if (!CUtils.copyFile(FileUrls.fromLocalPath(source), FileUrls.fromLocalPath(temp), true)) {
            CUtils.removeCaptureTemp(temp);
            return false;
        }
        if (add(info, temp, temp, false))
            return true;
        CUtils.removeCaptureTemp(temp);
        return false;
    }

    function canAdd(info: var): bool {
        return interactionEnabled && enabled && !!info && Array.from(screenList).some(screen => screen.name === info.screen);
    }

    function add(info: var, path: string, temp: string, saved: bool): bool {
        if (!canAdd(info) || !path)
            return false;
        // Each screen keeps its own stack. The oldest preview of this screen goes
        // when it already holds five.
        const doomed = Logic.evictions(entries.map(entry => entry.screen), info.screen, Logic.MAX_PREVIEWS).map(index => entries[index]);
        const entry = entryComponent.createObject(root, {
            serial: ++lastId,
            screen: info.screen,
            path: path,
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
    // no temp path, so a file the user keeps is never touched. A viewer may still
    // hold the file open, in which case the path stays for the next attempt.
    function release(entry: var): void {
        if (!entry.temp)
            return;
        CUtils.removeCaptureTemp(entry.temp);
        if (!WindowsFiles.isFile(entry.temp))
            entry.temp = "";
    }

    function copyEntry(entry: var): bool {
        if (clipboard.copyImageFile(entry.path))
            return true;
        Toaster.toast(Tr.tr("Screenshot failed"), Tr.tr("The image could not be copied."), "screenshot_region", Toast.Error);
        return false;
    }

    // Writes a copy-only capture to the screenshots folder with the picker's
    // naming, and then shows that file. Returns whether the capture is saved.
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
        release(entry);
        Toaster.toast(Tr.tr("Screenshot taken"), Tr.tr("Saved to %1").arg(dest), "screenshot_region");
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
        for (const entry of entries)
            release(entry);
    }

    Component {
        id: entryComponent

        QtObject {
            required property int serial
            required property string screen
            property string path
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
            readonly property var bounds: Logic.stackBounds(rects)

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
            // Presses outside the stack reach the windows below.
            mask: Region {
                item: stackBox
            }

            anchors.top: true
            anchors.bottom: true
            anchors.left: true
            anchors.right: true

            Item {
                id: stackBox

                objectName: "captureThumbnailStack"
                x: win.bounds ? win.bounds.x : 0
                y: win.bounds ? win.bounds.y : 0
                width: win.bounds ? win.bounds.width : 0
                height: win.bounds ? win.bounds.height : 0
            }

            Repeater {
                model: ScriptModel {
                    values: win.stack
                }

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
