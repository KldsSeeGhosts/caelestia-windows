// Pure logic for the shell screenshot picker. No QML types, clipboard, files or
// clock: callers pass in what they read, so node can test every rule. There is
// no .pragma line because node loads this file as a plain script.
//
// Coordinates. A picker window covers one screen and works in that screen's
// logical (device independent) pixels with the origin at its top left corner.
// Hyprland.windowStack() reports window pieces in Qt global logical
// coordinates, so a screen's own origin is subtracted before hit testing.

var DRAG_THRESHOLD = 4;
var DEFAULT_STEM = "annotate-%Y-%m-%d_%H-%M-%S";

function rect(x, y, width, height) {
    return { x: x, y: y, width: width, height: height };
}

function contains(r, x, y) {
    return !!r && x >= r.x && y >= r.y && x < r.x + r.width && y < r.y + r.height;
}

function clamp(value, low, high) {
    return Math.min(Math.max(value, low), high);
}

// The rectangle spanned by two corners, in any order, kept inside the screen.
function spanRect(x1, y1, x2, y2, bounds) {
    var ax = clamp(Math.min(x1, x2), 0, bounds.width);
    var ay = clamp(Math.min(y1, y2), 0, bounds.height);
    var bx = clamp(Math.max(x1, x2), 0, bounds.width);
    var by = clamp(Math.max(y1, y2), 0, bounds.height);
    return rect(ax, ay, bx - ax, by - ay);
}

// A press that never leaves the dead zone is a click on the hovered target,
// not a drag, so a shaky click does not select a one pixel region.
function isDrag(startX, startY, x, y, threshold) {
    var limit = threshold === undefined ? DRAG_THRESHOLD : threshold;
    return Math.abs(x - startX) >= limit || Math.abs(y - startY) >= limit;
}

function wholeScreen(screen) {
    return rect(0, 0, screen.width, screen.height);
}

// The window pieces of one screen, topmost first, in that screen's own
// coordinates. `stack` is the sequence wrapper from Hyprland.windowStack(), so
// it is copied with Array.from and never tested with Array.isArray. Entries are
// { id, title, rects: [{ screen, rect }] }; only pieces whose `screen` is this
// screen's name count, and each is clipped to the screen.
function screenWindows(stack, screen) {
    var result = [];
    if (!stack)
        return result;
    var entries = Array.from(stack);
    for (var i = 0; i < entries.length; i++) {
        var entry = entries[i];
        if (!entry || !entry.rects)
            continue;
        var pieces = Array.from(entry.rects);
        for (var j = 0; j < pieces.length; j++) {
            var piece = pieces[j];
            if (!piece || piece.screen !== screen.name || !piece.rect)
                continue;
            var local = spanRect(piece.rect.x - screen.x, piece.rect.y - screen.y,
                piece.rect.x - screen.x + piece.rect.width, piece.rect.y - screen.y + piece.rect.height, screen);
            if (local.width < 1 || local.height < 1)
                continue;
            result.push({ id: String(entry.id), title: String(entry.title || ""), rect: local });
        }
    }
    return result;
}

// Topmost window under the point, or null.
function hitWindow(windows, x, y) {
    for (var i = 0; i < windows.length; i++) {
        if (contains(windows[i].rect, x, y))
            return windows[i];
    }
    return null;
}

// What a click at (x, y) would select: the topmost window there, otherwise the
// whole monitor.
function targetAt(windows, x, y, screen) {
    var hit = hitWindow(windows, x, y);
    if (hit)
        return { kind: "window", id: hit.id, title: hit.title, rect: hit.rect };
    return { kind: "monitor", id: "", title: "", rect: wholeScreen(screen) };
}

// The integer logical rectangle that is saved. It never grows past the
// selection (round the origin up, the size down) and stays on the screen.
// Returns null for an empty selection.
function logicalExport(sel, screen) {
    var x = Math.ceil(sel.x);
    var y = Math.ceil(sel.y);
    var right = Math.min(Math.floor(sel.x + sel.width), screen.width);
    var bottom = Math.min(Math.floor(sel.y + sel.height), screen.height);
    var width = right - x;
    var height = bottom - y;
    if (!(width >= 1 && height >= 1))
        return null;
    return rect(x, y, width, height);
}

// Qt's qRound for the non-negative values used here: halves round up.
function qRound(value) {
    return Math.floor(value + 0.5);
}

// CUtils.saveItem multiplies the rectangle by the window's device pixel ratio
// (unless the ratio is 1) and calls QRectF::toRect. Qt 6.11.2 qrect.h rounds
// the origin first, then rounds the size after adding half of the origin's
// rounding error:
//   nx = round(x); nw = round(w + (x - nx) / 2)
// so the far edge stays within a pixel of the exact value. This is the same
// arithmetic, so a test can check the pixels that are cut out.
function physicalExport(logical, dpr) {
    if (Math.abs(dpr - 1) < 1e-9)
        return rect(logical.x, logical.y, logical.width, logical.height);
    var x = logical.x * dpr;
    var y = logical.y * dpr;
    var nx = qRound(x);
    var ny = qRound(y);
    return rect(nx, ny, qRound(logical.width * dpr + (x - nx) / 2), qRound(logical.height * dpr + (y - ny) / 2));
}

