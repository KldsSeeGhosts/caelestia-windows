import QtQuick
import Quickshell
import Quickshell.Windows
import Caelestia
import Caelestia.I18n
import "modules/bar/popouts/kblayout"

// Offscreen fixture for the Windows KbLayoutModel adapter. The fake backend
// exercises the model surface (five layouts, active entry, list/current
// notifications, the switch request and the failure toast) without reading or
// changing the live
// desktop. The final check reads the real native singleton's read-only layout
// list so the backend binding is compiled and populated at runtime.
ShellRoot {
    id: root

    property int assertions: 0
    property int failures: 0
    property var switches: []

    function check(ok, message) {
        root.assertions++;
        if (!ok) {
            root.failures++;
            console.error("CAELESTIA_KBLAYOUT_FAIL " + message);
        }
    }

    function equals(actual, expected, message) {
        root.check(actual === expected, message + " (got " + actual + ", expected " + expected + ")");
    }

    function labelOf(layout) {
        const layoutName = String(layout.layoutName ?? "").trim();
        const code = String(layout.code ?? "").trim().toUpperCase();
        const name = String(layout.shortName ?? layout.name ?? "").trim();
        return Tr.trCtx("%1 - %2", "keyboard layout code and name").arg(layoutName || code).arg(name || code);
    }

    QtObject {
        id: fakeKeyboard

        property var layouts: [
            { id: "1", code: "en-US", name: "English (United States)", shortName: "English (US)", layoutName: "US" },
            { id: "2", code: "en-US", name: "English (United States)", shortName: "English (US)", layoutName: "United States-Dvorak" },
            { id: "3", code: "de-DE", name: "German (Germany)", shortName: "German (DE)", layoutName: "German" },
            { id: "4", code: "fr-FR", name: "French (France)", shortName: "French (FR)", layoutName: "French" },
            { id: "5", code: "ru-RU", name: "Russian (Russia)", shortName: "Russian (RU)", layoutName: "Russian" }
        ]
        property int currentLayoutIndex: 1
        property string currentLayoutName: "English (United States)"
        property string switchResult: "requested"

        signal currentLayoutChanged()

        function activateLayoutAt(index) {
            root.switches.push(index);
            return switchResult;
        }

        function replaceLayouts(value) {
            layouts = value;
        }

        function setCurrent(index) {
            currentLayoutIndex = index;
            currentLayoutChanged();
        }
    }

    KbLayoutModel {
        id: model

        keyboard: fakeKeyboard
    }

    Component.onCompleted: {
        // Construct the native singleton before the late check so its deferred
        // enumeration has run. This only reads layouts and locks.
        const native = Keyboard;
        if (!native)
            console.error("CAELESTIA_KBLAYOUT_FAIL native singleton unavailable");
    }

    Timer {
        interval: 0
        running: true

        onTriggered: {
            model.start();

            root.equals(model.visibleModel.count, 4, "the active layout is hidden");
            root.equals(model.visibleModel.get(0).layoutIndex, 0, "first entry keeps its original index");
            root.equals(model.visibleModel.get(1).layoutIndex, 2, "the active index is skipped");
            root.equals(model.activeIndex, 1, "active index follows the backend");
            root.equals(model.activeLabel, root.labelOf(fakeKeyboard.layouts[1]), "active label is the short layout name");

            const toastsBefore = Toaster.toasts.length;
            root.equals(model.switchTo(4), "requested", "the switch result is forwarded");
            root.equals(Toaster.toasts.length, toastsBefore, "a requested switch raises no toast");
            root.equals(root.switches.length, 1, "one switch request");
            root.equals(root.switches[0], 4, "the request carries the selected original index");
            root.equals(model.activeIndex, 1, "a switch request does not change the selection optimistically");

            fakeKeyboard.switchResult = "denied";
            root.equals(model.switchTo(2), "denied", "a denied result is forwarded");
            root.equals(root.switches.length, 2, "the denied request is still attempted");
            root.equals(Toaster.toasts.length, toastsBefore + 1, "a denied switch raises one toast");
            // Toaster keeps the newest toast first.
            const denied = Toaster.toasts[0];
            root.equals(denied.type, Toast.Warning, "the failure toast is a warning");
            root.equals(denied.icon, "keyboard", "the failure toast uses the keyboard icon");
            root.check(denied.message.length > 0, "the denied toast explains the failure");

            for (const result of ["no-target", "unsupported"]) {
                fakeKeyboard.switchResult = result;
                root.equals(model.switchTo(0), result, result + " is forwarded");
                const toast = Toaster.toasts[0];
                root.check(toast.message.length > 0 && toast.message !== denied.message,
                    result + " has its own message");
            }
            root.equals(Toaster.toasts.length, toastsBefore + 3, "each failure raises one toast");
            root.equals(model.activeIndex, 1, "a failed switch keeps the selection");
            fakeKeyboard.switchResult = "requested";

            fakeKeyboard.setCurrent(4);
            root.equals(model.activeIndex, 4, "current notification moves the active index");
            root.equals(model.activeLabel, root.labelOf(fakeKeyboard.layouts[4]), "current notification moves the label");
            root.equals(model.visibleModel.count, 4, "the new active layout is hidden");
            root.equals(model.visibleModel.get(3).layoutIndex, 3, "the previous active layout is visible again");

            fakeKeyboard.replaceLayouts([
                { id: "6", code: "en-GB", name: "English (United Kingdom)", shortName: "English (GB)", layoutName: "United Kingdom" },
                { id: "7", code: "pl-PL", name: "Polish (Poland)", shortName: "Polish (PL)", layoutName: "Polish" }
            ]);
            root.equals(model.activeIndex, 4, "an out-of-range active index is kept");
            root.equals(model.activeLabel, fakeKeyboard.currentLayoutName, "an unknown active layout falls back to its name");
            root.equals(model.visibleModel.count, 2, "an unknown active layout hides nothing");

            fakeKeyboard.setCurrent(0);
            root.equals(model.activeLabel, root.labelOf(fakeKeyboard.layouts[0]), "current notification after a rebuild");
            root.equals(model.visibleModel.count, 1, "the active layout is excluded after a rebuild");
            root.equals(model.visibleModel.get(0).layoutIndex, 1, "the other layout remains selectable");

            model.refresh();
            root.equals(model.visibleModel.count, 1, "refresh keeps the active layout filtered");
        }
    }

    Timer {
        interval: 500
        running: true

        onTriggered: {
            const layouts = Keyboard.layouts;
            root.check(layouts !== undefined && layouts !== null
                && typeof layouts.length === "number", "native layout list is readable");
            if (layouts.length === 0) {
                // A machine with no installed layouts is valid; do not make the
                // fixture depend on this PC's input configuration.
                console.log("CAELESTIA_KBLAYOUT_NATIVE_SKIP no installed layouts");
            } else {
                for (let i = 0; i < layouts.length; i++) {
                    const layout = layouts[i];
                    root.check(typeof layout.code === "string", "native layout " + i + " code is a string");
                    root.check(typeof layout.name === "string", "native layout " + i + " name is a string");
                    root.check(typeof layout.shortName === "string", "native layout " + i + " short name is a string");
                    root.check(typeof layout.layoutName === "string", "native layout " + i + " layout name is a string");
                }
            }
            root.check(Keyboard.currentLayoutIndex >= -1
                && Keyboard.currentLayoutIndex < layouts.length,
                "native current index is in range");

            if (root.failures === 0) {
                console.log("CAELESTIA_KBLAYOUT_PASS " + root.assertions);
                Qt.quit();
            } else {
                console.error("CAELESTIA_KBLAYOUT_FAIL " + root.failures + " of " + root.assertions);
                Qt.exit(1);
            }
        }
    }
}
