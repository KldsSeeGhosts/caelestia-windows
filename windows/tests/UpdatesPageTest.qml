import QtQuick
import QtTest
import Quickshell
import Caelestia.Config
import qs.components
import qs.modules.nexus as Nexus
import qs.modules.nexus.pages as Pages
import qs.services

// Real staged page/RowButton, offscreen only. No installed prefix is supplied:
// no status command or rollback is started. The browser callback records URLs.
ShellRoot {
    id: root
    settings.watchFiles: false
    Config.screen: screenState.modelData?.name ?? ""
    Tokens.screen: screenState.modelData?.name ?? ""
    WindowsFonts {}
    FontLoader {
        source: Quickshell.shellPath("assets/google-sans-flex/GoogleSansFlex-VariableFont_GRAD,ROND,opsz,slnt,wdth,wght.ttf")
    }
    FontLoader { source: Quickshell.shellPath("assets/material-symbols-rounded/MaterialSymbolsRounded.ttf") }
    ScreenState {
        id: screenState
        modelData: Quickshell.screens[0] ?? null
        session: false
    }
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
        color: Colours.palette.m3background
        contentItem.Config.screen: screenState.modelData?.name ?? ""
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
            check(!page.detailsExpanded && !find(page, "updateDetails").visible, "Details must start collapsed");
            const primary = find(page, "primaryUpdateButton");
            check(primary !== null && primary.text === "Check for updates", "single primary check action missing");
            check(primary.disabled, "uninstalled session offered update/check");
            check(primary.activeFocusOnTab === false && primary.Accessible.role === Accessible.Button, "disabled primary keyboard semantics");
            find(page, "detailsButton").activate();
            check(page.detailsExpanded && find(page, "updateDetails").visible, "Details did not expand");
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
            check(!page.checkProcess.running && !page.channelProcess.running, "page open started a network or settings operation");
            const status = find(page, "updateStatusLabel");
            check(status !== null, "main card status is missing");
            for (const state of ["not-newer", "not-configured", "offline", "http", "too-large",
                "bad-signature", "bad-metadata", "expired", "clock", "replay", "unsupported", "busy"]) {
                page.checkResult = {state: state, channel: "preview", available: null};
                check(status.text !== "", "empty update label for " + state);
            }
            page.checkResult = {state: "available", channel: "preview", available: {
                displayVersion: "0.2.0-preview.1", buildVersion: "0.2.0-dev.1.57.1", size: 100, notesUrl: page.releasesUrl
            }};
            check(primary.text === "Update now", "available update did not replace primary check action");
            check(primary.disabled, "available metadata bypassed installed-prefix guard");
            page.info = {schema: 1, displayVersion: "0.2.0-dev.1.283.1"};
            page.loadState = "ready";
            check(page.runningLabel === "0.2.0 \u00b7 Dev build 283", "friendly running version not used");
            const progress = find(page, "updateProgress");
            check(!progress.visible, "idle page has a progress bar");
            UpdateManager.operationKind = "update";
            UpdateManager.operationState = "waiting";
            for (const phase of ["downloading", "verifying", "installing", "restarting"]) {
                UpdateManager.step = phase;
                check(primary.disabled && primary.text === status.text, "running action is not disabled for " + phase);
                check(progress.visible && progress.indeterminate, "unmeasured phase must be indeterminate");
            }
            UpdateManager.step = "downloading";
            UpdateManager.progressUnit = "bytes";
            UpdateManager.progressTotal = 100;
            UpdateManager.progressCompleted = 40;
            check(!progress.indeterminate && progress.value === 0.4, "page did not bind real download progress");
            check(Math.abs(find(page, "updateProgressFill").width - progress.width * 0.4) < 1,
                "rendered fill does not match measured fraction");
            check(page.progressLabel !== "", "download byte totals missing");
            UpdateManager.operationState = "unconfirmed";
            check(primary.disabled && status.text.indexOf("may still run") >= 0, "unconfirmed operation lost duplicate protection");
            UpdateManager.operationState = "complete";
            check(primary.disabled && progress.value === 1, "complete operation did not fill bar and block duplicate");
            UpdateManager.operationState = "idle";
            UpdateManager.progressTotal = 0;
            page.detailsExpanded = false;
            page.confirmingDevelopment = true;
            check(find(page, "confirmDevelopment").visible, "development warning has no explicit confirmation");
            check(!page.channelProcess.running, "showing development warning changed channel");
            const screenshot = Quickshell.env("CAELESTIA_UPDATES_SCREENSHOT");
            if (screenshot) {
                page.confirmingDevelopment = false;
                UpdateManager.operationState = "waiting";
                UpdateManager.operationKind = "update";
                UpdateManager.step = "downloading";
                UpdateManager.progressUnit = "bytes";
                UpdateManager.progressTotal = 104857600;
                UpdateManager.progressCompleted = 41943040;
                page.flickable.contentY = 0;
                root.input.wait(1200);
                check(page.contentChild.width > 0 && page.contentChild.height > 0, "page content has no geometry");
                const grabbed = page.contentChild.grabToImage(result => {
                    if (!result.saveToFile(screenshot)) {
                        console.log("CAELESTIA_UPDATES_FAIL screenshot save failed");
                        Qt.exit(1);
                        return;
                    }
                    console.log("CAELESTIA_UPDATES_PASS " + root.assertions);
                    Qt.quit();
                });
                check(grabbed, "offscreen page grab was refused");
                return;
            }
            console.log("CAELESTIA_UPDATES_PASS " + assertions);
            Qt.quit();
        } catch (error) {
            console.log("CAELESTIA_UPDATES_FAIL " + error);
            Qt.exit(1);
        }
    }
    Timer { interval: 500; running: true; onTriggered: root.run() }
}
