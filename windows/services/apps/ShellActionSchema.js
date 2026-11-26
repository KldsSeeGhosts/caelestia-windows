.pragma library

function isArrayLike(value) {
    return value !== null && value !== undefined && typeof value !== "string"
        && Number.isSafeInteger(value.length) && value.length >= 0 && value.length <= 512;
}

function stringList(value, allowEmpty) {
    if (!isArrayLike(value))
        return null;
    const result = [];
    for (let index = 0; index < value.length; ++index) {
        if (typeof value[index] !== "string" || /[\u0000-\u001f\u007f]/.test(value[index]))
            return null;
        result.push(value[index]);
    }
    if (!allowEmpty && result.length === 0)
        return null;
    return result;
}

function cleanText(value) {
    return typeof value === "string" && value.trim().length > 0
        && !/[\u0000-\u001f\u007f]/.test(value) ? value : "";
}

function validExecutableTarget(value) {
    const text = cleanText(value);
    if (!text || text !== text.trim() || !/\.(exe|com)$/i.test(text) || /[<>:"|?*]/.test(text.replace(/^[A-Za-z]:/, "")))
        return "";
    // Allow executable names, drive-absolute paths and ordinary UNC paths.
    // Reject relative paths and Windows device/extended namespaces.
    return /^[\w.-]+$/i.test(text) || /^[A-Za-z]:[\\/][^\\/]/.test(text)
        || /^(?:\\\\|\/\/)[\w.-]+[\\/][^\\/]+[\\/]/.test(text) ? text : "";
}

function validAumid(value) {
    const text = cleanText(value);
    return /^[A-Za-z0-9._-]+![A-Za-z0-9._-]+$/.test(text) ? text : "";
}

function uriScheme(value) {
    const text = cleanText(value);
    if (!text || /[\s\\<>"{}|^`]/.test(text) || /%(?![0-9a-f]{2})/i.test(text))
        return "";
    const match = text.match(/^([A-Za-z][A-Za-z0-9+.-]*):/);
    return match && match[1].length > 1 ? match[1].toLowerCase() : "";
}

function validateShellAction(value) {
    if (!value || typeof value !== "object" || Array.isArray(value))
        return { ok: false, error: "The launcher action is not an object." };
    const verb = value.verb;
    if (verb !== "open" && verb !== "runas")
        return { ok: false, error: "The launcher action verb must be open or runas." };

    const endpoints = [];
    for (const key of ["target", "aumid", "uri"]) {
        if (value[key] !== undefined && value[key] !== null && value[key] !== "") {
            let endpoint = "";
            if (key === "target")
                endpoint = validExecutableTarget(value[key]);
            else if (key === "aumid")
                endpoint = validAumid(value[key]);
            else
                endpoint = uriScheme(value[key]) ? cleanText(value[key]) : "";
            if (!endpoint)
                return { ok: false, error: "The launcher action " + key + " is invalid." };
            endpoints.push([key, endpoint]);
        }
    }
    if (endpoints.length !== 1)
        return { ok: false, error: "The launcher action needs exactly one target, aumid or uri." };
    if (verb === "runas" && endpoints[0][0] !== "target")
        return { ok: false, error: "Elevation requires an executable target." };

    const action = { verb: verb };
    action[endpoints[0][0]] = endpoints[0][1];

    if (value.args !== undefined && value.args !== null) {
        const args = stringList(value.args, true);
        if (!args)
            return { ok: false, error: "The launcher action arguments must be strings." };
        if (args.length > 0)
            action.args = args;
    }
    if (value.workingDir !== undefined && value.workingDir !== null && value.workingDir !== "") {
        const workingDir = cleanText(value.workingDir);
        if (!workingDir)
            return { ok: false, error: "The launcher action working directory is invalid." };
        action.workingDir = workingDir;
    }
    if (endpoints[0][0] === "uri" && (action.args || action.workingDir))
        return { ok: false, error: "URI actions cannot specify arguments or a working directory." };
    return { ok: true, action: action, error: "" };
}


function isDangerousShellAction(value) {
    if (!value || typeof value !== "object")
        return false;
    if (!hasShellAction(value))
        return false;
    const result = validateShellAction(value);
    // Only direct Settings page identifiers are allowed without opt-in.
    return !result.ok || result.action.verb !== "open"
        || !/^ms-settings:[a-z0-9-]*$/i.test(result.action.uri || "");
}

function hasShellAction(value) {
    return !!value && typeof value === "object"
        && (value.args?.length > 0
            || [value.verb, value.target, value.aumid, value.uri, value.workingDir].some(field => field !== "" && field != null));
}

function launchRequestId(result) {
    const value = result && typeof result === "object" ? result.requestId : result;
    if (typeof value === "string")
        return value;
    return Number.isSafeInteger(value) && value > 0 ? String(value) : "";
}

function launchStatus(result) {
    return result === true ? "started" : String(result?.status ?? "").toLowerCase();
}

function dispatchLauncherAction(appActions, action, list) {
    // The backend can resolve the HWND from QQuickItem::window(). The
    // Quickshell QsWindow.window wrapper is not a QWindow.
    return appActions.launchShellAction(action, list ?? null);
}

function captureLauncherSession(screenState) {
    return screenState?.launcher === true && Number.isInteger(screenState.launcherGeneration)
        ? {screenState, generation: screenState.launcherGeneration} : null;
}

function dismissLauncherSession(session) {
    const state = session?.screenState;
    if (state?.launcher === true && state.launcherGeneration === session.generation)
        state.launcher = false;
}

function terminalAction(terminal, entry) {
    const terminalCommand = stringList(terminal, false);
    if (!terminalCommand)
        return { ok: false, error: "No valid terminal command is configured." };
    if (!entry || typeof entry !== "object")
        return { ok: false, error: "Unknown terminal application entry." };

    const command = stringList(entry.command, false);
    if (!command || !validExecutableTarget(command[0]))
        return { ok: false, error: "The terminal application needs a structured executable and argument list." };

    const spec = {
        verb: "open",
        target: terminalCommand[0],
        args: terminalCommand.slice(1).concat(command)
    };
    const workingDir = cleanText(entry.workingDirectory);
    if (workingDir)
        spec.workingDir = workingDir;
    return validateShellAction(spec);
}
