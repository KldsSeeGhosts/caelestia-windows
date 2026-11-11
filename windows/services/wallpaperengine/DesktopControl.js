// Discovery and WE config changes never reassert a consumed switch choice.
function startup(settingsReady, discoveryReady, enabled, running) {
    if (!settingsReady || !discoveryReady)
        return null;
    return !enabled && running ? "stop" : "";
}

function toggle(enabled) {
    return enabled ? "play" : "stop";
}

function command(python, helper, action, allowed) {
    if (!allowed || !python || !["stop", "play"].includes(action))
        return [];
    return [python, helper, action];
}
