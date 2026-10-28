// Status-only projection of the Linux overlay's dictation protocol.
// Never retain transcript/error payloads, which may contain user speech.
.pragma library

var doneDurationMs = 1800;
var errorDurationMs = 2600;
var activeTimeoutMs = 300000;

function idle() {
    return { state: "idle", screenName: "", startedAt: 0, updatedAt: 0 };
}

function durationMsFor(state) {
    if (state === "done")
        return doneDurationMs;
    if (state === "error")
        return errorDurationMs;
    return state === "listening" || state === "processing" ? activeTimeoutMs : 0;
}

function normalize(data, nowMs) {
    if (!data || typeof data !== "object" || Array.isArray(data)
        || !["listening", "processing", "done", "error"].includes(data.state))
        return idle();
    // Unix seconds, as in the overlay. Reject malformed/future observations.
    const updated = data.updatedAt;
    if (typeof updated !== "number" || !Number.isFinite(updated) || updated <= 0
        || updated * 1000 > nowMs + 5000
        || nowMs - updated * 1000 >= durationMsFor(data.state))
        return idle();
    const started = data.startedAt;
    return {
        state: data.state,
        screenName: typeof data.screen === "string" ? data.screen.slice(0, 256) : "",
        startedAt: typeof started === "number" && Number.isFinite(started)
            && started > 0 && started <= updated ? started : 0,
        updatedAt: updated
    };
}

function targetScreen(screens, name) {
    for (const screen of screens)
        if (screen.name === name)
            return screen;
    return screens[0] ?? null;
}
