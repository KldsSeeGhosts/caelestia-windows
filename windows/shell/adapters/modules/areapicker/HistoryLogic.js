// The history index never stores absolute paths. Only this module's generated
// names can be resolved inside the private history folder.
var OWNED_PNG = /^[a-f0-9]{32}\.png$/;
var MAX_INDEX = 8 * 1024 * 1024;
var MODES = ["copy", "save", "save-and-copy", "save-and-copy-path", "preview"];

function settings(capture) {
    var c = capture || {};
    return {
        mode: MODES.includes(c.quickCapture) ? c.quickCapture : "copy",
        limit: Number.isInteger(c.historyLimit) ? Math.max(0, Math.min(50, c.historyLimit)) : 10,
        bytes: 256 * 1024 * 1024,
        openEditor: c.quickCaptureOpenEditor === true,
        closeAfterCopy: c.closeEditorAfterCopy === true
    };
}

function fileName(name) {
    return typeof name === "string" && OWNED_PNG.test(name);
}

function dimensions(info) {
    return info && Number.isInteger(info.width) && Number.isInteger(info.height)
        && info.width > 0 && info.height > 0 && info.width <= 32768 && info.height <= 32768;
}

function validStrokes(strokes) {
    return strokes.every(function (stroke) {
        return stroke && ["pencil", "highlighter", "line", "arrow", "rect", "circle", "text", "step", "blur"].includes(stroke.tool)
            && typeof stroke.color === "string" && /^#[a-f0-9]{6}$/i.test(stroke.color)
            && [stroke.size, stroke.x1, stroke.y1, stroke.x2, stroke.y2].every(Number.isFinite)
            && Array.isArray(stroke.points) && stroke.points.length <= 2001
            && stroke.points.every(function (p) { return p && [p.x, p.y, p.w].every(Number.isFinite); })
            && (stroke.fill === undefined || typeof stroke.fill === "boolean")
            && (stroke.text === undefined || (typeof stroke.text === "string" && stroke.text.length <= 4096))
            && (stroke.step === undefined || Number.isFinite(stroke.step))
            && (stroke.id === undefined || (Number.isFinite(stroke.id) && stroke.id > 0));
    });
}

function valid(row) {
    return row && fileName(row.raw) && fileName(row.image) && typeof row.id === "string"
        && /^[a-f0-9]{32}$/.test(row.id) && dimensions(row.info) && Number.isFinite(row.updated)
        && Number.isFinite(row.created) && Array.isArray(row.strokes) && validStrokes(row.strokes)
        && (!row.strokes.length || (Number.isFinite(row.canvasWidth) && row.canvasWidth > 0));
}

function decode(text) {
    try {
        var index = text.length <= MAX_INDEX ? JSON.parse(text) : null;
        if (!index || index.version !== 1 || !Array.isArray(index.rows))
            return null;
        var seen = new Set();
        return index.rows.filter(function (row) {
            if (!valid(row) || seen.has(row.id))
                return false;
            seen.add(row.id);
            return true;
        });
    } catch (_) {
        return null;
    }
}

// Conservatively charge for each RGBA8 PNG and annotation metadata. This
// bounds the cache without reading or decoding screenshots to measure them.
function cost(row) {
    var image = 5 * row.info.width * row.info.height + 65536;
    return image * (row.raw === row.image ? 1 : 2) + 2 * JSON.stringify(row.strokes).length;
}

function bounded(rows, limit, bytes) {
    var kept = [];
    for (var row of rows) {
        if (kept.length >= limit)
            break;
        var charge = cost(row);
        if (charge > bytes)
            break;
        bytes -= charge;
        kept.push(row);
    }
    return kept;
}

function ownedFiles(rows) {
    var files = new Set();
    for (var row of rows) {
        files.add(row.raw);
        files.add(row.image);
    }
    return files;
}
