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
    property string externalName: ""
    property int externalCode: -1
    property bool productionPickerActive: false

    readonly property string wallsPath: Quickshell.env("CAELESTIA_WALLPAPER_DIR") || ""
    readonly property string realSourcePath: Quickshell.env("CAELESTIA_WALLPAPER_SOURCE") || ""

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
        WallpaperFolderService.reloadWallpapers = () => {
            root.reloads++;
            root.defaultReload();
        };
        WallpaperFolderService.revealLocalFiles = () => {
            root.reveals++;
            Wallpapers.showLocalSource = true;
        };
    }

    function run(): void {
        try {
            root.defaultStartJob = WallpaperFolderService.startFileJob;
            root.defaultReload = WallpaperFolderService.reloadWallpapers;
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
            root.check(openButton !== null && addButton !== null && refreshButton !== null && sourceButton !== null,
                "the folder actions are missing");
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

            // 10. A failed copy leaves the list alone and explains the failure.
            root.reloads = 0;
            root.reveals = 0;
            root.check(WallpaperFolderService.addWallpaper("file:///C:/fixtures/Broken.png") === true,
                "the failing copy was not accepted");
            WallpaperFolderService.finishJob(2, "ERROR:io\n");
            root.check(root.reloads === 0 && root.reveals === 0, "a failed copy refreshed the folder");
            root.check(root.toastBodies().includes("Could not add"), "a failed copy had no explanation");

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
            root.check(root.toastBodies().includes("Could not add"), "a failed copy start had no explanation");
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
            refreshAfter.clicked();
            root.waitFor(() => Wallpapers.listRequest !== requestsBeforeRefresh, 5000,
                "Refresh did not request a new folder scan");
            root.check(Wallpapers.showLocalSource, "Refresh did not show the folder it rescans");
            root.check(!WallpaperFolderService.busy, "Refresh left the folder job busy");
            root.productionPickerActive = false;
            root.picker = null;

            console.log("CAELESTIA_WALLPAPER_FOLDER_PASS " + assertions);
            Qt.quit();
        } catch (error) {
            console.error("CAELESTIA_WALLPAPER_FOLDER_FAIL " + error);
            Qt.exit(1);
        }
    }
}
