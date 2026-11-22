// Pure logic for the post-capture thumbnail. No QML types, files, clipboard or
// clock: callers pass in what they read, so node can test every rule. There is
// no .pragma line because node loads this file as a plain script.
//
// All sizes are logical (device independent) pixels. The thumbnail panel covers
// the work area of one screen, so a rectangle here is relative to the panel's
// top left corner.

var MAX_PREVIEWS = 5;
var GAP = 8;
var EDGE = 16;
var WIDTH = 240;
var HEIGHT = 160;
var DEFAULT_SECONDS = 5;
// How far a preview drifts to the right while it enters and leaves.
var DRIFT = 60;

// Reads windows.capture. `thumbnail` turns the preview off only when it is the
// boolean false. `thumbnailSeconds` is a whole number of seconds, 0 means the
// preview stays until it is closed, and anything else falls back to the default.
function settings(capture) {
    var enabled = true;
    var seconds = DEFAULT_SECONDS;
    if (capture) {
        if (typeof capture.thumbnail === "boolean")
            enabled = capture.thumbnail;
        var value = capture.thumbnailSeconds;
        if (typeof value === "number" && isFinite(value) && value >= 0)
            seconds = Math.floor(value);
    }
    return { enabled: enabled, seconds: seconds };
}

function appearance(capture) {
    var c = capture || {};
    return {
        scale: typeof c.thumbnailScale === "number" && isFinite(c.thumbnailScale) ? Math.max(0.5, Math.min(2, c.thumbnailScale)) : 1,
        corner: ["top-left", "top-right", "bottom-left", "bottom-right"].includes(c.thumbnailCorner) ? c.thumbnailCorner : "bottom-right",
        stack: c.thumbnailStacking !== false,
        cover: c.thumbnailLetterbox !== true
    };
}

// One preview. The width never exceeds the work area minus a gap on each side,
// and the height is a fifth of what is left after six gaps, so five previews
// always fit the work area.
function previewSize(work, scale) {
    var factor = Math.min(scale || 1, (work.width - 2 * EDGE) / WIDTH,
        (work.height - 2 * EDGE - GAP * (MAX_PREVIEWS - 1)) / (MAX_PREVIEWS * HEIGHT));
    return { width: Math.max(1, Math.round(WIDTH * factor)), height: Math.max(1, Math.floor(HEIGHT * factor)) };
}

// The rectangle of each preview in a stack of `count`. Index 0 is the oldest and
// sits highest; the newest (index count - 1) sits at the bottom right corner,
// `EDGE` away from both edges.
function stackRects(work, count, size, corner) {
    var rects = [];
    var left = corner && corner.endsWith("-left");
    var top = corner && corner.startsWith("top-");
    var x = left ? Math.max(0, Math.min(EDGE, work.width - size.width)) : Math.max(0, work.width - EDGE - size.width);
    for (var i = 0; i < count; i++) {
        var fromBottom = count - 1 - i;
        var y = top ? EDGE + fromBottom * (size.height + GAP) : work.height - EDGE - size.height - fromBottom * (size.height + GAP);
        rects.push({ x: x, y: y, width: size.width, height: size.height });
    }
    return rects;
}

// Which previews a new one pushes out. The limit is global, as in the classic
// tool: at most `max` previews exist at once, across all screens, and the oldest
// one goes first wherever it is. `screens` lists the screen name of every open
// preview, oldest first. Returns indices into `screens`. Where a preview is
// drawn is still decided per screen (stackRects).
function evictions(screens, max) {
    var limit = max === undefined ? MAX_PREVIEWS : max;
    var excess = screens.length + 1 - limit;
    var result = [];
    for (var i = 0; i < excess && i < screens.length; i++)
        result.push(i);
    return result;
}

function controls(width, height, labelWidth) {
    var scale = Math.min(2, Math.max(0.55, Math.min(width / WIDTH, height / HEIGHT)));
    var pad = Math.max(5, Math.round(10 * scale));
    return {
        pad: pad,
        corner: Math.max(18, Math.round(28 * scale)),
        icon: Math.max(9, Math.round(13 * scale)),
        buttonHeight: Math.max(18, Math.round(32 * scale)),
        buttonWidth: Math.max(1, Math.min(width - 2 * pad,
            Math.max(64, Math.round(110 * scale), Math.ceil((labelWidth || 0) + Math.max(18, Math.round(32 * scale)))))),
        gap: Math.max(4, Math.round(8 * scale)),
        font: Math.max(9, Math.round(13 * scale))
    };
}

function dismissOffset(dx, dy, towardLeft) {
    var outward = dx * (towardLeft ? -1 : 1);
    return outward > 6 && Math.abs(dx) >= Math.max(6, Math.abs(dy) * 0.35) ? outward : 0;
}

// Adds the time since the last tick, unless the preview is paused (the pointer
// is over it, or the panel is hidden). A timeout of 0 seconds never expires.
// Times are in milliseconds.
function advance(elapsed, delta, paused, seconds) {
    var next = paused ? elapsed : elapsed + Math.max(0, delta);
    return { elapsed: next, expired: seconds > 0 && next >= seconds * 1000 };
}

// Rounds to a whole device pixel. `scale` is the device pixel ratio.
function snap(value, scale) {
    var s = scale > 0 ? scale : 1;
    return Math.round(value * s) / s;
}

// Whether a press at `origin` has moved far enough, at `point`, to become a
// drag. Both points are in logical pixels of the card. `distance` is the
// system's { width, height } in device pixels (SM_CXDRAG and SM_CYDRAG), and
// `scale` is the device pixel ratio. Like the classic tool, the pointer starts
// a drag when it has moved the distance on either axis, and it never starts one
// without a press. Distances below one device pixel count as one.
function dragStarts(origin, point, distance, scale) {
    if (!origin || !point)
        return false;
    var s = scale > 0 ? scale : 1;
    var d = distance || {};
    var across = d.width >= 1 ? d.width : 1;
    var down = d.height >= 1 ? d.height : 1;
    return Math.abs(point.x - origin.x) * s >= across || Math.abs(point.y - origin.y) * s >= down;
}
