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
    if (joined === "dpmson" || joined === "displayon" || joined === "screenon")
        return {kind: "displayOn"};
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

function transitions(entries, fired, idleSeconds, inhibited, hasPlayer, onAcPower, globalInhibitAudio, globalInhibitCharging, activityResumed) {
    const result = [];
    const nextFired = {};
    for (let i = 0; i < entries.length; ++i) {
        const entry = entries[i] || {};
        const timeout = entryTimeout(entry);
        const key = String(i);
        const inhibitorBlocked = inhibited && entry.respectInhibitors !== false;
        const audioBlocked = (entry.inhibitWhenAudio === true || globalInhibitAudio === true) && hasPlayer;
        const chargingBlocked = (entry.inhibitWhenCharging === true || globalInhibitCharging === true) && onAcPower;
        const blocked = inhibitorBlocked || audioBlocked || chargingBlocked || entry.enabled === false;
        const due = timeout > 0 && !blocked && idleSeconds >= timeout;
        const wasFired = fired[key] === true;
        if (wasFired && timeout > 0 && (activityResumed || idleSeconds < timeout)) {
            const action = normalizeAction(entry.returnAction);
            if (action)
                result.push({index: i, entry: entry, kind: "return", action});
            nextFired[key] = false;
            continue;
        }
        if (due && !wasFired) {
            const action = normalizeAction(entry.idleAction);
            if (action)
                result.push({index: i, entry: entry, kind: "idle", action});
        }
        nextFired[key] = due || (wasFired && idleSeconds >= timeout);
    }
    return {fired: nextFired, actions: result};
}
