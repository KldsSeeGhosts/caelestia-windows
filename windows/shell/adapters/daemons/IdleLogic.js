.pragma library

function tokens(action) {
    if (typeof action === "string")
        return action.length > 0 ? [action] : [];
    if (!action || typeof action.length !== "number")
        return [];
    const result = [];
    for (let i = 0; i < action.length; ++i) {
        if (typeof action[i] !== "string")
            return [];
        result.push(action[i]);
    }
    return result;
}

function normalizeAction(action) {
    const words = tokens(action);
    if (words.length === 0)
        return null;
    const joined = words.join(" ").replace(/[_\s]+/g, "").toLowerCase();
    if (joined === "lock")
        return {kind: "lock"};
    if (joined === "dpmsoff" || joined === "displayoff" || joined === "screenoff")
        return {kind: "displayOff"};
    if (joined === "suspend" || joined === "sleep" || joined === "suspendthenhibernate")
        return {kind: "session", action: "suspend"};
    if (joined === "hibernate")
        return {kind: "session", action: "hibernate"};
    return null;
}

function entryTimeout(entry) {
    const timeout = Number(entry ? entry.timeout : NaN);
    return Number.isFinite(timeout) && timeout > 0 ? timeout : 0;
}

function transitions(entries, fired, idleSeconds, inhibited, hasPlayer, isCharging, globalInhibitAudio, globalInhibitCharging) {
    const result = [];
    const nextFired = {};
    for (let i = 0; i < entries.length; ++i) {
        const entry = entries[i] || {};
        const timeout = entryTimeout(entry);
        const key = String(i);
        const audioBlocked = (entry.inhibitWhenAudio === true || globalInhibitAudio === true) && hasPlayer;
        const chargingBlocked = (entry.inhibitWhenCharging === true || globalInhibitCharging === true) && isCharging;
        const blocked = inhibited || audioBlocked || chargingBlocked || entry.enabled === false;
        const due = timeout > 0 && !blocked && idleSeconds >= timeout;
        if (due && fired[key] !== true)
            result.push({index: i, entry: entry, action: normalizeAction(entry.idleAction)});
        nextFired[key] = due || (fired[key] === true && idleSeconds >= timeout);
    }
    return {fired: nextFired, actions: result};
}
