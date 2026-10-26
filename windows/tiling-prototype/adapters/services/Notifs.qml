pragma Singleton

import QtQuick

// Windows stand-in for services/Notifs.qml, staged at services/Notifs.qml
// only by the tiling prototype. The original toast surface asks one question
// of the notification service: whether a fullscreen window should suppress
// toasts (modules/utilities/toasts/Toasts.qml:16-24). There is no Windows
// notification observation in this slice, so the answer is a truthful
// constant false and no notification daemon, DBus or Quickshell service is
// constructed. Toast filtering then follows the utilities config alone.
QtObject {
    function hasFullscreen(): bool {
        return false;
    }
}
