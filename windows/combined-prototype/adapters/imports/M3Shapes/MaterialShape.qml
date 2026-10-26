import QtQuick
// Decorative native M3Shapes plugin is absent from the supplied build.
// Preserve dashboard sizing/contents and the original workspace type's enum
// and animation contract. Workspaces use Text, so their shapes stay unrendered.
Rectangle {
    enum Shape { Circle, Cookie4Sided, Cookie6Sided, Cookie7Sided, Cookie9Sided, Cookie12Sided, Sunny, VerySunny, SoftBurst, Pentagon, Gem, Arch, Arrow, Pill, Triangle, Fan, Oval, ClamShell, Diamond, Slanted, Clover4Leaf, Ghostish, Square }
    property int shape
    property real implicitSize: 48
    property int animationDuration: 0
    property var animationEasing: Easing.Linear
    implicitWidth: implicitSize
    implicitHeight: implicitSize
    radius: Math.min(width, height) / 2
    function pathBounds(): rect { return Qt.rect(0, 0, width, height); }
    function distanceAtAngle(angle): real { return width / 2; }
}
