import Quickshell

PersistentProperties {
    required property ShellScreen modelData

    // Drawer visibilities
    property bool bar
    property bool osd
    property bool session
    property bool launcher
    // A queued launch must not dismiss a later opening of this drawer.
    property int launcherGeneration: 0
    onLauncherChanged: launcherGeneration++
    property bool dashboard
    // Windows: opt-in CPA quota drawer, ported from the custom Linux overlay.
    property bool quota
    property bool utilities
    property bool sidebar

    // Dashboard state
    property int dashboardTab
    property date dashboardDate: new Date()
}
