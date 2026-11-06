import QtQuick
import Quickshell
import Caelestia.Services
import qs.modules.utilities.cards as Cards

// The complete production card consumes a fake request holder. No native
// inhibition is created and no live profile is read.
ShellRoot {
    id: root

    property int assertions: 0

    property Cards.IdleInhibit card: Cards.IdleInhibit {
        visible: false
    }
    function check(condition, message): void {
        if (!condition)
            throw new Error(message);
        assertions++;
    }

    function run(): void {
        try {
            check(inhibitStatus(true, false, true, "", true) === "Preventing sleep mode", "a full hold was not preventing sleep");
            check(inhibitStatus(true, false, false, "", false) === "Normal power management", "a released request was not normal power management");
            check(inhibitStatus(true, false, true, "PowerSetRequest failed", true) === "Could not prevent sleep", "a display-only failed acquire claimed to prevent sleep");
            check(inhibitStatus(true, false, true, "PowerClearRequest failed", false) === "Could not prevent sleep", "a display-only failed clear was reported as normal");
            check(inhibitStatus(true, false, false, "PowerCreateRequest failed", true) === "Could not prevent sleep", "a failed acquire with nothing held was reported as normal");
            check(inhibitStatus(false, true, false, "", false) === "Suppressed during smoke", "smoke status changed");
            check(inhibitStatus(false, false, false, "", false) === "Live controls are off", "the live-off status changed");
            IdleHold.held = true;
            IdleHold.error = "";
            check(card.preventingSleep, "clean hold enables the active treatment");
            IdleHold.error = "PowerSetRequest failed";
            check(!card.preventingSleep, "display-only hold does not enable active treatment");
            IdleHold.held = false;
            IdleHold.error = "";
            check(!card.preventingSleep, "release clears active treatment");
            console.log("CAELESTIA_IDLE_STATUS_PASS " + assertions);
            Qt.quit();
        } catch (error) {
            console.log("CAELESTIA_IDLE_STATUS_FAIL " + error);
            Qt.exit(1);
        }
    }

    function inhibitStatus(permitted, smoke, held, error, requested): string {
        return card.inhibitStatus(permitted, smoke, held, error, requested);
    }
    Component.onCompleted: Qt.callLater(run)
}
