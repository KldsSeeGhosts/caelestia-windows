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
    // Two profiles behave differently. A profile this build first created (the
    // WallpaperProvenance marker says "fresh") shows the bundled asset until
    // the user picks a wallpaper in Caelestia, then shows only Caelestia picks:
    // a Windows Settings or Wallpaper Engine change is never followed. A
    // profile that existed before (marker "existing", or classified as existing
    // by the state/caelestia rule) follows Windows exactly as before.
    //
    // Only a fresh profile persists picks, in desktop.json. The record keeps
    // the profile-wide pick and the per-display picks. There is no baseline to
    // compare, because a Windows image can no longer become a source here.
    // Unknown top-level keys survive a rewrite, and a malformed or
    // unknown-version record is preserved until an explicit pick replaces it.
    readonly property string sourceRecordPath: `${Paths.state}/wallpaper/desktop.json`
    property bool sourceComponentReady: false
    property bool sourceInitialized: false
    property bool sourceFresh: false
    property string profilePick: ""
    property var monitorPicks: ({})
    // "valid", "missing" or "invalid". Read at startup; only a fresh profile
    // uses the picks.
    property string sourceRecordHealth: ""
    property var sourceRecordDocument: null
    // Pending is the last proposed text; confirmed is the text FileView
    // reported as saved. A failed write stays pending and retries instead of
    // being mistaken for a saved choice.
    property string sourceRecordPending: ""
    property string sourceRecordConfirmed: ""
    property string sourceRecordWritingText: ""
    property bool sourceRecordWriting: false
    property bool sourceRecordVerifying: false
    property int sourceRecordFailures: 0
    property int sourceRecordRetryInterval: 2000
    property bool sourceRecordDirty: false
    property string sourceRecordError: ""
    // Start on the bundled asset so the first frame is Caelestia even before
    // the record and the user's Windows wallpaper are read. Resolution below
    // replaces it for a profile that follows Windows or saved a pick.
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
    // The enabled-dependent visible source applies only to a fresh profile.
    // An existing profile keeps the released build's behaviour exactly: a
    // running engine owns the visible desktop whether or not this profile
    // enabled the integration, so a saved enabled:false does not change what
    // it shows. A fresh profile shows Caelestia's own wallpaper while the
    // integration is off.
    readonly property bool externalWallpaperActive: WallpaperEngine.ownsDesktop
        && (!root.sourceFresh || WallpaperEngine.enabled)
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
    // Windows adaptation (PR #66): a picker may show the scanned local folder
    // while Wallpaper Engine's own picker choice hides it, so an imported image
    // is not silently invisible. This changes only what the pickers display;
    // the engine integration, its default and the saved setting are untouched.
    property bool showLocalSource: false
    // The local-only override is for the engine picker only, which is the one
    // source that hides local files. "files" already shows them, and forcing
    // "both" to local-only dropped every engine entry while the switch-back
    // control (shown only for "engine") stayed hidden.
    readonly property bool localSourceOverride: showLocalSource && WallpaperEngine.picker === "engine"
    readonly property string activeSource: localSourceOverride ? "files" : WallpaperEngine.picker
    readonly property var list: {
        const engine = WallpaperEngine.enabled && WallpaperEngine.detected ? WallpaperEngine.items : [];
        const raw = activeSource === "engine" ? engine
            : activeSource === "both" ? [...engine, ...files] : files;
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
        // WallpaperProvenance has already classified and recorded this profile
        // before this object exists in production. An existing profile
        // resolves from Windows at once; a fresh one waits for the record read
        // so a saved pick is known before the first frame settles.
        root.sourceFresh = !WallpaperProvenance.existing;
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
        // remember the path the engine just left. Otherwise refreshScreenFiles
        // decides whether the own desktop shows the bundled asset, a pick or a
        // display that follows Windows.
        if (externalWallpaperActive || WallpaperEngine.desktopHandedBack)
            return;
        if (root.sourceFresh) {
            root.refreshFreshScreenFiles();
            root.noteGoodFile(root.fileCurrent);
            return;
        }
        root.noteGoodFile(root.fileCurrent);
        root.refreshScreenFiles();
    }

    // A display shows its own pick, else the profile-wide pick, else the
    // bundled asset. A pick whose file is gone is skipped, so a deleted image
    // can never paint an empty desktop.
    function pickForScreen(id): string {
        const own = root.monitorPicks[id];
        if (typeof own === "string" && root.usableFile(own))
            return own;
        return root.usableFile(root.profilePick) ? root.profilePick : "";
    }
    function firstPickFile(): string {
        for (const screen of Quickshell.screens) {
            const id = Native.Wallpaper.screenTargetId(screen.name);
            if (!id)
                continue;
            const pick = root.pickForScreen(id);
            if (pick !== "")
                return pick;
        }
        return root.usableFile(root.profilePick) ? root.profilePick : "";
    }
    // Strict schema check. A truncated record, or one written by a build with
    // another schema version, is not a set of picks this build may apply:
    // returning null keeps it on disk and shows the bundled asset until an
    // explicit pick replaces it. Unknown top-level keys are preserved.
    function parseSourceRecord(content): var {
        let document = null;
        try { document = JSON.parse(String(content ?? "")); } catch (_) { return null; }
        if (!document || typeof document !== "object" || Array.isArray(document))
            return null;
        if (document.version !== 1)
            return null;
        if (document.wallpaper !== undefined && typeof document.wallpaper !== "string")
            return null;
        const monitors = {};
        if (document.monitors !== undefined) {
            if (!document.monitors || typeof document.monitors !== "object"
                    || Array.isArray(document.monitors))
                return null;
            for (const id of Object.keys(document.monitors)) {
                const value = document.monitors[id];
                if (typeof value !== "string" || value.length === 0)
                    return null;
                monitors[id] = value;
            }
        }
        return {wallpaper: String(document.wallpaper ?? ""), monitors: monitors, document: document};
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
                root.profilePick = parsed.wallpaper;
                root.monitorPicks = parsed.monitors;
            }
        }
        root.maybeResolve();
    }
    function maybeResolve(): void {
        if (root.sourceInitialized || !root.sourceComponentReady)
            return;
        // A fresh profile waits for the record read; its absence is itself the
        // answer (bundled asset). An existing profile never consults it.
        if (root.sourceFresh && root.sourceRecordHealth === "")
            return;
        root.resolveInitialSource();
    }
    // Decide the own wallpaper once per process. An existing profile follows
    // Windows, as every build before this change did. A fresh profile shows
    // the saved Caelestia picks or the bundled asset, and never adopts a
    // Windows image.
    function resolveInitialSource(): void {
        root.sourceInitialized = true;
        if (!root.sourceFresh) {
            // Exactly the released build's startup source: the saved Windows
            // wallpaper, or the bundled asset when Windows reports no path.
            const current = Native.Wallpaper.currentWallpaper().replace(/\\/g, "/");
            root.fileCurrent = current || root.fallback;
            root.refreshScreenFiles();
            if (!root.externalWallpaperActive)
                root.noteGoodFile(root.fileCurrent);
            root.applyPalette(false);
            return;
        }
        // A missing record means no Caelestia pick yet. A damaged or
        // unknown-version record cannot name a pick; an explicit pick may
        // replace it.
        if (root.sourceRecordHealth !== "valid") {
            root.profilePick = "";
            root.monitorPicks = {};
        }
        root.refreshFreshScreenFiles();
        root.applyPalette(false);
    }
    // Persist only what a fresh profile's user chose, and only after a pick.
    // A damaged or unknown-version record is left untouched unless an explicit
    // pick (force) replaces it. The marker writer has already created the
    // directory; a retry repairs it if it disappeared.
    function persistPicks(force): void {
        if (!root.sourceFresh || !root.sourceInitialized)
            return;
        const invalid = root.sourceRecordHealth === "invalid";
        if (invalid && force !== true)
            return;
        const base = !invalid && root.sourceRecordDocument
            && typeof root.sourceRecordDocument === "object"
            ? JSON.parse(JSON.stringify(root.sourceRecordDocument)) : {};
        base.version = 1;
        if (root.profilePick !== "" || base.wallpaper !== undefined)
            base.wallpaper = root.profilePick;
        // monitorPicks is the complete saved set: loading replaces it and a
        // pick adds to it. Writing it as-is lets a profile-wide pick clear the
        // old per-display picks instead of merging them back in.
        const picks = Object.assign({}, root.monitorPicks);
        if (Object.keys(picks).length > 0 || base.monitors !== undefined)
            base.monitors = picks;
        const text = JSON.stringify(base, null, 2) + "\n";
        if (root.sourceRecordConfirmed === text && !root.sourceRecordWriting) {
            root.sourceRecordDirty = false;
            return;
        }
        // The desired document can move ahead of the saved one. Only saved()
        // confirms it; a failure leaves this pending text in place to retry.
        root.sourceRecordPending = text;
        root.sourceRecordDirty = text !== root.sourceRecordConfirmed;
        root.sourceRecordDocument = base;
        if (invalid || root.sourceRecordHealth === "missing")
            root.sourceRecordHealth = "valid";
        root.writeSourceRecord();
    }
    // The marker writer creates the record directory at startup. If it is
    // removed while the shell runs, a retry has to repair it before the atomic
    // write can create the replacement file.
    function ensureSourceRecordDirectory(): void {
        const slash = root.sourceRecordPath.lastIndexOf("/");
        if (slash <= 0)
            return;
        const dir = root.sourceRecordPath.slice(0, slash);
        if (Native.FsUtils.classify(dir) !== "dir")
            Native.FsUtils.makePath(dir);
    }
    function writeSourceRecord(): void {
        if (!root.sourceInitialized || root.sourceRecordWriting
                || root.sourceRecordPending === root.sourceRecordConfirmed)
            return;
        root.ensureSourceRecordDirectory();
        root.sourceRecordWriting = true;
        root.sourceRecordWritingText = root.sourceRecordPending;
        // The pinned backend keeps the attempted bytes cached after a failed
        // write, so an identical setText() is dropped and no completion ever
        // arrives (backend issue #28). Recreate the writer for every attempt;
        // the workaround can go when the backend stops caching failed writes.
        sourceRecordWriter.active = false;
        sourceRecordWriter.active = true;
    }
    function confirmSourceRecord(): void {
        if (!root.sourceRecordWriting || root.sourceRecordVerifying)
            return;
        // saved() alone does not prove the bytes reached disk on this backend:
        // a failed atomic commit is only logged (backend issue #28). Read the
        // file back independently before treating the choice as saved.
        root.sourceRecordVerifying = true;
        sourceRecord.reload();
    }
    function acceptSourceRecord(): void {
        // The proposed text can advance while a write is in flight. Confirm
        // only the text that was actually handed to the writer, then write the
        // newer proposal if one exists.
        root.sourceRecordConfirmed = root.sourceRecordWritingText;
        root.sourceRecordWritingText = "";
        root.sourceRecordWriting = false;
        root.sourceRecordFailures = 0;
        root.sourceRecordError = "";
        root.sourceRecordDirty = root.sourceRecordPending !== root.sourceRecordConfirmed;
        // saved() still runs inside FileView's operation completion. A write
        // issued here would cancel that completion and lose its own saved().
        if (root.sourceRecordDirty)
            Qt.callLater(root.writeSourceRecord);
    }
    function failSourceRecord(error): void {
        root.sourceRecordVerifying = false;
        root.sourceRecordWritingText = "";
        root.sourceRecordWriting = false;
        root.sourceRecordFailures++;
        root.sourceRecordDirty = root.sourceRecordPending !== root.sourceRecordConfirmed;
        root.sourceRecordError = "could not save the wallpaper record: " + String(error);
        // One retry is normal after a transient lock. A third consecutive
        // failure is persistent and is reported once so it is not silent.
        if (root.sourceRecordFailures === 3)
            console.warn("CAELESTIA_WALLPAPER_RECORD_FAIL " + root.sourceRecordError);
        recordRetry.restart();
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
    // intentionally black image is as valid as any other. On a fresh profile
    // it is the profile-wide pick and supersedes per-display picks; on an
    // existing profile it is just the Windows wallpaper change of before.
    function adoptPickedFile(path): void {
        const local = String(path).replace(/^file:\/\/\//, "");
        fileCurrent = local;
        root.noteGoodFile(local);
        if (!root.sourceFresh)
            return;
        root.profilePick = local;
        root.monitorPicks = {};
        root.persistPicks(root.sourceRecordHealth === "invalid");
        root.refreshFreshScreenFiles();
    }
    // A pick made on one display records that display only. On a fresh profile
    // the other displays keep their own pick or the profile-wide pick, and a
    // later Windows notification cannot import old wallpapers onto them. On an
    // existing profile the display file is kept by setWallpaper, as before.
    function adoptPickedScreen(targetId, path): void {
        if (!root.sourceFresh)
            return;
        const local = String(path).replace(/^file:\/\/\//, "");
        root.monitorPicks = Object.assign({}, root.monitorPicks, {[targetId]: local});
        root.persistPicks(root.sourceRecordHealth === "invalid");
        root.refreshFreshScreenFiles();
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
    // Launcher picks are shared until the user has individual wallpapers.
    // Fresh profiles already persist that intent in monitorPicks; existing
    // profiles persist it in Windows, which refreshScreenFiles reads.
    readonly property bool individualWallpapers: (root.externalWallpaperActive
        && new Set(Object.values(WallpaperEngine.displays).map(project => project.path)).size > 1)
        || (root.sourceFresh ? Object.keys(root.monitorPicks).length > 0
            : new Set(Object.values(root.screenFiles)).size > 1)
    function defaultPickerTarget(screen): var {
        return individualWallpapers ? captureScreen(screen) : undefined;
    }
    // A fresh profile's displays show their picks or the bundled asset. Nothing
    // in this function reads Windows: an image written there by Windows
    // Settings, Wallpaper Engine or an older build is never adopted.
    function refreshFreshScreenFiles(): void {
        if (!root.sourceInitialized)
            return;
        if (externalWallpaperActive || WallpaperEngine.desktopHandedBack)
            return;
        const next = {};
        for (const screen of Quickshell.screens) {
            const id = Native.Wallpaper.screenTargetId(screen.name);
            if (!id)
                continue;
            next[id] = root.pickForScreen(id) || root.fallback;
        }
        root.screenFiles = next;
        // The palette follows the first display with a pick. Recomputing it on
        // every topology change keeps a disconnected display from staying the
        // colour source while the remaining monitor shows something else.
        const first = root.firstPickFile();
        root.fileCurrent = first !== "" ? first : root.fallback;
        if (!root.externalWallpaperActive)
            root.noteGoodFile(root.fileCurrent);
    }
    // An existing profile reads each display's Windows wallpaper, as every
    // build before this change did. One display's pick never imports the other
    // displays' older images because each display is read independently.
    function refreshScreenFiles(): void {
        if (!root.sourceInitialized)
            return;
        if (externalWallpaperActive || WallpaperEngine.desktopHandedBack)
            return;
        if (root.sourceFresh) {
            root.refreshFreshScreenFiles();
            return;
        }
        const next = {};
        for (const screen of Quickshell.screens) {
            const id = Native.Wallpaper.screenTargetId(screen.name);
            if (!id)
                continue;
            const file = Native.Wallpaper.currentWallpaperForScreen(screen.name).replace(/\\/g, "/");
            next[id] = root.usableFile(file) ? file : screenFiles[id] || handbackWallpaper;
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

    // Upstream services/Wallpapers.qml registers this target; the Windows
    // adapter replaces that file, so it must keep the same IPC contract.
    // set(path) goes through setWallpaper, the same path a launcher or Nexus
    // pick uses, including the fresh-profile pick record and the control gate.
    IpcHandler {
        function get(): string {
            return root.actualCurrent;
        }

        function set(path: string): void {
            root.setWallpaper(path);
        }

        function list(): string {
            // `files` is the adapter's scan, the counterpart of upstream's
            // scanned `list`; the picker list also carries engine projects.
            return root.files.map(w => w.path).join("\n");
        }

        target: "wallpaper"
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

    // Owned by the shell and never watched: a pick or a saved pick is the only
    // reader, and reloading our own write has no new decision to make. The
    // reader and writer are separate views because a save issued from the
    // read's onLoaded callback would cancel that read and lose the writer's
    // saved() signal. Atomic writes keep a crash from leaving a partial
    // record. Errors stay in a property instead of being logged: a normal
    // fresh start must emit no QML diagnostic.
    FileView {
        id: sourceRecord

        path: root.sourceRecordPath
        blockLoading: true
        watchChanges: false
        printErrors: false
        onLoaded: {
            if (root.sourceRecordVerifying) {
                // saved() is not proof of the bytes on this backend (issue
                // #28), so the record is confirmed only after an independent
                // read returns exactly what the writer was given.
                root.sourceRecordVerifying = false;
                if (text() === root.sourceRecordWritingText)
                    root.acceptSourceRecord();
                else
                    root.failSourceRecord("the saved record did not match the file");
                return;
            }
            root.readSourceRecord(text(), false);
        }
        onLoadFailed: error => {
            if (root.sourceRecordVerifying) {
                root.sourceRecordVerifying = false;
                root.failSourceRecord("the saved record could not be read back");
                return;
            }
            root.readSourceRecord("", error === FileViewError.FileNotFound);
        }
    }

    // Recreated for every attempt. A FileView that failed a write caches the
    // attempted bytes, so reusing it would drop an identical retry (backend
    // issue #28). This can become a plain FileView when that lands.
    Loader {
        id: sourceRecordWriter

        active: false
        sourceComponent: Component {
            FileView {
                path: root.sourceRecordPath
                preload: false
                atomicWrites: true
                watchChanges: false
                printErrors: false
                onSaved: root.confirmSourceRecord()
                onSaveFailed: error => root.failSourceRecord(error)
            }
        }
        onLoaded: {
            if (root.sourceRecordWriting)
                item.setText(root.sourceRecordWritingText);
        }
    }

    Timer {
        id: recordRetry
        interval: root.sourceRecordRetryInterval
        repeat: false
        onTriggered: root.writeSourceRecord()
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
            // An explicit pick is recorded before any native notification: a
            // global pick sets the profile-wide pick on a fresh profile or
            // changes every display on an existing one, while a display pick
            // records only that display. Untouched displays keep their own
            // source and are not re-read from Windows on a fresh profile.
            root.markOpened(local);
            if (target) {
                screenFiles = Object.assign({}, screenFiles, {[target.targetId]: local});
                root.adoptPickedScreen(target.targetId, local);
            } else {
                screenFiles = {};
                root.adoptPickedFile(local);
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
            // A fresh profile does not follow Windows. A Windows Settings
            // change, a Wallpaper Engine write and an older build's rollback
            // are all changes to an image Caelestia did not choose, so the
            // bundled asset or the saved Caelestia pick stays.
            if (root.sourceFresh)
                return;
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
