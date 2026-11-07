pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Caelestia.Config
import Caelestia.I18n
import qs.components
import qs.services
import qs.modules.nexus.common
import "UpdatesLogic.js" as UpdatesLogic

// Windows page for the "Updates" entry. Upstream's registry still maps this
// entry to PlaceholderComp (caelestia-dots/shell main, stable and feat/plugins
// all checked); the Linux shell updates through the package manager or
// `caelestia update`, so there is no upstream design to adapt. This page is
// built from the same nexus rows as AboutPage and AppsPage.
//
// Explicit checks and authenticated updates run in the stable root's worker,
// never through QML networking. No check occurs on page open. Status comes from the stable
// install root's Manage-Caelestia.ps1 (`-Command Status`, which touches neither
// the desktop nor the network). Rollback queues an independent maintenance task
// that restarts the shell on the retained version.
//
// Environment from the running shell: CAELESTIA_INSTALL_ROOT (stable root),
// CAELESTIA_VERSION_ID (immutable id of the running version) and
// CAELESTIA_SOURCE_REVISION. CAELESTIA_SHELL_SMOKE=1 disables rollback.
PageBase {
    id: root

    readonly property var updateStatus: UpdatesLogic.normalize(loaded ? info : null)
    readonly property string releasesUrl: updateStatus.manualReleaseUrl
    // Declarative action boundary also lets offscreen fixtures record the target
    // without opening a browser in the user's session.
    property var openReleasePage: url => Qt.openUrlExternally(url)

    readonly property string installRoot: String(Quickshell.env("CAELESTIA_INSTALL_ROOT") ?? "")
    readonly property string runningId: String(Quickshell.env("CAELESTIA_VERSION_ID") ?? "")
    readonly property string runningRevision: String(Quickshell.env("CAELESTIA_SOURCE_REVISION") ?? "")
    readonly property string systemRoot: String(Quickshell.env("SystemRoot") ?? "")
    readonly property bool smoke: Quickshell.env("CAELESTIA_SHELL_SMOKE") === "1"
    readonly property bool available: installRoot !== "" && systemRoot !== ""

    // idle | loading | ready | error. "Unavailable" is derived from `available`.
    property string loadState: "idle"
    property var info: null
    property bool confirming: false
    property bool confirmingUpdate: false
    property bool confirmingDevelopment: false
    property var checkResult: null
    // The singleton retains ownership after the page closes. An unconfirmed
    // or complete request cannot be submitted again from this session.
    readonly property bool rollbackSubmitted: UpdateManager.submitted
    readonly property bool rollbackFailed: UpdateManager.failed
    readonly property bool rollbackUnconfirmed: UpdateManager.unconfirmed
    readonly property bool rollbackComplete: UpdateManager.complete

    readonly property bool loaded: loadState === "ready" && info !== null
    readonly property bool busy: loadState === "loading" || rollbackSubmitted || checkProc.running || channelProc.running
    readonly property bool versioned: loaded && updateStatus.versioned
    readonly property string selectedId: loaded ? updateStatus.current : ""
    readonly property string previousId: loaded ? updateStatus.previous : ""
    readonly property string previousRevision: loaded ? updateStatus.previousRevision : ""
    // The shell was started from an older version than the one now selected.
    readonly property bool stale: loaded && runningId !== "" && selectedId !== "" && selectedId !== runningId
    readonly property string runningLabel: runningId === "" ? Tr.tr("Unknown") : runningId === "legacy" ? Tr.tr("Legacy install") : runningId

    // Why rollback is off, or "" when it is allowed.
    readonly property string rollbackBlocker: {
        if (smoke)
            return Tr.tr("Turned off during smoke runs");
        if (!available)
            return Tr.tr("Needs an installed Caelestia");
        if (rollbackSubmitted)
            return UpdateManager.operationKind === "update" ? Tr.tr("An update is in progress") : Tr.tr("Restarting on the previous version");
        if (rollbackUnconfirmed)
            return Tr.tr("The earlier rollback outcome is unconfirmed");
        if (rollbackComplete)
            return Tr.tr("Rollback completed; restart Caelestia if this session remains");
        if (loadState === "loading" || !loaded)
            return loadState === "error" ? Tr.tr("Version status could not be read") : Tr.tr("Reading installed versions");
        if (!versioned)
            return Tr.tr("This install does not keep earlier versions");
        if (stale)
            return Tr.tr("Restart Caelestia first; a different version is selected");
        if (!updateStatus.canRollback)
            return Tr.tr("No earlier version is kept");
        return "";
    }
    readonly property bool canRollback: rollbackBlocker === ""

    readonly property string notice: {
        if (!available)
            return Tr.tr("Version management needs an installed Caelestia. This session was not started from one.");
        if (rollbackUnconfirmed)
            return Tr.tr("Maintenance confirmation is unavailable. It may still run. Refresh to check the selected version; another request is blocked.");
        if (rollbackComplete)
            return Tr.tr("Maintenance completed. Refresh to check the selected version.");
        if (loadState === "error")
            return Tr.tr("Version status could not be read. Try refreshing.");
        if (rollbackFailed)
            return Tr.tr("Maintenance could not complete. Refresh to check the selected version.");
        if (rollbackSubmitted)
            return UpdateManager.operationKind === "update" ? Tr.tr("Authenticated update in progress. Caelestia will restart after verification.") : Tr.tr("Rollback requested. Caelestia will restart shortly.");
        return "";
    }

    function shortRevision(rev: string): string {
        return rev ? rev.substring(0, 8) : Tr.tr("Unknown");
    }

    function refresh(): void {
        if (!available || statusProc.running || rollbackSubmitted)
            return;
        loadState = "loading";
        statusProc.command = powershellCommand(["-Command", "Status"]);
        statusProc.running = true;
    }

    function requestRollback(): void {
        if (!canRollback)
            return;
        confirming = false;
        UpdateManager.request(powershellCommand(["-Command", "Rollback", "-ExpectedCurrent", selectedId]));
    }

    function check(): void {
        if (smoke || !loaded || busy || stale || UpdateManager.unconfirmed || UpdateManager.complete)
            return;
        checkResult = null;
        confirmingUpdate = false;
        checkProc.command = powershellCommand(["-Command", "CheckUpdate"]);
        checkProc.running = true;
    }

    function setChannel(channel: string): void {
        if (smoke || !loaded || busy || UpdateManager.unconfirmed || UpdateManager.complete)
            return;
        checkResult = null;
        confirmingDevelopment = false;
        const args = ["-Command", "SetChannel", "-Channel", channel];
        if (channel === "development")
            args.push("-AcceptDevelopment");
        channelProc.command = powershellCommand(args);
        channelProc.running = true;
    }

    function requestUpdate(): void {
        if (smoke || busy || stale || !checkResult?.available || checkResult.channel !== updateStatus.channel)
            return;
        confirmingUpdate = false;
        UpdateManager.request(powershellCommand(["-Command", "Update", "-ExpectedCurrent", selectedId,
            "-ExpectedBuild", checkResult.available.buildVersion, "-Channel", checkResult.channel]), "update");
    }

    function powershellCommand(extra: var): var {
        return [
            `${systemRoot}\\System32\\WindowsPowerShell\\v1.0\\powershell.exe`,
            "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden",
            "-File", `${installRoot}\\Manage-Caelestia.ps1`,
            "-Prefix", installRoot,
            ...extra
        ];
    }

    title: Tr.tr("Updates")

    Component.onCompleted: refresh()

    // Drop the confirmation if the action stops being allowed underneath it.
    onCanRollbackChanged: {
        if (!canRollback)
            confirming = false;
    }

    property Process statusProcess: Process {
        id: statusProc

        command: []

        stdout: StdioCollector {
            id: statusOut
        }

        onExited: code => {
            const data = UpdatesLogic.parseStatus(code, statusOut.text.trim());
            if (data) {
                root.info = data;
                root.loadState = "ready";
            } else {
                root.info = null;
                root.loadState = "error";
                // Exit code only: the output can carry user paths.
                console.warn(`CAELESTIA_UPDATES_STATUS_FAIL exit=${code}`);
            }
        }
    }

    property Process checkProcess: Process {
        id: checkProc
        stdout: StdioCollector { id: checkOut }
        onExited: code => {
            root.checkResult = UpdatesLogic.parseCheck(code, checkOut.text.trim()) ||
                {state: "bad-metadata", channel: root.updateStatus.channel, available: null};
        }
    }
    property Process channelProcess: Process {
        id: channelProc
        onExited: code => {
            if (code === 0)
                root.refresh();
        }
    }

    ColumnLayout {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        width: root.cappedWidth
        spacing: Tokens.spacing.extraSmall / 2

        // Notice
        InfoRow {
            first: true
            last: true
            visible: root.notice !== ""
            icon: root.rollbackSubmitted ? "restart_alt" : "info"
            iconColour: root.rollbackFailed || root.loadState === "error" ? Colours.palette.m3error : Colours.palette.m3onSurfaceVariant
            label: root.notice
            value: ""
        }

        // This build
        SectionHeader {
            first: root.notice === ""
            text: Tr.tr("This build")
        }

        InfoRow {
            first: true
            icon: "deployed_code"
            label: Tr.tr("Running version")
            value: !root.stale && root.updateStatus.displayVersion !== "" ? root.updateStatus.displayVersion : root.runningLabel
        }

        InfoRow {
            visible: !root.stale && root.updateStatus.releaseVersion !== ""
            icon: "fingerprint"
            label: Tr.tr("Artifact build")
            value: root.updateStatus.releaseVersion
        }

        InfoRow {
            icon: "commit"
            label: Tr.tr("Source revision")
            value: root.shortRevision(root.runningRevision || (root.stale ? "" : String(root.info?.sourceRevision ?? "")))
        }

        InfoRow {
            visible: root.stale
            icon: "swap_horiz"
            label: Tr.tr("Selected version")
            subtext: Tr.tr("Restart Caelestia to switch to it")
            value: root.selectedId
        }

        RowButton {
            last: true
            icon: "refresh"
            text: Tr.tr("Refresh")
            subtext: Tr.tr("Read the installed versions again")
            disabled: !root.available || root.busy
            subLabel.animate: true
            onClicked: root.refresh()
        }

        // Previous version
        SectionHeader {
            text: Tr.tr("Previous version")
        }

        InfoRow {
            first: true
            icon: "history"
            label: Tr.tr("Kept version")
            value: root.previousId !== "" ? root.previousId : Tr.tr("None")
        }

        InfoRow {
            visible: root.previousId !== ""
            icon: "commit"
            label: Tr.tr("Source revision")
            value: root.shortRevision(root.previousRevision)
        }

        RowButton {
            last: true
            visible: !root.confirming
            icon: "undo"
            text: root.previousId !== "" ? Tr.tr("Roll back to previous version") : Tr.tr("Roll back")
            subtext: root.rollbackBlocker
            disabled: !root.canRollback
            subLabel.animate: true
            onClicked: root.confirming = true
        }

        // Second step: restart and settings are stated before anything is queued
        InfoRow {
            visible: root.confirming
            icon: "restart_alt"
            label: Tr.tr("Caelestia will restart on the previous version")
            subtext: Tr.tr("Your settings are kept")
            value: ""
        }

        RowButton {
            visible: root.confirming
            icon: "check"
            text: Tr.tr("Restart and roll back")
            disabled: !root.canRollback
            onClicked: root.requestRollback()
        }

        RowButton {
            last: true
            visible: root.confirming
            icon: "close"
            text: Tr.tr("Cancel")
            onClicked: root.confirming = false
        }

        // Updates
        SectionHeader {
            text: Tr.tr("New versions")
        }

        InfoRow {
            first: true
            icon: "route"
            label: Tr.tr("Update channel")
            subtext: Tr.tr("Checks only when requested. Channel selection survives update and rollback.")
            value: root.updateStatus.channel
        }

        RowButton {
            icon: "science"
            text: Tr.tr("Use development channel")
            subtext: Tr.tr("Automatic verified-main builds. Can break. Click again to accept.")
            disabled: root.smoke || !root.loaded || root.busy
            onClicked: {
                if (root.confirmingDevelopment)
                    root.setChannel("development");
                else
                    root.confirmingDevelopment = true;
            }
        }
        RowButton {
            icon: "preview"
            text: Tr.tr("Use preview channel")
            disabled: root.smoke || !root.loaded || root.busy
            onClicked: root.setChannel("preview")
        }
        RowButton {
            icon: "verified"
            text: Tr.tr("Use stable channel")
            subtext: Tr.tr("Owner-promoted 1.0 or newer only; never development builds")
            disabled: root.smoke || !root.loaded || root.busy
            onClicked: root.setChannel("stable")
        }
        RowButton {
            icon: "refresh"
            text: Tr.tr("Check for updates")
            disabled: root.smoke || !root.loaded || root.busy || root.stale
            onClicked: root.check()
        }
        InfoRow {
            objectName: "updateResultRow"
            icon: "info"
            label: checkProc.running ? Tr.tr("Checking") : root.checkResult?.available
                ? root.checkResult.available.displayVersion : root.checkResult
                ? Tr.tr(UpdatesLogic.checkLabel(root.checkResult.state)) : root.updateStatus.updatesConfigured
                ? Tr.tr("Not checked") : Tr.tr("Updates aren't set up for this build")
            subtext: root.checkResult?.available ? root.checkResult.available.buildVersion : ""
            value: UpdateManager.operationKind === "update" && UpdateManager.submitted ? UpdateManager.step : ""
        }
        RowButton {
            visible: root.checkResult?.available !== undefined && root.checkResult?.available !== null
            icon: "download"
            text: root.confirmingUpdate ? Tr.tr("Confirm download, verify and restart") : Tr.tr("Download and install")
            subtext: root.confirmingUpdate ? Tr.tr("Settings are kept; the current payload remains available for rollback. No automatic settings migration.") : root.checkResult?.available
                ? `${Math.ceil(root.checkResult.available.size / 1048576)} MB` : ""
            disabled: root.smoke || root.busy || root.stale || UpdateManager.unconfirmed || UpdateManager.complete
            onClicked: {
                if (root.confirmingUpdate)
                    root.requestUpdate();
                else
                    root.confirmingUpdate = true;
            }
        }
        RowButton {
            visible: root.checkResult?.available !== undefined && root.checkResult?.available !== null
            icon: "open_in_new"
            text: Tr.tr("Release notes")
            onClicked: root.openReleasePage(root.checkResult.available.notesUrl)
        }

        RowButton {
            objectName: "manualReleasesButton"
            last: true
            icon: "open_in_new"
            text: Tr.tr("View manual downloads")
            subtext: Tr.tr("Public previews and verification instructions on GitHub")
            onClicked: root.openReleasePage(root.releasesUrl)
        }
    }
}
