pragma Singleton

import QtQuick

// Confirmed power-request state, written by the idle-inhibit daemon. The
// utilities card reads it so a failed acquire or release cannot be reported
// as the state the user asked for.
QtObject {
    property bool held: false
    property string error: ""
}
