import QtQuick
import QtQuick.Layouts
import Quickshell
import Caelestia.Config
import Caelestia.I18n
import Caelestia.State
import qs.components
import qs.components.controls
import qs.services

// Original upstream idle-inhibitor card. Windows keeps the layout, the
// RuntimeState contract and the "active since" chip; only the switch gate and
// the explanatory line are localized. The actual inhibition is held by
// daemons/IdleInhibit.qml, because Windows has no IdleInhibitor protocol.
StyledRect {
    id: root

    readonly property bool permitted: Quickshell.env("CAELESTIA_COMBINED_LIVE") === "1"
        && Quickshell.env("CAELESTIA_SHELL_SMOKE") !== "1"
    readonly property real nonAnimHeight: layout.implicitHeight + (RuntimeState.inhibitIdle ? activeChip.implicitHeight + activeChip.anchors.topMargin : 0) + Tokens.padding.extraLargeIncreased

    implicitHeight: nonAnimHeight

    radius: Tokens.rounding.large
    color: Colours.tPalette.m3surfaceContainer
    clip: true

    RowLayout {
        id: layout

        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: Tokens.padding.large
        spacing: Tokens.spacing.medium

        StyledRect {
            implicitWidth: implicitHeight
            implicitHeight: icon.implicitHeight + Tokens.padding.large

            radius: Tokens.rounding.full
            color: RuntimeState.inhibitIdle ? Colours.palette.m3secondary : Colours.palette.m3secondaryContainer

            MaterialIcon {
                id: icon

                anchors.centerIn: parent
                text: "coffee"
                color: RuntimeState.inhibitIdle ? Colours.palette.m3onSecondary : Colours.palette.m3onSecondaryContainer
                fontStyle: Tokens.font.icon.large
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 0

            StyledText {
                Layout.fillWidth: true
                text: Tr.trCtx("Keep awake", "idle inhibitor")
                font: Tokens.font.body.medium
                elide: Text.ElideRight
            }

            StyledText {
                Layout.fillWidth: true
                text: {
                    if (!root.permitted)
                        return Quickshell.env("CAELESTIA_SHELL_SMOKE") === "1" ? Tr.trCtx("Suppressed during smoke", "idle inhibitor") : Tr.trCtx("Live controls are off", "idle inhibitor");
                    if (RuntimeState.inhibitIdle)
                        return Tr.trCtx("Preventing sleep mode", "idle inhibitor");
                    return Tr.trCtx("Normal power management", "idle inhibitor");
                }
                color: Colours.palette.m3onSurfaceVariant
                font: Tokens.font.body.small
                elide: Text.ElideRight
            }
        }

        StyledSwitch {
            checked: RuntimeState.inhibitIdle
            disabled: !root.permitted
            onToggled: RuntimeState.inhibitIdle = checked
        }
    }

    Loader {
        id: activeChip

        asynchronous: true
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.topMargin: Tokens.spacing.large
        anchors.bottomMargin: RuntimeState.inhibitIdle ? Tokens.padding.large : -implicitHeight
        anchors.leftMargin: Tokens.padding.large

        opacity: RuntimeState.inhibitIdle ? 1 : 0
        scale: RuntimeState.inhibitIdle ? 1 : 0.5

        Component.onCompleted: active = Qt.binding(() => opacity > 0)

        sourceComponent: StyledRect {
            implicitWidth: activeText.implicitWidth + Tokens.padding.medium * 2
            implicitHeight: activeText.implicitHeight + Tokens.padding.small

            radius: Tokens.rounding.full
            color: Colours.palette.m3primary

            StyledText {
                id: activeText

                anchors.centerIn: parent
                // TRANSLATORS: %1 = a clock time, e.g. 14:30
                text: Tr.tr("Active since %1").arg(Tr.formatDateTime(new Date(RuntimeState.inhibitingIdleSince), Units.twelveHourClock ? "hh:mm a" : "hh:mm"))
                color: Colours.palette.m3onPrimary
                font: Tokens.font.body.builders.small.size(Math.round(Tokens.font.body.small.pointSize * 0.9)).build()
            }
        }

        Behavior on anchors.bottomMargin {
            Anim {}
        }

        Behavior on opacity {
            Anim {
                type: Anim.StandardSmall
            }
        }

        Behavior on scale {
            Anim {}
        }
    }

    Behavior on implicitHeight {
        Anim {}
    }
}
