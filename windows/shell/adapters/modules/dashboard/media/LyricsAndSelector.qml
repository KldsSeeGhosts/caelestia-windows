import QtQuick
import QtQuick.Layouts
import Quickshell.Widgets
import Caelestia.Config
import qs.components
import qs.components.controls
import qs.services
ColumnLayout {
    StyledText { text: "Media sessions"; font: Tokens.font.title.medium }
    Repeater {
        model: Players.list
        RowLayout {
            id: playerRow

            required property var modelData

            spacing: Tokens.spacing.small

            // Windows: the backend resolves each session's desktopEntry to a
            // lowercased AUMID or an executable path. Show the app icon it
            // names, with a glyph when the provider cannot load one.
            PlayerIconSource {
                id: playerIcon

                player: playerRow.modelData
            }

            Item {
                implicitWidth: 20
                implicitHeight: 20

                IconImage {
                    id: playerIconImage

                    anchors.fill: parent
                    asynchronous: true
                    source: playerIcon.source
                }

                MaterialIcon {
                    anchors.centerIn: parent
                    text: "music_note"
                    color: Colours.palette.m3onSurfaceVariant
                    visible: playerIconImage.status === Image.Error || playerIconImage.status === Image.Null
                }
            }

            TextButton {
                Layout.fillWidth: true
                text: playerRow.modelData.identity || playerRow.modelData.trackTitle || "Player"
                onClicked: Players.manualActive = playerRow.modelData
            }
        }
    }
    StyledText { text: "Lyrics unavailable"; color: Colours.palette.m3outline }
}
