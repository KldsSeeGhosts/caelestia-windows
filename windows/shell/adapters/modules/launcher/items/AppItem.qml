import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Widgets
import Quickshell.Windows as Native
import Caelestia
import Caelestia.Config
import Caelestia.I18n
import qs.components
import qs.services
import qs.utils
import qs.modules.launcher.services
import "../../../windows/services/apps/ElevationLogic.js" as ElevationLogic

// Windows launcher application row. Upstream keeps its Linux item; this adapter
// adds the native shell verbs that Windows exposes for an installed app.
Item {
    id: root

    required property DesktopEntry modelData
    required property ScreenState screenState

    implicitHeight: Tokens.sizes.launcher.itemHeight

    anchors.left: parent?.left
    anchors.right: parent?.right

    // Windows port: the painted name/comment are not exposed to a
    // screen reader, so give every result one named list row.
    Accessible.role: Accessible.ListItem
    Accessible.selectable: true
    Accessible.selected: root.ListView.isCurrentItem
    Accessible.name: {
        const name = root.modelData?.name ?? "";
        const detail = root.modelData?.comment || root.modelData?.genericName || "";
        return detail ? name + ", " + detail : name;
    }

    property var actionInfo: ({})

    function elevationOwner(): var {
        return root.ListView.view ?? root;
    }

    function readActionInfo(): var {
        if (!root.modelData?.id || typeof Native.AppActions?.info !== "function")
            return ({});
        try {
            return Native.AppActions.info(root.modelData.id) ?? ({});
        } catch (error) {
            return ({});
        }
    }

    function openContextMenu(position): void {
        actionInfo = readActionInfo();
        menuLoader.menuX = position?.x ?? 0;
        menuLoader.menuY = position?.y ?? 0;
        menuLoader.active = true;
    }

    function reportElevation(result): bool {
        const outcome = ElevationLogic.report(result, {
            started: function() {
                root.screenState.launcher = false;
            },
            cancelled: function() {
                Toaster.toast(Tr.tr("Elevation cancelled"), Tr.tr("The application was not started as administrator."), "info", Toast.Info);
            },
            refused: function(message) {
                Toaster.toast(Tr.tr("Elevation unavailable"), message, "admin_panel_settings", Toast.Warning);
            }
        });
        return outcome.status === "started";
    }

    // ShellExecuteExW must receive this item's HWND while the launcher is still
    // open and owns the foreground. Closing is strictly a started-result effect.
    function launchElevated(): bool {
        const result = ElevationLogic.runAsAdminDetailed(
            Native.AppActions, root.modelData?.id ?? "", root.elevationOwner());
        return root.reportElevation(result);
    }

    function runSimpleAction(name, failureText): void {
        const action = Native.AppActions ? Native.AppActions[name] : null;
        if (!root.modelData?.id || typeof action !== "function")
            return;
        let accepted = false;
        try {
            accepted = action.call(Native.AppActions, root.modelData.id) === true;
        } catch (error) {
            accepted = false;
        }
        if (accepted)
            root.screenState.launcher = false;
        else
            Toaster.toast(Tr.tr("App action unavailable"), failureText, "error", Toast.Warning);
    }

    StateLayer {
        radius: Tokens.rounding.large
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: event => {
            if (event.button === Qt.RightButton) {
                root.openContextMenu(event);
                return;
            }
            if (event.button !== Qt.LeftButton)
                return;
            if (typeof Apps.launchWithFeedback === "function")
                Apps.launchWithFeedback(root.modelData, root.screenState);
            else {
                Apps.launch(root.modelData);
                root.screenState.launcher = false;
            }
        }
    }

    Loader {
        id: menuLoader

        active: false
        property real menuX: 0
        property real menuY: 0
        onLoaded: item.popup(root, menuX, menuY)

        sourceComponent: Menu {
            objectName: "appItemContextMenu"
            popupType: Popup.Window
            onClosed: Qt.callLater(() => menuLoader.active = false)

            MenuItem {
                objectName: "appItemRunAsAdmin"
                text: Tr.tr("Run as administrator")
                visible: root.actionInfo.canRunAsAdmin === true
                enabled: visible
                onTriggered: root.launchElevated()
            }
            MenuItem {
                objectName: "appItemOpenFileLocation"
                text: Tr.tr("Open file location")
                visible: root.actionInfo.canOpenLocation === true
                enabled: visible
                onTriggered: root.runSimpleAction("openFileLocation", Tr.tr("Windows could not open the application location."))
            }
            MenuItem {
                objectName: "appItemOpenSettings"
                text: Tr.tr("App settings")
                visible: root.actionInfo.packaged === true
                enabled: visible
                onTriggered: root.runSimpleAction("openAppSettings", Tr.tr("Windows could not open the application settings."))
            }
            MenuSeparator {}
            MenuItem {
                objectName: "appItemUninstall"
                text: Tr.tr("Uninstall")
                visible: root.actionInfo.canUninstall === true
                enabled: visible
                onTriggered: root.runSimpleAction("uninstall", Tr.tr("Windows could not open uninstall for the application."))
            }
        }
    }

    Item {
        anchors.fill: parent
        anchors.leftMargin: Tokens.padding.medium
        anchors.rightMargin: Tokens.padding.medium
        anchors.margins: Tokens.padding.small

        IconImage {
            id: icon

            asynchronous: true
            source: Quickshell.iconPath(root.modelData?.icon, "image-missing")
            implicitSize: parent.height * 0.8

            anchors.verticalCenter: parent.verticalCenter
        }

        Item {
            anchors.left: icon.right
            anchors.leftMargin: Tokens.spacing.medium
            anchors.verticalCenter: icon.verticalCenter

            implicitWidth: parent.width - icon.width - favouriteIcon.width
            implicitHeight: name.implicitHeight + comment.implicitHeight

            StyledText {
                id: name

                text: root.modelData?.name ?? ""
                font: Tokens.font.body.medium
            }

            StyledText {
                id: comment

                text: (root.modelData?.comment || root.modelData?.genericName || root.modelData?.name) ?? ""
                font: Tokens.font.body.small
                color: Colours.palette.m3outline

                elide: Text.ElideRight
                width: root.width - icon.width - favouriteIcon.width - Tokens.rounding.extraLargeIncreased

                anchors.top: name.bottom
            }
        }

        Loader {
            id: favouriteIcon

            asynchronous: true
            anchors.verticalCenter: parent.verticalCenter
            anchors.right: parent.right
            active: root.modelData && Strings.testRegexList(GlobalConfig.launcher.favouriteApps, root.modelData.id)

            sourceComponent: MaterialIcon {
                text: "favorite"
                fill: 1
                color: Colours.palette.m3primary
            }
        }
    }
}
