import QtQuick

QtObject {
    id: root
    required property int screenCount
    required property var scopes
    readonly property bool ready: screenCount > 0 && scopes.length === screenCount
        && scopes.every(scope => scope && scope.window && scope.firstFrame && scope.window.backingWindowVisible
            && scope.window.width > 0 && scope.window.height > 0)
    // IPC keeps the strict first-frame predicate above. Only the takeover
    // marker can accept a panel intentionally lowered under confirmed
    // fullscreen, where the compositor need not deliver its first frame.
    readonly property bool takeoverReady: screenCount > 0 && scopes.length === screenCount
        && scopes.every(scope => scope && scope.window && scope.window.backingWindowVisible
            && scope.window.width > 0 && scope.window.height > 0
            && (scope.firstFrame || scope.window.takeoverOccluded === true))
    property bool reported: false
    signal takeoverReported()

    onTakeoverReadyChanged: {
        if (takeoverReady && !reported) {
            reported = true;
            // No paths, monitor names or state. The watchdog reads this through
            // its async stdout drain. Each QML root reports once, including a
            // soft reload, but never sends a transient not-ready transition.
            console.info("CAELESTIA_SHELL_READY");
            takeoverReported();
        }
    }
}
