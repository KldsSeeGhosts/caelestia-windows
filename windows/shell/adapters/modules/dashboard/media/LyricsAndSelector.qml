import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import qs.components
import qs.components.controls
import qs.services
ColumnLayout {
    StyledText { text: "Media sessions"; font: Tokens.font.title.medium }
    Repeater {
        model: Players.list
        TextButton {
            required property var modelData
            text: modelData.identity || modelData.trackTitle || "Player"
            onClicked: Players.manualActive = modelData
        }
    }
    StyledText { text: "Lyrics unavailable"; color: Colours.palette.m3outline }
}
