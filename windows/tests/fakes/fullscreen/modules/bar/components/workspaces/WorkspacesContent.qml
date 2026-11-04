import QtQuick
import Quickshell

// Workspace rendering is not the fullscreen consumer under test. Keep the
// real ContentWindow and BarWrapper, without requiring native monitor objects
// in the upstream workspace indicator.
Item {
    required property ShellScreen screen
    required property bool fullscreen
}
