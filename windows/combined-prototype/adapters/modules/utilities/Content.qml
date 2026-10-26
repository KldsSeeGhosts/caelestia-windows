import QtQuick
import Caelestia.Config
import qs.components
import qs.modules.bar.popouts as BarPopouts
import "cards"
Item {
    required property var props
    required property ScreenState screenState
    required property BarPopouts.Wrapper popouts
    required property matrix4x4 deformMatrix
    readonly property real nonAnimHeight: toggles.implicitHeight
    implicitHeight: nonAnimHeight
    Toggles {
        id: toggles
        width: parent.width
        screenState: parent.screenState
        popouts: parent.popouts
    }
}
