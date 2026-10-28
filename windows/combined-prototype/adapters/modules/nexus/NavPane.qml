import "navpane"
import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import Caelestia.I18n
import qs.components
import qs.components.controls
import qs.services
import qs.modules.nexus

ColumnLayout {
    id: root

    required property NexusState nState
    objectName: "nexusNavPane"

    spacing: Tokens.spacing.large

    SearchBar {
        id: searchField
        objectName: "nexusSearch"

        Layout.fillWidth: true

        placeholderText: Tr.tr("Search settings")
        font: Tokens.font.body.large

        bg.color: Colours.tPalette.m3surfaceContainerLowest
        bg.border.color: Colours.palette.m3outlineVariant
        searchIcon.fontStyle: Tokens.font.icon.medium
        searchIcon.anchors.leftMargin: Tokens.padding.largeIncreased
        clearIcon.font: Tokens.font.icon.medium
        clearIcon.padding: Tokens.padding.extraSmall
        onAccepted: locations.openFirstMatch()

        Behavior on bg.border.color {
            CAnim {}
        }

        Binding {
            target: root.nState
            property: "searchOpen"
            value: searchField.text.length > 0
        }
    }

    NavLocations {
        id: locations
        Layout.fillWidth: true
        Layout.fillHeight: true
        Layout.topMargin: -topMargin
        Layout.bottomMargin: -bottomMargin
        nState: root.nState
        query: searchField.text
    }
}
