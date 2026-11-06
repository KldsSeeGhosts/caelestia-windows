import QtQuick
import QtTest
import Quickshell
import qs.modules.nexus as Nexus
import qs.modules.nexus.pages as Pages

// Real staged page/RowButton, offscreen only. No installed prefix is supplied:
// no status command or rollback is started. The browser callback records URLs.
ShellRoot {
    id: root
    property int assertions: 0
    property int opened: 0
    property string target: ""
    property var input
    property Component inputComponent: Component { TestCase { when: false } }
    Nexus.NexusState { id: navigation }
    FloatingWindow {
        id: win
        visible: true
        implicitWidth: 900
        implicitHeight: 900
        Pages.UpdatesPage {
            id: page
            anchors.fill: parent
            nState: navigation
            openReleasePage: url => { root.opened++; root.target = url; }
        }
    }
    function check(value, message): void {
        if (!value) throw new Error(message);
        assertions++;
    }
    function find(item, name): var {
        if (item.objectName === name) return item;
        for (const child of item.children ?? []) {
            const found = find(child, name);
            if (found) return found;
        }
        return null;
    }
    function run(): void {
        try {
            check(!page.available, "fixture must not have an installed prefix");
            check(!page.statusProcess.running, "fixture started a real status process");
            check(page.releasesUrl === "https://github.com/KldsSeeGhosts/caelestia-windows/releases", "manual target missing when status unavailable");
            check(!page.canRollback, "uninstalled session offered rollback");
            page.info = {schema: 1, versioned: true, current: "fixture-current", previous: "fixture-old", canRollback: true};
            page.loadState = "ready";
            check(page.previousId === "fixture-old", "retained version was not displayed");
            check(page.updateStatus.canRollback, "valid retained status lost rollback capability");
            check(!page.updateStatus.automaticUpdatesAvailable && page.updateStatus.latestVersion === null, "retained version implied a remote update");
            page.info = {schema: 1, versioned: true, previous: "", canRollback: true};
            check(!page.updateStatus.canRollback && page.previousId === "", "empty previous version offered rollback");
            page.info = {schema: 1};
            check(page.selectedId === "" && page.previousId === "", "partial status fabricated installed versions");
            page.statusProcess.exited(1, 0);
            check(page.loadState === "error" && page.info === null, "unavailable command did not clear stale status");
            check(page.notice.indexOf("status could not be read") !== -1 || !page.available, "unavailable status has no useful explanation");
            check(page.releasesUrl === "https://github.com/KldsSeeGhosts/caelestia-windows/releases", "status error removed manual downloads");
            const button = find(page, "manualReleasesButton");
            check(button !== null && !button.disabled, "manual action missing or disabled offline");
            check(button.activeFocusOnTab && button.Accessible.role === Accessible.Button, "manual action is not a keyboard button");
            root.input = inputComponent.createObject(win.contentItem);
            page.flickable.contentY = Math.max(0, page.flickable.contentHeight - page.flickable.height);
            button.forceActiveFocus(Qt.TabFocusReason);
            root.input.wait(50);
            check(button.activeFocus, "manual action did not accept keyboard focus");
            root.input.keyClick(Qt.Key_Return);
            check(root.opened === 1 && root.target === page.releasesUrl, "Enter did not route to the manual release target");
            root.input.keyClick(Qt.Key_Space);
            check(root.opened === 2, "Space did not activate the manual action");
            check(!page.statusProcess.running, "manual action started a status/download process");
            console.log("CAELESTIA_UPDATES_PASS " + assertions);
            Qt.quit();
        } catch (error) {
            console.log("CAELESTIA_UPDATES_FAIL " + error);
            Qt.exit(1);
        }
    }
    Timer { interval: 500; running: true; onTriggered: root.run() }
}
