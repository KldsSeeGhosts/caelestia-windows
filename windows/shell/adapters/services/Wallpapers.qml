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
    // whatever Windows happened to have before install. Windows already
    // stores the chosen image per display, so the record only keeps what
    // Windows cannot: whether Caelestia follows the Windows wallpaper or
    // keeps its bundled asset, which displays override that baseline, and the
    // Windows value each default display had when Caelestia last resolved.
    // That last part is how a later start notices a selection made by an
    // older build (downgrade, choose, upgrade again) without treating every
    // stock Windows wallpaper as a Caelestia choice.
    readonly property string sourceRecordPath: `${Paths.state}/wallpaper/desktop.json`
    // A profile that has run any earlier build has at least one of these.
    // theme-tokens.json is written by every build, independently of the
    // optional colour runtime, so it separates an upgrade from a fresh
    // install without relying on palette history. They are sampled before the
    // first event-loop turn, so this run's own writers cannot create them.
    readonly property var priorStatePaths: [`${Paths.state}/theme-tokens.json`,
        `${Paths.state}/scheme.json`, `${Paths.state}/wallpaper/path.txt`,
        `${Paths.state}/recordings.json`]
    property bool priorStateSeen: false
    property bool sourceComponentReady: false
    property bool sourceInitialized: false
    // Profile baseline: false keeps the bundled asset, true follows Windows.
    property bool sourceChosen: false
    // Per-display overrides, keyed by the stable physical-target id, and the
    // Windows value a default display had when this build last looked. A
    // display name is not an identity, and a path alone cannot say whether a
    // Caelestia profile chose the image.
    property var sourceMonitors: ({})
    property var sourceSeen: ({})
    // "valid", "missing" or "invalid". An invalid or unknown-version record
    // is never trusted or rewritten without an explicit user pick.
    property string sourceRecordHealth: ""
    property var sourceRecordDocument: null
    property string persistedSourceRecord: ""
    property bool sourceRecordDirty: false
    property string sourceRecordError: ""
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
    // WallpaperEngine.ownsDesktop keeps the physical claim even for a running
    // process this profile did not opt into, so the underlay, handback latch
    // and above-icons guard still protect issue #25's ownership boundary.
    // The adapter, however, only treats that foreign output as its visible
    // source when the integration is enabled. With the toggle off, the desktop
    // and the palette use Caelestia's own wallpaper, as a fresh profile does.
    readonly property bool externalWallpaperActive: WallpaperEngine.enabled && WallpaperEngine.ownsDesktop
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
        // Sample the previous-run evidence before this run's writers
        // (theme-tokens.json and the palette bridge) can create it.
        root.priorStateSeen = root.priorStatePaths.some(
            path => Native.FsUtils.classify(path) === "file");
        root.sourceComponentReady = true;
        root.maybeResolve();
        reload();
    }
    onCurrentImageChanged: applyPalette(false)
    // The record decides between a saved wallpaper and the bundled default,
    // and the default must be decided even when the optional colour runtime
    // never writes scheme.json. Resolution therefore runs at completion;
    // these files only gate colour generation.
    onSchemeStateReadyChanged: root.applyPalette(false)
    // Only the own desktop contributes a known-good file. While an engine
    // claims the desktop its preview is visible, and the system wallpaper it
    // leaves behind is not a source this shell chose.
    onFileCurrentChanged: {
        if (externalWallpaperActive)
            return;
        root.noteGoodFile(root.fileCurrent);
    }
    onExternalWallpaperActiveChanged: {
        // A handback releases the claim and adopts its source in the
        // WallpaperEngine connection below; noting fileCurrent first would
        // remember the path the engine just left.
        if (externalWallpaperActive || WallpaperEngine.desktopHandedBack)
            return;
        if (root.sourceInitialized && !root.sourceChosen && !root.hasUserMonitor()) {
            // A profile on the bundled default made no Caelestia choice. An
            // engine that stopped without handing back leaves its system
            // wallpaper in fileCurrent; that is not a choice and must not
            // replace the bundled desktop.
            if (!Paths.samePath(root.fileCurrent, root.fallback))
                root.fileCurrent = root.fallback;
        }
        root.noteGoodFile(root.fileCurrent);
        root.refreshScreenFiles();
    }

    function hasUserMonitor(): bool {
        return Object.keys(root.sourceMonitors).some(id => root.sourceMonitors[id] === "user");
    }
    // The palette follows the first display this profile follows from
    // Windows. On a profile that is otherwise still on the bundled default,
    // that is the only sensible visible image.
    function firstUserFile(): string {
        for (const screen of Quickshell.screens) {
            const id = Native.Wallpaper.screenTargetId(screen.name);
            if (id && root.effectiveSource(id) === "user" && root.usableFile(root.screenFiles[id]))
                return root.screenFiles[id];
        }
        return "";
    }
    function effectiveSource(id): string {
        const value = root.sourceMonitors[id];
        if (value === "user" || value === "default")
            return value;
        return root.sourceChosen ? "user" : "default";
    }
    // Strict schema check. A truncated record, or one written by a build with
    // another schema version, is not a decision this build may reinterpret:
    // returning null keeps it on disk and makes the caller keep the saved
    // Windows wallpaper. Unknown top-level keys are preserved for the writer.
    function parseSourceRecord(content): var {
        let document = null;
        try { document = JSON.parse(String(content ?? "")); } catch (_) { return null; }
        if (!document || typeof document !== "object" || Array.isArray(document))
            return null;
        if (document.version !== 1)
            return null;
        if (document.source !== "default" && document.source !== "user")
            return null;
        const monitors = {};
        if (document.monitors !== undefined) {
            if (!document.monitors || typeof document.monitors !== "object"
                    || Array.isArray(document.monitors))
                return null;
            for (const id of Object.keys(document.monitors)) {
                const value = document.monitors[id];
                if (value !== "default" && value !== "user")
                    return null;
                monitors[id] = value;
            }
        }
        const seen = {};
        if (document.seen !== undefined) {
            if (!document.seen || typeof document.seen !== "object" || Array.isArray(document.seen))
                return null;
            for (const id of Object.keys(document.seen)) {
                if (typeof document.seen[id] !== "string")
                    return null;
                seen[id] = document.seen[id];
            }
        }
        return {source: document.source, monitors: monitors, seen: seen, document: document};
    }
    function readSourceRecord(content, missing): void {
        if (root.sourceRecordHealth !== "")
            return;
        if (missing === true) {
            root.sourceRecordHealth = "missing";
        } else {
            const parsed = root.parseSourceRecord(content);
            if (!parsed) {
                root.sourceRecordHealth = "invalid";
            } else {
                root.sourceRecordHealth = "valid";
                root.sourceRecordDocument = parsed.document;
                root.sourceChosen = parsed.source === "user";
                root.sourceMonitors = parsed.monitors;
                root.sourceSeen = parsed.seen;
            }
        }
        root.maybeResolve();
    }
    function maybeResolve(): void {
        if (root.sourceInitialized || !root.sourceComponentReady || root.sourceRecordHealth === "")
            return;
        root.resolveInitialSource();
    }
    // Decide the own wallpaper once per process. A present and valid record
    // wins. A missing record is an upgrade when earlier Caelestia state
    // exists, and a fresh install otherwise. A malformed or unknown-version
    // record is not rewritten: the saved Windows wallpaper stays until the
    // user makes a new choice. The choice is never stored as an image path,
    // because a physical file cannot distinguish a pick from a stock
    // wallpaper; only the observed baseline is compared.
    function resolveInitialSource(): void {
        root.sourceInitialized = true;
        if (root.sourceRecordHealth === "missing") {
            root.sourceChosen = root.priorStateSeen;
            root.sourceMonitors = {};
            root.sourceSeen = {};
            root.sourceRecordDirty = true;
        } else if (root.sourceRecordHealth === "invalid") {
            root.sourceChosen = true;
            root.sourceMonitors = {};
            root.sourceSeen = {};
        }
        root.refreshScreenFiles();
        if (root.sourceChosen) {
            const current = Native.Wallpaper.currentWallpaper().replace(/\\/g, "/");
            root.fileCurrent = root.usableFile(current) ? current : root.fallback;
        } else {
            const userFile = root.firstUserFile();
            root.fileCurrent = userFile !== "" ? userFile : root.fallback;
        }
        if (!root.externalWallpaperActive)
            root.noteGoodFile(root.fileCurrent);
        root.persistSourceChoice(false);
        root.applyPalette(false);
    }
    // Write only a decision this build understands. A malformed or
    // unknown-version record is left untouched unless an explicit pick
    // replaces it (force), so loading can never silently persist a different
    // choice. The parent directory is created first: FileView's own mkpath
    // races with the theme-token export on a fresh profile and fails.
    function persistSourceChoice(force): void {
        if (!root.sourceInitialized)
            return;
        if (!root.sourceRecordDirty && root.sourceRecordHealth === "valid" && force !== true)
            return;
        const invalid = root.sourceRecordHealth === "invalid";
        if (invalid && force !== true)
            return;
        const base = !invalid && root.sourceRecordDocument
            && typeof root.sourceRecordDocument === "object"
            ? JSON.parse(JSON.stringify(root.sourceRecordDocument)) : {};
        base.version = 1;
        base.source = root.sourceChosen ? "user" : "default";
        if (Object.keys(root.sourceMonitors).length > 0 || base.monitors !== undefined)
            base.monitors = Object.assign({}, base.monitors ?? {}, root.sourceMonitors);
        if (Object.keys(root.sourceSeen).length > 0 || base.seen !== undefined)
            base.seen = Object.assign({}, base.seen ?? {}, root.sourceSeen);
        const text = JSON.stringify(base, null, 2) + "\n";
        if (root.persistedSourceRecord === text) {
            root.sourceRecordDirty = false;
            return;
        }
        root.persistedSourceRecord = text;
        root.sourceRecordDocument = base;
        root.sourceRecordDirty = false;
        // From here on this build owns a document it understands. Recovery
        // from an invalid file is only reached through an explicit pick.
        if (invalid || root.sourceRecordHealth === "missing")
            root.sourceRecordHealth = "valid";
        const directory = root.sourceRecordPath.slice(0, root.sourceRecordPath.lastIndexOf("/"));
        if (!Native.FsUtils.makePath(directory)) {
            root.sourceRecordError = "could not create " + directory;
            root.sourceRecordDirty = true;
            return;
        }
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
    // An explicit global pick is a Caelestia choice even while an engine owns
    // the desktop: it becomes the file a handback returns to, and an
    // intentionally black image is as valid as any other. A global pick sets
    // the profile baseline; a display pick records only that display below.
    function adoptPickedFile(path): void {
        const local = String(path).replace(/^file:\/\/\//, "");
        root.sourceChosen = true;
        fileCurrent = local;
        root.noteGoodFile(local);
        root.sourceRecordDirty = true;
        root.persistSourceChoice(root.sourceRecordHealth === "invalid");
    }
    // A pick made on one display records that display only. The baseline and
    // every untouched display keep the bundled default, so a later Windows
    // notification cannot import old wallpapers onto the other monitors.
    function adoptPickedScreen(targetId, path): void {
        const local = String(path).replace(/^file:\/\/\//, "");
        root.sourceMonitors = Object.assign({}, root.sourceMonitors, {[targetId]: "user"});
        fileCurrent = local;
        root.noteGoodFile(local);
        root.sourceRecordDirty = true;
        root.persistSourceChoice(root.sourceRecordHealth === "invalid");
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
    // A running engine writes the Windows wallpaper itself. For a display on
    // the bundled default, that change is its bookkeeping, never this
    // profile's choice: move the observation baseline so a later comparison
    // cannot adopt the image the engine leaves behind. Discovery must have
    // settled first; before that the process is unknown.
    function baselineEngineWallpapers(): void {
        if (!root.sourceInitialized || !WallpaperEngine.snapshotReady
                || !WallpaperEngine.running)
            return;
        let changed = false;
        for (const screen of Quickshell.screens) {
            const id = Native.Wallpaper.screenTargetId(screen.name);
            if (!id || root.effectiveSource(id) !== "default")
                continue;
            const windows = Native.Wallpaper.currentWallpaperForScreen(screen.name).replace(/\\/g, "/");
            if (windows.length === 0)
                continue;
            const seen = root.sourceSeen[id];
            if (typeof seen === "string" && Paths.samePath(seen, windows))
                continue;
            root.sourceSeen = Object.assign({}, root.sourceSeen, {[id]: windows});
            root.sourceRecordDirty = true;
            changed = true;
        }
        if (changed)
            root.persistSourceChoice(false);
    }
    // Read each display's Windows wallpaper. A display on the bundled default
    // keeps the bundled asset even when Windows still has an older image, so
    // one display's pick never imports the others. A default display whose
    // Windows image changed since this build last looked was changed outside
    // this process (an older build after a downgrade, or Windows settings):
    // that is an intervening selection, adopted only for that display. While
    // discovery is unsettled, or a running engine is the writer, the change is
    // not treated as a profile choice.
    function refreshScreenFiles(): void {
        if (!root.sourceInitialized)
            return;
        root.baselineEngineWallpapers();
        if (externalWallpaperActive || WallpaperEngine.desktopHandedBack)
            return;
        const settled = WallpaperEngine.snapshotReady;
        const next = {};
        let adopted = "";
        for (const screen of Quickshell.screens) {
            const id = Native.Wallpaper.screenTargetId(screen.name);
            if (!id)
                continue;
            const windows = Native.Wallpaper.currentWallpaperForScreen(screen.name).replace(/\\/g, "/");
            if (root.effectiveSource(id) === "user") {
                next[id] = root.usableFile(windows) ? windows : screenFiles[id] || root.handbackWallpaper;
                continue;
            }
            const seen = root.sourceSeen[id];
            if (typeof seen === "string" && seen.length > 0 && windows.length > 0
                    && !Paths.samePath(seen, windows)) {
                if (!settled || WallpaperEngine.running) {
                    next[id] = root.fallback;
                    continue;
                }
                root.sourceMonitors = Object.assign({}, root.sourceMonitors, {[id]: "user"});
                root.sourceRecordDirty = true;
                if (adopted === "" && root.usableFile(windows))
                    adopted = windows;
                next[id] = root.usableFile(windows) ? windows : root.fallback;
                continue;
            }
            if (!seen && windows.length > 0 && settled && !WallpaperEngine.running) {
                root.sourceSeen = Object.assign({}, root.sourceSeen, {[id]: windows});
                root.sourceRecordDirty = true;
            }
            next[id] = root.fallback;
        }
        root.screenFiles = next;
        if (adopted !== "") {
            root.fileCurrent = adopted;
            root.noteGoodFile(adopted);
        }
        root.persistSourceChoice(false);
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

    // Owned by the shell and never watched: a pick or a resolved decision is
    // the only writer, and reloading our own write has no new decision to
    // make. Atomic writes are used so a crash cannot leave a partial record.
    // Errors are kept in a property instead of logged: a normal fresh start
    // must emit no QML diagnostic, and the smoke gate fails on any warning.
    FileView {
        id: sourceRecord

        path: root.sourceRecordPath
        blockLoading: true
        atomicWrites: true
        watchChanges: false
        printErrors: false
        onLoaded: root.readSourceRecord(text(), false)
        onLoadFailed: error => root.readSourceRecord("", error === FileViewError.FileNotFound)
        onSaveFailed: error => {
            root.sourceRecordError = "save failed: " + String(error);
            root.sourceRecordDirty = true;
        }
    }

    Connections {
        target: SchemeGenerator
        function onSchemeChanged(): void { root.reloadSchemeState(); }
        function onSchemeListChanged(): void { root.reloadSchemeState(); }
    }

    Connections {
        target: WallpaperEngine
        // Discovery settling and process starts/stops decide whether a
        // changed Windows image is an intervening selection or engine
        // bookkeeping, so re-read the displays on both.
        function onSnapshotReadyChanged(): void {
            root.refreshScreenFiles();
            root.applyPalette(false);
        }
        function onRunningChanged(): void { root.refreshScreenFiles(); }
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
            // An explicit pick is recorded before any native notification:
            // a global pick opts the profile in, while a display pick records
            // only that display. The untouched displays keep the bundled
            // default and are not re-read from Windows.
            root.markOpened(local);
            if (target) {
                screenFiles = Object.assign({}, screenFiles, {[target.targetId]: local});
                root.adoptPickedScreen(target.targetId, local);
            } else {
                root.adoptPickedFile(local);
                root.refreshScreenFiles();
            }
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
            // adoptPickedFile/adoptPickedScreen and are kept, including
            // intentional black ones.
            root.baselineEngineWallpapers();
            if (WallpaperEngine.desktopHandedBack || !root.sourceInitialized)
                return;
            const next = Native.Wallpaper.currentWallpaper().replace(/\\/g, "/");
            // During an engine era this is bookkeeping: fileCurrent may follow
            // it, but it never becomes the remembered own source. On the own
            // desktop a baseline that already follows Windows keeps tracking
            // it. A profile on the bundled default is decided per display by
            // refreshScreenFiles, which adopts only a display whose Windows
            // image actually changed; flipping the whole profile here would
            // import old wallpapers onto every untouched monitor.
            if (next && (root.externalWallpaperActive || root.sourceChosen))
                root.fileCurrent = next;
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
