pragma Singleton

import QtQuick

// Windows localized adapter for the original utils/SysInfo.qml singleton.
// The original reads /etc/os-release, /proc and DMI files, none of which exist
// on Windows. The combined prototype's bar logo (modules/bar/components/
// OsIcon.qml) only consumes isDefaultLogo and osLogo, so this adapter keeps
// the default Caelestia vector logo and reports the host platform name.
// Everything else stays empty rather than guessing a Linux value.
QtObject {
    readonly property string osName: "Windows"
    readonly property string osPrettyName: "Windows"
    readonly property string osId: "windows"
    readonly property list<string> osIdLike: []
    readonly property string osLogo: ""
    readonly property bool isDefaultLogo: true

    readonly property string uptime: ""
    readonly property string uptimeShort: ""
    readonly property string user: ""
    readonly property string wm: ""
    readonly property string shell: ""
    readonly property string kernel: ""
    readonly property string hostname: ""
    readonly property string firmware: ""
    readonly property string boardVendor: ""
    readonly property string boardName: ""
    readonly property string device: ""
}
