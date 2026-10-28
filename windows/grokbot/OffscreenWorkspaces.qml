import QtQuick
import Quickshell

// The offscreen platform has no native monitor workspace. This stub isolates
// that unrelated backend dependency while the real Bar and popout are tested.
Item {
    required property ShellScreen screen
    required property bool fullscreen
    implicitWidth: 32
    implicitHeight: 32
}
