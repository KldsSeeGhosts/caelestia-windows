import QtQuick
import QtQuick.Layouts
import "VramMeter.js" as Vram
import M3Shapes
import Caelestia.Config
import Caelestia.I18n
import qs.components
import qs.components.controls
import qs.services
import qs.utils

StyledRect {
    id: root

    required property string icon
    required property string label
    required property string subLabel
    required property color accent
    required property real usage
    required property real temperature
    // Windows: the GPU card passes the Gpu service here to add a dedicated
    // VRAM meter under the temperature. Left null, the card is unchanged.
    property var memorySource: null
    readonly property var vram: memorySource ? Vram.evaluate(memorySource.vramUsed, memorySource.vramTotal) : null

    color: Colours.tPalette.m3surfaceContainer
    radius: Tokens.rounding.extraLarge

    implicitWidth: Tokens.sizes.dashboard.perfHeroCardWidth
    implicitHeight: Math.max(tempProg.implicitHeight + detailsRow.implicitHeight + Tokens.spacing.large, usageShape.implicitHeight + usageLabel.implicitHeight) + Tokens.padding.large * 2

    CircularProgress {
        id: tempProg

        anchors.left: parent.left
        anchors.top: parent.top
        anchors.margins: Tokens.padding.large

        fgColour: root.accent

        spacing: Tokens.spacing.extraSmall
        strokeWidth: Tokens.padding.extraSmall
        implicitSize: Math.max(icon.implicitWidth, icon.implicitHeight) + Tokens.padding.medium * 2
        value: root.usage

        Behavior on clampedVal {
            Anim {}
        }

        MaterialIcon {
            id: icon

            anchors.centerIn: parent
            text: root.icon
            color: root.accent
            fontStyle: Tokens.font.icon.medium
        }
    }

    ColumnLayout {
        anchors.left: tempProg.right
        anchors.right: usageShape.left
        anchors.verticalCenter: tempProg.verticalCenter
        anchors.margins: Tokens.spacing.large
        spacing: Tokens.spacing.extraSmall

        StyledText {
            text: root.label
            font: Tokens.font.title.medium
            color: root.accent
        }

        StyledText {
            Layout.fillWidth: true
            text: root.subLabel
            font: Tokens.font.body.small
            color: Colours.palette.m3onSurfaceVariant
            elide: Text.ElideRight
        }
    }

    ColumnLayout {
        id: detailsRow

        anchors.left: parent.left
        anchors.bottom: parent.bottom
        anchors.margins: Tokens.padding.largeIncreased
        spacing: Tokens.spacing.extraSmall

        RowLayout {
            Layout.leftMargin: -Tokens.padding.extraSmall
            spacing: Tokens.spacing.extraSmall

            MaterialIcon {
                Layout.topMargin: Math.round(fontInfo.pointSize * 0.08)
                text: root.temperature > 90 ? "thermometer_alert" : "thermometer"
                color: root.temperature > 90 ? Colours.palette.m3error : root.accent
                fontStyle: Tokens.font.icon.medium
                fill: 1
            }

            StyledText {
                text: Number.isFinite(root.temperature) ? Units.formatSensorTemp(root.temperature) : Tr.tr("Unavailable")
                font: Tokens.font.body.builders.medium.build()
            }
        }

        StyledProgressBar {
            visible: Number.isFinite(root.temperature)
            value: Number.isFinite(root.temperature) ? root.temperature / 100 : 0
            implicitHeight: Tokens.padding.small
            fgColour: root.accent
            indeterminate: isNaN(root.usage) || isNaN(root.temperature)
        }

        // Same row and bar as the temperature, stacked below it so the card
        // keeps its width and the name and usage shape stay clear.
        RowLayout {
            Layout.topMargin: Tokens.spacing.small
            Layout.leftMargin: -Tokens.padding.extraSmall
            spacing: Tokens.spacing.extraSmall
            visible: root.vram !== null

            MaterialIcon {
                Layout.topMargin: Math.round(fontInfo.pointSize * 0.08)
                text: "memory_alt"
                color: root.accent
                fontStyle: Tokens.font.icon.medium
                fill: 1
            }

            StyledText {
                text: root.vram?.valid ? Units.formatKibUsage(root.vram.usedBytes / 1024, root.vram.totalBytes / 1024) : Tr.tr("Unavailable")
                font: Tokens.font.body.builders.medium.build()
            }
        }

        StyledProgressBar {
            visible: root.vram?.valid ?? false
            value: root.vram?.ratio ?? 0
            implicitHeight: Tokens.padding.small
            fgColour: root.accent
        }
    }

    MaterialShape {
        id: usageShape

        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: Tokens.padding.medium

        implicitSize: Tokens.sizes.dashboard.perfUsageShapeSize
        color: Colours.palette.m3secondaryContainer
        shape: {
            if (root.usage >= 0.8)
                return MaterialShape.SoftBurst;
            if (root.usage >= 0.4)
                return MaterialShape.Sunny;
            return MaterialShape.Cookie4Sided;
        }

        Behavior on color {
            CAnim {}
        }

        StyledText {
            id: usageLabel

            anchors.bottom: parent.top
            anchors.horizontalCenter: parent.horizontalCenter

            // TRANSLATORS: labels the CPU or GPU utilisation percentage shown below it
            text: Tr.trCtx("Usage", "resource usage")
            color: Colours.palette.m3onSurfaceVariant
            font: Tokens.font.body.small
        }

        StyledText {
            anchors.centerIn: parent
            text: isNaN(root.usage) ? "..." : Strings.percentOne(root.usage)
            color: root.accent
            font: Tokens.font.headline.builders.small.width(50).build()
        }
    }
}
