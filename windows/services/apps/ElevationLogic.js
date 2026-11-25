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

function runAsAdminDetailed(appActions, entryId, ownerWindow) {
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
