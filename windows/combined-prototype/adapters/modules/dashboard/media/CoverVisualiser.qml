import QtQuick
import Caelestia.Config
import qs.components.widgets
Item {
    implicitWidth: Tokens.sizes.dashboard.mediaCoverArtSize
    CoverArt { anchors.centerIn: parent; implicitWidth: parent.width; implicitHeight: width }
}
