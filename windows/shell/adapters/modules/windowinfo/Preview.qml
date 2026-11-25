pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import Caelestia.Config
import Caelestia.I18n
import qs.components
import qs.services

Item {
    id: root

    required property var screen
    required property var client

    function ipcNumber(name, index, fallback): real {
        const values = root.client?.lastIpcObject?.[name];
        if (!Array.isArray(values) || values.length <= index || typeof values[index] !== "number")
            return fallback;
        return values[index];
    }

    readonly property real aspectRatio: {
        const width = ipcNumber("size", 0, 0);
        const height = ipcNumber("size", 1, 0);
        if (width > 0 && height > 0)
            return width / height;
        const screenWidth = root.screen?.width ?? 16;
        const screenHeight = root.screen?.height ?? 9;
        return screenHeight > 0 ? screenWidth / screenHeight : 16 / 9;
    }

    Layout.preferredWidth: preview.implicitWidth + Tokens.padding.extraLargeIncreased
    Layout.fillHeight: true

    ClipRect {
        id: preview

        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        anchors.bottom: label.top
        anchors.topMargin: Tokens.padding.large
        anchors.bottomMargin: Tokens.spacing.medium

        implicitWidth: view.implicitWidth

        color: Colours.tPalette.m3surfaceContainer
        radius: Tokens.rounding.medium

        Loader {
            asynchronous: true
            anchors.centerIn: parent
            active: !root.client

            sourceComponent: ColumnLayout {
                spacing: 0

                MaterialIcon {
                    Layout.alignment: Qt.AlignHCenter
                    text: "web_asset_off"
                    color: Colours.palette.m3outline
                    fontStyle: Tokens.font.icon.builders.extraLarge.scale(3).build()
                }

                StyledText {
                    Layout.alignment: Qt.AlignHCenter
                    text: Tr.tr("No active client")
                    color: Colours.palette.m3outline
                    font: Tokens.font.body.builders.large.size(28).weight(Font.Medium).build()
                }

                StyledText {
                    Layout.alignment: Qt.AlignHCenter
                    text: Tr.tr("Try switching to a window")
                    color: Colours.palette.m3outline
                    font: Tokens.font.body.large
                }
            }
        }

        ScreencopyView {
            id: view

            anchors.centerIn: parent

            captureSource: root.client?.wayland ?? null
            live: true

            constraintSize.width: root.client ? parent.height * root.aspectRatio : parent.height
            constraintSize.height: parent.height
        }
    }

    StyledText {
        id: label

        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Tokens.padding.large

        animate: true
        text: {
            const client = root.client;
            if (!client)
                return Tr.tr("No active client");

            const mon = client.monitor;
            // TRANSLATORS: %1 = window title, %2 = monitor name, %3/%4 = x/y position in pixels
            return Tr.tr("%1 on monitor %2 at %3, %4")
                .arg(client.title ?? Tr.tr("Untitled window"))
                .arg(mon?.name ?? Tr.tr("unknown"))
                .arg(root.ipcNumber("at", 0, -1))
                .arg(root.ipcNumber("at", 1, -1));
        }
    }
}
