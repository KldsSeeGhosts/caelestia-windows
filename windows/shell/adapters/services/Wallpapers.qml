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
    // #214: the last local wallpaper this desktop actually showed before an
    // engine took it over. IDesktopWallpaper can report an empty, missing or
    // system-black path at handback, and an Image with that source paints
    // nothing, leaving the window black. Keep this verified file instead and
    // fall back to the bundled asset when even it is gone. Starting at the
    // fallback means a fresh profile with the engine already running hands
    // back to a Caelestia image rather than an unusable system path.
    property string lastGoodFile: fallback
    readonly property string handbackWallpaper: usableFile(lastGoodFile) ? lastGoodFile : fallback
    readonly property string actualCurrent: WallpaperEngine.enabled && WallpaperEngine.running && WallpaperEngine.current?.path
        ? WallpaperEngine.current.path : fileCurrent
    // Image consumers (mode/variant generation and the desktop) need the
    // preview, while launcher selection needs the project.json identity. The
    // ownership claim, not the bare process, decides which image is visible:
    // after a genuine handback the engine still runs but the shell shows its
    // own wallpaper again, and the source change repaints the desktop (#214).
    readonly property string currentImage: externalWallpaperActive && !WallpaperEngine.desktopHandedBack
        && WallpaperEngine.current?.preview
        ? WallpaperEngine.current.preview
        : visibleOwnSource()
    property bool showPreview: false
    property string previewPath
    readonly property string current: showPreview && !externalWallpaperActive ? previewPath : currentImage
    readonly property bool externalWallpaperActive: WallpaperEngine.ownsDesktop
    property var files: []
    property int listRequest: 0
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
            parentDir: String(entry.parentDir ?? Paths.wallsdir),
            // A cloud placeholder is listed but its content is not local. The
            // pickers keep it visible and skip its thumbnail until it is opened.
            onDisk: entry.onDisk !== false
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
    property bool schemeNameLoaded: false
    property bool schemeSourceLoaded: false
    readonly property bool schemeStateReady: schemeNameLoaded && schemeSourceLoaded

    Component.onCompleted: {
        reload();
        if (!externalWallpaperActive)
            root.noteGoodFile(root.fileCurrent);
    }
    onCurrentImageChanged: applyPalette(false)
    // Both files have been read (or found missing) once: the startup check.
    onSchemeStateReadyChanged: applyPalette(false)
    // Only the own desktop contributes a known-good file. While an engine
    // claims the desktop its preview is visible, and the system wallpaper it
    // leaves behind is not a source this shell chose (#214).
    onFileCurrentChanged: {
        if (!externalWallpaperActive)
            root.noteGoodFile(root.fileCurrent);
    }
    onExternalWallpaperActiveChanged: {
        // A handback releases the claim and adopts its source in the
        // WallpaperEngine connection below; noting fileCurrent first would
        // remember the path the engine just left.
        if (!externalWallpaperActive && !WallpaperEngine.desktopHandedBack)
            root.noteGoodFile(root.fileCurrent);
    }

    // A wallpaper source is usable only when it names a local file that still
    // exists. classify is a synchronous attribute read, and a missing or
    // non-file source makes the desktop Image paint nothing (#214).
    function usableFile(path): bool {
        const value = String(path ?? "").replace(/^file:\/\/\//, "");
        return value.length > 0 && Native.FsUtils.classify(value) === "file";
    }
    // Remember the local file the own desktop shows. The path the engine leaves
    // in the Windows wallpaper setting is never adopted as this value (#214).
    function noteGoodFile(path): void {
        if (!usableFile(path))
            return;
        const value = String(path).replace(/^file:\/\/\//, "");
        if (lastGoodFile !== value)
            lastGoodFile = value;
    }
    // An explicit pick is a Caelestia choice even while an engine owns the
    // desktop: it becomes the file a handback returns to, and an intentionally
    // black image is as valid as any other. This is the only source adoption
    // allowed while the desktop is handed back (#214).
    function adoptPickedFile(path): void {
        const local = String(path).replace(/^file:\/\/\//, "");
        fileCurrent = local;
        root.noteGoodFile(local);
    }
    // A genuine handback must show a loadable Caelestia image, never the WE
    // preview and never the path the engine left behind. Reuse the last file
    // the own desktop showed, or the bundled asset on a fresh profile.
    function adoptHandbackSource(): void {
        const source = usableFile(lastGoodFile) ? lastGoodFile : fallback;
        // Resolve a vanished last file once, so the state matches the image
        // that is actually visible and the next handback starts from a
        // verified source.
        if (lastGoodFile !== source)
            lastGoodFile = source;
        if (!Paths.samePath(fileCurrent, source))
            fileCurrent = source;
    }
    function visibleOwnSource(): string {
        return usableFile(fileCurrent) ? fileCurrent : handbackWallpaper;
    }

    function applyPalette(force): void {
        if (!SchemeGenerator.available || schemeName !== "dynamic" || currentImage === "")
            return;
        // Wallpaper Engine discovery can briefly report the Windows wallpaper
        // at startup; wait for it and the persisted state before comparing.
        if (!schemeStateReady || !WallpaperEngine.snapshotReady)
            return;
        if (!force && Paths.samePath(currentImage, schemeSource))
            return;
        console.debug("CAELESTIA_PALETTE_TIMING stage=palette_request ts=" + Date.now() + (force ? " force=1" : ""));
        SchemeGenerator.applyWallpaper(currentImage, GlobalConfig.services.smartScheme);
    }

    // Loading scheme state never regenerates: only a currentImage change, the
    // smart-scheme toggle or an explicit user action does, so a scheme write
    // can not trigger another one.
    function setSchemeName(json: string): void {
        try {
            schemeName = String(JSON.parse(json).name ?? "");
        } catch (error) {
            schemeName = "";
        }
        schemeNameLoaded = true;
    }
    function setSchemeSource(content: string): void {
        schemeSource = content.trim();
        schemeSourceLoaded = true;
    }
    // A FileView cannot watch a file whose directory does not exist yet, which
    // is the case on a fresh profile. The generator creates both files, so
    // reload them whenever it reports a finished run instead.
    function reloadSchemeState(): void {
        nameFile.reload();
        sourceFile.reload();
    }

    FileView {
        id: nameFile

        path: root.schemeStatePath
        watchChanges: true
        printErrors: false
        onLoaded: root.setSchemeName(text())
        onFileChanged: reload()
        onLoadFailed: root.setSchemeName("")
    }

    FileView {
        id: sourceFile

        path: root.schemeSourcePath
        watchChanges: true
        printErrors: false
        onLoaded: root.setSchemeSource(text())
        onFileChanged: reload()
        onLoadFailed: root.setSchemeSource("")
    }

    Connections {
        target: SchemeGenerator
        function onSchemeChanged(): void { root.reloadSchemeState(); }
        function onSchemeListChanged(): void { root.reloadSchemeState(); }
    }

    Connections {
        target: WallpaperEngine
        function onSnapshotReadyChanged(): void { root.applyPalette(false); }
        function onDesktopHandedBackChanged(): void {
            if (!WallpaperEngine.desktopHandedBack)
                return;
            // Drop a launcher preview left open across the handback: it may be
            // an engine preview, and the desktop must show the shell's own
            // image instead of keeping it (#214).
            root.stopPreview();
            root.adoptHandbackSource();
        }
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

    Connections {
        target: Native.FsUtils
        function onListDirFinished(request, path, entries): void {
            root.applyListing(request, path, entries);
        }
    }

    function reload(): void {
        listRequest = Native.FsUtils.listDirAsync(Paths.wallsdir);
    }
    function applyListing(request, dir, entries): void {
        // A slow share may answer after wallsdir has already moved on.
        if (request !== listRequest)
            return;
        files = entries.filter(entry => /\.(png|jpe?g|bmp|webp)$/i.test(entry.name)).map(entry => ({
                    path: Paths.joinPath(dir, entry.name),
                    relativePath: entry.name,
                    name: entry.name,
                    parentDir: dir,
                    onDisk: entry.onDisk !== false
                }));
    }
    // Decoding a placeholder would fetch its content, so the pickers only do
    // that once the user has opened it.
    function markOpened(path): void {
        const index = files.findIndex(entry => Paths.samePath(entry.path, path));
        if (index < 0 || files[index].onDisk !== false)
            return;
        const next = files.slice();
        next[index] = Object.assign({}, next[index], { onDisk: true });
        files = next;
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
    // A listed cloud placeholder is not local: previewing its path hydrates it.
    function preview(path): void {
        const listed = list.find(entry => entry && Paths.samePath(entry.path, String(path ?? "")));
        if (listed && listed.onDisk === false) {
            stopPreview();
            return;
        }
        previewPath = path;
        showPreview = true;
    }
    function previewEntry(entry): void {
        if (!entry || entry.onDisk === false) {
            stopPreview();
            return;
        }
        preview(entry.path);
    }
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
            root.markOpened(local);
            root.adoptPickedFile(local);
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
            // #214: after the handback the shell owns the visible wallpaper
            // again, so a native change is the engine's own bookkeeping (or an
            // event independent of the handback), never proof that Caelestia
            // chose or could decode this file. Adopting an existing system
            // path would replace the verified source and, because the external
            // claim is released, promote it to lastGoodFile, so every later
            // handback would return to it. Explicit picks apply through
            // adoptPickedFile and are kept, including intentional black ones.
            if (WallpaperEngine.desktopHandedBack)
                return;
            const next = Native.Wallpaper.currentWallpaper().replace(/\\/g, "/");
            root.fileCurrent = next || root.fallback;
        }
    }
    NativeDialogs.FileDialog {
        id: picker

        title: "Choose desktop wallpaper"
        nameFilters: ["Images (*.png *.jpg *.jpeg *.bmp *.webp)"]
        onAccepted: root.setWallpaper(decodeURIComponent(selectedFile.toString()))
    }
}
