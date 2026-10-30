import QtQuick
import Quickshell
import qs.components
import qs.modules.bar as Bar
import qs.modules.session as Session
import qs.modules.bar.popouts as BarPopouts

// Platform boundary derived from upstream modules/drawers/Panels.qml.
// Keep the original session and wrapper layout; other panels are unavailable.
Item {
    id: root

    required property ShellScreen screen
    required property ScreenState screenState
    required property Bar.BarWrapper bar
    required property real borderThickness

    readonly property alias osd: osd
    readonly property alias osdWrapper: osdWrapper
    readonly property alias notifications: notifications
    readonly property alias session: session
    readonly property alias sessionWrapper: sessionWrapper
    readonly property alias launcher: launcher
    readonly property alias dashboard: dashboard
    // Windows: the combined entry stages the quota drawer; other prototypes
    // keep an inert slot so the shared drawer files stay valid.
    readonly property alias quota: quota
    readonly property bool quotaEnabled: false
    readonly property bool quotaHoverBlocked: false
    readonly property alias popouts: popoutsWrapper.content
    readonly property alias popoutsWrapper: popoutsWrapper
    readonly property alias utilities: utilities
    readonly property alias toasts: toasts
    readonly property alias sidebar: sidebar

    anchors.fill: parent
    anchors.margins: borderThickness
    anchors.leftMargin: bar.implicitWidth

    Item {
        id: osdWrapper

        anchors.verticalCenter: parent.verticalCenter
        anchors.right: parent.right
        anchors.rightMargin: sessionWrapper.anchors.rightMargin + session.width * (1 - session.offsetScale)
        clip: sidebar.visible || session.visible

        implicitWidth: osd.implicitWidth * (1 - osd.offsetScale)
        implicitHeight: osd.implicitHeight

        UnavailablePanel {
            id: osd
            anchors.verticalCenter: parent.verticalCenter
            anchors.right: parent.right
        }
    }

    UnavailablePanel {
        id: notifications
        anchors.top: parent.top
        anchors.right: parent.right
    }

    Item {
        id: sessionWrapper

        anchors.verticalCenter: parent.verticalCenter
        anchors.right: parent.right
        anchors.rightMargin: sidebar.width * (1 - sidebar.offsetScale)
        clip: sidebar.visible

        implicitWidth: session.implicitWidth * (1 - session.offsetScale)
        implicitHeight: session.implicitHeight

        Session.Wrapper {
            id: session

            screenState: root.screenState
            sidebarVisible: sidebar.visible

            anchors.verticalCenter: parent.verticalCenter
            anchors.right: parent.right
        }
    }

    UnavailablePanel {
        id: launcher
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
    }

    UnavailablePanel {
        id: dashboard
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
    }

    // Inert quota slot for prototypes that do not stage windows/quota.
    UnavailablePanel {
        id: quota
        anchors.top: parent.top
        anchors.right: parent.right
    }

    BarPopouts.ClipWrapper {
        id: popoutsWrapper
        screen: root.screen
        borderThickness: root.borderThickness
    }

    UnavailablePanel {
        id: utilities
        anchors.bottom: parent.bottom
        anchors.right: parent.right
    }

    UnavailablePanel {
        id: toasts
    }

    UnavailablePanel {
        id: sidebar
        anchors.top: notifications.bottom
        anchors.right: parent.right
        anchors.topMargin: -notifications.anchors.topMargin
    }
}
