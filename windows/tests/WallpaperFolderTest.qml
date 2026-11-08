import QtQuick
import QtTest
import Quickshell
import Quickshell.Io
import Quickshell.Windows as Native
import Caelestia.Config
import qs.components
import qs.components.controls
import qs.components.wallpaper
import qs.modules.launcher
import qs.modules.nexus as Nexus
import qs.modules.nexus.pages.wallandstyle as WallStyle
import qs.services
import qs.utils

// Launcher and Nexus wallpaper-folder visibility (issue #62, section 2).
//
// Runs the real shared components and both real picker adapters in the staged
// Windows graph. Folder creation, opening, existence checks, copies, the
// native picker and the rescan are replaced with recording functions for the
// deterministic cases, so no native dialog opens and no Explorer window or
// user file is touched. The final phase runs the real asynchronous jobs
// against the disposable folder supplied by Test-WallpaperFolder.ps1, then
// copies a file in behind the facade's back to prove that reopening the picker
// discovers it.
ShellRoot {
    id: root

    Config.screen: Quickshell.screens[0]?.name ?? ""
    Tokens.screen: Quickshell.screens[0]?.name ?? ""

    property int assertions: 0
    property var input: null
    property var folder: null
    property var picker: null
    property var nexusPage: null
    property var opened: []
    property var jobs: []
    property var notifications: []
    property int pickers: 0
    property int reloads: 0
    property int reveals: 0
    property var defaultStartJob: null
    property var defaultReload: null
    property var defaultReveal: null
    property var defaultJobCommand: WallpaperFolderService.jobCommand
    property int defaultJobTimeout: 0
    property int defaultJobExitGrace: 0
    property string externalName: ""
    property int externalCode: -1
    property bool productionPickerActive: false
    // The real facade's asynchronous folder listing. The interruption phase
    // polls it for the temporary file the copy writes.
    property bool probeDone: false
    property var probeEntries: []
    property int probeRequest: -1
    property bool watchingPartial: false
    property bool partialSeen: false
    property bool tempSeedDone: false
    property int tempSeedCode: -1
    property bool stagingProbeDone: false
    property string stagingAttributes: ""
    property bool deniedDone: false
    property int deniedCode: -1
    property string deniedOutput: ""
    property string deniedError: ""

    readonly property string wallsPath: Quickshell.env("CAELESTIA_WALLPAPER_DIR") || ""
    readonly property string realSourcePath: Quickshell.env("CAELESTIA_WALLPAPER_SOURCE") || ""
    readonly property string cleanupSourcePath: Quickshell.env("CAELESTIA_WALLPAPER_CLEANUP_SOURCE") || ""
    readonly property string largeSourcePath: Quickshell.env("CAELESTIA_WALLPAPER_LARGE_SOURCE") || ""
    readonly property string retrySourcePath: Quickshell.env("CAELESTIA_WALLPAPER_RETRY_SOURCE") || ""
    readonly property string deniedFolderPath: Quickshell.env("CAELESTIA_WALLPAPER_DENIED_DIR") || ""
    // The service owns this hidden folder. Nothing in the wallpapers folder
    // itself is staged or cleaned.
    readonly property string stagingFolderName: ".caelestia-import-staging"
    readonly property string stagingPath: Paths.joinPath(Paths.wallsdir, stagingFolderName)
    readonly property string staleTempName: ".caelestia-import-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.partial"
    readonly property string freshTempName: ".caelestia-import-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.partial"
    readonly property string userGuidTempName: ".caelestia-import-cccccccccccccccccccccccccccccccc.partial"
    readonly property string lookalikeTempName: ".caelestia-import-family-holiday.partial"

    readonly property Component inputComponent: Component {
        TestCase { when: false }
    }
    readonly property Component folderComponent: Component {
        WallpaperFolder {}
    }
    readonly property Component emptyComponent: Component {
        WallpaperEmptyState {}
    }
    // The real launcher adapter. Its required collaborators are inert objects;
    // the point is that the shipped file loads and its header is wired.
    readonly property Component pickerComponent: Component {
        WallpaperList {
            height: 300
            search: SearchBar {
                text: ">wallpaper "
            }
            screenState: launcherScreenState
            panels: QtObject {
                property QtObject bar: QtObject {
                    property real implicitWidth: 40
                }
                property QtObject popouts: QtObject {
                    property bool hasCurrent: false
                    property real currentCenter: 0
                    property real nonAnimHeight: 0
                    property real nonAnimWidth: 0
                }
                property QtObject utilities: QtObject {
                    property real implicitWidth: 0
                }
            }
            content: QtObject {
                property real implicitHeight: 100
            }
        }
    }
    readonly property Component nexusComponent: Component {
        WallStyle.WallpaperSelect {
            width: 900
            height: 900
            nState: Nexus.NexusState {}
        }
    }
    // The fixture never says how wide the picker should be. A production
    // ContentList Loader sizes it from implicitWidth, which is where the path
    // used to collapse to zero.
    readonly property string externalCopyScript: `$ErrorActionPreference = 'Stop'
[IO.Directory]::CreateDirectory($env:CAELESTIA_TEST_FOLDER) | Out-Null
[IO.File]::Copy($env:CAELESTIA_TEST_SOURCE, [IO.Path]::Combine($env:CAELESTIA_TEST_FOLDER, $env:CAELESTIA_TEST_NAME), $false)`
    // One old temporary of the copy script's own pattern and one fresh one in
    // the service staging folder, then user files in the wallpapers folder
    // itself: a lookalike name, a GUID-shaped name and an unrelated
    // `.partial`. The next real copy may remove only the old owned one.
    readonly property string tempSeedScript: `$ErrorActionPreference = 'Stop'
$folder = $env:CAELESTIA_TEST_FOLDER
$staging = [IO.Path]::Combine($folder, $env:CAELESTIA_TEST_STAGING)
[IO.Directory]::CreateDirectory($staging) | Out-Null
$stale = [IO.Path]::Combine($staging, $env:CAELESTIA_TEST_STALE)
$fresh = [IO.Path]::Combine($staging, $env:CAELESTIA_TEST_FRESH)
$lookalike = [IO.Path]::Combine($folder, $env:CAELESTIA_TEST_LOOKALIKE)
$userTemp = [IO.Path]::Combine($folder, $env:CAELESTIA_TEST_USER_GUID)
$userPartial = [IO.Path]::Combine($folder, 'notes.partial')
[IO.File]::WriteAllText($stale, 'stale')
[IO.File]::WriteAllText($fresh, 'fresh')
[IO.File]::WriteAllText($lookalike, 'lookalike')
[IO.File]::WriteAllText($userTemp, 'user')
[IO.File]::WriteAllText($userPartial, 'user')
[IO.File]::SetLastWriteTimeUtc($stale, [DateTime]::UtcNow.AddHours(-2))
[IO.File]::SetLastWriteTimeUtc($lookalike, [DateTime]::UtcNow.AddHours(-2))
[IO.File]::SetLastWriteTimeUtc($userTemp, [DateTime]::UtcNow.AddHours(-2))
[IO.File]::SetLastWriteTimeUtc($userPartial, [DateTime]::UtcNow.AddHours(-2))`
    // The staging folder must be hidden, because it sits in the user's
    // wallpapers folder where Explorer would otherwise show it.
    readonly property string stagingProbeScript: `$ErrorActionPreference = 'Stop'
$attributes = [IO.File]::GetAttributes($env:CAELESTIA_TEST_STAGING)
if (($attributes -band [IO.FileAttributes]::Hidden) -ne 0) {
    [Console]::Out.WriteLine('HIDDEN')
} else {
    [Console]::Out.WriteLine('VISIBLE')
}`

    FloatingWindow {
        id: win

        visible: true
        implicitWidth: 960
        implicitHeight: 720

        Item {
            id: host

            anchors.fill: parent
        }

        Loader {
            id: productionPicker

            height: 300
            active: root.productionPickerActive
            sourceComponent: root.pickerComponent
        }
    }

    ScreenState {
        id: launcherScreenState

        modelData: Quickshell.screens[0] ?? null
    }

    // Test-only copy into the real disposable folder. Bypasses the facade so
    // the fixture can prove an externally copied image only appears after the
    // picker rescans.
    Process {
        id: externalCopy

        command: ["powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", root.externalCopyScript]
        environment: ({
                CAELESTIA_TEST_SOURCE: root.realSourcePath,
                CAELESTIA_TEST_FOLDER: Paths.wallsdir,
                CAELESTIA_TEST_NAME: root.externalName
            })
        stdout: StdioCollector {}
        stderr: StdioCollector {}
        onExited: code => root.externalCode = code
    }

    // Test-only files in the disposable folder: an old and a fresh temporary
    // of the copy script's pattern, plus a user file that only ends in
    // .partial. The next real copy may remove the old temporary and nothing
    // else.
    Process {
        id: seedTemps

        command: ["powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", root.tempSeedScript]
        environment: ({
                CAELESTIA_TEST_FOLDER: Paths.wallsdir,
                CAELESTIA_TEST_STAGING: root.stagingFolderName,
                CAELESTIA_TEST_STALE: root.staleTempName,
                CAELESTIA_TEST_FRESH: root.freshTempName,
                CAELESTIA_TEST_USER_GUID: root.userGuidTempName,
                CAELESTIA_TEST_LOOKALIKE: root.lookalikeTempName
            })
        stdout: StdioCollector {}
        stderr: StdioCollector {}
        onExited: code => {
            root.tempSeedCode = code;
            root.tempSeedDone = true;
        }
    }

    Process {
        id: stagingProbe

        command: ["powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", root.stagingProbeScript]
        environment: ({
                CAELESTIA_TEST_STAGING: root.stagingPath
            })
        stdout: StdioCollector {
            id: stagingProbeOutput
        }
        stderr: StdioCollector {}
        onExited: code => {
            root.stagingAttributes = code === 0 ? stagingProbeOutput.text.trim() : "ERROR " + code;
            root.stagingProbeDone = true;
        }
    }

    // The production job script against a real permission-denied folder, so
    // the emitted marker comes from a wrapped .NET failure rather than a
    // fixture string.
    Process {
        id: deniedJob

        command: root.defaultJobCommand
        environment: ({
                CAELESTIA_WALLPAPER_JOB_MODE: "copy",
                CAELESTIA_WALLPAPER_JOB_SOURCE: root.realSourcePath,
                CAELESTIA_WALLPAPER_JOB_FOLDER: root.deniedFolderPath
            })
        stdout: StdioCollector {
            id: deniedJobOutput
        }
        stderr: StdioCollector {
            id: deniedJobError
        }
        onExited: code => {
            root.deniedCode = code;
            root.deniedOutput = deniedJobOutput.text;
            root.deniedError = deniedJobError.text;
            root.deniedDone = true;
        }
    }

    // The interruption phase watches every listing for the copy's temporary.
    Connections {
        target: Native.FsUtils

        function onListDirFinished(request, path, entries): void {
            if (request !== root.probeRequest)
                return;
            root.probeEntries = entries;
            root.probeDone = true;
            if (root.watchingPartial && entries.some(entry => /^\.caelestia-import-[0-9a-f]+\.partial$/.test(entry.name))) {
                root.partialSeen = true;
                root.watchingPartial = false;
            }
        }
    }

    Timer {
        id: partialPoller

        interval: 40
        repeat: true
        running: root.watchingPartial && !root.partialSeen
        onTriggered: root.startListing(root.stagingPath)
    }

    Component.onCompleted: Qt.callLater(run)

    function check(value, message): void {
        assertions++;
        if (!value)
            throw new Error(message);
    }

    function find(item, name): var {
        if (!item)
            return null;
        if (item.objectName === name)
            return item;
        for (const child of item.children ?? []) {
            const found = root.find(child, name);
            if (found)
                return found;
        }
        return null;
    }

    function waitFor(predicate, timeout, message): void {
        const deadline = Date.now() + timeout;
        while (!predicate()) {
            if (Date.now() > deadline)
                throw new Error(message);
            root.input.wait(20);
        }
        assertions++;
    }

    function toastBodies(): string {
        return root.notifications.map(call => call.body).join("\n");
    }

    function hasFile(name): bool {
        return Wallpapers.files.some(file => file.name === name);
    }

    // Real directory listing through the facade. The copy's temporary is not
    // part of Wallpapers.files by design, so the test looks at the directory.
    // The staging folder is hidden, but a direct listing still answers.
    function startListing(path): void {
        root.probeEntries = [];
        root.probeDone = false;
        root.probeRequest = Native.FsUtils.listDirAsync(path ?? Paths.wallsdir);
    }

    function listPath(path): var {
        root.startListing(path);
        root.waitFor(() => root.probeDone, 5000, "the folder listing did not answer");
        return root.probeEntries;
    }

    function listFolder(): var {
        return root.listPath(Paths.wallsdir);
    }

    function listStaging(): var {
        return root.listPath(root.stagingPath);
    }

    function folderNames(): var {
        return root.listFolder().map(entry => entry.name);
    }

    function releaseJob(): void {
        if (WallpaperFolderService.busy)
            WallpaperFolderService.finishJob(-1, "");
    }

    function resetActions(): void {
        root.releaseJob();
        root.opened = [];
        root.jobs = [];
        root.notifications = [];
        root.pickers = 0;
        root.reloads = 0;
        root.reveals = 0;
        root.folder.openFolder = path => {
            root.opened.push(path);
            return true;
        };
        WallpaperFolderService.startFileJob = (kind, source, folder) => {
            root.jobs.push({kind, source, folder});
            return true;
        };
        WallpaperFolderService.notify = (message, icon) => {
            root.notifications.push({body: message, icon});
        };
        WallpaperFolderService.reloadWallpapers = () => {
            root.reloads++;
        };
        WallpaperFolderService.revealLocalFiles = () => {
            root.reveals++;
            Wallpapers.showLocalSource = true;
        };
        WallpaperFolderService.chooseAndAdd = () => {
            root.pickers++;
        };
    }

    // Real processes against the disposable folder, while still recording the
    // notifications and rescan/reveal calls.
    function useRealJobs(): void {
        WallpaperFolderService.startFileJob = root.defaultStartJob;
        WallpaperFolderService.jobCommand = root.defaultJobCommand;
        WallpaperFolderService.reloadWallpapers = () => {
            root.reloads++;
            root.defaultReload();
        };
        WallpaperFolderService.revealLocalFiles = () => {
            root.reveals++;
            root.defaultReveal();
        };
    }

    function run(): void {
        try {
            root.defaultStartJob = WallpaperFolderService.startFileJob;
            root.defaultReload = WallpaperFolderService.reloadWallpapers;
            root.defaultReveal = WallpaperFolderService.revealLocalFiles;
            root.defaultJobCommand = WallpaperFolderService.jobCommand;
            root.defaultJobTimeout = WallpaperFolderService.jobTimeoutMs;
            root.defaultJobExitGrace = WallpaperFolderService.jobExitGraceMs;
            WallpaperEngine.options = {enabled: false};
            Wallpapers.showLocalSource = false;
            Wallpapers.files = [];
            root.input = root.inputComponent.createObject(win.contentItem);
            root.folder = root.folderComponent.createObject(host, {
                width: 900,
                height: 120
            });
            // The facade starts its folder scan when it is first used. Let that
            // answer settle so a later fixture assignment is not cleared.
            root.input.wait(150);
            root.resetActions();

            // 1. The folder label is the resolved Windows path, and screen
            // readers hear the same value.
            const label = root.find(root.folder, "wallpaperFolderPath");
            root.check(root.wallsPath.length > 0, "the fixture supplied a wallpaper folder");
            root.check(Paths.samePath(root.folder.folderPath, root.wallsPath),
                `the component scans "${root.folder.folderPath}" not "${root.wallsPath}"`);
            root.check(root.folder.folderLabel === root.folder.folderPath.replace(/\//g, "\\"),
                `the folder label is "${root.folder.folderLabel}"`);
            root.check(label !== null && label.text === root.folder.folderLabel, "the folder path is not painted");
            root.check(label !== null && label.Accessible.name.includes(root.folder.folderLabel),
                "the folder path has no accessible name");

            // 2. Both actions and the refresh action are named, keyboard buttons.
            const openButton = root.find(root.folder, "wallpaperOpenFolderButton");
            const addButton = root.find(root.folder, "wallpaperAddButton");
            const refreshButton = root.find(root.folder, "wallpaperRefreshButton");
            const sourceButton = root.find(root.folder, "wallpaperSourceButton");
            const cancelButton = root.find(root.folder, "wallpaperCancelButton");
            root.check(openButton !== null && addButton !== null && refreshButton !== null && sourceButton !== null,
                "the folder actions are missing");
            root.check(cancelButton !== null && !cancelButton.visible, "the cancel control shows while no job runs");
            root.check(cancelButton.activeFocusOnTab, "Cancel the wallpaper folder job is not in the tab chain");
            root.check(cancelButton.Accessible.role === Accessible.Button, "Cancel has no button role");
            root.check(cancelButton.Accessible.name === "Cancel the wallpaper folder job",
                `Cancel is named "${cancelButton.Accessible.name}"`);
            root.check(root.find(cancelButton, "cancelFocusRing") !== null, "Cancel has no focus treatment");
            root.check(openButton.activeFocusOnTab, "Open wallpapers folder is not in the tab chain");
            root.check(openButton.Accessible.role === Accessible.Button, "Open wallpapers folder has no button role");
            root.check(openButton.Accessible.name === "Open wallpapers folder",
                `Open wallpapers folder is named "${openButton.Accessible.name}"`);
            root.check(addButton.activeFocusOnTab, "Add wallpaper is not in the tab chain");
            root.check(addButton.Accessible.role === Accessible.Button, "Add wallpaper has no button role");
            root.check(addButton.Accessible.name === "Add wallpaper…", `Add wallpaper is named "${addButton.Accessible.name}"`);
            root.check(refreshButton.Accessible.name === "Refresh wallpapers",
                `Refresh is named "${refreshButton.Accessible.name}"`);
            root.check(root.find(addButton, "addWallpaperFocusRing") !== null,
                "Add wallpaper has no focus treatment");
            root.check(root.find(openButton, "openFolderFocusRing") !== null,
                "Open wallpapers folder has no focus treatment");
            root.check(root.find(refreshButton, "refreshFocusRing") !== null,
                "Refresh has no focus treatment");

            // 3. Open starts an asynchronous folder job and disables both
            // actions until it answers.
            openButton.clicked();
            root.check(root.jobs.length === 1 && root.jobs[0].kind === "folder",
                "Open did not start a folder job");
            root.check(root.jobs[0].folder === root.folder.folderPath, "Open named another folder");
            root.check(WallpaperFolderService.busy, "a running folder job is not marked busy");
            root.check(openButton.disabled && addButton.disabled && refreshButton.disabled,
                "the actions stay enabled while a folder job runs");
            root.check(cancelButton.visible, "a running folder job has no cancel control");
            WallpaperFolderService.finishJob(0, "FOLDER_OK\n");
            root.check(!WallpaperFolderService.busy, "a finished folder job is still busy");
            root.check(root.opened.length === 1 && Paths.samePath(root.opened[0], root.folder.folderPath),
                "Open did not open the scanned folder");
            root.check(root.toastBodies() === "", "a successful Open explained an error");
            root.check(!openButton.disabled && !addButton.disabled, "the actions stayed disabled");

            // 4. A failed folder job never opens Explorer and explains itself.
            openButton.clicked();
            root.check(root.jobs.length === 2, "a second Open did not start a folder job");
            WallpaperFolderService.finishJob(2, "ERROR:folder\n");
            root.check(root.opened.length === 1, "a failed folder creation still opened Explorer");
            root.check(root.toastBodies().includes("Could not create the wallpapers folder"),
                "a failed creation had no explanation");
            root.check(!root.folder.waitingForFolder, "a failed folder creation left the opener waiting");

            // 5. A job that cannot start reports failure instead of hanging.
            WallpaperFolderService.startFileJob = (kind, source, folder) => {
                root.jobs.push({kind, source, folder});
                return false;
            };
            openButton.clicked();
            root.check(!WallpaperFolderService.busy, "a failed process start stayed busy");
            root.check(!root.folder.waitingForFolder, "a failed process start left the opener waiting");
            root.check(root.toastBodies().includes("Could not create the wallpapers folder"),
                "a failed process start had no explanation");
            root.resetActions();

            // 6. Keyboard activation uses the same asynchronous actions.
            openButton.forceActiveFocus(Qt.TabFocusReason);
            root.input.wait(30);
            root.check(openButton.activeFocus, "Open wallpapers folder did not take keyboard focus");
            root.check(root.find(openButton, "openFolderFocusRing").showing,
                "Open wallpapers folder does not show keyboard focus");
            root.input.keyClick(Qt.Key_Return);
            root.check(root.jobs.length === 1 && root.jobs[0].kind === "folder",
                "Return did not start the folder job");
            WallpaperFolderService.finishJob(0, "FOLDER_OK\n");
            root.check(root.opened.length === 1, "Return did not open the folder");
            addButton.forceActiveFocus(Qt.TabFocusReason);
            root.input.wait(30);
            root.check(addButton.activeFocus, "Add wallpaper did not take keyboard focus");
            root.input.keyClick(Qt.Key_Space);
            root.check(root.pickers === 1, "Space did not request the file picker");
            addButton.clicked();
            root.check(root.pickers === 2, "Add wallpaper did not request the file picker");

            // 7. A chosen file is copied by a job under its decoded name, and
            // the folder is rescanned so the tile appears without a restart.
            root.resetActions();
            const first = WallpaperFolderService.addWallpaper("file:///C:/fixtures/My%20Photo.PNG");
            root.check(first === true, "the first add was refused");
            root.check(root.jobs.length === 1 && root.jobs[0].kind === "copy", "the first add did not start a copy");
            root.check(root.jobs[0].source === "C:/fixtures/My Photo.PNG",
                `the chosen file source is "${root.jobs[0].source}"`);
            root.check(root.jobs[0].folder === Paths.wallsdir, "the copy target is not the scanned folder");
            root.check(addButton.disabled && openButton.disabled, "the actions stay enabled during a copy");
            WallpaperFolderService.finishJob(0, "COPY_OK 1\n");
            root.check(!WallpaperFolderService.busy, "a finished copy is still busy");
            root.check(root.reloads === 1, "a successful add did not rescan the folder");
            root.check(root.reveals === 1, "a successful add did not reveal the local source");
            root.check(root.notifications.some(call => call.icon === "wallpaper" && call.body.includes("My Photo.PNG")),
                "a successful add had no explanation");

            // 8. The copy's own numbered name is used, so an existing file is
            // never replaced.
            root.check(WallpaperFolderService.addWallpaper("file:///C:/fixtures/My%20Photo.PNG") === true,
                "the collision add was refused");
            WallpaperFolderService.finishJob(0, "COPY_OK 2\n");
            root.check(root.notifications.some(call => call.body.includes("My Photo (2).PNG")),
                "a collision was not reported as a numbered name");
            root.check(WallpaperFolderService.targetPath("My Photo.PNG", 2) === Paths.joinPath(Paths.wallsdir, "My Photo (2).PNG"),
                "the numbered target does not match the copy script");

            // 9. Only the image types the scanner lists can be added, and a
            // malformed or reserved name cannot escape the folder.
            root.check(WallpaperFolderService.imageFilters.join(",") === "png,jpg,jpeg,bmp,webp", "the image filters changed");
            root.jobs = [];
            root.check(WallpaperFolderService.addWallpaper("file:///C:/fixtures/notes.txt") === false, "a text file was accepted");
            root.check(WallpaperFolderService.addWallpaper("file:///C:/fixtures/..%2Fsecret.png") === false,
                "a path segment escaped the folder");
            root.check(WallpaperFolderService.addWallpaper("file:///C:/fixtures/CON.png") === false, "a reserved device name was accepted");
            root.check(root.jobs.length === 0, "a rejected file started a copy");
            root.check(root.toastBodies().includes("Only PNG, JPEG, BMP and WebP"),
                "an unsupported type had no explanation");

            // 10. A failed copy leaves the list alone and names its category.
            root.reloads = 0;
            root.reveals = 0;
            root.check(WallpaperFolderService.addWallpaper("file:///C:/fixtures/Broken.png") === true,
                "the failing copy was not accepted");
            WallpaperFolderService.finishJob(2, "ERROR:io\n", "IOException: There is not enough space on the disk.\n");
            root.check(root.reloads === 0 && root.reveals === 0, "a failed copy refreshed the folder");
            root.check(root.toastBodies().includes("Windows could not copy that image"),
                "a failed copy had no explanation");

            // 10b. The child's stderr names the category when the script could
            // not write a marker, and a source failure says the image is gone.
            root.check(WallpaperFolderService.addWallpaper("file:///C:/fixtures/Denied.png") === true,
                "the access failure was not accepted");
            WallpaperFolderService.finishJob(2, "", "UnauthorizedAccessException: Access is denied.\n");
            root.check(root.toastBodies().includes("Windows denied access to the wallpapers folder"),
                "a stderr-only failure had no category");
            root.check(WallpaperFolderService.addWallpaper("file:///C:/fixtures/Gone.png") === true,
                "the missing-source failure was not accepted");
            WallpaperFolderService.finishJob(2, "ERROR:source\n");
            root.check(root.toastBodies().includes("could not be read"),
                "a missing source did not name its category");

            // 11. A backslash path from Explorer-like input also yields a name.
            root.check(WallpaperFolderService.addWallpaper("C:\\fixtures\\Backslash.jpg") === true,
                "a backslash path was refused");
            root.check(root.jobs[root.jobs.length - 1].source === "C:/fixtures/Backslash.jpg",
                `a backslash path became "${root.jobs[root.jobs.length - 1].source}"`);
            WallpaperFolderService.finishJob(0, "COPY_OK 1\n");

            // 12. A job that cannot start reports failure instead of hanging.
            WallpaperFolderService.startFileJob = () => false;
            root.check(WallpaperFolderService.addWallpaper("file:///C:/fixtures/Start.png") === false,
                "a copy that could not start was accepted");
            root.check(!WallpaperFolderService.busy, "a failed copy start stayed busy");
            root.check(root.toastBodies().includes("Windows could not copy that image"),
                "a failed copy start had no explanation");
            root.resetActions();

            // 13. An engine picker hides local files. Importing reveals them,
            // and the source button switches back without changing the engine
            // default.
            Wallpapers.files = [{
                path: Paths.absolutePath(Quickshell.shellPath("assets/wallpaper.webp")),
                relativePath: "one.png",
                name: "one.png",
                parentDir: Paths.wallsdir,
                onDisk: true
            }];
            Wallpapers.showLocalSource = false;
            WallpaperEngine.options = {enabled: true, picker: "engine"};
            root.check(WallpaperEngine.picker === "engine", "the engine picker was not selected");
            root.check(Wallpapers.list.length === 0, "the engine picker did not hide local files");
            root.check(WallpaperFolderService.addWallpaper("file:///C:/fixtures/Engine%20Import.png") === true,
                "the engine-mode import was refused");
            WallpaperFolderService.finishJob(0, "COPY_OK 1\n");
            root.check(Wallpapers.showLocalSource, "a successful import did not reveal the local source");
            root.check(Wallpapers.list.some(entry => entry.name === "one.png"),
                "the imported local source is still hidden");
            root.check(sourceButton.visible, "the source button is hidden while the engine picker is active");
            root.check(sourceButton.text === "Show Wallpaper Engine",
                `the source button reads "${sourceButton.text}"`);
            sourceButton.clicked();
            root.check(!Wallpapers.showLocalSource, "the source button did not return to Wallpaper Engine");
            root.check(Wallpapers.list.length === 0, "Wallpaper Engine entries did not return");
            root.check(sourceButton.text === "Show local wallpapers",
                `the source button reads "${sourceButton.text}"`);
            sourceButton.clicked();
            root.check(Wallpapers.showLocalSource, "the source button did not return to local files");
            WallpaperEngine.options = {enabled: false};
            Wallpapers.files = [];
            Wallpapers.showLocalSource = false;
            root.resetActions();

            // 14. The empty-folder state names the folder and both ways to add.
            root.check(root.folder.busy === false, "the folder bar starts busy");
            Wallpapers.files = [];
            const emptyState = root.emptyComponent.createObject(host, {
                width: 460
            });
            root.check(emptyState.folderEmpty, "an empty scan was not reported as empty");
            const title = root.find(emptyState, "wallpaperEmptyTitle");
            const hint = root.find(emptyState, "wallpaperEmptyHint");
            root.check(title !== null && title.text === "No wallpapers found", "the empty title is missing");
            root.check(hint !== null && hint.text.includes(root.folder.folderLabel),
                "the empty explanation does not name the folder");
            root.check(hint !== null && hint.text.includes("Add wallpaper"), "the empty explanation does not mention Add wallpaper");
            Wallpapers.files = [{
                path: Paths.absolutePath(Quickshell.shellPath("assets/wallpaper.webp")),
                relativePath: "one.png",
                name: "one.png",
                parentDir: Paths.wallsdir,
                onDisk: true
            }];
            root.check(!emptyState.folderEmpty, "a non-empty scan still reported empty");
            emptyState.destroy();
            Wallpapers.files = [];

            // 15. The real launcher picker sizes itself from the header at
            // production width. No test width is forced, so a path that still
            // collapsed to 0 px fails here.
            root.productionPickerActive = true;
            root.waitFor(() => productionPicker.item !== null, 5000, "the launcher WallpaperList adapter did not load");
            root.picker = productionPicker.item;
            root.input.wait(50);
            const launcherFolder = root.find(root.picker, "launcherWallpaperFolder");
            const launcherPath = root.find(root.picker, "wallpaperFolderPath");
            root.check(launcherFolder !== null, "the launcher picker has no folder header");
            root.check(launcherFolder.folderLabel === root.folder.folderLabel, "the launcher header names another folder");
            root.check(root.picker.width > 0, "the launcher picker has no production width");
            root.check(root.picker.width === root.picker.implicitWidth,
                "the launcher picker was not sized by its own header");
            root.check(root.picker.implicitWidth >= launcherFolder.minimumWidth,
                "the launcher picker is narrower than the folder actions");
            root.check(launcherPath !== null && launcherPath.width > 0,
                `the folder path collapsed to ${launcherPath?.width} px at production width`);
            root.check(launcherPath !== null && launcherPath.paintedWidth > 0,
                "the folder path paints nothing at production width");
            root.check(root.picker.headerHeight > 0, "the launcher picker did not reserve the header height");
            root.check(root.picker.implicitHeight === root.picker.headerHeight + Tokens.sizes.launcher.wallpaperHeight,
                "the launcher picker does not reserve the carousel below the header");
            root.check(root.picker.count === 0, "the empty production scan produced wallpaper tiles");
            root.productionPickerActive = false;
            root.picker = null;
            root.input.wait(50);

            // 16. The real Nexus page loads and shows the same folder at its
            // production width.
            root.nexusPage = root.nexusComponent.createObject(host);
            root.input.wait(50);
            root.check(root.nexusPage !== null, "the Nexus WallpaperSelect adapter did not load");
            const nexusFolder = root.find(root.nexusPage, "nexusWallpaperFolder");
            const nexusPath = root.find(root.nexusPage, "wallpaperFolderPath");
            root.check(nexusFolder !== null, "the Nexus page has no folder header");
            root.check(nexusFolder.folderLabel === root.folder.folderLabel, "the Nexus header names another folder");
            root.check(nexusPath !== null && nexusPath.width > 0, "the Nexus folder path has no width");
            const nexusEmpty = root.find(root.nexusPage, "nexusWallpaperEmpty");
            root.check(nexusEmpty !== null && nexusEmpty.folderEmpty, "the Nexus page has no empty-folder explanation");

            // 17. The real asynchronous folder job and copy against the
            // disposable directory. The facade's startup scan saw no folder.
            root.check(Native.FsUtils.classify(Paths.wallsdir) === "invalid",
                "the disposable wallpaper folder existed before the test");
            root.useRealJobs();
            root.opened = [];
            root.reloads = 0;
            root.reveals = 0;
            openButton.clicked();
            root.check(WallpaperFolderService.busy, "the real folder job is not busy");
            root.waitFor(() => !WallpaperFolderService.busy, 30000, "the real folder job did not finish");
            root.check(Native.FsUtils.classify(Paths.wallsdir) === "dir", "the real folder job did not create the folder");
            root.check(root.opened.length === 1 && Paths.samePath(root.opened[0], Paths.wallsdir),
                "the real folder job did not open the created folder");

            // 18. A real image is copied into the folder and scanned without a
            // restart.
            root.check(Native.FsUtils.classify(root.realSourcePath) === "file", "the fixture source image is missing");
            const realSource = Paths.absolutePath(root.realSourcePath);
            const realName = WallpaperFolderService.wallpaperName(realSource);
            root.check(realName === "Picked Image.png", `the fixture source name is "${realName}"`);
            root.check(WallpaperFolderService.addWallpaper(realSource) === true, "the real copy was refused");
            root.check(WallpaperFolderService.busy, "the real copy is not busy");
            root.waitFor(() => !WallpaperFolderService.busy, 30000, "the real copy did not finish");
            const firstTarget = WallpaperFolderService.targetPath(realName, 1);
            root.check(Native.FsUtils.classify(firstTarget) === "file", "the real copy did not create the expected file");
            root.check(root.reloads >= 1, "the real copy did not rescan the folder");
            root.check(root.reveals >= 1, "the real copy did not reveal the local source");
            root.waitFor(() => root.hasFile(realName), 10000, "the real copy did not appear in the folder scan");

            // 19. A second real copy of the same name uses the numbered name
            // and leaves the first file untouched.
            root.check(WallpaperFolderService.addWallpaper(realSource) === true, "the real collision copy was refused");
            root.waitFor(() => !WallpaperFolderService.busy, 30000, "the real collision copy did not finish");
            const secondTarget = WallpaperFolderService.targetPath(realName, 2);
            root.check(Native.FsUtils.classify(firstTarget) === "file", "the first copy was replaced");
            root.check(Native.FsUtils.classify(secondTarget) === "file", "the numbered copy was not created");
            root.waitFor(() => root.hasFile(realName) && Wallpapers.files.length === 2, 10000,
                "the second real copy did not appear in the folder scan");

            // 20. A file copied in externally (Explorer) is not noticed until a
            // picker opens, then the real directory scan shows it.
            const filesBeforeExternal = Wallpapers.files.length;
            const requestsBeforeExternal = Wallpapers.listRequest;
            root.externalCode = -1;
            root.externalName = "External.png";
            externalCopy.running = true;
            root.check(externalCopy.running, "the external copy did not start");
            root.waitFor(() => root.externalCode === 0, 30000, "the external copy failed");
            const externalTarget = Paths.joinPath(Paths.wallsdir, "External.png");
            root.check(Native.FsUtils.classify(externalTarget) === "file", "the external copy was not created");
            root.check(Wallpapers.files.length === filesBeforeExternal,
                "an external copy refreshed the folder without the picker reopening");
            root.productionPickerActive = true;
            root.waitFor(() => productionPicker.item !== null, 5000, "the picker did not reopen");
            root.picker = productionPicker.item;
            root.waitFor(() => root.hasFile("External.png"), 10000, "reopening the picker did not discover the external copy");
            root.check(Wallpapers.files.length === filesBeforeExternal + 1,
                "the reopened picker shows the wrong number of wallpapers");
            root.check(Wallpapers.listRequest !== requestsBeforeExternal,
                "reopening the picker did not request a new scan");
            root.check(root.picker.count === filesBeforeExternal + 1,
                `the reopened picker shows ${root.picker.count} tiles`);

            // 21. The visible refresh action rescans, and the production header
            // keeps the path readable with real tiles present.
            const launcherPathAfter = root.find(root.picker, "wallpaperFolderPath");
            const refreshAfter = root.find(root.picker, "wallpaperRefreshButton");
            root.check(launcherPathAfter !== null && launcherPathAfter.width > 0,
                "the folder path collapsed with real wallpapers present");
            const requestsBeforeRefresh = Wallpapers.listRequest;
            const filesBeforeRefresh = Wallpapers.files;
            refreshAfter.clicked();
            root.waitFor(() => Wallpapers.listRequest !== requestsBeforeRefresh, 5000,
                "Refresh did not request a new folder scan");
            root.check(Wallpapers.activeSource === "files", "Refresh changed the displayed source");
            root.check(!WallpaperFolderService.busy, "Refresh left the folder job busy");
            root.waitFor(() => Wallpapers.files !== filesBeforeRefresh, 10000, "the Refresh rescan did not answer");
            root.productionPickerActive = false;
            root.picker = null;

            // 22. With the configured source "both", importing or refreshing
            // must keep the engine entries. The local-only override may only
            // replace a source that hides local files.
            Wallpapers.files = [{
                path: Paths.absolutePath(Quickshell.shellPath("assets/wallpaper.webp")),
                relativePath: "both-local.png",
                name: "both-local.png",
                parentDir: Paths.wallsdir,
                onDisk: true
            }];
            WallpaperEngine.detected = true;
            WallpaperEngine.items = [{
                path: "C:/engine/both.png",
                name: "Both",
                preview: "C:/engine/both.png"
            }];
            WallpaperEngine.options = {enabled: true, picker: "both"};
            Wallpapers.showLocalSource = false;
            root.resetActions();
            WallpaperFolderService.revealLocalFiles = root.defaultReveal;
            root.check(WallpaperEngine.picker === "both", "the both picker was not selected");
            root.check(Wallpapers.activeSource === "both", "both is not the active source");
            root.check(Wallpapers.list.length === 2, "both did not list the engine and local entries");
            root.check(WallpaperFolderService.addWallpaper("file:///C:/fixtures/Both%20Import.png") === true,
                "the both-mode import was refused");
            WallpaperFolderService.finishJob(0, "COPY_OK 1\n");
            root.check(!Wallpapers.showLocalSource, "an import set the local-only override in both mode");
            root.check(Wallpapers.list.length === 2 && Wallpapers.list.some(entry => entry.path === "C:/engine/both.png"),
                "an import hid the engine entries in both mode");
            root.check(Wallpapers.activeSource === "both", "an import changed the active source in both mode");
            // A direct override assignment must leave both alone as well, so a
            // later caller cannot reintroduce the bug.
            Wallpapers.showLocalSource = true;
            root.check(Wallpapers.list.length === 2, "the local-only override hid the engine entries in both mode");
            root.check(Wallpapers.activeSource === "both", "the local-only override replaced both mode");
            Wallpapers.showLocalSource = false;
            root.resetActions();
            WallpaperFolderService.revealLocalFiles = root.defaultReveal;
            refreshButton.clicked();
            root.input.wait(20);
            root.check(root.reloads === 1, "Refresh did not rescan in both mode");
            root.check(!Wallpapers.showLocalSource, "Refresh set the local-only override in both mode");
            root.check(Wallpapers.list.length === 2,
                `Refresh hid the engine entries in both mode (source ${Wallpapers.activeSource}, picker ${WallpaperEngine.picker}, override ${Wallpapers.showLocalSource}, detected ${WallpaperEngine.detected}, items ${WallpaperEngine.items.length}, files ${Wallpapers.files.length}, list ${Wallpapers.list.length})`);
            root.check(!sourceButton.visible, "the switch-back button appeared for both mode");
            // The same Refresh in engine mode still reveals the folder.
            WallpaperEngine.options = {enabled: true, picker: "engine"};
            refreshButton.clicked();
            root.input.wait(20);
            root.check(Wallpapers.showLocalSource, "Refresh did not reveal the folder in engine mode");
            root.check(Wallpapers.activeSource === "files", "the engine picker did not switch to the folder");
            WallpaperEngine.options = {enabled: false};
            WallpaperEngine.detected = false;
            WallpaperEngine.items = [];
            Wallpapers.files = [];
            Wallpapers.showLocalSource = false;
            root.resetActions();

            // 23. A child that never answers is killed after the job deadline
            // and finishes with a timeout; the visible cancel control stops one
            // sooner. Either way busy clears so the folder actions return.
            root.check(WallpaperFolderService.jobTimeoutMs === 300000 && WallpaperFolderService.jobExitGraceMs === 5000,
                "the production job deadline changed");
            root.resetActions();
            WallpaperFolderService.startFileJob = root.defaultStartJob;
            WallpaperFolderService.jobCommand = ["powershell.exe", "-NoLogo", "-NoProfile", "-NonInteractive",
                "-Command", "Start-Sleep -Seconds 120"];
            WallpaperFolderService.jobTimeoutMs = 4000;
            WallpaperFolderService.jobExitGraceMs = 3000;
            root.check(!root.folder.waitingForFolder, "the folder opener started waiting");
            openButton.clicked();
            root.check(WallpaperFolderService.busy, "the stalled folder job is not busy");
            root.check(openButton.disabled && addButton.disabled && refreshButton.disabled && cancelButton.visible,
                "a stalled job did not disable the folder actions");
            root.waitFor(() => !WallpaperFolderService.busy, 20000, "the watchdog did not stop the stalled folder job");
            root.check(!WallpaperFolderService.jobRunning, "the watchdog left its child running");
            root.check(root.toastBodies().includes("took too long"), "a timed-out job had no explanation");
            root.check(!root.folder.waitingForFolder, "a timed-out folder job left the opener waiting");
            root.check(root.opened.length === 0, "a timed-out folder job opened Explorer");
            root.check(!cancelButton.visible, "the cancel control stayed visible after the job");
            // The visible cancel control stops a running copy at once.
            root.notifications = [];
            WallpaperFolderService.jobTimeoutMs = 120000;
            root.check(WallpaperFolderService.addWallpaper(Paths.absolutePath(root.retrySourcePath)) === true,
                "the stalled copy was refused");
            root.waitFor(() => WallpaperFolderService.busy && !WallpaperFolderService.jobStarted, 10000,
                "the stalled copy did not report its start");
            root.check(WallpaperFolderService.jobRunning, "the stalled copy has no live child");
            cancelButton.clicked();
            root.waitFor(() => !WallpaperFolderService.busy, 10000, "the cancel control did not stop the copy");
            root.check(!WallpaperFolderService.jobRunning, "the cancelled copy left its child running");
            root.check(root.toastBodies().includes("was cancelled"), "a cancelled copy had no explanation");
            WallpaperFolderService.jobCommand = root.defaultJobCommand;
            WallpaperFolderService.jobTimeoutMs = root.defaultJobTimeout;
            WallpaperFolderService.jobExitGraceMs = root.defaultJobExitGrace;
            root.resetActions();

            // 24. A copy killed mid-write leaves no file under its final name:
            // it writes a temporary the scan ignores and publishes by rename. A
            // retry therefore still gets the plain name.
            root.resetActions();
            root.useRealJobs();
            root.check(Native.FsUtils.classify(root.largeSourcePath) === "file", "the large fixture source is missing");
            root.check(Native.FsUtils.classify(root.retrySourcePath) === "file", "the retry fixture source is missing");
            const largeSource = Paths.absolutePath(root.largeSourcePath);
            const largeName = WallpaperFolderService.wallpaperName(largeSource);
            root.check(largeName === "Interrupted Copy.png", `the interrupted source name is "${largeName}"`);
            root.check(root.folderNames().indexOf(largeName) < 0, "the interrupted target name was already taken");
            root.partialSeen = false;
            root.watchingPartial = true;
            root.check(WallpaperFolderService.addWallpaper(largeSource) === true, "the interrupted copy was refused");
            root.check(WallpaperFolderService.busy, "the interrupted copy is not busy");
            root.waitFor(() => root.partialSeen, 20000, "the copy did not write a temporary file");
            root.check(WallpaperFolderService.cancelJob("cancel") === true, "the interrupted copy could not be stopped");
            root.waitFor(() => !WallpaperFolderService.busy, 15000, "the interrupted copy stayed busy");
            root.watchingPartial = false;
            root.check(Native.FsUtils.classify(WallpaperFolderService.targetPath(largeName, 1)) === "invalid",
                "an interrupted copy left a file under its final name");
            root.check(Native.FsUtils.classify(WallpaperFolderService.targetPath(largeName, 2)) === "invalid",
                "an interrupted copy left a numbered file");
            root.check(root.listStaging().some(entry => /^\.caelestia-import-[0-9a-f]{32}\.partial$/.test(entry.name)),
                "the interrupted copy did not leave an owned temporary in staging for cleanup");
            root.check(!root.folderNames().some(name => /\.partial$/i.test(name)),
                "an interrupted copy left a temporary in the wallpapers folder");
            // The retry comes from another folder but keeps the same name.
            root.check(WallpaperFolderService.addWallpaper(Paths.absolutePath(root.retrySourcePath)) === true,
                "the retry was refused");
            root.waitFor(() => !WallpaperFolderService.busy, 30000, "the retry did not finish");
            root.check(Native.FsUtils.classify(WallpaperFolderService.targetPath(largeName, 1)) === "file",
                "a retry after an interrupted copy did not get the plain name");
            root.check(Native.FsUtils.classify(WallpaperFolderService.targetPath(largeName, 2)) === "invalid",
                "a retry after an interrupted copy created a numbered duplicate");
            root.check(root.toastBodies().includes("Added Interrupted Copy.png"),
                "the retry did not report the published name");

            // 25. The next copy cleans only an old abandoned temporary of its
            // own exact pattern, and only inside its hidden staging folder. A
            // user file in the wallpapers folder survives even when its name
            // looks like the service pattern.
            root.tempSeedDone = false;
            root.tempSeedCode = -1;
            seedTemps.running = true;
            root.check(seedTemps.running, "the temporary seed did not start");
            root.waitFor(() => root.tempSeedDone, 15000, "the temporary seed did not finish");
            root.check(root.tempSeedCode === 0, "the temporary seed failed");
            root.check(Native.FsUtils.classify(Paths.joinPath(root.stagingPath, root.staleTempName)) === "file"
                && Native.FsUtils.classify(Paths.joinPath(root.stagingPath, root.freshTempName)) === "file",
                "the seeded staging temporaries are missing");
            root.check(Native.FsUtils.classify(Paths.joinPath(Paths.wallsdir, root.lookalikeTempName)) === "file"
                && Native.FsUtils.classify(Paths.joinPath(Paths.wallsdir, root.userGuidTempName)) === "file"
                && Native.FsUtils.classify(Paths.joinPath(Paths.wallsdir, "notes.partial")) === "file",
                "the seeded user files are missing");
            root.check(WallpaperFolderService.addWallpaper(Paths.absolutePath(root.cleanupSourcePath)) === true,
                "the cleanup copy was refused");
            root.waitFor(() => !WallpaperFolderService.busy, 30000, "the cleanup copy did not finish");
            root.check(Native.FsUtils.classify(Paths.joinPath(root.stagingPath, root.staleTempName)) === "invalid",
                "an old owned temporary in staging was not removed");
            root.check(Native.FsUtils.classify(Paths.joinPath(root.stagingPath, root.freshTempName)) === "file",
                "a fresh temporary in staging was removed");
            root.check(Native.FsUtils.classify(Paths.joinPath(Paths.wallsdir, root.lookalikeTempName)) === "file",
                "cleanup removed a user lookalike in the wallpapers folder");
            root.check(Native.FsUtils.classify(Paths.joinPath(Paths.wallsdir, root.userGuidTempName)) === "file",
                "cleanup reached into the wallpapers folder itself");
            root.check(Native.FsUtils.classify(Paths.joinPath(Paths.wallsdir, "notes.partial")) === "file",
                "cleanup removed a file outside its own pattern");
            root.check(Native.FsUtils.classify(Paths.joinPath(Paths.wallsdir, "Cleanup Probe.png")) === "file",
                "the cleanup copy was not published");
            root.waitFor(() => root.hasFile("Cleanup Probe.png"), 10000, "the cleanup copy did not appear in the scan");
            root.check(!Wallpapers.files.some(file => file.name.endsWith(".partial")),
                "the folder scan listed a temporary file");
            root.check(!Wallpapers.files.some(file => file.name.includes(".caelestia-import")),
                "the folder scan listed the staging folder or its contents");
            stagingProbe.running = true;
            root.waitFor(() => root.stagingProbeDone, 10000, "the staging attribute probe did not answer");
            root.check(root.stagingAttributes === "HIDDEN",
                `the staging folder attributes are "${root.stagingAttributes}"`);

            // 26. A real permission failure emits its inner exception's marker,
            // and the diagnostic line carries no message or path.
            root.check(root.deniedFolderPath.length > 0, "the fixture supplied no permission-denied folder");
            root.check(Native.FsUtils.classify(root.deniedFolderPath) === "dir", "the permission-denied folder is missing");
            root.check(Native.FsUtils.classify(Paths.joinPath(root.deniedFolderPath, root.stagingFolderName)) === "dir",
                "the permission-denied staging folder is missing");
            root.deniedDone = false;
            deniedJob.running = true;
            root.check(deniedJob.running, "the permission-denied copy did not start");
            root.waitFor(() => root.deniedDone, 30000, "the permission-denied copy did not finish");
            root.check(root.deniedCode === 2, `the permission-denied copy exited with ${root.deniedCode}`);
            root.check(root.deniedOutput.trim() === "ERROR:access",
                `the permission-denied copy emitted "${root.deniedOutput.trim()}"`);
            root.check(/UnauthorizedAccessException:/.test(root.deniedError),
                "the permission-denied copy did not name its inner exception");
            WallpaperFolderService.reportJob("copy", root.deniedCode, "access", root.deniedError);
            WallpaperFolderService.reportJob("copy", 2, "io",
                "IOException: Access to the path 'C:\\Users\\canary-drive-private\\secret.png' is denied.");
            WallpaperFolderService.reportJob("copy", 2, "io",
                "IOException: The network path '\\\\canary-unc-private\\share\\secret.png' is unavailable.");

            console.log("CAELESTIA_WALLPAPER_FOLDER_PASS " + assertions);
            Qt.quit();
        } catch (error) {
            console.error("CAELESTIA_WALLPAPER_FOLDER_FAIL " + error);
            Qt.exit(1);
        }
    }
}
