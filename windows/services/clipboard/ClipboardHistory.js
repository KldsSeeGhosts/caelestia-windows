// Clipboard display rows for the Windows Caelestia overlay.
//
// Adapted from the Omarchy clipboard history model that the user's Linux
// Caelestia overlay also derives from. See upstream/SOURCE.md and
// upstream/LICENSE-MIT.txt. The Windows port keeps only presentation logic:
// entries come from Windows' native clipboard history through
// Caelestia.Windows.WindowsClipboard, and nothing here stores or persists
// clipboard contents.

// Bound rendering, not searching. Searchable text is read from the complete
// entry so a match past the rendered preview still finds the original item.
.import "../../utils/FileUrls.js" as FileUrls

const displayTextLimit = 8192;

function normalizeEntry(value) {
    if (!value || typeof value !== "object")
        return null;

    const id = String(value.id ?? "");
    if (!id)
        return null;

    const kind = String(value.kind ?? "");
    const entry = {
        id: id,
        type: kind === "image" || kind === "other" ? kind : "text",
        text: typeof value.text === "string" ? value.text : "",
        imageUrl: typeof value.imageUrl === "string" ? value.imageUrl : "",
        timestamp: typeof value.timestamp === "string" ? value.timestamp : "",
        timestampLabel: typeof value.timestampLabel === "string" ? value.timestampLabel : "",
        formats: typeof value.formats === "string" ? value.formats : ""
    };

    // Windows reports an item as text only when a usable text format exists.
    // Tolerate an empty text anyway instead of rendering a blank row.
    if (entry.type === "text" && entry.text.trim().length === 0)
        entry.type = "other";

    return entry;
}

function decodeFileUri(uri) {
    const parsed = FileUrls.parseFileUrl(String(uri || "").trim());
    // Clipboard text is untrusted, not an explicit request to browse a share.
    // Reject remote authorities and decoded UNC/device spellings before a row
    // can hand a path to Image or any file probe. Explicit Paths conversion
    // deliberately keeps UNC support.
    if (!parsed || parsed.authority || /^[\\/]{2}/.test(parsed.path))
        return "";
    return parsed.path;
}

// Windows clipboard text may contain "file://" lines. Keep the reference's
// file-reference presentation for those, with Windows-aware basenames.
function filePaths(entry) {
    if (!entry || entry.type !== "text")
        return [];

    const lines = String(entry.text || "").split(/\r?\n/);
    const paths = [];
    for (let i = 0; i < lines.length; i++) {
        const path = decodeFileUri(lines[i]);
        if (path)
            paths.push(path);
    }
    return paths;
}

function fileName(path) {
    const parts = String(path || "").split(/[\\/]/);
    return parts.length > 0 ? parts[parts.length - 1] : String(path || "");
}

function isImagePath(path) {
    return /\.(png|jpe?g|webp|gif|bmp|tiff?)$/i.test(String(path || ""));
}

// Local path or file URL to a QML Image source. Empty when the path cannot be
// represented as a file URL.
function fileUrl(path) {
    return FileUrls.fromPathOrUrl(path);
}

function isCodeText(text) {
    if (!text || typeof text !== "string") return false;
    const trimmed = text.trim();
    if (trimmed.length < 5) return false;
    if (/\b(const|let|var|function|import|export|class|interface|type|return|if|else|for|while|def|fn|pub|impl|struct|enum|async|await|package|select|from|where|switch|case)\b/.test(trimmed)) return true;
    if (/^[ \t]*[{\[<]/m.test(trimmed) && /[}\]>][ \t]*$/m.test(trimmed)) return true;
    if (trimmed.includes(" => ") || trimmed.includes(" -> ") || trimmed.includes("::") || trimmed.includes("</")) return true;
    if ((trimmed.match(/\n/g) || []).length >= 2 && /^\s+/m.test(trimmed)) return true;
    return false;
}

function isUrlText(text) {
    if (!text || typeof text !== "string") return false;
    const trimmed = text.trim();
    return /^https?:\/\/[^\s]+$/i.test(trimmed);
}

