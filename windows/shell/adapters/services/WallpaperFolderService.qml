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
// variables, so no user path is ever interpolated into a command line.
//
// A copy writes a unique `.caelestia-import-<32 hex>.partial` file in the
// hidden `.caelestia-import-staging` folder inside the scanned folder, then
// publishes it with a no-overwrite rename only after the bytes are complete.
// Staging inside the destination keeps publishing a same-volume rename. The
// scan lists only image extensions and never descends into subfolders, and the
// staging folder is hidden, so neither it nor a temporary is ever a wallpaper.
//
// If the shell is killed mid-copy the child dies with it and the temporary is
// left behind. The next copy removes abandoned temporaries only inside its own
// staging folder, only names matching the exact `.caelestia-import-<32 hex
// GUID>.partial` pattern, and only when they are more than an hour old. A
// retry therefore still finds the plain name free instead of dropping a
// full-size truncated file beside a numbered copy. Nothing in the user's
// wallpapers folder itself is ever deleted.
//
// A job that never reports is killed after five minutes and the kill is
// followed by a short grace period, because an unavailable network folder used
// to leave every folder action disabled for the rest of the session. The same
// stop path backs the visible cancel control.
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
    // "timeout" or "cancel" once a job is being stopped. The exit reports the
    // reason so a killed child is not mistaken for a generic failure.
    property string jobStopReason: ""
    // Five minutes covers a large local copy and a slow cloud hydration, and
    // is short enough that a stalled destination cannot hold every folder
    // action for the rest of the session. Fixtures shorten both values to
    // exercise the watchdog; production never assigns them.
    property int jobTimeoutMs: 300000
    property int jobExitGraceMs: 5000

    // A job is one inbox PowerShell invocation. The script is constant; the
    // paths arrive in the environment. Console output is ASCII:
    //   COPY_OK <n>   the source was published as the n-th free name
    //   FOLDER_OK     the directory exists
    //   ERROR:<kind>  the job failed; the detail goes to stderr
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
    # The service owns this staging folder. It sits inside the scanned folder
    # so publishing stays a same-volume rename, and it is hidden so Explorer
    # users do not see half-written copies.
    $staging = [IO.Path]::Combine($folder, '.caelestia-import-staging')
    [IO.Directory]::CreateDirectory($staging) | Out-Null
    try {
        $attributes = [IO.File]::GetAttributes($staging)
        if (($attributes -band [IO.FileAttributes]::Hidden) -eq 0) {
            [IO.File]::SetAttributes($staging, $attributes -bor [IO.FileAttributes]::Hidden)
        }
    } catch {
    }
    # A killed shell leaves its copy behind as a temporary. Cleanup only ever
    # looks inside the staging folder, only at the exact name this service
    # writes (a real 32-hex GUID), and only at an old one: another shell
    # instance may still be writing a fresh one. A user file in the wallpapers
    # folder is never touched, whatever its name. Cleanup is best-effort: a
    # denied or unreadable staging folder must not stop the copy, which reports
    # the access failure itself.
    try {
        $staleBefore = [DateTime]::UtcNow.AddMinutes(-60)
        foreach ($stale in [IO.Directory]::EnumerateFiles($staging, '.caelestia-import-*.partial')) {
            $staleName = [IO.Path]::GetFileName($stale)
            if ($staleName.Length -ne 58 -or -not $staleName.StartsWith('.caelestia-import-') -or -not $staleName.EndsWith('.partial')) {
                continue
            }
            $identifier = [Guid]::Empty
            if (-not [Guid]::TryParseExact($staleName.Substring(18, 32), 'N', [ref]$identifier)) {
                continue
            }
            try {
                if ([IO.File]::GetLastWriteTimeUtc($stale) -lt $staleBefore) {
                    [IO.File]::Delete($stale)
                }
            } catch {
            }
        }
    } catch {
    }
    $name = [IO.Path]::GetFileName($source)
    $stem = [IO.Path]::GetFileNameWithoutExtension($name)
    $extension = [IO.Path]::GetExtension($name)
    # Same folder as the published name, so publishing is a same-volume rename
    # and not a second copy that can be interrupted under the final name.
    $temporary = [IO.Path]::Combine($staging, '.caelestia-import-' + [Guid]::NewGuid().ToString('N') + '.partial')
    try {
        [IO.File]::Copy($source, $temporary, $false)
        $index = 1
        while ($index -lt 1000) {
            if ($index -eq 1) {
                $candidate = [IO.Path]::Combine($folder, $name)
            } else {
                $candidate = [IO.Path]::Combine($folder, $stem + ' (' + $index + ')' + $extension)
            }
            try {
                # Move never replaces an existing file. A target that appeared
                # after the loop started makes it fail and the next number win.
                [IO.File]::Move($temporary, $candidate)
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
    } finally {
        # A completed job has moved the file away. A failed one removes its own
        # temporary; a killed process leaves it for the next copy's cleanup.
        if ([IO.File]::Exists($temporary)) {
            try {
                [IO.File]::Delete($temporary)
            } catch {
            }
        }
    }
} catch {
    # PowerShell wraps failures from a .NET call in MethodInvocationException.
    # Walk down to the real exception so an inner UnauthorizedAccessException
    # is not reported as a generic io failure.
    $exception = $_.Exception
    while ($null -ne $exception.InnerException -and $exception.InnerException -ne $exception) {
        $exception = $exception.InnerException
    }
    $type = $exception.GetType().Name
    [Console]::Error.WriteLine($type + ': ' + $exception.Message)
    [Console]::Error.WriteLine('HRESULT: 0x' + $exception.HResult.ToString('X8'))
    if ($type -eq 'UnauthorizedAccessException') {
        [Console]::Out.WriteLine('ERROR:access')
    } elseif ($type -eq 'FileNotFoundException' -or $type -eq 'DirectoryNotFoundException') {
        [Console]::Out.WriteLine('ERROR:source')
    } else {
        [Console]::Out.WriteLine('ERROR:io')
    }
    exit 2
}`

    // The child command is a property so a fixture can answer with a
    // controlled child that stalls. Production always runs jobScript above.
    property var jobCommand: ["powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", root.jobScript]

    // Starts one folder/copy job. Fixtures replace this to answer immediately.
    property var startFileJob: (kind, source, folder) => root.startProcess(kind, source, folder)
    property var notify: (message, icon) => Toaster.toast(Tr.tr("Wallpapers"), message, icon || "error")
    property var reloadWallpapers: () => Wallpapers.reload()
    // The reveal is for the engine picker only. "both" already lists local
    // files, and setting the override there would hide its engine entries.
    property var revealLocalFiles: () => {
        if (WallpaperEngine.picker === "engine")
            Wallpapers.showLocalSource = true;
    }
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

    // True while a child is alive, including the short window between a kill
    // and its exit. Exposed for the cancel control and the fixture.
    readonly property bool jobRunning: job.running

    function startProcess(kind, source, folder): bool {
        // A killed child that has not reported its exit yet still owns the
        // Process. Starting a second one would never launch, and its exit
        // would finish the new job.
        if (job.running) {
            console.log("CAELESTIA_WALLPAPER_FOLDER_DIAG kind=" + String(kind) + " result=failed category=busy");
            return false;
        }
        root.jobKind = String(kind);
        root.jobSource = String(source ?? "");
        root.jobFolder = String(folder ?? "");
        root.jobStarted = true;
        root.jobStopReason = "";
        job.running = true;
        if (!job.running) {
            root.jobStarted = false;
            return false;
        }
        jobWatchdog.restart();
        return true;
    }

    // The category both the user message and the diagnostic name. The script
    // writes a marker for the failures it controls; a killed or crashed child
    // only leaves its exception on stderr, so that is inspected too.
    function errorCategory(code, output, error): string {
        const marker = /^ERROR:([a-z]+)$/.exec(String(output ?? "").trim());
        if (marker)
            return marker[1];
        const detail = String(error ?? "");
        if (/UnauthorizedAccessException|Access is denied/i.test(detail))
            return "access";
        if (/FileNotFoundException|DirectoryNotFoundException|could not find/i.test(detail))
            return "source";
        if (/IOException|being used by another process|not enough space/i.test(detail))
            return "io";
        return code === 0 ? "" : "io";
    }

    function failureMessage(kind, category): string {
        if (kind === "folder") {
            if (category === "access")
                return Tr.tr("Windows denied access to the wallpapers folder");
            return Tr.tr("Could not create the wallpapers folder");
        }
        if (category === "source")
            return Tr.tr("That image could not be read. It may have moved or been deleted");
        if (category === "access")
            return Tr.tr("Windows denied access to the wallpapers folder");
        if (category === "names")
            return Tr.tr("The wallpapers folder has no free name for that image");
        if (category === "io")
            return Tr.tr("Windows could not copy that image to the wallpapers folder");
        return Tr.tr("Could not add that image to the wallpapers folder");
    }

    function stopMessage(kind, reason): string {
        if (reason === "cancel")
            return kind === "folder" ? Tr.tr("Creating the wallpapers folder was cancelled") : Tr.tr("Adding the image was cancelled");
        return kind === "folder" ? Tr.tr("Creating the wallpapers folder took too long and was stopped")
            : Tr.tr("Adding the image took too long and was stopped");
    }

    // One diagnostic line per stopped or failed job. The child's stderr can
    // contain a drive or UNC path, and core/redact.hpp treats path identifiers
    // as private, so only the exception type name and the numeric HRESULT are
    // copied out of it. The message itself never reaches the log.
    function safeDiagnostic(error): string {
        const text = String(error ?? "");
        const firstLine = text.split(/\r?\n/, 1)[0] ?? "";
        const type = /^\s*([A-Za-z][A-Za-z0-9]*Exception)\s*:/.exec(firstLine);
        const hresult = /HResult\s*[:=]?\s*(0x[0-9A-Fa-f]{8})\b/i.exec(text);
        return (type ? " exception=" + type[1].slice(0, 64) : "") + (hresult ? " hresult=" + hresult[1].toLowerCase() : "");
    }

    function reportJob(kind, code, category, error): void {
        console.log("CAELESTIA_WALLPAPER_FOLDER_DIAG kind=" + kind + " result=failed code=" + code + " category=" + (category || "unknown") + root.safeDiagnostic(error));
    }

    // Finishes the active job. Public so offscreen fixtures can answer the
    // recording startFileJob without starting a process.
    function finishJob(code, output, error): void {
        if (!root.busy)
            return;
        const kind = root.jobKind;
        const source = root.jobSource;
        const text = String(output ?? "").trim();
        const reason = root.jobStopReason;
        const copied = /^COPY_OK ([0-9]+)$/.exec(text);
        const index = copied ? parseInt(copied[1]) : 0;
        const created = kind === "folder" && code === 0 && text === "FOLDER_OK";
        const published = kind === "copy" && code === 0 && index >= 1;
        // A kill that raced a job already completing is a success: the marker
        // proves the copy was published before the stop was requested.
        const stopped = created || published ? "" : reason;
        const category = stopped.length > 0 ? stopped : root.errorCategory(code, text, error);
        jobWatchdog.stop();
        exitGrace.stop();
        root.busy = false;
        root.jobStarted = false;
        root.jobStopReason = "";
        root.jobKind = "";
        root.jobSource = "";
        root.jobFolder = "";
        if (kind === "folder") {
            if (created) {
                root.folderFinished(true);
                return;
            }
            root.reportJob(kind, code, category, error);
            if (stopped.length > 0)
                root.notify(root.stopMessage(kind, stopped), stopped === "cancel" ? "wallpaper" : undefined);
            else
                root.notify(root.failureMessage(kind, category));
            root.folderFinished(false);
            return;
        }
        if (stopped.length > 0) {
            root.reportJob(kind, code, category, error);
            root.notify(root.stopMessage(kind, stopped), stopped === "cancel" ? "wallpaper" : undefined);
            return;
        }
        if (!published || index < 1) {
            root.reportJob(kind, code, category, error);
            root.notify(root.failureMessage(kind, category));
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

    // Stops the active job for the watchdog or the cancel control. The child
    // is killed and the job finishes when it reports its exit, or after the
    // grace period if the kill produces none.
    function cancelJob(reason): bool {
        if (!root.busy || root.jobStopReason.length > 0)
            return false;
        root.jobStopReason = String(reason ?? "cancel");
        if (job.running) {
            // Signal 9 maps to QProcess::kill on Windows; terminate asks a
            // console child with no window to close, which it can ignore.
            job.signal(9);
            exitGrace.restart();
        } else {
            root.finishJob(-1, "", jobError.text);
        }
        return true;
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
        root.jobStopReason = "";
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
        root.jobStopReason = "";
        if (!root.startFileJob("copy", source, root.jobFolder)) {
            root.finishJob(-1, "");
            return false;
        }
        return true;
    }

    function toggleLocalSource(): void {
        // The control is only shown for the engine picker, which is the only
        // source the local-only override replaces.
        if (WallpaperEngine.picker !== "engine")
            return;
        Wallpapers.showLocalSource = !Wallpapers.showLocalSource;
    }

    // The folder bar's refresh action shows the folder it names when an engine
    // picker is hiding it, then rescans. "both" already includes local files,
    // so forcing it local-only there would drop the engine entries.
    function refreshLocal(): void {
        if (WallpaperEngine.picker === "engine")
            Wallpapers.showLocalSource = true;
        root.reloadWallpapers();
    }

    Process {
        id: job

        command: root.jobCommand
        environment: ({
                CAELESTIA_WALLPAPER_JOB_MODE: root.jobKind,
                CAELESTIA_WALLPAPER_JOB_SOURCE: root.jobSource,
                CAELESTIA_WALLPAPER_JOB_FOLDER: root.jobFolder
            })
        stdout: StdioCollector {
            id: jobOutput
        }
        stderr: StdioCollector {
            id: jobError
        }

        onStarted: root.jobStarted = false
        onExited: code => root.finishJob(code, jobOutput.text, jobError.text)
        onRunningChanged: {
            if (job.running || !root.jobStarted)
                return;
            // FailedToStart clears running without emitting exited.
            Qt.callLater(() => {
                if (!job.running && root.jobStarted) {
                    root.jobStarted = false;
                    root.finishJob(-1, "", jobError.text);
                }
            });
        }
    }

    // The watchdog covers a stalled UNC or OneDrive destination, and a child
    // that never answers for any other reason.
    Timer {
        id: jobWatchdog

        interval: root.jobTimeoutMs
        onTriggered: root.cancelJob("timeout")
    }

    // A killed child has jobExitGraceMs to report its exit. If it does not,
    // the job still finishes so every folder action cannot stay disabled.
    Timer {
        id: exitGrace

        interval: root.jobExitGraceMs
        onTriggered: {
            if (!root.busy)
                return;
            root.finishJob(-1, "", jobError.text);
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
