pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
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
// Folder creation and the copy run in an inbox PowerShell process, not on the
// GUI thread. A large image, a cloud placeholder being hydrated, or a stalled
// UNC destination used to freeze the whole shell while QFile::copy and
// QDir::mkpath ran. The process talks to this singleton through environment
// variables, so no user path is ever interpolated into a command line, and the
// destination naming is decided by the copy itself: an existing file makes the
// copy fail and the next numbered name is tried. That removes the race between
// a separate existence check and the copy.
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

    // One filesystem job at a time. Both surfaces disable their actions while
    // this is true, so two copies cannot race for the same numbered name.
    property bool busy: false
    property string jobKind: ""
    property string jobSource: ""
    property string jobFolder: ""
    // True between Process start and QProcess::started. A failed start clears
    // running without emitting exited, so onRunningChanged reports the failure.
    property bool jobStarted: false

    // A job is one inbox PowerShell invocation. The script is constant; the
    // paths arrive in the environment. Console output is ASCII:
    //   COPY_OK <n>   the source was copied as the n-th free name
    //   FOLDER_OK     the directory exists
    //   ERROR:<kind>  the job failed
    readonly property string jobScript: `$ErrorActionPreference = 'Stop'
$mode = $env:CAELESTIA_WALLPAPER_JOB_MODE
$folder = $env:CAELESTIA_WALLPAPER_JOB_FOLDER
$source = $env:CAELESTIA_WALLPAPER_JOB_SOURCE
if ([String]::IsNullOrWhiteSpace($folder)) {
    [Console]::Out.WriteLine('ERROR:folder')
    exit 2
}
try {
    if ($mode -eq 'folder') {
        [IO.Directory]::CreateDirectory($folder) | Out-Null
        [Console]::Out.WriteLine('FOLDER_OK')
        exit 0
    }
    if ($mode -ne 'copy') {
        [Console]::Out.WriteLine('ERROR:mode')
        exit 2
    }
    if ([String]::IsNullOrWhiteSpace($source)) {
        [Console]::Out.WriteLine('ERROR:source')
        exit 2
    }
    $source = [IO.Path]::GetFullPath($source)
    if (-not [IO.File]::Exists($source)) {
        [Console]::Out.WriteLine('ERROR:source')
        exit 2
    }
    [IO.Directory]::CreateDirectory($folder) | Out-Null
    $name = [IO.Path]::GetFileName($source)
    $stem = [IO.Path]::GetFileNameWithoutExtension($name)
    $extension = [IO.Path]::GetExtension($name)
    $index = 1
    while ($index -lt 1000) {
        if ($index -eq 1) {
            $candidate = [IO.Path]::Combine($folder, $name)
        } else {
            $candidate = [IO.Path]::Combine($folder, $stem + ' (' + $index + ')' + $extension)
        }
        if ([IO.File]::Exists($candidate) -or [IO.Directory]::Exists($candidate)) {
            $index = $index + 1
            continue
        }
        try {
            [IO.File]::Copy($source, $candidate, $false)
            [Console]::Out.WriteLine('COPY_OK ' + $index)
            exit 0
        } catch [IO.IOException] {
            if ([IO.File]::Exists($candidate) -or [IO.Directory]::Exists($candidate)) {
                $index = $index + 1
                continue
            }
            throw
        }
    }
    [Console]::Out.WriteLine('ERROR:names')
    exit 2
} catch {
    [Console]::Out.WriteLine('ERROR:io')
    exit 2
}`

    // Starts one folder/copy job. Fixtures replace this to answer immediately.
    property var startFileJob: (kind, source, folder) => root.startProcess(kind, source, folder)
    property var notify: (message, icon) => Toaster.toast(Tr.tr("Wallpapers"), message, icon || "error")
    property var reloadWallpapers: () => Wallpapers.reload()
    property var revealLocalFiles: () => Wallpapers.showLocalSource = true
    property var chooseAndAdd: () => dialog.open()

    // While Wallpaper Engine's own picker is active, the local scan is hidden.
    // The pickers can switch the displayed source without changing the engine
    // default or its saved setting.
    readonly property bool enginePickerActive: WallpaperEngine.picker === "engine"
    readonly property bool localSourceShown: Wallpapers.showLocalSource

    // Emitted once per folder job, after busy cleared. The requesting component
    // opens Explorer only on success; the failure toast is sent here so it
    // appears even if the picker closed while the job ran.
    signal folderFinished(bool ok)

    function startProcess(kind, source, folder): bool {
        root.jobKind = String(kind);
        root.jobSource = String(source ?? "");
        root.jobFolder = String(folder ?? "");
        root.jobStarted = true;
        job.running = true;
        if (!job.running) {
            root.jobStarted = false;
            return false;
        }
        return true;
    }

    // Finishes the active job. Public so offscreen fixtures can answer the
    // recording startFileJob without starting a process.
    function finishJob(code, output): void {
        if (!root.busy)
            return;
        const kind = root.jobKind;
        const source = root.jobSource;
        const text = String(output ?? "").trim();
        root.busy = false;
        root.jobStarted = false;
        root.jobKind = "";
        root.jobSource = "";
        root.jobFolder = "";
        if (kind === "folder") {
            const ok = code === 0 && text === "FOLDER_OK";
            if (!ok)
                root.notify(Tr.tr("Could not create the wallpapers folder"));
            root.folderFinished(ok);
            return;
        }
        const match = /^COPY_OK ([0-9]+)$/.exec(text);
        const index = match ? parseInt(match[1]) : 0;
        if (code !== 0 || index < 1) {
            root.notify(Tr.tr("Could not add that image to the wallpapers folder"));
            return;
        }
        const name = root.wallpaperName(source);
        const target = root.targetName(name, index);
        // The facade does not watch the folder, so refresh it explicitly. The
        // scan is asynchronous; the picker updates through Wallpapers.list.
        root.reloadWallpapers();
        // The copy is visible only when the displayed source includes local
        // files. Wallpaper Engine's own picker choice is left untouched.
        root.revealLocalFiles();
        root.notify(Tr.tr("Added %1 to the wallpapers folder").arg(target), "wallpaper");
    }

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

    // The copy reports which numbered name it used; the notification names the
    // same file. The existing name is never replaced.
    function targetName(name: string, index: int): string {
        if (index <= 1)
            return name;
        const dot = name.lastIndexOf(".");
        const base = dot > 0 ? name.substring(0, dot) : name;
        const suffix = dot > 0 ? name.substring(dot) : "";
        return `${base} (${index})${suffix}`;
    }

    function targetPath(name: string, index: int): string {
        return Paths.joinPath(Paths.wallsdir, root.targetName(name, index));
    }

    function ensureFolder(folder): bool {
        if (root.busy)
            return false;
        root.busy = true;
        root.jobKind = "folder";
        root.jobSource = "";
        root.jobFolder = String(folder ?? "");
        root.jobStarted = false;
        if (!root.startFileJob("folder", "", root.jobFolder)) {
            root.finishJob(-1, "");
            return false;
        }
        return true;
    }

    // Starts a copy into the scanned folder. Returns true when the job was
    // accepted; completion arrives through finishJob(). An existing file is
    // never replaced: the target gets a numbered suffix, and the non-
    // overwriting copy retries the next name if another writer won the race.
    function addWallpaper(selected): bool {
        if (root.busy)
            return false;
        const name = root.wallpaperName(selected);
        if (!root.validWallpaperName(name)) {
            root.notify(Tr.tr("That file name cannot be used for a wallpaper"));
            return false;
        }
        if (!root.supportedWallpaper(name)) {
            root.notify(Tr.tr("Only PNG, JPEG, BMP and WebP images can be added"));
            return false;
        }
        if (Paths.wallsdir.length === 0) {
            root.notify(Tr.tr("Could not create the wallpapers folder"));
            return false;
        }
        // Native path for the process; the URL is decoded once by the same
        // helper the Nexus picker uses for its selected file.
        const source = CUtils.toLocalFile(Qt.resolvedUrl(Paths.absolutePath(String(selected))));
        if (!source || source.length === 0) {
            root.notify(Tr.tr("Could not add that image to the wallpapers folder"));
            return false;
        }
        root.busy = true;
        root.jobKind = "copy";
        root.jobSource = source;
        root.jobFolder = Paths.wallsdir;
        root.jobStarted = false;
        if (!root.startFileJob("copy", source, root.jobFolder)) {
            root.finishJob(-1, "");
            return false;
        }
        return true;
    }

    function toggleLocalSource(): void {
        Wallpapers.showLocalSource = !Wallpapers.showLocalSource;
    }

    // The folder bar's refresh action shows the folder it names when an engine
    // picker is hiding it, then rescans. Opening a picker also rescans, which
    // covers images copied in through Explorer while the picker was closed.
    function refreshLocal(): void {
        Wallpapers.showLocalSource = true;
        root.reloadWallpapers();
    }

    Process {
        id: job

        command: ["powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", root.jobScript]
        environment: ({
                CAELESTIA_WALLPAPER_JOB_MODE: root.jobKind,
                CAELESTIA_WALLPAPER_JOB_SOURCE: root.jobSource,
                CAELESTIA_WALLPAPER_JOB_FOLDER: root.jobFolder
            })
        stdout: StdioCollector {
            id: jobOutput
        }
        stderr: StdioCollector {
        }

        onStarted: root.jobStarted = false
        onExited: code => root.finishJob(code, jobOutput.text)
        onRunningChanged: {
            if (job.running || !root.jobStarted)
                return;
            // FailedToStart clears running without emitting exited.
            Qt.callLater(() => {
                if (!job.running && root.jobStarted) {
                    root.jobStarted = false;
                    root.finishJob(-1, "");
                }
            });
        }
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
