import QtQuick
import Quickshell.Io
import Caelestia

// Upstream toaster IPC contract. `toast` is a Windows extension that reports
// whether dispatch was enabled; the upstream convenience methods stay void.
IpcHandler {
    id: root

    property bool parityEnabled: false

    target: "toaster"

    function toast(title: string, body: string, icon: string, kind: string): bool {
        if (!root.parityEnabled)
            return false;
        const types = ({info: Toast.Info, success: Toast.Success, warn: Toast.Warning, error: Toast.Error});
        const type = Object.prototype.hasOwnProperty.call(types, kind) ? types[kind] : Toast.Info;
        Toaster.toast(String(title), String(body), String(icon || "info"), type);
        return true;
    }
    function info(title: string, message: string, icon: string): void { toast(title, message, icon, "info"); }
    function success(title: string, message: string, icon: string): void { toast(title, message, icon, "success"); }
    function warn(title: string, message: string, icon: string): void { toast(title, message, icon, "warn"); }
    function error(title: string, message: string, icon: string): void { toast(title, message, icon, "error"); }
}