function isColorText(text) {
    if (!text || typeof text !== "string") return false;
    const trimmed = text.trim();
    return /^#(?:[0-9a-fA-F]{3,4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/.test(trimmed) ||
           /^rgba?\(\s*\d+\s*,\s*\d+\s*,\s*\d+/i.test(trimmed) ||
           /^hsla?\(\s*\d+\s*,\s*[\d.]+%?\s*,\s*[\d.]+%?/i.test(trimmed);
}

function lineCount(text) {
    if (!text || typeof text !== "string" || text.length === 0) return 0;
    return text.split(/\r?\n/).length;
}

function charCount(text) {
    if (!text || typeof text !== "string") return 0;
    return text.length;
}

function searchableText(entry) {
    if (!entry)
        return "";
    if (entry.type === "image")
        return `image screenshot bitmap ${entry.formats} ${entry.timestampLabel} ${entry.timestamp}`;
    if (entry.type === "other")
        return `clipboard item ${entry.formats} ${entry.timestampLabel} ${entry.timestamp}`;
    return `${String(entry.text || "")} ${fileEntryText(entry)}`;
}

function fileEntryText(entry) {
    const paths = filePaths(entry);
    if (paths.length === 0)
        return "";
    if (paths.length === 1)
        return fileName(paths[0]);
    return `${paths.length} files`;
}

function imagePreviewText(entry) {
    const label = String(entry && entry.timestampLabel || "");
    return label ? `Image from ${label}` : "Image";
}

function otherPreviewText(entry) {
    const formats = String(entry && entry.formats || "");
    return formats ? `Clipboard item (${formats})` : "Clipboard item";
}

function entryTitle(entry) {
    if (!entry) return "";
    if (entry.type === "image") return imagePreviewText(entry);
    if (entry.type === "other") return otherPreviewText(entry);
    const paths = filePaths(entry);
    if (paths.length > 0) return fileEntryText(entry);
    const lines = String(entry.text || "").trim().split(/\r?\n/);
    return lines[0] ? lines[0].trim() : "";
}

function entrySubtitle(entry) {
    if (!entry) return "";
    if (entry.type === "image") return entry.timestampLabel || entry.formats;
    if (entry.type === "other") return entry.timestampLabel || entry.formats;
    const paths = filePaths(entry);
    if (paths.length > 1) return paths.slice(0, 3).map(fileName).join(", ");
    if (paths.length === 1) return paths[0];
    const lines = String(entry.text || "").trim().split(/\r?\n/);
    if (lines.length > 1) {
        return lines.slice(1).map(l => l.trim()).filter(Boolean).join(" ");
    }
    return "";
}

function previewText(entry) {
    if (!entry)
        return "";
    if (entry.type === "image")
        return imagePreviewText(entry);
    if (entry.type === "other")
        return otherPreviewText(entry);
    const fileText = fileEntryText(entry);
    if (fileText)
        return fileText;
    return String(entry.text || "").replace(/\s+/g, " ");
}

function fullText(entry) {
    if (!entry)
        return "";
    if (entry.type === "image" || entry.type === "other")
        return "";
    const paths = filePaths(entry);
    if (paths.length > 0)
        return paths.join("\n");
    return String(entry.text || "");
}

function cappedEntry(entry) {
    if (!entry || entry.type !== "text" || entry.text.length <= displayTextLimit)
        return entry;

    const cut = entry.text.lastIndexOf("\n", displayTextLimit);
    return {
        id: entry.id,
        type: "text",
        text: entry.text.slice(0, cut > 0 ? cut : displayTextLimit),
        imageUrl: entry.imageUrl,
        timestamp: entry.timestamp,
        timestampLabel: entry.timestampLabel,
        formats: entry.formats
    };
}

// WindowsClipboard.items is a native QVariantList. QML hands that to JS as an
// array-like sequence wrapper for which Array.isArray() is false, so a plain
// Array.isArray check silently treats the whole history as empty. Accept any
// array-like object and copy it into a real array.
function toArray(value) {
    if (Array.isArray(value))
        return value;
    if (value && typeof value === "object" && typeof value.length === "number")
        return Array.from(value);
    return [];
}

// Selection is preserved by stable item id, not by row index. A refresh can
// insert new entries above the selected one; keeping the index would silently
// move the selection (and Delete would remove the wrong entry). When the
// selected entry is gone, fall back to the clamped previous index.
function indexOfId(list, id) {
    const wanted = String(id || "");
    const rows = toArray(list);
    if (!wanted)
        return -1;
    for (let i = 0; i < rows.length; i++) {
        if (String(rows[i].itemId || rows[i].id || "") === wanted)
            return i;
    }
    return -1;
}

function selectionIndex(previousId, previousIndex, list) {
    const rows = toArray(list);
    if (rows.length === 0)
        return -1;
    const found = indexOfId(rows, previousId);
    if (found >= 0)
        return found;
    const fallback = Number.isFinite(previousIndex) ? previousIndex : 0;
    return Math.max(0, Math.min(fallback, rows.length - 1));
}

function displayRows(history, query, limit) {
    const values = toArray(history);
    const needle = String(query || "").trim().toLowerCase();
    let max = limit === undefined || limit === null ? 50 : Number(limit);
    if (isNaN(max))
        max = 50;
    max = Math.max(0, max);
    if (max === 0)
        return [];

    const rows = [];
    for (let i = 0; i < values.length; i++) {
        const original = normalizeEntry(values[i]);
        if (!original)
            continue;
        // Bound rendering, not searching: matches beyond the preview limit
        // must still find the original clipboard entry.
        if (needle && searchableText(original).toLowerCase().indexOf(needle) < 0)
            continue;
        const entry = cappedEntry(original);

        const paths = filePaths(entry);
        const isFile = paths.length > 0;
        const isImage = entry.type === "image";
        const isOther = entry.type === "other";
        const text = isImage || isOther ? "" : fullText(entry);
        const isUrl = !isImage && !isOther && !isFile && isUrlText(text);
        const isColor = !isImage && !isOther && !isFile && isColorText(text);
        const isCode = !isImage && !isOther && !isFile && !isUrl && !isColor && isCodeText(text);

        let type = "text";
        if (isImage) type = "image";
        else if (isOther) type = "other";
        else if (isFile) type = "file";
        else if (isUrl) type = "url";
        else if (isColor) type = "color";
        else if (isCode) type = "code";

        let previewImage = isImage ? entry.imageUrl : "";
        if (!previewImage && isFile && paths.length === 1 && isImagePath(paths[0]))
            previewImage = fileUrl(paths[0]);

        rows.push({
            itemId: entry.id,
            entryType: type,
            title: entryTitle(entry),
            subtitle: entrySubtitle(entry),
            fullText: text,
            previewText: previewText(entry),
            previewImage: previewImage,
            path: isFile && paths.length === 1 ? paths[0] : "",
            formats: entry.formats,
            timestamp: entry.timestamp,
            timestampLabel: entry.timestampLabel,
            charCount: charCount(text),
            lineCount: lineCount(text),
            isCode: isCode,
            isUrl: isUrl,
            isColor: isColor,
            colorValue: isColor ? text.trim() : "",
            index: i
        });
        if (rows.length >= max)
            break;
    }

    return rows;
}
