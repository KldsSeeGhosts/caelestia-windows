import QtQuick
import Quickshell.Io
import Caelestia

// Executes the production toaster IPC component in the real QJSEngine through
// the same target/function path a Quickshell IPC client uses.
QtObject {
    id: root

    property int assertions: 0

    readonly property ToasterIpc ipc: ToasterIpc {
        parityEnabled: true
    }

    function check(value, message): void {
        assertions++;
        if (!value)
            throw new Error(message);
    }

    function run(): void {
        try {
            check(IpcTargets.has("toaster"), "toaster IPC target did not register");
            check(IpcTargets.call("toaster", "toast", ["Title", "Body", "info", "success"]) === true,
                "toast extension did not dispatch");
            IpcTargets.call("toaster", "info", ["Info title", "Info body", "info"]);
            IpcTargets.call("toaster", "warn", ["Warn title", "Warn body", "warning"]);
            IpcTargets.call("toaster", "error", ["Error title", "Error body", "error"]);
            IpcTargets.call("toaster", "success", ["Success title", "Success body", "check"]);
            check(Toaster.calls.length === 5, "IPC calls did not reach Toaster");
            check(Toaster.calls[0].type === Toast.Success, "explicit kind was not mapped");
            check(Toaster.calls[1].type === Toast.Info, "info convenience method was not mapped");
            check(Toaster.calls[2].type === Toast.Warning, "warn convenience method was not mapped");
            check(Toaster.calls[3].type === Toast.Error, "error convenience method was not mapped");
            check(Toaster.calls[4].type === Toast.Success, "success convenience method was not mapped");
            check(IpcTargets.call("toaster", "toast", ["Unknown", "", "", "__proto__"]) === true
                && Toaster.calls[5].type === Toast.Info, "unknown kind did not safely fall back to info");
            ipc.parityEnabled = false;
            check(IpcTargets.call("toaster", "toast", ["Off", "Off", "info", "info"]) === false,
                "disabled parity did not refuse dispatch");
            check(Toaster.calls.length === 6, "disabled parity still toasted");
            console.log("CAELESTIA_TOASTER_IPC_PASS " + assertions);
            Qt.quit();
        } catch (error) {
            console.error("CAELESTIA_TOASTER_IPC_FAIL " + error);
            Qt.exit(1);
        }
    }

    Component.onCompleted: Qt.callLater(run)
}
