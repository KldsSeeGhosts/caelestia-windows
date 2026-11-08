import QtQuick
import Quickshell
import Quickshell.Hyprland

// Pin smoke for #71. It confirms the two backend APIs the shell's capture
// design relies on are reachable from QML: PanelWindow.excludeFromCapture and
// Hyprland.windowStack() returning an array-like list. The panel stays hidden. windowStack() is a read-only
// window enumeration, and the fixture asserts only its type, never window
// titles or ids, so nothing from the host desktop reaches the logs.
ShellRoot {
    id: root

    property int assertions: 0

    function check(condition, message): void {
        if (!condition)
            throw new Error(message);
        assertions++;
    }

    PanelWindow {
        id: panel

        visible: false
        implicitWidth: 40
        implicitHeight: 40
    }

    PanelWindow {
        id: bound

        // A binding must also reach the property, as the shell will use it.
        property bool wanted: true

        excludeFromCapture: wanted
        visible: false
        implicitWidth: 40
        implicitHeight: 40
    }

    function run(): void {
        try {
            check(panel.excludeFromCapture === false, "excludeFromCapture must default to false");
            let changes = 0;
            panel.excludeFromCaptureChanged.connect(() => changes++);
            panel.excludeFromCapture = true;
            check(panel.excludeFromCapture === true, "excludeFromCapture did not store true");
            check(changes === 1, "excludeFromCaptureChanged must fire once for a change");
            panel.excludeFromCapture = true;
            check(changes === 1, "excludeFromCaptureChanged must not fire for an unchanged value");
            panel.excludeFromCapture = false;
            check(panel.excludeFromCapture === false, "excludeFromCapture did not store false");
            check(changes === 2, "excludeFromCaptureChanged must fire for the reverse change");

            check(bound.excludeFromCapture === true, "a bound excludeFromCapture did not apply");
            bound.wanted = false;
            check(bound.excludeFromCapture === false, "a bound excludeFromCapture did not follow its binding");

            check(typeof Hyprland.windowStack === "function", "Hyprland.windowStack is not callable");
            // Qt hands a QVariantList to QML as a sequence wrapper. On Qt 6.11
            // Array.isArray is false for it, so assert what consumers use: a
            // numeric length, the array methods, and a real array from Array.from.
            const stack = Hyprland.windowStack();
            check(typeof stack === "object" && stack !== null, "Hyprland.windowStack() must return an object");
            check(typeof stack.length === "number" && stack.length >= 0, "the window stack needs a numeric length");
            check(typeof stack.map === "function" && typeof stack.filter === "function"
                  && typeof stack.forEach === "function", "the window stack must offer the array methods");
            const copy = Array.from(stack);
            check(Array.isArray(copy) && copy.length === stack.length, "Array.from must copy the window stack");
            check(stack.map(entry => entry).length === stack.length, "map must visit every window");
            check(Array.from(Hyprland.windowStack()).length >= 0, "a second windowStack() call must also succeed");

            console.log("CAELESTIA_CAPTURE_BACKEND_API_PASS " + assertions);
            Qt.quit();
        } catch (error) {
            console.log("CAELESTIA_CAPTURE_BACKEND_API_FAIL " + error);
            Qt.exit(1);
        }
    }

    Component.onCompleted: Qt.callLater(run)
}
