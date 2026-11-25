.pragma library

// Pure elevation-result handling for launcher and Nexus tests. The caller owns
// every UI decision; this module only normalizes the backend result and invokes
// the matching callback after ShellExecute has returned.
function canonicalStatus(result) {
    const value = String(result && typeof result === "object" ? result.status ?? "" : "").toLowerCase();
    if (value === "started")
        return "started";
    if (value === "cancelled")
        return "cancelled";
    if (value === "notsupported")
        return "notSupported";
    if (value === "queued")
        return "queued";
    return "refused";
}

function errorText(result, fallback) {
    const value = result && typeof result === "object" ? result.error : "";
    return typeof value === "string" && value.length > 0 ? value : fallback;
}

function launchDisabledError() {
    return "Application launching is disabled; this session is read-only.";
}

function runAsAdminDetailed(appActions, entryId, ownerWindow, launchEnabled) {
    if (launchEnabled !== true)
        return { status: "refused", error: launchDisabledError() };
    if (!appActions || typeof appActions.runAsAdminDetailed !== "function")
        return { status: "notSupported", error: "Windows elevation is unavailable." };
    if (typeof entryId !== "string" || entryId.length === 0)
        return { status: "notSupported", error: "The application entry is not available." };
    try {
        const result = appActions.runAsAdminDetailed(entryId, ownerWindow);
        return result && typeof result === "object"
            ? result
            : { status: "refused", error: "Windows returned no elevation result." };
    } catch (error) {
        return { status: "refused", error: String(error) };
    }
}

function entryText(entry) {
    if (!entry || typeof entry !== "object")
        return "";
    const command = entry.command && typeof entry.command.length === "number"
        ? Array.prototype.join.call(entry.command, " ") : "";
    return [entry.id ?? "", entry.name ?? "", entry.execString ?? "", command].join(" ").toLowerCase();
}

// Microsoft Sudo requires the command it elevates. Pick the shell associated
// with the catalog entry where one is identifiable, falling back to Windows
// PowerShell because powershell.exe exists on a stock Windows 11 install.
function shellExecutableForEntry(entry) {
    const text = entryText(entry);
    if (/pwsh(?:\.exe)?|powershell\s*7/.test(text))
        return "pwsh.exe";
    if (/command prompt|cmd(?:\.exe)?/.test(text))
        return "cmd.exe";
    return "powershell.exe";
}

function inlineSudoSpec(entry) {
    return {
        verb: "open",
        target: "wt.exe",
        args: ["new-tab", "--", "sudo.exe", "--inline", shellExecutableForEntry(entry)]
    };
}

function isInlineSudoEnabled(appActions) {
    if (!appActions || typeof appActions.isInlineSudoEnabled !== "function")
        return false;
    try {
        return appActions.isInlineSudoEnabled() === true;
    } catch (error) {
        return false;
    }
}

function launchInlineSudo(appActions, entry, ownerWindow, launchEnabled) {
    if (launchEnabled !== true)
        return { status: "refused", error: launchDisabledError() };
    if (!appActions || typeof appActions.launchShellAction !== "function")
        return { status: "notSupported", error: "Windows shell actions are unavailable." };
    if (!isInlineSudoEnabled(appActions))
        return { status: "refused", error: "Inline sudo is no longer enabled.", inlineSudoEnabled: false };
    try {
        const result = appActions.launchShellAction(inlineSudoSpec(entry), ownerWindow);
        if (result && typeof result === "object")
            return result;
        return result === true
            ? { status: "started" }
            : { status: "refused", error: "Windows returned no shell action result." };
    } catch (error) {
        return { status: "refused", error: String(error) };
    }
}

// Qt reports numeric keypad Enter with Qt.KeypadModifier set. Mask that bit
// out before comparing the exact Ctrl+Shift chord.
function isCtrlShiftEnter(key, modifiers, constants) {
    const keys = constants || {};
    const keypad = Number(keys.keypadModifier ?? 0);
    const mods = Number(modifiers ?? 0) & ~keypad;
    const required = Number(keys.controlModifier ?? 0) | Number(keys.shiftModifier ?? 0);
    return (key === keys.returnKey || key === keys.enterKey) && mods === required;
}

function report(result, handlers) {
    const status = canonicalStatus(result);
    const error = errorText(result, "Windows refused the elevation request.");
    const sink = handlers || {};
    if (status === "started") {
        if (typeof sink.started === "function")
            sink.started(result);
    } else if (status === "cancelled") {
        if (typeof sink.cancelled === "function")
            sink.cancelled(error, result);
    } else {
        if (typeof sink.refused === "function")
            sink.refused(error, status, result);
    }
    return { status: status, error: error };
}
