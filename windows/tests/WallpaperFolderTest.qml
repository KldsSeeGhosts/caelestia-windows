import QtQuick
import QtTest
import Quickshell
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
// native picker and the rescan are replaced with recording functions, so no
// native dialog opens and no Explorer window or user file is touched.
ShellRoot {
    id: root

    Config.screen: Quickshell.screens[0]?.name ?? ""
    Tokens.screen: Quickshell.screens[0]?.name ?? ""

    property int assertions: 0
    property var input: null
    property var folder: null
    property var emptyState: null
    property var picker: null
    property var nexusPage: null
    property var made: []
    property var opened: []
    property var copies: []
    property var blockedTargets: []
    property bool makeFolderOk: true
    property bool copyOk: true
    property int pickers: 0
    property int reloads: 0
    property var notifications: []

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
            width: 700
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

    FloatingWindow {
        id: win

        visible: true
        implicitWidth: 960
        implicitHeight: 720

        Item {
            id: host

            anchors.fill: parent
        }
    }

    ScreenState {
        id: launcherScreenState

        modelData: Quickshell.screens[0] ?? null
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

    function resetActions(): void {
        root.made = [];
        root.opened = [];
        root.copies = [];
        root.blockedTargets = [];
        root.makeFolderOk = true;
        root.copyOk = true;
        root.pickers = 0;
        root.reloads = 0;
        root.notifications = [];
        root.folder.openFolder = path => {
            root.opened.push(path);
            return true;
        };
        WallpaperFolderService.makeFolder = path => {
            root.made.push(path);
            return root.makeFolderOk;
        };
        WallpaperFolderService.fileExists = path => root.blockedTargets.some(target => Paths.samePath(target, path));
        WallpaperFolderService.copyFile = (source, target) => {
            root.copies.push({source, target});
            return root.copyOk;
        };
        WallpaperFolderService.notify = (message, icon) => {
            root.notifications.push({body: message, icon});
        };
        WallpaperFolderService.reloadWallpapers = () => {
            root.reloads++;
        };
        WallpaperFolderService.chooseAndAdd = () => {
            root.pickers++;
        };
    }

    function toastBodies(): string {
        return root.notifications.map(call => call.body).join("\n");
    }

    function run(): void {
        try {
            WallpaperEngine.options = {enabled: false};
            Wallpapers.files = [];
            root.input = root.inputComponent.createObject(win.contentItem);
            root.folder = root.folderComponent.createObject(host, {
                width: 900,
                height: 80
            });
            root.resetActions();
            // The facade starts its folder scan when it is first used. Let that
            // empty answer settle so a later fixture assignment is not cleared.
            root.input.wait(100);

            // 1. The folder label is the resolved Windows path, and screen
            // readers hear the same value.
            const label = root.find(root.folder, "wallpaperFolderPath");
            root.check(root.folder.folderPath === Paths.wallsdir, "the component scans Paths.wallsdir");
            root.check(root.folder.folderLabel === "C:\\walls", `the folder label is "${root.folder.folderLabel}"`);
            root.check(label !== null && label.text === "C:\\walls", "the folder path is not painted");
            root.check(label !== null && label.Accessible.name.includes("C:\\walls"),
                "the folder path has no accessible name");

            // 2. Both actions are named, keyboard buttons.
            const openButton = root.find(root.folder, "wallpaperOpenFolderButton");
            const addButton = root.find(root.folder, "wallpaperAddButton");
            root.check(openButton !== null && addButton !== null, "the folder actions are missing");
            root.check(openButton.activeFocusOnTab, "Open wallpapers folder is not in the tab chain");
            root.check(openButton.Accessible.role === Accessible.Button, "Open wallpapers folder has no button role");
            root.check(openButton.Accessible.name === "Open wallpapers folder",
                `Open wallpapers folder is named "${openButton.Accessible.name}"`);
            root.check(addButton.activeFocusOnTab, "Add wallpaper is not in the tab chain");
            root.check(addButton.Accessible.role === Accessible.Button, "Add wallpaper has no button role");
            root.check(addButton.Accessible.name === "Add wallpaper…", `Add wallpaper is named "${addButton.Accessible.name}"`);
            root.check(root.find(addButton, "addWallpaperFocusRing") !== null,
                "Add wallpaper has no focus treatment");
            root.check(root.find(openButton, "openFolderFocusRing") !== null,
                "Open wallpapers folder has no focus treatment");

            // 3. Open creates a missing folder, then opens it.
            openButton.clicked();
            root.check(root.made.length === 1 && root.made[0] === "C:/walls", "Open did not create the scanned folder");
            root.check(root.opened.length === 1 && root.opened[0] === "C:/walls", "Open did not open the scanned folder");
            root.check(root.toastBodies() === "", "a successful Open explained an error");

            // 4. A failed creation never opens Explorer and explains itself.
            root.makeFolderOk = false;
            openButton.clicked();
            root.check(root.made.length === 2, "a second Open did not try to create the folder");
            root.check(root.opened.length === 1, "a failed folder creation still opened Explorer");
            root.check(root.toastBodies().includes("Could not create the wallpapers folder"),
                "a failed creation had no explanation");
            root.makeFolderOk = true;

            // 5. Keyboard activation uses the same actions. The fixture is the
            // established offscreen shell pattern, so focus is real.
            openButton.forceActiveFocus(Qt.TabFocusReason);
            root.input.wait(30);
            root.check(openButton.activeFocus, "Open wallpapers folder did not take keyboard focus");
            root.check(root.find(openButton, "openFolderFocusRing").showing,
                "Open wallpapers folder does not show keyboard focus");
            root.input.keyClick(Qt.Key_Return);
            root.check(root.opened.length === 2 && root.made.length === 3, "Return did not open the folder");
            addButton.forceActiveFocus(Qt.TabFocusReason);
            root.input.wait(30);
            root.check(addButton.activeFocus, "Add wallpaper did not take keyboard focus");
            root.input.keyClick(Qt.Key_Space);
            root.check(root.pickers === 1, "Space did not request the file picker");
            addButton.clicked();
            root.check(root.pickers === 2, "Add wallpaper did not request the file picker");

            // 6. A chosen file is copied into the folder under its decoded name,
            // and the folder is rescanned so the tile appears without a restart.
            root.resetActions();
            const first = WallpaperFolderService.addWallpaper("file:///C:/fixtures/My%20Photo.PNG");
            root.check(first === "C:/walls/My Photo.PNG", `the copy target is "${first}"`);
            root.check(root.copies.length === 1 && root.copies[0].source === "file:///C:/fixtures/My%20Photo.PNG",
                "the chosen file was not copied from its picked URL");
            root.check(root.copies[0].target === "C:/walls/My Photo.PNG", "the copy target was not the scanned folder");
            root.check(root.reloads === 1, "a successful add did not rescan the folder");
            root.check(root.notifications.some(call => call.icon === "wallpaper" && call.body.includes("My Photo.PNG")),
                "a successful add had no explanation");

            // 7. An existing name gets a suffix and is never replaced.
            root.blockedTargets = ["C:/walls/My Photo.PNG"];
            const second = WallpaperFolderService.addWallpaper("file:///C:/fixtures/My%20Photo.PNG");
            root.check(second === "C:/walls/My Photo (2).PNG", `the collision target is "${second}"`);
            root.check(root.copies[1].target === second, "the existing file was targeted for overwrite");

            // 8. Only the image types the scanner lists can be added, and a
            // malformed or reserved name cannot escape the folder.
            root.check(WallpaperFolderService.imageFilters.join(",") === "png,jpg,jpeg,bmp,webp", "the image filters changed");
            const beforeRejected = root.copies.length;
            root.check(WallpaperFolderService.addWallpaper("file:///C:/fixtures/notes.txt") === "", "a text file was accepted");
            root.check(WallpaperFolderService.addWallpaper("file:///C:/fixtures/..%2Fsecret.png") === "",
                "a path segment escaped the folder");
            root.check(WallpaperFolderService.addWallpaper("file:///C:/fixtures/CON.png") === "", "a reserved device name was accepted");
            root.check(root.copies.length === beforeRejected, "a rejected file was copied");
            root.check(root.toastBodies().includes("Only PNG, JPEG, BMP and WebP"),
                "an unsupported type had no explanation");

            // 9. A failed copy leaves the list alone and explains the failure.
            const beforeFailure = root.reloads;
            root.copyOk = false;
            const failed = WallpaperFolderService.addWallpaper("file:///C:/fixtures/Broken.png");
            root.check(failed === "", "a failed copy returned a target");
            root.check(root.reloads === beforeFailure, "a failed copy rescanned the folder");
            root.check(root.toastBodies().includes("Could not add"), "a failed copy had no explanation");
            root.copyOk = true;

            // 10. A backslash path from Explorer-like input also yields a name.
            const plain = WallpaperFolderService.addWallpaper("C:\\fixtures\\Backslash.jpg");
            root.check(plain === "C:/walls/Backslash.jpg", `a plain path produced "${plain}"`);

            // 11. The real launcher picker loads and carries the same header.
            root.picker = root.pickerComponent.createObject(host);
            root.check(root.picker !== null, "the launcher WallpaperList adapter did not load");
            const launcherFolder = root.find(root.picker, "launcherWallpaperFolder");
            root.check(launcherFolder !== null, "the launcher picker has no folder header");
            root.check(launcherFolder.folderLabel === "C:\\walls", "the launcher header names another folder");
            root.check(root.picker.headerHeight > 0, "the launcher picker did not reserve the header height");
            root.check(root.picker.implicitHeight === root.picker.headerHeight + Tokens.sizes.launcher.wallpaperHeight,
                "the launcher picker does not reserve the carousel below the header");
            root.check(root.picker.count === 0, "the empty production scan produced wallpaper tiles");

            // 12. The real Nexus page loads and shows the same header and
            // empty explanation.
            root.nexusPage = root.nexusComponent.createObject(host);
            root.input.wait(50);
            root.check(root.nexusPage !== null, "the Nexus WallpaperSelect adapter did not load");
            const nexusFolder = root.find(root.nexusPage, "nexusWallpaperFolder");
            root.check(nexusFolder !== null, "the Nexus page has no folder header");
            root.check(nexusFolder.folderLabel === "C:\\walls", "the Nexus header names another folder");
            const nexusEmpty = root.find(root.nexusPage, "nexusWallpaperEmpty");
            root.check(nexusEmpty !== null && nexusEmpty.folderEmpty, "the Nexus page has no empty-folder explanation");

            // 13. The empty-folder state names the folder and both ways to add.
            Wallpapers.files = [];
            root.emptyState = root.emptyComponent.createObject(host, {
                width: 460
            });
            root.check(root.emptyState.folderEmpty, "an empty scan was not reported as empty");
            const title = root.find(root.emptyState, "wallpaperEmptyTitle");
            const hint = root.find(root.emptyState, "wallpaperEmptyHint");
            root.check(title !== null && title.text === "No wallpapers found", "the empty title is missing");
            root.check(hint !== null && hint.text.includes("C:\\walls"), "the empty explanation does not name the folder");
            root.check(hint !== null && hint.text.includes("Add wallpaper"), "the empty explanation does not mention Add wallpaper");
            Wallpapers.files = [{
                path: Paths.absolutePath(Quickshell.shellPath("assets/wallpaper.webp")),
                relativePath: "one.png",
                name: "one.png",
                parentDir: "C:/walls",
                onDisk: true
            }];
            root.check(!root.emptyState.folderEmpty, "a non-empty scan still reported empty");
            root.input.wait(50);
            root.check(root.nexusPage.localWalls.length === 1, "Nexus did not list the new wallpaper without a restart");
            root.check(root.picker.count === 1, "the launcher picker did not list the new wallpaper without a restart");
            Wallpapers.files = [];

            console.log("CAELESTIA_WALLPAPER_FOLDER_PASS " + assertions);
            Qt.quit();
        } catch (error) {
            console.error("CAELESTIA_WALLPAPER_FOLDER_FAIL " + error);
            Qt.exit(1);
        }
    }
}
