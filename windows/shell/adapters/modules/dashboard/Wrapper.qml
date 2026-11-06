pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Caelestia
import Caelestia.Config
import Caelestia.I18n
import qs.components
import qs.components.filedialog
import qs.utils

Item {
    id: root

    required property ScreenState screenState
    // Windows has no supported way to change the account picture, so the picked
    // image is copied into the shell's own state folder and shown in the
    // dashboard only. The copy happens here, not in dash/User.qml: the native
    // dialog takes focus and the dashboard can close (destroying User) before
    // the dialog is accepted, as upstream's own handler also lives here.
    readonly property FileDialog facePicker: FileDialog {
        title: Tr.tr("Select a profile picture")
        nameFilters: ["Images (*.png *.jpg *.jpeg *.bmp *.webp)"]
        onAccepted: {
            const target = "file:///" + Quickshell.stateDir.replace(/\\/g, "/") + "/profile-picture";
            if (CUtils.copyFile(selectedFile, Qt.resolvedUrl(target))) {
                selected(String(selectedFile));
                Toaster.toast("Profile image", "Profile image changed. This does not change your Windows account picture.", "person");
            } else {
                Toaster.toast("Profile image", "Could not use that image as the profile image.", "person");
            }
        }
    }

    readonly property real contentScale: Math.min(1, Math.max(1, parent.width - Tokens.padding.large * 2) / Math.max(1, content.implicitWidth))
    readonly property real nonAnimHeight: ((content.item as Content)?.nonAnimHeight ?? 0) * contentScale
    readonly property bool shouldBeActive: screenState.dashboard && Config.dashboard.enabled
    property real offsetScale: shouldBeActive ? 0 : 1

    visible: offsetScale < 1
    anchors.topMargin: (-implicitHeight - 5) * offsetScale
    implicitHeight: content.implicitHeight * contentScale
    implicitWidth: (content.implicitWidth || 854) * contentScale // Hard coded fallback for first open
    opacity: 1 - offsetScale

    Behavior on offsetScale {
        Anim {}
    }

    Loader {
        id: content
        scale: root.contentScale
        transformOrigin: Item.Bottom

        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom

        active: root.shouldBeActive || root.visible

        sourceComponent: Content {
            objectName: "combinedDashboardContent"
            screenState: root.screenState
            facePicker: root.facePicker
        }
    }
}
