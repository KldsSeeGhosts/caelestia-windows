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

// Windows page for the "Updates" entry. Upstream's registry still maps this
// entry to PlaceholderComp (caelestia-dots/shell main, stable and feat/plugins
// all checked); the Linux shell updates through the package manager or
// `caelestia update`, so there is no upstream design to adapt. This page is
// built from the same nexus rows as AboutPage and AppsPage.
//
// It only reports and switches installed versions. No release feed or download
// channel is published yet, so nothing here checks the network, downloads or
// claims an update is available. The version status comes from the stable
// install root's Manage-Caelestia.ps1 (`-Command Status`, which touches neither
// the desktop nor the network). Rollback queues an independent maintenance task
// that restarts the shell on the retained version.
//
// Environment from the running shell: CAELESTIA_INSTALL_ROOT (stable root),
// CAELESTIA_VERSION_ID (immutable id of the running version) and
// CAELESTIA_SOURCE_REVISION. CAELESTIA_SHELL_SMOKE=1 disables rollback.
PageBase {
    id: root

    readonly property string releasesUrl: "https://github.com/KldsSeeGhosts/caelestia-windows/releases"

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
    // Set on submit and kept after success: the shell restarts, so the page
    // never re-enables the action.
    readonly property bool rollbackSubmitted: UpdateManager.submitted
    readonly property bool rollbackFailed: UpdateManager.failed

    readonly property bool loaded: loadState === "ready" && info !== null
    readonly property bool busy: loadState === "loading" || rollbackSubmitted
    readonly property bool versioned: loaded && info.versioned === true
    readonly property string selectedId: loaded ? String(info.current ?? "") : ""
    readonly property string previousId: loaded ? String(info.previous ?? "") : ""
    readonly property string previousRevision: loaded ? String(info.previousRevision ?? "") : ""
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
            return Tr.tr("Restarting on the previous version");
        if (loadState === "loading" || !loaded)
            return loadState === "error" ? Tr.tr("Version status could not be read") : Tr.tr("Reading installed versions");
        if (!versioned)
            return Tr.tr("This install does not keep earlier versions");
        if (stale)
            return Tr.tr("Restart Caelestia first; a different version is selected");
        if (info.canRollback !== true || previousId === "")
            return Tr.tr("No earlier version is kept");
        return "";
    }
    readonly property bool canRollback: rollbackBlocker === ""

    readonly property string notice: {
        if (!available)
            return Tr.tr("Version management needs an installed Caelestia. This session was not started from one.");
        if (loadState === "error")
            return Tr.tr("Version status could not be read. Try refreshing.");
        if (rollbackFailed)
            return Tr.tr("Rollback could not complete. Refresh to check the selected version.");
        if (rollbackSubmitted)
            return Tr.tr("Rollback requested. Caelestia will restart shortly.");
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

    Process {
        id: statusProc

        command: []

        stdout: StdioCollector {
            id: statusOut
        }

        onExited: code => {
            let data = null;
            if (code === 0) {
                try {
                    data = JSON.parse(statusOut.text.trim());
                } catch (error) {
                    data = null;
                }
            }
            if (data && data.schema === 1) {
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
            value: root.runningLabel
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
            icon: "cloud_off"
            label: Tr.tr("Download channel")
            subtext: Tr.tr("No releases are published yet, so Caelestia cannot download updates")
            value: Tr.tr("Not available")
        }

        RowButton {
            last: true
            icon: "open_in_new"
            text: Tr.tr("View releases")
            subtext: Tr.tr("Opens the project page in your browser")
            onClicked: Qt.openUrlExternally(root.releasesUrl)
        }
    }
}
