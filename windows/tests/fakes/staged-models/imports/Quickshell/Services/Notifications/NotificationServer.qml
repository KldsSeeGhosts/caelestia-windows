import QtQuick
import StagedFixture
QtObject {
    property bool keepOnReload: false
    property bool actionsSupported: false
    property bool bodyHyperlinksSupported: false
    property bool bodyImagesSupported: false
    property bool bodyMarkupSupported: false
    property bool imageSupported: false
    property bool persistenceSupported: false
    property bool mirrorSystemNotifications: false
    readonly property bool systemMirrorActive: mirrorSystemNotifications && systemNotificationAccess === 2
    readonly property int systemNotificationAccess: Driver.access
    readonly property string ownership: Driver.ownership
    property bool accessRequested: false
    signal notification(var notification)
    function claimSystemAccessObservation(): int { return Driver.claimObservation(); }
    function setSystemAccessObservation(enabled, token): void { Driver.observe(enabled, token); }
    function requestSystemNotificationAccess(): void { accessRequested = true; Driver.accessRequests++; }
    function refreshAccessStatus(): void { Driver.accessProbes++; }
    function activateMirrored(id): bool { Driver.forbiddenCalls++; return false; }
    function notifySend(summary, body, args): int { Driver.forbiddenCalls++; return 0; }
}
