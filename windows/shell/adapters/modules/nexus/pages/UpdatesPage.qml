pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtQuick.Templates as T
import Quickshell
import Quickshell.Io
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
    readonly property bool available: installRoot !== "" && systemRoot !== ""

    property string loadState: "idle"
    property var info: null
    property bool confirming: false
    property bool confirmingDevelopment: false
    property bool detailsExpanded: false
    property string channelError: ""
    property var checkResult: null
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
    readonly property bool stale: loaded && runningId !== "" && selectedId !== "" && selectedId !== runningId
    readonly property string runningLabel: runningId === "legacy" ? Tr.tr("Legacy install")
        : UpdatesLogic.formatVersion((!stale && updateStatus.displayVersion) || runningId)
    readonly property bool channelBlocked: smoke || !available || !loaded || busy || rollbackUnconfirmed || rollbackComplete
    readonly property var primary: UpdatesLogic.primaryState({
        operationState: UpdateManager.operationState, operationKind: UpdateManager.operationKind,
        step: UpdateManager.step, checking: checkProc.running, result: checkResult,
        available: checkResult?.channel === updateStatus.channel ? checkResult.available : null,
        configured: loaded ? updateStatus.updatesConfigured : undefined,
        notice: notice, blocked: channelBlocked || stale
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
        if (channelError) return channelError;
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
        if (channelBlocked || stale) return;
        checkResult = null;
        checkProc.command = powershellCommand(["-Command", "CheckUpdate"]);
        checkProc.running = true;
    }
    function selectChannel(channel: string): void {
        if (channelBlocked) return;
        confirmingDevelopment = false;
        if (channel === updateStatus.channel) return;
        if (channel === "development") confirmingDevelopment = true;
        else setChannel(channel);
    }
    function setChannel(channel: string): void {
        if (channelBlocked) return;
        checkResult = null;
        confirmingDevelopment = false;
        channelError = "";
        const args = ["-Command", "SetChannel", "-Channel", channel];
        if (channel === "development") args.push("-AcceptDevelopment");
        channelProc.command = powershellCommand(args);
        channelProc.running = true;
    }
    function requestUpdate(): void {
        if (channelBlocked || stale || !checkResult?.available || checkResult.channel !== updateStatus.channel) return;
        UpdateManager.request(powershellCommand(["-Command", "Update", "-ExpectedCurrent", selectedId,
            "-ExpectedBuild", checkResult.available.buildVersion, "-Channel", checkResult.channel]), "update");
    }
    function activatePrimary(): void {
        if (primary.disabled) return;
        if (primary.action === "update") requestUpdate();
        else check();
    }
    function powershellCommand(extra: var): var {
        return [
            `${systemRoot}\\System32\\WindowsPowerShell\\v1.0\\powershell.exe`,
            "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden",
            "-File", `${installRoot}\\Manage-Caelestia.ps1`, "-Prefix", installRoot, ...extra
        ];
    }

    title: Tr.tr("Updates")
    Component.onCompleted: refresh()
    onCanRollbackChanged: { if (!canRollback) confirming = false; }
    onChannelBlockedChanged: { if (channelBlocked) confirmingDevelopment = false; }

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
            {state: "bad-metadata", channel: root.updateStatus.channel, available: null}
    }
    property Process channelProcess: Process {
        id: channelProc
        onExited: code => {
            if (code === 0) root.refresh();
            else root.channelError = Tr.tr("Channel could not be changed. Try again.");
        }
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
                    text: Tr.tr(root.primary.status)
                    font: Tokens.font.body.medium
                    color: root.rollbackFailed || root.loadState === "error" || root.channelError
                        ? Colours.palette.m3error : Colours.palette.m3onSurfaceVariant
                    wrapMode: Text.WordWrap
                    Accessible.role: Accessible.StaticText
                    Accessible.name: text
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
                    visible: !!root.checkResult?.available && !root.rollbackSubmitted
                    text: Tr.tr("Downloads, verifies, installs and restarts. Your settings are kept.")
                    font: Tokens.font.label.small
                    color: Colours.palette.m3onSurfaceVariant
                    wrapMode: Text.WordWrap
                }
            }
        }

        ConnectedRect {
            Layout.fillWidth: true
            Layout.topMargin: Tokens.spacing.medium
            first: true
            last: !root.confirmingDevelopment
            implicitHeight: channelLayout.implicitHeight + Tokens.padding.medium * 2
            ColumnLayout {
                id: channelLayout
                anchors.fill: parent
                anchors.margins: Tokens.padding.medium
                spacing: Tokens.spacing.small
                StyledText {
                    text: Tr.tr("Update channel")
                    font: Tokens.font.body.small
                }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Tokens.spacing.extraSmall
                    Repeater {
                        model: [
                            {channel: "stable", label: Tr.tr("Stable")},
                            {channel: "preview", label: Tr.tr("Preview")},
                            {channel: "development", label: Tr.tr("Development")}
                        ]
                        delegate: ActionButton {
                            required property var modelData
                            objectName: `channel-${modelData.channel}`
                            Layout.fillWidth: true
                            horizontalPadding: Tokens.padding.small
                            type: TextButton.Tonal
                            text: modelData.label
                            checked: root.updateStatus.channel === modelData.channel
                            disabled: root.channelBlocked
                            border.width: checked ? 1 : 0
                            border.color: Colours.palette.m3outline
                            Accessible.role: Accessible.RadioButton
                            Accessible.name: Tr.tr("Update channel: %1").arg(modelData.label)
                            Accessible.checked: checked
                            onClicked: root.selectChannel(modelData.channel)
                        }
                    }
                }
            }
        }
        ConnectedRect {
            Layout.fillWidth: true
            visible: root.confirmingDevelopment
            last: true
            implicitHeight: warning.implicitHeight + Tokens.padding.medium * 2
            ColumnLayout {
                id: warning
                anchors.fill: parent
                anchors.margins: Tokens.padding.medium
                StyledText {
                    Layout.fillWidth: true
                    text: Tr.tr("Development builds follow verified main. They can break. Switch to Development?")
                    wrapMode: Text.WordWrap
                    font: Tokens.font.body.small
                }
                RowLayout {
                    ActionButton {
                        objectName: "confirmDevelopment"
                        text: Tr.tr("Use Development")
                        disabled: root.channelBlocked
                        onClicked: root.setChannel("development")
                    }
                    ActionButton {
                        text: Tr.tr("Cancel")
                        type: TextButton.Text
                        onClicked: root.confirmingDevelopment = false
                    }
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
            InfoRow { visible: !!root.checkResult?.available; label: Tr.tr("Available artifact"); value: root.checkResult?.available?.buildVersion ?? "" }
            RowButton {
                icon: "refresh"
                text: Tr.tr("Refresh")
                disabled: !root.available || root.busy
                onClicked: root.refresh()
            }
            RowButton {
                visible: !!root.checkResult?.available
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
}
