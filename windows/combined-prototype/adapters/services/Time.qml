pragma Singleton

import QtQuick
import Quickshell
import Caelestia.I18n

// Windows-only teardown guard: two-monitor background consumers can outlive
// the clock and locale objects during hard reload or IPC shutdown.
Singleton {
    property alias enabled: clock.enabled
    readonly property date date: (clock?.date ?? new Date(0))
    readonly property int hours: (clock?.hours ?? 0)
    readonly property int minutes: (clock?.minutes ?? 0)
    readonly property int seconds: (clock?.seconds ?? 0)

    readonly property string timeStr: format((Units?.twelveHourClock ?? false) ? "hh:mm:A" : "hh:mm")
    readonly property list<string> timeComponents: timeStr.split(":")
    readonly property string hourStr: timeComponents[0] ?? ""
    readonly property string minuteStr: timeComponents[1] ?? ""
    readonly property string amPmStr: timeComponents[2] ?? ""

    function format(fmt: string): string {
        return Tr.formatDateTime((clock?.date ?? new Date(0)), fmt);
    }

    SystemClock {
        id: clock

        precision: SystemClock.Seconds
    }
}
