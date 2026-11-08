pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Windows as Native
import Caelestia
import Caelestia.I18n
import qs.components.filedialog
import qs.services
import qs.utils

// Windows adaptation: the "Add wallpaper…" picker for the scanned wallpaper
// folder.
//
// The dialog lives in a singleton instead of inside the picker that pressed
// the button. A native dialog takes foreground focus, and the launcher closes
// when it loses focus; a dialog owned by the launcher content would be
// destroyed before its accepted() arrived. The existing desktop wallpaper
// picker and the dashboard profile-picture picker use the same pattern.
//
// The file operations are properties so offscreen fixtures can replace them
// instead of opening a dialog or touching a user file.
Singleton {
    id: root

    // Image types the Windows folder scan lists. Anything else would be copied
    // but never appear in the picker.
    readonly property var imageFilters: ["png", "jpg", "jpeg", "bmp", "webp"]
    // Windows forbids these characters in a file name. The picker only returns
    // real files, so this rejects a malformed or hand-built URL rather than
    // writing outside the scanned folder.
    readonly property var invalidNameCharacters: /[<>:"/\\|?*\u0000-\u001f]/
    readonly property var reservedNames: /^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\..*)?$/i

    property var makeFolder: path => Native.FsUtils.makePath(String(path))
    property var fileExists: path => Native.FsUtils.classify(String(path)) !== "invalid"
    property var copyFile: (source, target) => CUtils.copyFile(source, Paths.absolutePath(String(target)), false)
    property var notify: (message, icon) => Toaster.toast(Tr.tr("Wallpapers"), message, icon || "error")
    property var reloadWallpapers: () => Wallpapers.reload()
    property var chooseAndAdd: () => dialog.open()

    function wallpaperName(selected): string {
        const value = String(selected ?? "");
        if (value.length === 0)
            return "";
        const segment = value.substring(value.lastIndexOf("/") + 1).replace(/\\/g, "/").split("/").pop();
        if (segment.length === 0)
            return "";
        try {
            return decodeURIComponent(segment);
        } catch (error) {
            return segment;
        }
    }

    function supportedWallpaper(name): bool {
        const dot = name.lastIndexOf(".");
        if (dot <= 0 || dot === name.length - 1)
            return false;
        return root.imageFilters.indexOf(name.substring(dot + 1).toLowerCase()) >= 0;
    }

    function validWallpaperName(name): bool {
        return name.length > 0 && name !== "." && name !== ".." && name.indexOf("\u0000") < 0
            && !root.invalidNameCharacters.test(name) && !root.reservedNames.test(name);
    }

    function uniqueTarget(name): string {
        const dot = name.lastIndexOf(".");
        const base = dot > 0 ? name.substring(0, dot) : name;
        const suffix = dot > 0 ? name.substring(dot) : "";
        let candidate = Paths.joinPath(Paths.wallsdir, name);
        for (let copy = 2; root.fileExists(candidate); copy++)
            candidate = Paths.joinPath(Paths.wallsdir, `${base} (${copy})${suffix}`);
        return candidate;
    }

    // Copies an image into the scanned folder. Returns the new path, or "" when
    // nothing was added. An existing file is never replaced: the target gets a
    // numbered suffix, and the copy itself is non-overwriting.
    function addWallpaper(selected): string {
        const name = root.wallpaperName(selected);
        if (!root.validWallpaperName(name)) {
            root.notify(Tr.tr("That file name cannot be used for a wallpaper"));
            return "";
        }
        if (!root.supportedWallpaper(name)) {
            root.notify(Tr.tr("Only PNG, JPEG, BMP and WebP images can be added"));
            return "";
        }
        if (!root.makeFolder(Paths.wallsdir)) {
            root.notify(Tr.tr("Could not create the wallpapers folder"));
            return "";
        }
        const target = root.uniqueTarget(name);
        if (!root.copyFile(String(selected), target)) {
            root.notify(Tr.tr("Could not add that image to the wallpapers folder"));
            return "";
        }
        // The facade does not watch the folder, so refresh it explicitly. The
        // scan is asynchronous; the picker updates through Wallpapers.list.
        root.reloadWallpapers();
        root.notify(Tr.tr("Added %1 to the wallpapers folder").arg(name), "wallpaper");
        return target;
    }

    FileDialog {
        id: dialog

        title: Tr.tr("Add a wallpaper")
        filterLabel: Tr.tr("Image files")
        filters: root.imageFilters
        // Accepted is parameterless on the Windows adapter; read selectedFile.
        onAccepted: {
            if (!selectedFile || String(selectedFile).length === 0)
                return;
            root.addWallpaper(selectedFile);
        }
    }
}
