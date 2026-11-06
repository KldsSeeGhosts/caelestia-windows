.pragma library

function isFileUrl(value) {
    return /^file:/i.test(String(value || ""));
}

function encodePathSegments(path) {
    const value = String(path || "");
    if (/[\u0000-\u001f\u007f]/.test(value))
        return "";
    try {
        return value.split("/").map(segment => encodeURIComponent(segment)).join("/");
    } catch (error) {
        return "";
    }
}

function parseFileUrl(url) {
    // Older clipboard/config values may contain literal ASCII spaces. Escape
    // only those spaces, leaving existing escapes intact for one decode below.
    const value = String(url || "").replace(/ /g, "%20");
    const match = /^file:\/\/([^/?#]*)(\/[^?#]*)?$/i.exec(value);
    if (!match || /[\\\s]/.test(value) || /%(?![0-9a-f]{2})/i.test(value))
        return null;

    const authority = match[1];
    const encodedPath = match[2] || "/";
    let path;
    try {
        path = decodeURIComponent(encodedPath);
    } catch (error) {
        return null;
    }
    if (/[\u0000-\u001f\u007f]/.test(path))
        return null;

    // A file URI with an authority names a UNC share, except for localhost,
    // which is the local machine. Do not accept a server URI without a share.
    if (authority && !/^localhost$/i.test(authority)) {
        if (/[?#%:@\s\\]/.test(authority) || !path.slice(1))
            return null;
        return { authority: authority, path: path };
    }
    if (path.length >= 3 && /^\/[a-z]:\//i.test(path))
        path = path.slice(1);
    else if (path.length === 3 && /^\/[a-z]:$/i.test(path))
        path = path.slice(1);
    return { authority: "", path: path };
}

// Convert an unescaped local filesystem path to its hierarchical file URL.
// Only absolute drive, UNC, and rooted paths are accepted. A string that is
// already a URL belongs to fromPathOrUrl() and is never re-encoded here.
function fromLocalPath(path) {
    const value = String(path || "");
    if (!value || isFileUrl(value) || /[\u0000-\u001f\u007f]/.test(value))
        return "";

    const normalized = value.replace(/\\/g, "/");
    if (/^[a-z]:\//i.test(normalized)) {
        const rest = normalized.slice(3);
        const encoded = encodePathSegments(rest);
        if (rest && !encoded)
            return "";
        return "file:///" + normalized.slice(0, 3) + encoded;
    }
    if (/^[a-z][a-z0-9+.-]*:/i.test(normalized))
        return "";

    if (normalized.startsWith("//")) {
        const remainder = normalized.slice(2);
        const slash = remainder.indexOf("/");
        if (slash <= 0)
            return "";
        const server = remainder.slice(0, slash);
        const shareAndPath = remainder.slice(slash + 1);
        if (!shareAndPath || /[/?#%:@\s\\]/.test(server))
            return "";
        const encoded = encodePathSegments(shareAndPath);
        return encoded ? "file://" + server + "/" + encoded : "";
    }

    if (normalized.startsWith("/"))
        return "file://" + encodePathSegments(normalized);
    return "";
}

// Local paths are raw text; file URLs are already encoded data. Keep an encoded
// URL byte-for-byte; normalize legacy raw spaces without touching its escapes.
function fromPathOrUrl(value) {
    const text = String(value || "");
    if (isFileUrl(text)) {
        const normalized = text.replace(/ /g, "%20");
        return parseFileUrl(normalized) ? normalized : "";
    }
    return fromLocalPath(text);
}

// Decode a file URL exactly once. Unsupported schemes, query/fragment
// components, malformed escapes, and incomplete UNC paths are not local paths.
function toLocalPath(url) {
    const parsed = parseFileUrl(url);
    if (!parsed)
        return "";
    if (parsed.authority)
        return "//" + parsed.authority + parsed.path;
    return parsed.path;
}
