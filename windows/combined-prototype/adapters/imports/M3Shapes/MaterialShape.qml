import QtQuick
// Decorative native M3Shapes plugin is absent from the supplied build.
// Preserve upstream sizing and contents with a neutral round surface.
Rectangle {
    enum Shape { Circle, Cookie4Sided, Cookie6Sided, Cookie7Sided, Cookie9Sided, Cookie12Sided, Sunny, VerySunny, SoftBurst, Pentagon, Gem, Arch, Arrow, Pill, Triangle, Fan, Oval, ClamShell, Diamond }
    property int shape
    property real implicitSize: 48
    implicitWidth: implicitSize
    implicitHeight: implicitSize
    radius: Math.min(width, height) / 2
    function pathBounds(): rect { return Qt.rect(0, 0, width, height); }
    function distanceAtAngle(angle): real { return width / 2; }
}
