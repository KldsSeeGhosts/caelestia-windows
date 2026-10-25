import QtQuick

// Local compatibility module for the external `M3Shapes` QML dependency
// (README: qt6-m3shapes-git, github.com/soramanew/m3shapes), which is not part
// of the portable Caelestia build or the pinned dependency set. The original
// modules/bar/components/workspaces/Workspace.qml imports it for the shape
// workspace indicator and references its enum names directly.
//
// This adapter exists only so the ORIGINAL Workspace.qml compiles unmodified.
// It preserves the enum names the original component lists and the properties
// its indicator uses (shape, implicitSize, color, scale, animationEasing,
// animationDuration). It is a plain rounded Rectangle, not the upstream
// M3Shapes morphing path; the hypr prototype selects the original Text display
// type, so this component is not rendered in recorded runs. Do not treat it as
// an M3Shapes replacement for the full shell.
Rectangle {
    id: root

    enum ShapeKind {
        Slanted,
        Oval,
        Pill,
        Triangle,
        Arrow,
        Diamond,
        Pentagon,
        Gem,
        VerySunny,
        Sunny,
        Cookie4Sided,
        Cookie6Sided,
        Cookie7Sided,
        Cookie9Sided,
        Cookie12Sided,
        Clover4Leaf,
        SoftBurst,
        Ghostish,
        Square,
        Circle
    }

    property int shape: MaterialShape.Circle
    property real implicitSize: 24
    property int animationDuration: 0
    property var animationEasing: Easing.Linear

    implicitWidth: implicitSize
    implicitHeight: implicitSize
    radius: shape === MaterialShape.Square ? Math.max(2, width / 6) : width / 2

    Behavior on radius {
        NumberAnimation {
            duration: root.animationDuration
            easing.type: Easing.InOutQuad
        }
    }
}
