// Pure logic for the post-capture thumbnail. No QML types, files, clipboard or
// clock: callers pass in what they read, so node can test every rule. There is
// no .pragma line because node loads this file as a plain script.
//
// All sizes are logical (device independent) pixels. The thumbnail panel covers
// the work area of one screen, so a rectangle here is relative to the panel's
// top left corner. The numbers are the ones the classic capture tool uses
// (windows/capture/src/thumbnail.rs).

var MAX_PREVIEWS = 5;
var GAP = 12;
var WIDTH = 260;
var HEIGHT = 174;
var IMAGE_INSET = 20;
var DEFAULT_SECONDS = 6;
// How far a preview drifts to the right while it enters and leaves.
var DRIFT = 60;
var BUTTON = 30;
var BUTTON_GAP = 2;
var PILL_PADDING = 3;
// Distance from the card's bottom edge to the bottom of the button pill.
var PILL_BOTTOM = 9;

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

// One preview. The width never exceeds the work area minus a gap on each side,
// and the height is a fifth of what is left after six gaps, so five previews
// always fit the work area.
function previewSize(work) {
    var width = Math.min(WIDTH, Math.max(1, work.width - 2 * GAP));
    var height = Math.min(HEIGHT, Math.max(1, Math.floor((work.height - GAP * (MAX_PREVIEWS + 1)) / MAX_PREVIEWS)));
    return { width: width, height: height };
}

// The rectangle of each preview in a stack of `count`. Index 0 is the oldest and
// sits highest; the newest (index count - 1) sits at the bottom right corner,
// `GAP` away from both edges.
function stackRects(work, count, size) {
    var rects = [];
    var x = Math.max(0, work.width - GAP - size.width);
    for (var i = 0; i < count; i++) {
        var fromBottom = count - 1 - i;
        rects.push({ x: x, y: work.height - GAP - size.height - fromBottom * (size.height + GAP), width: size.width, height: size.height });
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

// The size the image is drawn at inside a card, in logical pixels. `image` is in
// physical pixels and `dpr` converts it. The image keeps its aspect, stays
// `inset` away from every card edge and is never scaled up. Without a known size
// the whole inner box is returned, for a caller that fits it by aspect.
function fitImage(card, image, dpr) {
    var boxWidth = Math.max(1, card.width - 2 * IMAGE_INSET);
    var boxHeight = Math.max(1, card.height - 2 * IMAGE_INSET);
    if (!image || !(image.width > 0) || !(image.height > 0))
        return { width: boxWidth, height: boxHeight, known: false };
    var scale = dpr > 0 ? dpr : 1;
    var naturalWidth = image.width / scale;
    var naturalHeight = image.height / scale;
    var factor = Math.min(boxWidth / naturalWidth, boxHeight / naturalHeight, 1);
    return {
        width: Math.max(1, Math.round(naturalWidth * factor)),
        height: Math.max(1, Math.round(naturalHeight * factor)),
        known: true
    };
}

// Adds the time since the last tick, unless the preview is paused (the pointer
// is over it, or the panel is hidden). A timeout of 0 seconds never expires.
// Times are in milliseconds.
function advance(elapsed, delta, paused, seconds) {
    var next = paused ? elapsed : elapsed + Math.max(0, delta);
    return { elapsed: next, expired: seconds > 0 && next >= seconds * 1000 };
}

// The hover buttons, in order. Save is offered only for a capture that exists
// only on the clipboard (nothing saved yet).
function actions(saved) {
    var list = ["copy"];
    if (!saved)
        list.push("save");
    list.push("reveal", "close");
    return list;
}

// Where the button pill sits in a card: centred horizontally, `PILL_BOTTOM` above
// the bottom edge. Buttons are BUTTON wide with BUTTON_GAP between them and
// PILL_PADDING around.
function pillRect(card, count) {
    var inner = count * BUTTON + (count - 1) * BUTTON_GAP;
    var width = inner + 2 * PILL_PADDING;
    var height = BUTTON + 2 * PILL_PADDING;
    return { x: Math.round((card.width - width) / 2), y: card.height - PILL_BOTTOM - height, width: width, height: height };
}
