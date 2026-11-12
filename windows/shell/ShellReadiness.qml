import QtQuick

QtObject {
    id: root
    required property int screenCount
    required property var scopes
    readonly property bool ready: screenCount > 0 && scopes.length === screenCount
        && scopes.every(scope => scope && scope.window && scope.firstFrame && scope.window.backingWindowVisible
            && scope.window.width > 0 && scope.window.height > 0)
    property bool reported: false
    signal firstFramesReady()

    onReadyChanged: {
        if (ready && !reported) {
            reported = true;
            // No paths, monitor names or state. The watchdog reads this through
            // its async stdout drain. Each QML root reports once, including a
            // soft reload, but never sends a transient not-ready transition.
            console.info("CAELESTIA_SHELL_READY");
            firstFramesReady();
        }
    }
}
