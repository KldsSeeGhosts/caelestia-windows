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
    // Which own wallpaper this profile shows is a Caelestia choice, not
    // whatever Windows happened to have before install. The small record keeps
    // that decision across restarts without copying the image: "user" adopts
    // the Windows wallpaper (where picks are written), "default" keeps the
    // bundled Caelestia asset. A physical file cannot be distinguished from a
    // stock Windows wallpaper, so the record is the opt-in boundary, not a
    // filter on the path.
    readonly property string sourceRecordPath: `${Paths.state}/wallpaper/desktop.json`
    property bool sourceRecordLoaded: false
    property string sourceRecordState: ""
    property bool sourceInitialized: false
    property bool sourceChosen: false
    property string persistedSourceRecord: ""
    // Start on the bundled asset so the first frame is Caelestia even before
    // the record and the user's Windows wallpaper are read. Resolution below
    // replaces it only for a profile that already chose a wallpaper.
    property string fileCurrent: fallback
    // the last local wallpaper this desktop actually showed before an
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
    // own wallpaper again, and the source change repaints the desktop.
    readonly property string currentImage: externalWallpaperActive && !WallpaperEngine.desktopHandedBack
        && WallpaperEngine.current?.preview
        ? WallpaperEngine.current.preview
        : visibleOwnSource()
    property bool showPreview: false
    property string previewPath
    property string previewScreenId: ""
    // Only local, verified images live here. Engine previews never replace
    // a display's retained underlay. Keys are opaque physical-target digests.
    property var screenFiles: ({})
    // the mounted underlay must retain our own image, not transition
    // to an engine preview as soon as process/config discovery changes.
    // currentImage still supplies that preview to palette generation; it is
    // not proof that the external renderer has presented anything.
    readonly property string current: externalWallpaperActive ? handbackWallpaper
        : showPreview ? previewPath : currentImage
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
        refreshScreenFiles();
    }
    onCurrentImageChanged: applyPalette(false)
    // Both files have been read (or found missing) once: the startup check.
    // The record decides between a saved wallpaper and the bundled default;
    // the palette must not run from the provisional default first.
    onSchemeStateReadyChanged: {
        root.resolveInitialSource();
        root.applyPalette(false);
    }
    // Only the own desktop contributes a known-good file. While an engine
    // claims the desktop its preview is visible, and the system wallpaper it
    // leaves behind is not a source this shell chose.
    onFileCurrentChanged: {
        if (externalWallpaperActive)
            return;
        root.noteGoodFile(root.fileCurrent);
        if (root.sourceInitialized && root.sourceChosen)
            root.persistSourceChoice();
    }
    onExternalWallpaperActiveChanged: {
        // A handback releases the claim and adopts its source in the
        // WallpaperEngine connection below; noting fileCurrent first would
        // remember the path the engine just left.
        if (externalWallpaperActive || WallpaperEngine.desktopHandedBack)
            return;
        if (root.sourceInitialized && !root.sourceChosen) {
            // A fresh profile made no Caelestia choice. An engine that stopped
            // without handing back leaves its system wallpaper in fileCurrent;
            // that is not a choice and must not replace the bundled desktop.
            if (!Paths.samePath(root.fileCurrent, root.fallback))
                root.fileCurrent = root.fallback;
            root.screenFiles = {};
        }
        root.noteGoodFile(root.fileCurrent);
        root.refreshScreenFiles();
    }

    function applySourceRecord(content): void {
        root.sourceRecordLoaded = true;
        const raw = String(content ?? "").trim();
        let parsed = null;
        try { parsed = JSON.parse(raw); } catch (_) {}
        const source = parsed && typeof parsed === "object" ? parsed.source : "";
        if (source === "user") {
            root.sourceRecordState = "user";
            root.sourceChosen = true;
        } else if (source === "default" || raw.length > 0) {
            // A damaged record is still this profile's decision, so it falls
            // back to the bundled default instead of migrating a stock
            // Windows wallpaper back in.
            root.sourceRecordState = "default";
            root.sourceChosen = false;
        } else {
            // No record from this version. A profile that already produced a
            // palette has a saved wallpaper in path.txt; a fresh profile has
            // never generated one.
            root.sourceRecordState = "";
            root.sourceChosen = false;
        }
        const wasInitialized = root.sourceInitialized;
        root.resolveInitialSource();
        // The scheme-state change already generated when it settled first;
        // only a record that loaded after it needs to start the palette here.
        if (!wasInitialized && root.sourceInitialized)
            root.applyPalette(false);
    }
    // Decide the own wallpaper once per process, after both the record and the
    // existing palette source have been read. A record wins. Without one, an
    // existing palette source means this is an upgrade and keeps the Windows
    // wallpaper the shell already showed; otherwise the bundled asset is the
    // fresh default. The record uses "user" or "default", never a path: picks
    // are written to Windows, and a path could not distinguish a Caelestia
    // choice from the stock wallpaper that happened to be there.
    function resolveInitialSource(): void {
        if (root.sourceInitialized || !root.sourceRecordLoaded || !root.schemeSourceLoaded)
            return;
        if (root.sourceRecordState === "") {
            root.sourceChosen = String(root.schemeSource ?? "").trim().length > 0;
        }
        if (root.sourceChosen) {
            const current = Native.Wallpaper.currentWallpaper().replace(/\\/g, "/");
            if (root.usableFile(current))
                root.fileCurrent = current;
        } else {
            root.fileCurrent = root.fallback;
            root.screenFiles = {};
        }
        root.sourceInitialized = true;
        root.persistSourceChoice();
        if (root.sourceChosen && !root.externalWallpaperActive)
            root.noteGoodFile(root.fileCurrent);
        root.refreshScreenFiles();
    }
    function persistSourceChoice(): void {
        if (!root.sourceInitialized)
            return;
        const text = JSON.stringify({version: 1, source: root.sourceChosen ? "user" : "default"}) + "\n";
        if (root.persistedSourceRecord === text)
            return;
        root.persistedSourceRecord = text;
        root.sourceRecordState = root.sourceChosen ? "user" : "default";
        sourceRecord.setText(text);
    }

    // A wallpaper source is usable only when it names a local file that still
    // exists. classify is a synchronous attribute read, and a missing or
    // non-file source makes the desktop Image paint nothing.
    function usableFile(path): bool {
        const value = String(path ?? "").replace(/^file:\/\/\//, "");
        return value.length > 0 && Native.FsUtils.classify(value) === "file";
    }
    // Remember the local file the own desktop shows. The path the engine leaves
    // in the Windows wallpaper setting is never adopted as this value.
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
    // allowed while the desktop is handed back.
    function adoptPickedFile(path): void {
        const local = String(path).replace(/^file:\/\/\//, "");
        root.sourceChosen = true;
        fileCurrent = local;
        root.noteGoodFile(local);
        if (root.sourceInitialized)
            root.persistSourceChoice();
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

    function captureScreen(screen): var {
        if (!screen || !screen.name)
            return null;
        const id = Native.Wallpaper.screenTargetId(screen.name);
        if (!id || (screen.targetId !== undefined && screen.targetId !== id))
            return null;
        return {name: screen.name, targetId: id};
    }
    function refreshScreenFiles(): void {
        if (!sourceChosen || externalWallpaperActive || WallpaperEngine.desktopHandedBack) {
            // A fresh profile keeps the bundled asset on every monitor too.
            // Reading the per-monitor Windows wallpapers here would put the
            // stock desktop back on each screen.
            if (Object.keys(screenFiles).length > 0)
                root.screenFiles = {};
            return;
        }
        const next = {};
        for (const screen of Quickshell.screens) {
            const id = Native.Wallpaper.screenTargetId(screen.name);
            if (!id)
                continue;
            const file = Native.Wallpaper.currentWallpaperForScreen(screen.name).replace(/\\/g, "/");
            next[id] = usableFile(file) ? file : screenFiles[id] || handbackWallpaper;
        }
        screenFiles = next;
    }
    function currentForScreen(screen): string {
        if (!screen)
            return current;
        const id = Native.Wallpaper.screenTargetId(screen.name);
        if (!externalWallpaperActive && showPreview && (!previewScreenId || previewScreenId === id))
            return previewPath;
        const own = screenFiles[id];
        return own && usableFile(own) ? own : externalWallpaperActive ? handbackWallpaper : visibleOwnSource();
    }

    Connections {
        target: Quickshell
        function onScreensChanged(): void { root.refreshScreenFiles(); }
    }
    function applyPalette(force): void {
        if (!sourceInitialized || !SchemeGenerator.available || schemeName !== "dynamic" || currentImage === "")
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

    // Owned by the shell and never watched: a pick or a resolved default is
    // the only writer, and reloading our own write has no new decision to
    // make. Atomic writes are used so a crash cannot leave a partial record.
    FileView {
        id: sourceRecord

        path: root.sourceRecordPath
        blockLoading: true
        atomicWrites: true
        watchChanges: false
        printErrors: false
        onLoaded: root.applySourceRecord(text())
        onLoadFailed: root.applySourceRecord("")
        onSaveFailed: error => console.warn("Caelestia wallpaper source record:", String(error))
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
            // image instead of keeping it.
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
    function setRandom(screen): bool {
        if (list.length === 0)
            return false;
        return setWallpaper(list[Math.floor(Math.random() * list.length)].path, screen);
    }
    function query(search): var { return list.filter(w => w.relativePath.toLowerCase().includes(search.toLowerCase())); }
    // Preview affects only the shell's wallpaper surface, never Windows state.
    // A listed cloud placeholder is not local: previewing its path hydrates it.
    function preview(path, screen): void {
        const listed = list.find(entry => entry && Paths.samePath(entry.path, String(path ?? "")));
        if (listed && listed.onDisk === false) {
            stopPreview();
            return;
        }
        previewPath = path;
        previewScreenId = screen ? Native.Wallpaper.screenTargetId(screen.name) : "";
        showPreview = true;
    }
    function previewEntry(entry, screen): void {
        if (!entry || entry.onDisk === false) {
            stopPreview();
            return;
        }
        preview(entry.path, screen);
    }
    function stopPreview(): void { showPreview = false; }
    function setWallpaper(path, screen): bool {
        if (!controlsEnabled) {
            // Every caller closes its picker or sub-page right after this call,
            // so the refusal has to speak here. Smoke stays silent, like the
            // other gated facade entry points.
            if (Quickshell.env("CAELESTIA_SHELL_SMOKE") !== "1")
                Toaster.toast("Wallpaper", "Wallpaper changes are turned off", "wallpaper");
            return false;
        }
        const explicit = screen !== undefined;
        const target = explicit ? captureScreen(screen) : null;
        if (explicit && !target) {
            Toaster.toast("Wallpaper", "The wallpaper display is no longer available", "wallpaper");
            return false;
        }
        if (WallpaperEngine.items.some(item => item.path === path))
            return WallpaperEngine.open(path, explicit ? target : undefined);
        const local = String(path).replace(/^file:\/\/\//, "");
        const ok = target ? Native.Wallpaper.setWallpaperForScreen(local, target.name)
            : Native.Wallpaper.setWallpaper(local, false);
        if (ok) {
            // An explicit pick opts this profile into its own wallpaper, for
            // this display or globally. The record makes it survive restarts
            // even before the native notification arrives.
            root.sourceChosen = true;
            root.markOpened(local);
            if (target)
                screenFiles = Object.assign({}, screenFiles, {[target.targetId]: local});
            else {
                screenFiles = {};
                root.adoptPickedFile(local);
            }
            root.persistSourceChoice();
            stopPreview();
            // Native change notifications refresh the global palette source;
            // a per-display pick must not replace another display's image.
            if (!SchemeGenerator.available) {
                Toaster.toast("Wallpaper", "Desktop wallpaper changed. Dynamic colours are unavailable.", "wallpaper");
            } else if (!target && schemeName === "dynamic") {
                Toaster.toast("Wallpaper", "Desktop wallpaper changed. Generating colours.", "palette");
            } else {
                Toaster.toast("Wallpaper", "Desktop wallpaper changed.", "wallpaper");
            }
        } else {
            Toaster.toast("Wallpaper", "Windows could not apply the wallpaper.", "wallpaper");
        }
        return ok;
    }

    function choose(screen): void {
        if (controlsEnabled) {
            picker.targetScreen = screen === undefined ? undefined : captureScreen(screen);
            picker.open();
        }
    }

    Connections {
        target: Native.DesktopLayer
        function onWallpaperChanged(): void {
            // after the handback the shell owns the visible wallpaper
            // again, so a native change is the engine's own bookkeeping (or an
            // event independent of the handback), never proof that Caelestia
            // chose or could decode this file. Adopting an existing system
            // path would replace the verified source and, because the external
            // claim is released, promote it to lastGoodFile, so every later
            // handback would return to it. Explicit picks apply through
            // adoptPickedFile and are kept, including intentional black ones.
            if (WallpaperEngine.desktopHandedBack || !root.sourceInitialized)
                return;
            // A change while the own desktop is visible is a user choice even
            // when this profile started on the bundled default. During an
            // engine era it is bookkeeping: fileCurrent may follow it, but it
            // never becomes the remembered own source.
            if (!root.externalWallpaperActive && !root.sourceChosen) {
                root.sourceChosen = true;
                root.persistSourceChoice();
            }
            const next = Native.Wallpaper.currentWallpaper().replace(/\\/g, "/");
            root.fileCurrent = next || root.fallback;
            root.refreshScreenFiles();
        }
    }
    NativeDialogs.FileDialog {
        id: picker
        property var targetScreen: undefined

        title: "Choose desktop wallpaper"
        nameFilters: ["Images (*.png *.jpg *.jpeg *.bmp *.webp)"]
        onAccepted: root.setWallpaper(decodeURIComponent(selectedFile.toString()), targetScreen)
    }
}
