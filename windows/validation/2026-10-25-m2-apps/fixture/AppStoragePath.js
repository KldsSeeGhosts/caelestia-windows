.pragma library

// Windows app-frequency path policy. This module is pure JavaScript so the
// frequency store can be exercised without Quickshell or a native backend.
//
// The only accepted root is the isolated profile state directory passed by the
// shell. There is no HOME/XDG fallback: an empty, relative, UNC or traversing
// value yields an empty path and the store stays memory-only instead of
// writing somewhere unexpected. Upstream's `${Paths.state}/apps.sqlite` is not
// reproduced.

var FILE_NAME = "apps-frequencies.json";

function normalizeDir(dir) {
    if (typeof dir !== "string")
        return "";
    var value = dir.trim().replace(/\//g, "\\");
    if (value.length === 0)
        return "";
    // Windows drive path. UNC shares are rejected so a profile root cannot
    // silently resolve to a network location.
    if (!/^[A-Za-z]:\\/.test(value))
        return "";
    if (/(^|\\)\.\.(\\|$)/.test(value))
        return "";
    value = value.replace(/\\+$/, "");
    return value.length === 2 ? value + "\\" : value;
}

function frequenciesPath(stateDir) {
    var dir = normalizeDir(stateDir);
    if (dir.length === 0)
        return "";
    return (dir.endsWith("\\") ? dir : dir + "\\") + FILE_NAME;
}

function isInside(path, stateDir) {
    var dir = normalizeDir(stateDir);
    if (typeof path !== "string" || path.length === 0 || dir.length === 0)
        return false;
    var normalized = path.trim().replace(/\//g, "\\");
    if (/(^|\\)\.\.(\\|$)/.test(normalized))
        return false;
    normalized = normalized.replace(/\\+$/, "").toLowerCase();
    var root = dir.replace(/\\+$/, "").toLowerCase();
    return normalized.indexOf(root + "\\") === 0;
}
