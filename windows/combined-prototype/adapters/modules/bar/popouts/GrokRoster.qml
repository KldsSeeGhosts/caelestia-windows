pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Caelestia.Config
import qs.components
import qs.components.controls
import qs.services
import "../components/grokbot"

Item {
    id: root

    required property PopoutState popouts

    implicitWidth: 360
    implicitHeight: layout.implicitHeight + Tokens.padding.medium * 2

    ColumnLayout {
        id: layout

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Tokens.spacing.medium

        // Header
        RowLayout {
            Layout.fillWidth: true
            spacing: Tokens.spacing.small

            Avatar {
                implicitWidth: 28
                implicitHeight: 28
                shape: "squircle"
                fill: Colours.palette.m3primary
                cutoutEyes: true
                face: "neutral"
                animate: false
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0

                StyledText {
                    text: "Grok Bot"
                    font: Tokens.font.body.builders.medium.weight(Font.Bold).build()
                    color: Colours.palette.m3onSurface
                }

                StyledText {
                    text: GrokBot.counts.awaiting > 0
                        ? qsTr("%1 bot(s) waiting for you").arg(GrokBot.counts.awaiting)
                        : (GrokBot.counts.working > 0
                            ? qsTr("%1 bot(s) working").arg(GrokBot.counts.working)
                            : qsTr("%1 bots available").arg(GrokBot.counts.bots))
                    font: Tokens.font.body.builders.small.scale(0.85).build()
                    color: GrokBot.counts.awaiting > 0 ? Colours.palette.m3error : Colours.palette.m3onSurfaceVariant
                }
            }

        }

        // Divider
        StyledRect {
            Layout.fillWidth: true
            implicitHeight: 1
            color: Colours.palette.m3outlineVariant
        }

        // Bots list
        Repeater {
            model: GrokBot.sortedBots

            Item {
                id: botRow

                required property var modelData

                Layout.fillWidth: true
                implicitHeight: rowContent.implicitHeight + Tokens.padding.small * 2

                RowLayout {
                    id: rowContent

                    anchors.fill: parent
                    anchors.margins: Tokens.padding.small
                    spacing: Tokens.spacing.medium

                    Avatar {
                        Layout.alignment: Qt.AlignTop
                        implicitWidth: 36
                        implicitHeight: 36
                        shape: botRow.modelData.shape || "squircle"
                        fill: GrokBot.colorFor(botRow.modelData, Colours.palette.m3primary)
                        face: GrokBot.faceFor(botRow.modelData)
                        animate: true
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 2

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Tokens.spacing.extraSmall

                            StyledText {
                                text: botRow.modelData.name || "Bot"
                                textFormat: Text.PlainText
                                // Windows: Qt exposes this weight as DemiBold.
                                font: Tokens.font.body.builders.small.weight(Font.DemiBold).build()
                                color: Colours.palette.m3onSurface
                                elide: Text.ElideRight
                                Layout.fillWidth: true
                            }

                            StyledText {
                                text: GrokBot.fmtAgo(botRow.modelData.last_activity_ts)
                                font: Tokens.font.body.builders.small.scale(0.8).build()
                                color: Colours.palette.m3outline
                            }

                            // Unread count badge
                            StyledRect {
                                visible: (botRow.modelData.unread || 0) > 0
                                implicitWidth: Math.max(16, unreadText.implicitWidth + 8)
                                implicitHeight: 16
                                radius: 8
                                color: Colours.palette.m3tertiary

                                StyledText {
                                    id: unreadText

                                    anchors.centerIn: parent
                                    text: String(botRow.modelData.unread || 0)
                                    font: Tokens.font.body.builders.small.scale(0.75).weight(Font.Bold).build()
                                    color: Colours.palette.m3onTertiary
                                }
                            }

                            // Awaiting badge
                            StyledRect {
                                visible: Boolean(botRow.modelData.awaiting)
                                implicitWidth: 10
                                implicitHeight: 10
                                radius: 5
                                color: Colours.palette.m3error
                            }
                        }

                        StyledText {
                            text: botRow.modelData.title || botRow.modelData.description || ""
                            textFormat: Text.PlainText
                            font: Tokens.font.body.builders.small.scale(0.85).build()
                            color: Colours.palette.m3onSurfaceVariant
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                            visible: text.length > 0
                        }

                        StyledText {
                            text: botRow.modelData.working
                                ? qsTr("Thinking…")
                                : (botRow.modelData.last_text || "")
                            textFormat: Text.PlainText
                            font: Tokens.font.body.builders.small.scale(0.85).weight(Font.Light).build()
                            color: botRow.modelData.working ? Colours.palette.m3primary : Colours.palette.m3outline
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                            maximumLineCount: 1
                            visible: text.length > 0
                        }
                    }
                }
            }
        }

        // Empty state if no bots found
        StyledText {
            Layout.fillWidth: true
            Layout.margins: Tokens.padding.medium
            visible: GrokBot.sortedBots.length === 0
            horizontalAlignment: Text.AlignHCenter
            text: GrokBot.status === "offline" ? qsTr("Grok Bot data unavailable") : qsTr("No Grok bots found")
            font: Tokens.font.body.builders.small.build()
            color: Colours.palette.m3outline
        }
    }
}
