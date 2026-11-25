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

function validateShellAction(value) {
    if (!value || typeof value !== "object" || Array.isArray(value))
        return { ok: false, error: "The launcher action is not an object." };
    const verb = value.verb;
    if (verb !== "open" && verb !== "runas")
        return { ok: false, error: "The launcher action verb must be open or runas." };

    const endpoints = [];
    for (const key of ["target", "aumid", "uri"]) {
        if (value[key] !== undefined && value[key] !== null && value[key] !== "") {
            const endpoint = cleanText(value[key]);
            if (!endpoint)
                return { ok: false, error: "The launcher action " + key + " is invalid." };
            endpoints.push([key, endpoint]);
        }
    }
    if (endpoints.length !== 1)
        return { ok: false, error: "The launcher action needs exactly one target, aumid or uri." };

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
    return { ok: true, action: action, error: "" };
}

function hasShellAction(value) {
    return !!value && typeof value === "object" && typeof value.verb === "string" && value.verb.length > 0;
}

function terminalAction(terminal, entry) {
    const terminalCommand = stringList(terminal, false);
    if (!terminalCommand)
        return { ok: false, error: "No valid terminal command is configured." };
    if (!entry || typeof entry !== "object")
        return { ok: false, error: "Unknown terminal application entry." };

    let command = stringList(entry.command, true);
    if (!command || command.length === 0) {
        const execString = cleanText(entry.execString);
        if (!execString)
            return { ok: false, error: "The terminal application has no command." };
        command = [execString];
    }

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
