import QtQuick

// In-process UI fixture. Native notifySend forwards to the session's existing
// shell owner, so it cannot exercise this isolated host without disturbing it.
// This uses the same record contract as a delivered notification and never
// sends, dismisses or requests access to a Windows notification.
QtObject {
    property int id: 1
    property string appName: "Caelestia Windows smoke"
    property string appIcon: ""
    property string summary: "Combined notification fixture"
    property string body: "In-process popup and history check"
    property string image: ""
    property var hints: ({})
    property int expireTimeout: 6000
    property int urgency: 1
    property bool resident: false
    property bool hasActionIcons: false
    property var actions: []
    signal closed(int reason)

    function dismiss(): void { closed(2); }
    function expire(): void { closed(1); }
}
