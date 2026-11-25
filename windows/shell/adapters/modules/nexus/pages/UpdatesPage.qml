pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtQuick.Templates as T
import Quickshell
import Quickshell.Io
import Caelestia.Windows
import Caelestia.Config
import Caelestia.I18n
import qs.components
import qs.components.controls
import qs.services
import qs.modules.nexus.common
import "UpdatesLogic.js" as UpdatesLogic

// Explicit checks and authenticated updates run in the stable root's worker,
// never through QML networking. Status reads installed state only. The service
// owns queued maintenance even after this page closes. Smoke cannot mutate.
PageBase {
    id: root

    readonly property var updateStatus: UpdatesLogic.normalize(loaded ? info : null)
    readonly property string releasesUrl: updateStatus.manualReleaseUrl
    property var openReleasePage: url => Qt.openUrlExternally(url)
    readonly property string installRoot: String(Quickshell.env("CAELESTIA_INSTALL_ROOT") ?? "")
    readonly property string runningId: String(Quickshell.env("CAELESTIA_VERSION_ID") ?? "")
    readonly property string runningRevision: String(Quickshell.env("CAELESTIA_SOURCE_REVISION") ?? "")
    readonly property string systemRoot: String(Quickshell.env("SystemRoot") ?? "")
    readonly property bool smoke: Quickshell.env("CAELESTIA_SHELL_SMOKE") === "1"
    readonly property bool available: installRoot !== "" && systemRoot !== "" && powerShellExecutable !== ""

    property string loadState: "idle"
    property var info: null
    property bool confirming: false
    property bool detailsExpanded: false
    property var checkResult: null
    readonly property bool rollbackSubmitted: UpdateManager.submitted
    readonly property bool rollbackFailed: UpdateManager.failed
    readonly property bool rollbackUnconfirmed: UpdateManager.unconfirmed
    readonly property bool rollbackComplete: UpdateManager.complete
    readonly property bool loaded: loadState === "ready" && info !== null
    readonly property bool busy: loadState === "loading" || rollbackSubmitted || checkProc.running
    readonly property bool versioned: loaded && updateStatus.versioned
    readonly property string selectedId: loaded ? updateStatus.current : ""
    readonly property string previousId: loaded ? updateStatus.previous : ""
    readonly property string previousRevision: loaded ? updateStatus.previousRevision : ""
    readonly property bool stale: loaded && runningId !== "" && selectedId !== "" && selectedId !== runningId
    readonly property string runningLabel: runningId === "legacy" ? Tr.tr("Legacy install")
        : UpdatesLogic.formatVersion((!stale && updateStatus.displayVersion) || runningId)
    readonly property bool updateBlocked: smoke || !available || !loaded || busy || rollbackUnconfirmed || rollbackComplete || stale
    readonly property var availableUpdate: checkResult?.channel === UpdatesLogic.releaseFeed ? checkResult.available : null
    readonly property var primary: UpdatesLogic.primaryState({
        operationState: UpdateManager.operationState, operationKind: UpdateManager.operationKind,
        step: UpdateManager.step, checking: checkProc.running, result: checkResult,
        available: availableUpdate,
        configured: loaded ? updateStatus.updatesConfigured : undefined,
        notice: notice, blocked: updateBlocked
    })
    readonly property string rollbackBlocker: {
        if (smoke) return Tr.tr("Turned off during smoke runs");
        if (!available) return Tr.tr("Needs an installed Caelestia");
        if (rollbackSubmitted) return Tr.tr("Maintenance is in progress");
        if (rollbackUnconfirmed) return Tr.tr("The earlier maintenance outcome is unconfirmed");
        if (rollbackComplete) return Tr.tr("Maintenance completed; restart Caelestia if this session remains");
        if (!loaded) return Tr.tr("Version status could not be read");
        if (!versioned) return Tr.tr("This install does not keep earlier versions");
        if (stale) return Tr.tr("Restart Caelestia first; a different version is selected");
        if (busy) return Tr.tr("Another operation is in progress");
        if (!updateStatus.canRollback) return Tr.tr("No earlier version is kept");
        return "";
    }
    readonly property bool canRollback: rollbackBlocker === ""
    readonly property string notice: {
        if (!available) return Tr.tr("Version management needs an installed Caelestia.");
        if (loadState === "error") return Tr.tr("Version status could not be read. Refresh in Details to retry.");
        if (stale) return Tr.tr("Restart Caelestia first; a different version is selected.");
        if (!loaded) return Tr.tr("Reading installed versions\u2026");
        return "";
    }
    readonly property string progressLabel: {
        if (!UpdateManager.determinate) return "";
        if (UpdateManager.progressUnit === "bytes")
            return `${(UpdateManager.progressCompleted / 1048576).toFixed(1)} / ${(UpdateManager.progressTotal / 1048576).toFixed(1)} MB`;
        return Tr.tr("Extracted %1 of %2 entries").arg(UpdateManager.progressCompleted).arg(UpdateManager.progressTotal);
    }

    function shortRevision(rev: string): string {
        return rev ? rev.substring(0, 8) : Tr.tr("Unknown");
    }
    function refresh(): void {
        if (!available || statusProc.running || rollbackSubmitted) return;
        loadState = "loading";
        statusProc.command = powershellCommand(["-Command", "Status"]);
        statusProc.running = true;
    }
    function requestRollback(): void {
        if (!canRollback) return;
        confirming = false;
        UpdateManager.request(powershellCommand(["-Command", "Rollback", "-ExpectedCurrent", selectedId]));
    }
    function check(): void {
        if (updateBlocked) return;
        checkResult = null;
        checkProc.command = powershellCommand(["-Command", "CheckUpdate", "-Channel", UpdatesLogic.releaseFeed]);
        checkProc.running = true;
    }
    function requestUpdate(): void {
        if (updateBlocked || !availableUpdate) return;
        UpdateManager.request(powershellCommand(["-Command", "Update", "-ExpectedCurrent", selectedId,
            "-ExpectedBuild", availableUpdate.buildVersion, "-Channel", UpdatesLogic.releaseFeed]), "update");
    }
    function activatePrimary(): void {
        if (primary.disabled) return;
        if (primary.action === "update") requestUpdate();
        else check();
    }
    function powershellCommand(extra: var): var {
        return [
            powerShellExecutable,
            "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden",
            "-File", `${installRoot}\\Manage-Caelestia.ps1`, "-Prefix", installRoot, ...extra
        ];
    }

    // The launcher passes the verified PowerShell 7 path. A standalone run
    // falls back to the fixed install locations rather than relying on PATH.
    readonly property string powerShellExecutable: {
        const configured = String(Quickshell.env("CAELESTIA_POWERSHELL") ?? "");
        if (configured.length > 0)
            return configured;
        const programFiles = String(Quickshell.env("ProgramFiles") ?? "");
        if (programFiles.length > 0) {
            const bundled = programFiles + "\\PowerShell\\7\\pwsh.exe";
            if (WindowsFiles.isFile(bundled))
                return bundled;
        }
        const localAppData = String(Quickshell.env("LOCALAPPDATA") ?? "");
        if (localAppData.length > 0) {
            const perUser = localAppData + "\\Programs\\PowerShell\\7\\pwsh.exe";
            if (WindowsFiles.isFile(perUser))
                return perUser;
            const storeAlias = localAppData
                + "\\Microsoft\\WindowsApps\\Microsoft.PowerShell_8wekyb3d8bbwe\\pwsh.exe";
            if (WindowsFiles.isFile(storeAlias))
                return storeAlias;
        }
        return "";
    }

    title: Tr.tr("Updates")
    Component.onCompleted: refresh()
    onCanRollbackChanged: { if (!canRollback) confirming = false; }

    property Process statusProcess: Process {
        id: statusProc
        command: []
        stdout: StdioCollector { id: statusOut }
        onExited: code => {
            const data = UpdatesLogic.parseStatus(code, statusOut.text.trim());
            root.info = data;
            root.loadState = data ? "ready" : "error";
            if (!data) console.warn(`CAELESTIA_UPDATES_STATUS_FAIL exit=${code}`);
        }
    }
    property Process checkProcess: Process {
        id: checkProc
        stdout: StdioCollector { id: checkOut }
        onExited: code => root.checkResult = UpdatesLogic.parseCheck(code, checkOut.text.trim()) ||
            {state: "bad-metadata", available: null}
    }

    // Native buttons with the keyboard/focus contract used by Nexus rows.
    component ActionButton: TextButton {
        id: action
        property bool pointerUsed: false
        activeFocusOnTab: !disabled
        onActiveFocusChanged: pointerUsed = false
        function activate(): void { if (!disabled) clicked(); }
        Keys.onPressed: event => {
            if ([Qt.Key_Return, Qt.Key_Enter, Qt.Key_Space].indexOf(event.key) >= 0) {
                event.accepted = true;
                if (!event.isAutoRepeat) activate();
            }
        }
        Accessible.role: Accessible.Button
        Accessible.name: text
        Accessible.onPressAction: activate()
        stateLayer.onPressed: focusRing.pointerPressed()
        FocusRing {
            id: focusRing
            anchors.fill: parent
            showing: action.activeFocus && !action.disabled && !action.pointerUsed
            radius: action.radius
        }
    }

    ColumnLayout {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        width: root.cappedWidth
        spacing: Tokens.spacing.extraSmall / 2

        ConnectedRect {
            objectName: "updateCard"
            Layout.fillWidth: true
            first: true
            last: true
            implicitHeight: hero.implicitHeight + Tokens.padding.largeIncreased * 2
            ColumnLayout {
                id: hero
                anchors.fill: parent
                anchors.margins: Tokens.padding.largeIncreased
                spacing: Tokens.spacing.medium
                StyledText {
                    Layout.fillWidth: true
                    text: `Caelestia ${root.runningLabel}`
                    font: Tokens.font.headline.small
                    wrapMode: Text.WordWrap
                }
                StyledText {
                    objectName: "updateStatusLabel"
                    Layout.fillWidth: true
                    text: UpdateManager.refusalMessage || Tr.tr(root.primary.status)
                    font: Tokens.font.body.medium
                    color: root.rollbackFailed || root.loadState === "error"
                        ? Colours.palette.m3error : Colours.palette.m3onSurfaceVariant
                    wrapMode: Text.WordWrap
                    Accessible.role: Accessible.StaticText
                    Accessible.name: text
                }
                TextEdit {
                    objectName: "manualMaintenanceCommand"
                    Layout.fillWidth: true
                    visible: UpdateManager.manualCommand !== ""
                    text: UpdateManager.manualCommand
                    textFormat: TextEdit.PlainText
                    readOnly: true
                    selectByMouse: true
                    wrapMode: TextEdit.Wrap
                    color: Colours.palette.m3onSurface
                    font: Tokens.font.body.medium
                }
                T.ProgressBar {
                    id: updateProgress
                    objectName: "updateProgress"
                    Layout.fillWidth: true
                    implicitHeight: Tokens.padding.extraSmall
                    visible: root.rollbackSubmitted || root.rollbackComplete
                    value: UpdateManager.progressFraction
                    indeterminate: !UpdateManager.determinate && !root.rollbackComplete
                    Accessible.name: Tr.tr(root.primary.status)
                    // A measured phase is a direct fill, with no looping or
                    // completion animation between byte/entry samples.
                    contentItem: Item {
                        StyledRect {
                            anchors.fill: parent
                            visible: !updateProgress.indeterminate
                            radius: Tokens.rounding.full
                            color: Colours.palette.m3secondaryContainer
                        }
                        StyledRect {
                            objectName: "updateProgressFill"
                            visible: !updateProgress.indeterminate
                            width: parent.width * updateProgress.position
                            height: parent.height
                            radius: Tokens.rounding.full
                            color: Colours.palette.m3primary
                        }
                        StyledProgressBar {
                            anchors.fill: parent
                            visible: updateProgress.indeterminate
                            indeterminate: visible
                        }
                    }
                }
                StyledText {
                    Layout.fillWidth: true
                    visible: root.progressLabel !== "" && root.rollbackSubmitted
                    text: root.progressLabel
                    font: Tokens.font.label.small
                    color: Colours.palette.m3onSurfaceVariant
                }
                ActionButton {
                    objectName: "primaryUpdateButton"
                    text: Tr.tr(root.primary.label)
                    disabled: root.primary.disabled
                    onClicked: root.activatePrimary()
                }
                StyledText {
                    Layout.fillWidth: true
                    visible: !!root.availableUpdate && !root.rollbackSubmitted
                    text: Tr.tr("Downloads, verifies, installs and restarts. Your settings are kept.")
                    font: Tokens.font.label.small
                    color: Colours.palette.m3onSurfaceVariant
                    wrapMode: Text.WordWrap
                }
            }
        }

        RowButton {
            objectName: "rollbackButton"
            Layout.topMargin: Tokens.spacing.medium
            first: true
            last: true
            icon: "undo"
            text: root.previousId ? Tr.tr("Roll back to %1").arg(UpdatesLogic.formatVersion(root.updateStatus.previousDisplayVersion || root.previousId)) : Tr.tr("Roll back")
            subtext: root.confirming ? Tr.tr("Caelestia will restart. Your settings are kept.") : root.rollbackBlocker
            disabled: !root.canRollback
            onClicked: root.confirming = true
        }
        RowLayout {
            visible: root.confirming
            ActionButton {
                text: Tr.tr("Restart and roll back")
                disabled: !root.canRollback
                onClicked: root.requestRollback()
            }
            ActionButton {
                text: Tr.tr("Cancel")
                type: TextButton.Text
                onClicked: root.confirming = false
            }
        }

        RowButton {
            objectName: "detailsButton"
            Layout.topMargin: Tokens.spacing.medium
            first: true
            last: !root.detailsExpanded
            icon: "info"
            text: Tr.tr("Details")
            trailingIcon: root.detailsExpanded ? "expand_less" : "expand_more"
            Accessible.description: root.detailsExpanded ? Tr.tr("Expanded") : Tr.tr("Collapsed")
            onClicked: root.detailsExpanded = !root.detailsExpanded
        }
        ColumnLayout {
            objectName: "updateDetails"
            Layout.fillWidth: true
            visible: root.detailsExpanded
            spacing: Tokens.spacing.extraSmall / 2
            InfoRow { label: Tr.tr("Running version id"); value: root.runningId || Tr.tr("Unknown") }
            InfoRow { label: Tr.tr("Artifact build"); value: root.updateStatus.releaseVersion || Tr.tr("Unknown") }
            InfoRow {
                label: Tr.tr("Source revision")
                value: root.shortRevision(root.runningRevision || (root.stale ? "" : root.updateStatus.sourceRevision))
            }
            InfoRow { visible: root.stale; label: Tr.tr("Selected version id"); value: root.selectedId }
            InfoRow { label: Tr.tr("Kept version id"); value: root.previousId || Tr.tr("None") }
            InfoRow { visible: root.previousId !== ""; label: Tr.tr("Previous revision"); value: root.shortRevision(root.previousRevision) }
            InfoRow { visible: !!root.availableUpdate; label: Tr.tr("Available version"); value: root.availableUpdate?.buildVersion ?? "" }
            RowButton {
                icon: "refresh"
                text: Tr.tr("Refresh")
                disabled: !root.available || root.busy
                onClicked: root.refresh()
            }
            RowButton {
                visible: !!root.availableUpdate
                icon: "open_in_new"
                text: Tr.tr("Release notes")
                onClicked: root.openReleasePage(root.availableUpdate.notesUrl)
            }
            RowButton {
                objectName: "manualReleasesButton"
                last: true
                icon: "open_in_new"
                text: Tr.tr("Download manually")
                subtext: Tr.tr("The same Windows release, with installation instructions")
                onClicked: root.openReleasePage(root.releasesUrl)
            }
        }
    }
}
