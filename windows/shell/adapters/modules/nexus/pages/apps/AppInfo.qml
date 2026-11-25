import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Widgets
import Quickshell.Windows as Native
import Caelestia
import Caelestia.Config
import Caelestia.I18n
import qs.components
import qs.services
import qs.utils
import qs.modules.nexus.common
import "../../../../windows/services/apps/ElevationLogic.js" as ElevationLogic

PageBase {
    id: root

    readonly property DesktopEntry app: nState.selectedApp
    readonly property bool favouriteByRegex: app && matchedByRegex(GlobalConfig.launcher.favouriteApps, app.id)
    readonly property bool hiddenByRegex: app && matchedByRegex(GlobalConfig.launcher.hiddenApps, app.id)

    function isRegexEntry(s: string): bool {
        return /^\^.*\$$/.test(s);
    }

    function matchedByRegex(filterList: list<string>, id: string): bool {
        // Windows: a user pattern that does not compile matches nothing; the
        // error text carries the pattern, so it is not logged.
        return filterList.some(f => {
            if (!isRegexEntry(f))
                return false;
            try {
                return new RegExp(f).test(id);
            } catch (error) {
                return false;
            }
        });
    }

    readonly property var actionInfo: {
        if (!root.app?.id || typeof Native.AppActions?.info !== "function")
            return ({});
        try {
            return Native.AppActions.info(root.app.id) ?? ({});
        } catch (error) {
            return ({});
        }
    }

    function isTerminalEntry(entry): bool {
        if (!entry)
            return false;
        const command = Array.isArray(entry.command) ? entry.command.join(" ") : "";
        const text = [entry.id ?? "", entry.name ?? "", entry.execString ?? "", command]
            .join(" ").toLowerCase();
        return text.indexOf("windowsterminal") >= 0 || /(^|[\s\/\\])wt\.exe(\s|$)/.test(text);
    }

    readonly property bool inlineSudoAvailable: {
        if (!isTerminalEntry(root.app) || typeof Native.AppActions?.isInlineSudoEnabled !== "function")
            return false;
        try {
            return Native.AppActions.isInlineSudoEnabled() === true;
        } catch (error) {
            return false;
        }
    }
    readonly property bool hasNativeActions: actionInfo.canRunAsAdmin === true
        || actionInfo.canOpenLocation === true || actionInfo.packaged === true
        || actionInfo.canUninstall === true || inlineSudoAvailable
    property string pendingInlineSudoRequest: ""

    function reportElevation(result): void {
        ElevationLogic.report(result, {
            started: function() {
                Toaster.toast(Tr.tr("Elevation started"), Tr.tr("Windows started the application as administrator."), "admin_panel_settings", Toast.Info);
            },
            cancelled: function() {
                Toaster.toast(Tr.tr("Elevation cancelled"), Tr.tr("The application was not started as administrator."), "info", Toast.Info);
            },
            refused: function(message) {
                Toaster.toast(Tr.tr("Elevation unavailable"), message, "admin_panel_settings", Toast.Warning);
            }
        });
    }

    function runAsAdmin(): void {
        const result = ElevationLogic.runAsAdminDetailed(Native.AppActions, root.app?.id ?? "", root);
        root.reportElevation(result);
    }

    function runSimpleAction(name, failureText): void {
        const action = Native.AppActions ? Native.AppActions[name] : null;
        if (!root.app?.id || typeof action !== "function")
            return;
        let accepted = false;
        try {
            accepted = action.call(Native.AppActions, root.app.id) === true;
        } catch (error) {
            accepted = false;
        }
        if (!accepted)
            Toaster.toast(Tr.tr("App action unavailable"), failureText, "error", Toast.Warning);
    }

    function inlineSudoSpec(): var {
        return { verb: "open", target: "wt.exe", args: ["sudo", "--inline"] };
    }

    function launchInlineSudo(): void {
        if (!root.inlineSudoAvailable || typeof Native.AppActions?.launchShellAction !== "function")
            return;
        let result = null;
        try {
            result = Native.AppActions.launchShellAction(root.inlineSudoSpec(), root);
        } catch (error) {
            result = { status: "refused", error: String(error) };
        }
        const status = String(result?.status ?? "").toLowerCase();
        if (status === "queued" && result?.requestId !== undefined) {
            root.pendingInlineSudoRequest = String(result.requestId);
            return;
        }
        if (status === "started")
            Toaster.toast(Tr.tr("Windows Terminal"), Tr.tr("Windows Terminal was asked to start sudo in inline mode."), "terminal", Toast.Info);
        else
            Toaster.toast(Tr.tr("Windows Terminal"), result?.error || Tr.tr("Windows could not start sudo in inline mode."), "terminal", Toast.Warning);
    }

    readonly property Connections inlineSudoResult: Connections {
        target: Native.AppActions
        ignoreUnknownSignals: true
        function onShellActionFinished(requestId, status, error): void {
            if (!root.pendingInlineSudoRequest || String(requestId) !== root.pendingInlineSudoRequest)
                return;
            root.pendingInlineSudoRequest = "";
            if (String(status).toLowerCase() === "started")
                Toaster.toast(Tr.tr("Windows Terminal"), Tr.tr("Windows Terminal was asked to start sudo in inline mode."), "terminal", Toast.Info);
            else
                Toaster.toast(Tr.tr("Windows Terminal"), error || Tr.tr("Windows could not start sudo in inline mode."), "terminal", Toast.Warning);
        }
    }

    onAppChanged: {
        // Auto close when app lost
        if (!app)
            nState.closeSubPage();
    }

    title: Tr.tr("App info")
    isSubPage: true

    ColumnLayout {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        width: root.cappedWidth
        spacing: Tokens.spacing.extraSmall / 2

        // Header
        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: Tokens.padding.small
            Layout.bottomMargin: Tokens.spacing.large
            spacing: Tokens.spacing.large

            IconImage {
                asynchronous: true
                implicitSize: Math.round(Tokens.font.icon.large.pointSize * 3)
                source: Quickshell.iconPath(root.app?.icon, "image-missing")
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: Tokens.spacing.extraSmall / 2

                StyledText {
                    Layout.fillWidth: true
                    text: root.app?.name ?? ""
                    font: Tokens.font.title.medium
                    wrapMode: Text.WordWrap
                }

                StyledText {
                    Layout.fillWidth: true
                    visible: text
                    text: (root.app?.comment || root.app?.genericName) ?? ""
                    color: Colours.palette.m3outline
                    font: Tokens.font.body.small
                    wrapMode: Text.WordWrap
                }
            }
        }

        // Launcher
        SectionHeader {
            first: true
            text: Tr.tr("Launcher")
        }

        ToggleRow {
            first: true
            text: Tr.tr("Favourite")
            subtext: root.favouriteByRegex ? Tr.tr("Matched by a regex in favouriteApps — edit the config file to change") : Tr.tr("Pin to the top of the launcher")
            enabled: !root.favouriteByRegex
            checked: root.app && Strings.testRegexList(GlobalConfig.launcher.favouriteApps, root.app.id)
            onToggled: {
                const apps = GlobalConfig.launcher.favouriteApps;
                GlobalConfig.launcher.favouriteApps = checked ? [...apps, root.app.id] : apps.filter(a => a !== root.app.id);
            }
        }

        ToggleRow {
            last: true
            text: Tr.tr("Hidden")
            subtext: root.hiddenByRegex ? Tr.tr("Matched by a regex in hiddenApps — edit the config file to change") : Tr.tr("Hide from the launcher")
            enabled: !root.hiddenByRegex
            checked: root.app && Strings.testRegexList(GlobalConfig.launcher.hiddenApps, root.app.id)
            onToggled: {
                const apps = GlobalConfig.launcher.hiddenApps;
                GlobalConfig.launcher.hiddenApps = checked ? [...apps, root.app.id] : apps.filter(a => a !== root.app.id);
            }
        }

        // Actions
        SectionHeader {
            visible: root.hasNativeActions
            text: Tr.tr("Actions")
        }

        RowButton {
            objectName: "appInfoRunAsAdmin"
            first: true
            visible: root.actionInfo.canRunAsAdmin === true
            icon: "admin_panel_settings"
            text: Tr.tr("Run as administrator")
            subtext: Tr.tr("Start this app through Windows User Account Control")
            onClicked: root.runAsAdmin()
        }

        RowButton {
            objectName: "appInfoOpenFileLocation"
            visible: root.actionInfo.canOpenLocation === true
            icon: "folder_open"
            text: Tr.tr("Open file location")
            subtext: Tr.tr("Show the app shortcut or executable in Explorer")
            onClicked: root.runSimpleAction("openFileLocation", Tr.tr("Windows could not open the application location."))
        }

        RowButton {
            objectName: "appInfoOpenSettings"
            visible: root.actionInfo.packaged === true
            icon: "settings"
            text: Tr.tr("App settings")
            subtext: Tr.tr("Open the Windows settings page for this packaged app")
            onClicked: root.runSimpleAction("openAppSettings", Tr.tr("Windows could not open the application settings."))
        }

        RowButton {
            objectName: "appInfoInlineSudo"
            visible: root.inlineSudoAvailable
            icon: "terminal"
            text: Tr.tr("Admin tab (inline sudo)")
            subtext: Tr.tr("Inline mode shares the console with medium-integrity processes and is less secure than a separate elevated window")
            onClicked: root.launchInlineSudo()
        }

        RowButton {
            objectName: "appInfoUninstall"
            last: true
            visible: root.actionInfo.canUninstall === true
            icon: "delete"
            text: Tr.tr("Uninstall")
            subtext: Tr.tr("Open Windows app management for this app")
            onClicked: root.runSimpleAction("uninstall", Tr.tr("Windows could not open uninstall for the application."))
        }

        // Details
        SectionHeader {
            text: Tr.tr("Details")
        }

        WrapInfoRow {
            id: appId

            first: true
            label: Tr.tr("App ID")
            value: root.app?.id ?? ""
            labelComp.Layout.preferredWidth: Math.max(labelComp.implicitWidth, command.labelComp.implicitWidth)
        }

        WrapInfoRow {
            id: command

            last: true
            label: Tr.tr("Command")
            value: (root.app?.command ?? []).join(" ")
            labelComp.Layout.preferredWidth: Math.max(labelComp.implicitWidth, appId.labelComp.implicitWidth)
        }
    }

    component WrapInfoRow: ConnectedRect {
        id: row

        property alias label: label.text
        property alias value: value.text
        readonly property alias labelComp: label

        Layout.fillWidth: true
        implicitHeight: rowLayout.implicitHeight + rowLayout.anchors.margins * 2

        RowLayout {
            id: rowLayout

            anchors.fill: parent
            anchors.margins: Tokens.padding.medium
            anchors.leftMargin: Tokens.padding.largeIncreased
            anchors.rightMargin: Tokens.padding.largeIncreased
            spacing: Tokens.spacing.medium

            StyledText {
                id: label

                Layout.alignment: Qt.AlignTop
                font: Tokens.font.body.small
            }

            Item {
                Layout.fillWidth: true
            }

            StyledText {
                id: value

                Layout.fillWidth: true
                Layout.maximumWidth: implicitWidth + 1 // Whyyyyyyyyy
                color: Colours.palette.m3onSurfaceVariant
                font: Tokens.font.body.small
                wrapMode: Text.WrapAtWordBoundaryOrAnywhere
            }
        }
    }
}
