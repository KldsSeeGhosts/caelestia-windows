// The manual destination is not a release check or an automatic update channel.
var defaultReleasesUrl = "https://github.com/KldsSeeGhosts/caelestia-windows/releases";

function text(value) {
    return typeof value === "string" ? value : "";
}

function normalize(data) {
    var value = data && typeof data === "object" ? data : {};
    var candidate = text(value.manualReleaseUrl || value.releasesUrl);
    var releasesUrl = /^https:\/\/github\.com\/KldsSeeGhosts\/caelestia-windows\/releases(?:\/tag\/[A-Za-z0-9._-]+)?$/.test(candidate)
        ? candidate : defaultReleasesUrl;
    var previous = text(value.previous);
    return {
        current: text(value.current),
        sourceRevision: text(value.sourceRevision),
        releaseVersion: text(value.releaseVersion),
        displayVersion: text(value.displayVersion),
        channel: ["development", "preview", "stable"].indexOf(value.channel) >= 0 ? value.channel : "preview",
        updatesConfigured: value.updatesConfigured === true,
        previous: previous,
        previousDisplayVersion: text(value.previousDisplayVersion),
        previousRevision: text(value.previousRevision),
        versioned: value.versioned === true,
        canRollback: value.versioned === true && value.canRollback === true && previous !== "",
        manualReleaseUrl: releasesUrl,
        automaticUpdatesAvailable: value.updatesConfigured === true && value.automaticUpdatesAvailable === true,
        remoteVersionChecked: false,
        latestVersion: null
    };
}

// Presentation only. Keep the exact release/build/version IDs for commands,
// trust checks and Details, including epoch and retry attempt.
function formatVersion(value) {
    var version = text(value);
    var dev = /^(\d+\.\d+\.\d+)-dev\.[1-9]\d*\.([1-9]\d*)\.[1-9]\d*$/.exec(version);
    if (dev)
        return dev[1] + " \u00b7 Dev build " + dev[2];
    var preview = /^(\d+\.\d+\.\d+)-(preview|rc)\.([1-9]\d*)$/.exec(version);
    if (preview)
        return preview[1] + " \u00b7 " + (preview[2] === "rc" ? "RC " : "Preview ") + preview[3];
    return version || "Unknown";
}

function primaryState(value) {
    var s = value || {};
    var action = s.available ? "update" : "check";
    var label = s.available ? "Update now" : "Check for updates";
    var status = s.available ? "Update available: " + formatVersion(s.available.displayVersion) : "Check for updates";
    var disabled = !!s.blocked;
    if (s.operationState === "waiting") {
        var phases = {checking: "Checking\u2026", downloading: "Downloading\u2026",
            verifying: "Verifying\u2026", installing: "Installing\u2026", restarting: "Restarting\u2026"};
        status = s.operationKind === "rollback" ? "Restarting\u2026" : phases[s.step] || "Preparing update\u2026";
        label = status;
        disabled = true;
    } else if (s.operationState === "unconfirmed") {
        status = "Maintenance confirmation unavailable. It may still run. Refresh Details to check the selected version.";
        disabled = true;
    } else if (s.operationState === "complete") {
        status = "Restarting\u2026";
        label = status;
        disabled = true;
    } else if (s.checking) {
        status = "Checking\u2026";
        label = status;
        disabled = true;
    } else if (s.operationState === "failed") {
        status = "Maintenance could not complete. Check Details before retrying.";
    } else if (s.notice) {
        status = s.notice;
    } else if (s.result && !s.available) {
        status = s.result.state === "not-newer" ? "Up to date" : checkLabel(s.result.state);
    } else if (s.configured === false) {
        status = "Updates aren't set up for this build";
    }
    return {action: action, label: label, status: status, disabled: disabled};
}

function parseCheck(exitCode, output) {
    if (exitCode !== 0)
        return null;
    try {
        var data = JSON.parse(output);
        var states = ["available", "not-newer", "not-configured", "offline", "http", "too-large",
            "bad-signature", "bad-metadata", "expired", "clock", "replay", "unsupported", "busy"];
        if (!data || data.schema !== 1 || states.indexOf(data.state) < 0 ||
                ["development", "preview", "stable"].indexOf(data.channel) < 0)
            return null;
        var available = null;
        if (data.state === "available") {
            var release = data.available;
            var dev = /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)-dev\.[1-9][0-9]*\.[1-9][0-9]*\.[1-9][0-9]*$/;
            var display = /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-(?:dev\.[1-9][0-9]*\.[1-9][0-9]*\.[1-9][0-9]*|(?:preview|rc)\.[1-9][0-9]*))?$/;
            if (!release || !dev.test(text(release.buildVersion)) || !display.test(text(release.displayVersion)) ||
                    /[\r\n]/.test(release.buildVersion + release.displayVersion) ||
                    !release.bundle || !Number.isSafeInteger(release.bundle.size) ||
                    release.bundle.size < 1 || release.bundle.size > 1073741824)
                return null;
            var notes = text(release.notesUrl);
            available = {
                buildVersion: release.buildVersion, displayVersion: release.displayVersion,
                size: release.bundle.size,
                notesUrl: /^https:\/\/github\.com\/KldsSeeGhosts\/caelestia-windows\/releases\/tag\/v[0-9A-Za-z.-]+$/.test(notes) && !/[\r\n]/.test(notes) ? notes : defaultReleasesUrl
            };
        }
        return {state: data.state, channel: data.channel, available: available};
    } catch (error) {
        return null;
    }
}

function checkLabel(state) {
    var labels = {
        "not-newer": "No newer build on this channel",
        "not-configured": "Updates aren't set up for this build",
        "offline": "Couldn't check (offline)",
        "clock": "Your clock looks wrong",
        "unsupported": "A newer updater or manual settings migration is needed",
        "busy": "Another update check is in progress"
    };
    return labels[state] || "Couldn't verify the update";
}

function parseStatus(exitCode, output) {
    if (exitCode !== 0)
        return null;
    try {
        var data = JSON.parse(output);
        return data && data.schema === 1 ? normalize(data) : null;
    } catch (error) {
        return null;
    }
}
