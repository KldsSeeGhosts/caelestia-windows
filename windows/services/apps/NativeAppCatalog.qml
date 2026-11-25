import QtQuick
import Quickshell
import Quickshell.Windows as Native
import "ShellActionSchema.js" as ShellActionSchema

// Thin native wrapper over Quickshell.DesktopEntries.
//
// Loaded by the Apps facade through a Loader that is active only after the
// CAELESTIA_WINDOWS_APPS opt-in. Referencing DesktopEntries constructs the
// shared desktop-entry manager, starts the Windows AppsFolder enumeration on
// the background pool and begins Start menu path monitoring
// (windows/deps/quickshell/src/core/desktopentry.cpp:420-447,
// src/windows/desktopentry_backend.cpp:142-156). It does not launch anything.
//
// The pinned public API has no scan-result flag: `applicationsChanged` fires
// after every completed scan, including one where the native scan returned an
// empty list because COM or the Apps folder failed
// (src/windows/desktopentry_backend.cpp:158-187). `scanCompleted` therefore
// records only that a scan finished; `scanError` stays empty unless a caller
// injects a known failure, because the backend never reports one.
QtObject {
    id: root

    signal launchFinished(string requestId, string status, string error)
    property var appActions: Native.AppActions
    readonly property var launchResults: root.appActions
    readonly property var observedEntries: new WeakSet()

    readonly property var applications: DesktopEntries.applications

    // DesktopEntryManager and its model outlive QML engines. A replacement
    // generation must use an existing snapshot without waiting for a rescan.
    // Keep the completion signal below for the first scan, including empty ones.
    property bool scanCompleted: (applications?.values?.length ?? 0) > 0
    property string scanError: ""

    readonly property Connections scan: Connections {
        target: DesktopEntries
        function onApplicationsChanged(): void {
            root.scanCompleted = true;
        }
    }

    // The catalog's exact id plus the Windows backend's alias: a running
    // window's app id/AUMID is matched only when it names an installed entry.
    // No startup-class or display-name guessing is allowed for a launch.
    function lookup(appId): var {
        return typeof appId === "string" && appId.length > 0
            ? DesktopEntries.byId(appId) : null;
    }

    // Forward the companion backend's asynchronous result when it exists. The
    // pinned backend has no shellActionFinished signal, so feature detection
    // leaves unconfirmed dispatches unranked instead of inventing success.
    function forwardShellActionFinished(requestId, status, error): void {
        root.launchFinished(String(requestId ?? ""), String(status ?? ""), String(error ?? ""));
    }

    readonly property Connections nativeResults: Connections {
        target: root.launchResults
        ignoreUnknownSignals: true
        function onShellActionFinished(requestId, status, error): void {
            root.forwardShellActionFinished(requestId, status, error);
        }
    }

    // The companion backend shares the AppsFolder launch routine: Explorer
    // ShellExecute first, then IApplicationActivationManager when needed.
    // A void return from the older DesktopEntry API stays unconfirmed.
    function execute(entry): var {
        if (!entry)
            return { state: "refused", requestId: "", error: "Unknown application entry." };
        let result;
        try {
            const commandToken = entry.command?.[0];
            const entryToken = typeof commandToken === "string" && commandToken.trim() ? commandToken : entry.execString;
            const token = typeof entryToken === "string" ? entryToken.replace(/^shell:AppsFolder\\/i, "") : "";
            if (typeof token === "string" && token.trim() && typeof appActions?.launchShellAction === "function"
                && appActions.shellActionFinished) {
                const workingDir = typeof entry.workingDirectory === "string" ? entry.workingDirectory : "";
                result = appActions.launchShellAction({verb: "open", aumid: token, workingDir}, null);
                const status = ShellActionSchema.launchStatus(result);
                const requestId = ShellActionSchema.launchRequestId(result);
                if (status === "started")
                    return {state: "confirmed"};
                if (status === "queued" && requestId)
                    return {state: "pending", requestId};
                return {state: "refused", error: result?.error || (status === "cancelled"
                    ? "Windows cancelled the application launch." : "Windows refused the application launch.")};
            }
            if (typeof entry.execute !== "function")
                return {state: "refused", error: "Unknown application entry."};
            const entryResult = entry.launchFinished;
            if (entryResult && typeof entryResult.connect === "function" && !observedEntries.has(entry)) {
                entryResult.connect(root.forwardShellActionFinished);
                observedEntries.add(entry);
            }
            result = entry.execute();
        } catch (error) {
            return { state: "refused", requestId: "", error: String(error) };
        }
        if (result === true)
            return { state: "confirmed", requestId: "", error: "" };
        if (result === false)
            return { state: "refused", requestId: "", error: "Windows refused the application launch." };
        const requestId = ShellActionSchema.launchRequestId(result);
        if (requestId)
            return { state: "pending", requestId, error: "" };
        return { state: "unconfirmed", requestId: "", error: "" };
    }
}
