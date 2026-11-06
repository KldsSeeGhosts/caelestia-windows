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
        previous: previous,
        previousRevision: text(value.previousRevision),
        versioned: value.versioned === true,
        canRollback: value.versioned === true && value.canRollback === true && previous !== "",
        manualReleaseUrl: releasesUrl,
        // This implementation never checks remote versions or performs updates,
        // including when a legacy/partial status object claims otherwise.
        automaticUpdatesAvailable: false,
        remoteVersionChecked: false,
        latestVersion: null
    };
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
