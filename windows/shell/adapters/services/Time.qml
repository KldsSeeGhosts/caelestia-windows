pragma Singleton

import QtQuick
import Quickshell
import Caelestia.I18n

// Windows-only teardown guard: two-monitor background consumers can outlive
// the clock and locale objects during hard reload or IPC shutdown.
Singleton {
    id: root

    property alias enabled: clock.enabled
    // Keep the last sample instead of binding through native objects whose
    // destruction invalidates the binding context, even with null guards.
    property date date: new Date(0)
    property int hours: 0
    property int minutes: 0
    property int seconds: 0
    property var locale: Qt.locale()

    property string timeStr: "00:00"
    readonly property list<string> timeComponents: timeStr.split(":")
    readonly property string hourStr: timeComponents[0] ?? ""
    readonly property string minuteStr: timeComponents[1] ?? ""
    readonly property string amPmStr: timeComponents[2] ?? ""

    function format(fmt: string): string {
        return root.date.toLocaleString(root.locale, fmt);
    }

    function sample(): void {
        if (!clock || !clock.date || !Tr || !Units)
            return;
        root.date = clock.date;
        root.hours = clock.hours;
        root.minutes = clock.minutes;
        root.seconds = clock.seconds;
        root.locale = Tr.locale;
        root.timeStr = Tr.formatDateTime(root.date, Units.twelveHourClock ? "hh:mm:A" : "hh:mm");
    }

    Component.onCompleted: sample()

    Connections {
        target: Tr
        function onLocaleChanged(): void { root.sample(); }
    }
    Connections {
        target: Units
        function onTwelveHourClockChanged(): void { root.sample(); }
    }

    SystemClock {
        id: clock

        precision: SystemClock.Seconds
        onDateChanged: root.sample()
    }
}
