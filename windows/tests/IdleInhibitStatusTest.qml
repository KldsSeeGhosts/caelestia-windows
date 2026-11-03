import QtQuick

// Offscreen regression for the keep-awake card. Test-IdleInhibitStatus.ps1
// splices inhibitStatus() out of the utilities card. A display-only leftover
// is still held, but it must not be described as preventing sleep.
QtObject {
    id: root

    property int assertions: 0

    function trCtx(text, context): string {
        return text;
    }
    function check(condition, message): void {
        if (!condition)
            throw new Error(message);
        assertions++;
    }

    // IDLE_STATUS

    function run(): void {
        try {
            check(inhibitStatus(true, false, true, "", true) === "Preventing sleep mode", "a full hold was not preventing sleep");
            check(inhibitStatus(true, false, false, "", false) === "Normal power management", "a released request was not normal power management");
            check(inhibitStatus(true, false, true, "PowerSetRequest failed", true) === "Could not prevent sleep", "a display-only failed acquire claimed to prevent sleep");
            check(inhibitStatus(true, false, true, "PowerClearRequest failed", false) === "Could not prevent sleep", "a display-only failed clear was reported as normal");
            check(inhibitStatus(true, false, false, "PowerCreateRequest failed", true) === "Could not prevent sleep", "a failed acquire with nothing held was reported as normal");
            check(inhibitStatus(false, true, false, "", false) === "Suppressed during smoke", "smoke status changed");
            check(inhibitStatus(false, false, false, "", false) === "Live controls are off", "the live-off status changed");
            console.log("CAELESTIA_IDLE_STATUS_PASS " + assertions);
            Qt.quit();
        } catch (error) {
            console.log("CAELESTIA_IDLE_STATUS_FAIL " + error);
            Qt.exit(1);
        }
    }

    Component.onCompleted: run()
}
