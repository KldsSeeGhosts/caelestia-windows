pragma Singleton

import QtQuick
import QtQuick.Dialogs as NativeDialogs
import Quickshell
import Quickshell.Io
import Quickshell.Windows as Native
import Caelestia
import Caelestia.Config
import qs.services
import qs.utils

Singleton {
    id: root

    readonly property bool controlsEnabled: Quickshell.env("CAELESTIA_COMBINED_LIVE") === "1" && Quickshell.env("CAELESTIA_SHELL_SMOKE") !== "1"
    readonly property string fallback: Quickshell.shellPath("assets/wallpaper.webp")
    property string fileCurrent: Native.Wallpaper.currentWallpaper().replace(/\\/g, "/") || fallback
    readonly property string actualCurrent: WallpaperEngine.enabled && WallpaperEngine.running && WallpaperEngine.current?.path
        ? WallpaperEngine.current.path : fileCurrent
    // Image consumers (mode/variant generation and the desktop) need the
    // preview, while launcher selection needs the project.json identity.
    readonly property string currentImage: WallpaperEngine.enabled && WallpaperEngine.running && WallpaperEngine.current?.preview
        ? WallpaperEngine.current.preview : fileCurrent
    property bool showPreview: false
    property string previewPath
    readonly property string current: showPreview && !externalWallpaperActive ? previewPath : currentImage
    readonly property bool externalWallpaperActive: WallpaperEngine.ownsDesktop
    property var files: []
    // Nexus's Wallpaper & style pages (modules/nexus/pages/wallandstyle) group
    // entries by `parentDir` and label them by `name`, and the launcher carousel
    // uses `path`/`relativePath`. The native file scan and Wallpaper Engine
    // snapshot only carry paths, so every entry is normalized once here instead
    // of editing the upstream pages. Both sources are flat on Windows, so
    // `parentDir` is the wallpaper directory and `getCategoryFor` returns no
    // category; Nexus then lists them directly on the wallpaper page.
    function normalize(entry): var {
        if (!entry || typeof entry.path !== "string" || entry.path.length === 0)
            return null;
        const relative = String(entry.relativePath ?? entry.path).split(/[\\/]/).pop();
        return Object.assign({}, entry, {
            name: String(entry.name ?? relative),
            relativePath: String(entry.relativePath ?? relative),
            parentDir: String(entry.parentDir ?? Paths.wallsdir)
        });
    }
    readonly property var list: {
        const engine = WallpaperEngine.enabled && WallpaperEngine.detected ? WallpaperEngine.items : [];
        const raw = WallpaperEngine.picker === "engine" ? engine
            : WallpaperEngine.picker === "both" ? [...engine, ...files] : files;
        return raw.map(normalize).filter(entry => entry !== null);
    }
    property bool previewColourLock: false
    // Single owner of wallpaper-derived colours: Wallpaper Engine quitting or
    // relaunching, a Windows wallpaper change and the picker all move
    // currentImage. The bridge records the image each scheme was generated from
    // beside scheme.json, so comparing against it survives restarts and covers
    // every generation path (picker, mode and variant). The scheme name comes
    // from scheme.json too: referencing Colours here would close a singleton
    // cycle, because Colours uses Wallpapers.currentImage.
    readonly property string schemeStatePath: `${Paths.state}/scheme.json`
    readonly property string schemeSourcePath: `${Paths.state}/wallpaper/path.txt`
    property string schemeName: ""
    property string schemeSource: ""
    property bool schemeSourceLoaded: false

    Component.onCompleted: reload()
    onCurrentImageChanged: applyPalette(false)

    function applyPalette(force): void {
        if (!SchemeGenerator.available || schemeName !== "dynamic" || currentImage === "")
            return;
        // Wallpaper Engine discovery can briefly report the Windows wallpaper
        // at startup; wait for it and the persisted source before comparing.
        if (!schemeSourceLoaded || !WallpaperEngine.snapshotReady)
            return;
        if (!force && Paths.samePath(currentImage, schemeSource))
            return;
        SchemeGenerator.applyWallpaper(currentImage, GlobalConfig.services.smartScheme);
    }

    FileView {
        path: root.schemeStatePath
        watchChanges: true
        printErrors: false
        onLoaded: {
            try {
                root.schemeName = String(JSON.parse(text()).name ?? "");
            } catch (error) {
                root.schemeName = "";
            }
            root.applyPalette(false);
        }
        onFileChanged: reload()
        onLoadFailed: root.schemeName = ""
    }

    FileView {
        path: root.schemeSourcePath
        watchChanges: true
        printErrors: false
        onLoaded: {
            root.schemeSource = text().trim();
            root.schemeSourceLoaded = true;
            root.applyPalette(false);
        }
        onFileChanged: reload()
        onLoadFailed: root.schemeSourceLoaded = true
    }

    Connections {
        target: WallpaperEngine
        function onSnapshotReadyChanged(): void { root.applyPalette(false); }
    }
    Connections {
        target: GlobalConfig.services
        function onSmartSchemeChanged(): void { root.applyPalette(true); }
    }

    // Paths.wallsdir can change once after startup, when the background probe
    // finds the wallpapers in the legacy folder; scan again for the new folder.
    Connections {
        target: Paths
        function onWallsdirChanged(): void {
            root.reload();
        }
    }

    function reload(): void {
        const dir = Paths.wallsdir;
        files = Native.FsUtils.listDir(dir).filter(n => /\.(png|jpe?g|bmp|webp)$/i.test(n)).map(n => ({
                    path: Paths.joinPath(dir, n),
                    relativePath: n,
                    name: n,
                    parentDir: dir
                }));
    }
    function getCategoryFor(w): string {
        const parent = String(w?.parentDir ?? "");
        if (parent === "" || parent === Paths.wallsdir)
            return "";
        return parent.slice(Paths.wallsdir.length + 1).split("/")[0];
    }
    // Upstream runs `caelestia wallpaper -r`; the Windows port applies the
    // chosen image through the native Wallpaper facade, so a local random pick
    // reuses setWallpaper and its control gate.
    function setRandom(): bool {
        if (list.length === 0)
            return false;
        return setWallpaper(list[Math.floor(Math.random() * list.length)].path);
    }
    function query(search): var { return list.filter(w => w.relativePath.toLowerCase().includes(search.toLowerCase())); }
    // Preview affects only the shell's wallpaper surface, never Windows state.
    function preview(path): void { previewPath = path; showPreview = true; }
    function stopPreview(): void { showPreview = false; }
    function setWallpaper(path): bool {
        if (!controlsEnabled) {
            // Every caller closes its picker or sub-page right after this call,
            // so the refusal has to speak here. Smoke stays silent, like the
            // other gated facade entry points.
            if (Quickshell.env("CAELESTIA_SHELL_SMOKE") !== "1")
                Toaster.toast("Wallpaper", "Wallpaper changes are turned off", "wallpaper");
            return false;
        }
        if (WallpaperEngine.items.some(item => item.path === path))
            return WallpaperEngine.open(path);
        const local = String(path).replace(/^file:\/\/\//, "");
        const ok = Native.Wallpaper.setWallpaper(local, false);
        if (ok) {
            fileCurrent = local;
            stopPreview();
            // The fileCurrent change above regenerates a dynamic palette.
            if (!SchemeGenerator.available) {
                Toaster.toast("Wallpaper", "Desktop wallpaper changed. Dynamic colours are unavailable.", "wallpaper");
            } else if (schemeName === "dynamic") {
                Toaster.toast("Wallpaper", "Desktop wallpaper changed. Generating colours.", "palette");
            } else {
                Toaster.toast("Wallpaper", "Desktop wallpaper changed.", "wallpaper");
            }
        } else {
            Toaster.toast("Wallpaper", "Windows could not apply the wallpaper.", "wallpaper");
        }
        return ok;
    }

    function choose(): void {
        if (controlsEnabled)
            picker.open();
    }

    Connections {
        target: Native.DesktopLayer
        function onWallpaperChanged(): void {
            root.fileCurrent = Native.Wallpaper.currentWallpaper().replace(/\\/g, "/") || root.fallback;
        }
    }
    NativeDialogs.FileDialog {
        id: picker

        title: "Choose desktop wallpaper"
        nameFilters: ["Images (*.png *.jpg *.jpeg *.bmp *.webp)"]
        onAccepted: root.setWallpaper(decodeURIComponent(selectedFile.toString()))
    }
}