// The size of the grabbed item image: the item size times the ratio, rounded.
function grabSize(screen, dpr) {
    return { width: Math.round(screen.width * dpr), height: Math.round(screen.height * dpr) };
}

function intersect(a, b) {
    var left = Math.max(a.x, b.x);
    var top = Math.max(a.y, b.y);
    var right = Math.min(a.x + a.width, b.x + b.width);
    var bottom = Math.min(a.y + a.height, b.y + b.height);
    return rect(left, top, Math.max(0, right - left), Math.max(0, bottom - top));
}

// Everything the saver needs. `physical` is the native crop Qt computes from the
// logical rectangle. At a fractional scale its far edge can land a pixel past the
// grabbed image. CUtils.saveItem clips the crop to the image before cutting, so
// `crop` (the intersection with the image) is exactly what is saved, and no
// column or row that lies inside both the selection and the image is lost.
// The selection is valid when that intersection is not empty.
function exportPlan(sel, screen, dpr) {
    var logical = logicalExport(sel, screen);
    if (!logical)
        return { valid: false, logical: null, physical: null, crop: null };
    var image = grabSize(screen, dpr);
    var physical = physicalExport(logical, dpr);
    var crop = intersect(physical, rect(0, 0, image.width, image.height));
    return { valid: crop.width >= 1 && crop.height >= 1, logical: logical, physical: physical, crop: crop, image: image };
}

// The tint appears only when every screen has a frozen frame, so a partial
// freeze is never visible. `ready` maps screen name to hasContent.
function allReady(ready, names) {
    if (!names || names.length === 0)
        return false;
    for (var i = 0; i < names.length; i++) {
        if (!ready || ready[names[i]] !== true)
            return false;
    }
    return true;
}

// Whether two screen name lists describe the same monitors, in any order.
function sameNames(a, b) {
    var left = Array.from(a || []).slice().sort();
    var right = Array.from(b || []).slice().sort();
    if (left.length !== right.length)
        return false;
    for (var i = 0; i < left.length; i++) {
        if (left[i] !== right[i])
            return false;
    }
    return true;
}

function pad(value, digits) {
    var text = String(value);
    while (text.length < digits)
        text = "0" + text;
    return text;
}

// File name stem. The format is the current tool's default; invalid file name
// characters become "_" and an empty result falls back to the default.
function fileStem(date, format) {
    var pattern = format && String(format).trim() ? String(format).trim() : DEFAULT_STEM;
    var stem = pattern
        .replace(/%Y/g, pad(date.getFullYear(), 4))
        .replace(/%m/g, pad(date.getMonth() + 1, 2))
        .replace(/%d/g, pad(date.getDate(), 2))
        .replace(/%H/g, pad(date.getHours(), 2))
        .replace(/%M/g, pad(date.getMinutes(), 2))
        .replace(/%S/g, pad(date.getSeconds(), 2))
        .replace(/[\\\/:*?"<>|\r\n\0]/g, "_")
        .trim()
        .replace(/\.+$/, "");
    return stem.length > 0 ? stem : fileStem(date, "");
}

// "name.png", then "name (2).png", "name (3).png" and so on, as the current
// tool numbers its files. `exists` tells whether a full path is taken.
function uniquePath(dir, stem, exists) {
    var base = dir.replace(/\\/g, "/").replace(/\/+$/, "");
    var path = base + "/" + stem + ".png";
    var n = 2;
    while (exists(path)) {
        path = base + "/" + stem + " (" + n + ").png";
        n++;
        if (n > 10000)
            break;
    }
    return path;
}

// The IPC function and shortcut names mean the same thing on Windows as on
// upstream, except that the picker always freezes the screen first: a
// Windows ScreencopyView never starts capturing while hidden, so there is no
// separate live mode.
function pickerOptions(name) {
    var table = {
        open: { freeze: false, clipboardOnly: false },
        openFreeze: { freeze: true, clipboardOnly: false },
        openClip: { freeze: false, clipboardOnly: true },
        openFreezeClip: { freeze: true, clipboardOnly: true }
    };
    return table[name] || null;
}

// "classic" starts the Rust capture tool and is the default. "shell" opens the
// QML picker. A legacy glazier.exe override has no shell integration, so it
// always stays on the classic path. `executable` is the resolved override or
// bundled helper path, empty when none is available.
function captureRoute(setting, executable) {
    if (setting !== "shell")
        return "classic";
    var path = String(executable || "");
    if (path.length > 0 && !/(?:^|[\\\/])caelestia-capture\.exe$/i.test(path))
        return "classic";
    return "shell";
}
