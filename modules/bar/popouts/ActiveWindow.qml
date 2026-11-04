import QtQuick
import QtQuick.Layouts
import Quickshell.Wayland
import Quickshell.Widgets
import Caelestia.Config
import qs.components
import qs.services
import qs.utils

Item {
    id: root

    required property PopoutState popouts

    // Windows capture reports its dimensions only after the first frame, and
    // clears them when the source changes. Hosts can reserve a stable viewport
    // while retaining the upstream layout and animations everywhere else.
    property bool reservePreviewGeometry: false

    // Windows: the running-app strip previews the application it points at
    // through this property. Linux leaves the default and keeps the upstream
    // single-window view.
    property var toplevel: Hypr.activeToplevel

    implicitWidth: reservePreviewGeometry || toplevel ? child.implicitWidth : -Tokens.padding.extraLargeIncreased
    implicitHeight: child.implicitHeight

    Column {
        id: child

        anchors.centerIn: parent
        spacing: Tokens.spacing.medium

        RowLayout {
            id: detailsRow

            anchors.left: parent.left
            anchors.right: parent.right
            spacing: Tokens.spacing.medium

            IconImage {
                id: icon

                asynchronous: true
                Layout.alignment: Qt.AlignVCenter
                implicitSize: details.implicitHeight
                source: Icons.getAppIcon(root.toplevel?.lastIpcObject.class ?? "", "image-missing")
            }

            ColumnLayout {
                id: details

                spacing: 0
                Layout.fillWidth: true

                StyledText {
                    Layout.fillWidth: true
                    text: root.toplevel?.title ?? ""
                    font: Tokens.font.body.medium
                    elide: Text.ElideRight
                }

                StyledText {
                    Layout.fillWidth: true
                    text: root.toplevel?.lastIpcObject.class ?? ""
                    color: Colours.palette.m3onSurfaceVariant
                    elide: Text.ElideRight
                }
            }

            Item {
                implicitWidth: expandIcon.implicitHeight + Tokens.padding.small
                implicitHeight: expandIcon.implicitHeight + Tokens.padding.small

                Layout.alignment: Qt.AlignVCenter

                StateLayer {
                    radius: Tokens.rounding.large
                    onClicked: root.popouts.detachRequested("winfo")
                }

                MaterialIcon {
                    id: expandIcon

                    anchors.centerIn: parent
                    anchors.horizontalCenterOffset: font.pointSize * 0.05

                    text: "chevron_right"

                    fontStyle: Tokens.font.icon.large
                }
            }
        }

        ClippingWrapperRectangle {
            color: "transparent"
            radius: Tokens.rounding.medium

            Item {
                implicitWidth: root.reservePreviewGeometry ? Tokens.sizes.bar.windowPreviewSize : preview.implicitWidth
                implicitHeight: root.reservePreviewGeometry ? Tokens.sizes.bar.windowPreviewSize * 9 / 16 : preview.implicitHeight

                ScreencopyView {
                    id: preview

                    objectName: "activeWindowPreview"
                    anchors.centerIn: parent
                    captureSource: root.toplevel?.wayland ?? null
                    live: visible

                    constraintSize.width: Tokens.sizes.bar.windowPreviewSize
                    constraintSize.height: root.reservePreviewGeometry ? Tokens.sizes.bar.windowPreviewSize * 9 / 16 : Tokens.sizes.bar.windowPreviewSize
                }
            }
        }
    }
}
