// Pure logic for the shell screenshot editor (windows.capture.ui = "shell"). No
// QML types, files, clipboard or clock: callers pass in what they read, so node
// can test every rule. There is no .pragma line because node loads this file as
// a plain script.
//
// Coordinates. The editor works in one screen's logical (device independent)
// pixels. Rectangles are { x, y, width, height }. A stroke's coordinates are
// relative to the selection's top left corner, and sizes are logical pixels, so
// a stroke looks the same at any scale. The numbers come from the classic
// capture tool (windows/capture/src: toolbar.rs, placement.rs, strokes.rs,
// overlay.rs, theme.rs).

// ---- tools, colours and sizes -------------------------------------------

// Part 1 of the editor offers these six. Text, Blur, Step and Ruler follow later.
var TOOLS = [
    { id: "pencil", key: 0x50, label: "Pencil", icon: "edit", group: 0, freehand: true },
    { id: "highlighter", key: 0x48, label: "Highlighter", icon: "ink_highlighter", group: 0, freehand: true },
    // Material Symbols has no plain diagonal line, so the dash is turned.
    { id: "line", key: 0x4C, label: "Line", icon: "remove", rotation: -45, group: 1, freehand: false },
    { id: "arrow", key: 0x41, label: "Arrow", icon: "north_east", group: 1, freehand: false },
    { id: "rect", key: 0x52, label: "Rectangle", icon: "crop_square", group: 1, freehand: false },
    { id: "circle", key: 0x43, label: "Circle", icon: "circle", group: 1, freehand: false }
];

var COLORS = ["#FF4444", "#FF8C00", "#FFD700", "#44FF88", "#44AAFF", "#CC44FF", "#FF44CC", "#FFFFFF", "#000000"];
var SIZES = [{ size: 2, label: "S" }, { size: 4, label: "M" }, { size: 7, label: "L" }];

var DEFAULT_TOOL = "pencil";
var DEFAULT_COLOR = COLORS[0];
// The classic default. It is none of S, M and L, so none is highlighted at first.
var DEFAULT_SIZE = 3;

// Qt.Key_Escape, and the letters whose key codes equal their capital ASCII code.
var KEY_ESCAPE = 0x01000000;
var KEY_C = 0x43;
var KEY_S = 0x53;
var KEY_Y = 0x59;
var KEY_Z = 0x5A;

function toolById(id) {
    for (var i = 0; i < TOOLS.length; i++) {
        if (TOOLS[i].id === id)
            return TOOLS[i];
    }
    return null;
}

function toolsInGroup(group) {
    return TOOLS.filter(function (tool) { return tool.group === group; });
}

function groupCount() {
    return TOOLS.reduce(function (count, tool) { return Math.max(count, tool.group + 1); }, 0);
}

// What a key press does. `key` is a Qt key code. Plain letters pick a tool (C is
// the circle, Ctrl+C is Copy). Returns null for a key the editor ignores. Escape
// is not handled here because it first closes an open popover.
function shortcut(key, ctrl, shift, alt) {
    if (ctrl) {
        if (key === KEY_C)
            return { action: "copy" };
        if (key === KEY_S)
            return { action: "save" };
        if (key === KEY_Z)
            return { action: shift ? "redo" : "undo" };
        if (key === KEY_Y)
            return { action: "redo" };
        return null;
    }
    if (alt)
        return null;
    for (var i = 0; i < TOOLS.length; i++) {
        if (TOOLS[i].key === key)
            return { action: "tool", tool: TOOLS[i].id };
    }
    return null;
}

// ---- rectangles ----------------------------------------------------------

function rect(x, y, width, height) {
    return { x: x, y: y, width: width, height: height };
}

function contains(r, x, y) {
    return !!r && x >= r.x && y >= r.y && x < r.x + r.width && y < r.y + r.height;
}

function clamp(value, low, high) {
    return Math.min(Math.max(value, low), high);
}

// ---- placement (placement.rs) -------------------------------------------

// Clamps one axis to [low, high], using the work area's hard edge when the
// margin-preferred range is too small, and the low hard edge when the surface is
// larger than the work area.
function axis(value, low, high, hardLow, hardHigh) {
    if (high >= low)
        return clamp(value, low, high);
    if (hardHigh >= hardLow)
        return clamp(value, hardLow, hardHigh);
    return hardLow;
}

// Keeps a width by height surface inside `work`, preferring `margin` on each edge.
function clampPoint(work, x, y, width, height, margin) {
    var right = work.x + work.width;
    var bottom = work.y + work.height;
    return {
        x: axis(x, work.x + margin, right - margin - width, work.x, right - width),
        y: axis(y, work.y + margin, bottom - margin - height, work.y, bottom - height)
    };
}

// Places a width by height surface around `region` in `work`: below the
// selection when it fits, then above, and otherwise just inside the selection's
// bottom edge. Every branch is clamped to the work area, so a toolbar stays
// visible next to a full-screen selection.
function controls(work, region, width, height, gap, margin) {
    var right = work.x + work.width;
    var bottom = work.y + work.height;
    var regionBottom = region.y + region.height;
    var x = axis(region.x + region.width / 2 - width / 2, work.x + margin, right - margin - width, work.x, right - width);
    var below = regionBottom + gap;
    var above = region.y - gap - height;
    var y;
    var inside = false;
    if (below + height <= bottom - margin) {
        y = below;
    } else if (above >= work.y + margin) {
        y = above;
    } else {
        y = regionBottom - gap - height;
        inside = true;
    }
    y = axis(y, work.y + margin, bottom - margin - height, work.y, bottom - height);
    return { x: x, y: y, inside: inside };
}

// ---- toolbar (toolbar.rs) -----------------------------------------------

var BAR_HEIGHT = 44;
var BAR_PADDING = 6;
var BUTTON = 30;
var ITEM_GAP = 2;
var GROUP_GAP = 8;
var SEPARATOR_GAP = 6;
var SEPARATOR_HEIGHT = 18;
var TAIL_GAP = 4;
// The distance from the selection, and the distance kept from the screen edge.
var BAR_SELECTION_GAP = 10;
var BAR_MARGIN = 6;
// A labelled button is its text plus this much for the icon and padding.
var LABEL_EXTRA = 39;
var CLEAR_ARM_MS = 2400;

// Lays the bar's items out along one row. Positions are relative to the bar's top
// left corner. `copyWidth` and `clearWidth` are the widths of the Copy button and
// of the armed Clear button, which depend on measured text.
// Options: { showOptions, clearArmed, copyWidth, clearWidth }
function barLayout(options) {
    var opts = options || {};
    var items = [];
    var gap = 0;
    var position = BAR_PADDING;
    function add(id, width, height) {
        var before = items.length === 0 ? 0 : gap;
        position += before;
        items.push({ id: id, x: position, y: (BAR_HEIGHT - height) / 2, width: width, height: height });
        position += width;
        gap = ITEM_GAP;
    }
    function separator() {
        gap = SEPARATOR_GAP;
        add("separator", 1, SEPARATOR_HEIGHT);
        gap = SEPARATOR_GAP;
    }
    for (var g = 0; g < groupCount(); g++) {
        if (g > 0)
            gap = GROUP_GAP;
        toolsInGroup(g).forEach(function (tool) { add("tool:" + tool.id, BUTTON, BUTTON); });
    }
    if (opts.showOptions !== false) {
        separator();
        add("color", BUTTON, BUTTON);
    }
    separator();
    add("undo", BUTTON, BUTTON);
    add("redo", BUTTON, BUTTON);
    add("clear", opts.clearArmed ? (opts.clearWidth || BUTTON) : BUTTON, BUTTON);
    separator();
    add("save", BUTTON, BUTTON);
    gap = TAIL_GAP;
    add("copy", opts.copyWidth || BUTTON + LABEL_EXTRA, BUTTON);
    gap = TAIL_GAP;
    add("close", BUTTON, BUTTON);
    return { width: position + BAR_PADDING, height: BAR_HEIGHT, items: items };
}

function itemRect(layout, id) {
    for (var i = 0; i < layout.items.length; i++) {
        if (layout.items[i].id === id)
            return layout.items[i];
    }
    return null;
}

// Where the bar sits. `userPos` is where the user dragged it, or null. The bar's
// size comes from barLayout.
function barPosition(work, region, size, userPos) {
    if (userPos)
        return clampPoint(work, userPos.x, userPos.y, size.width, size.height, BAR_MARGIN);
    var auto = controls(work, region, size.width, size.height, BAR_SELECTION_GAP, BAR_MARGIN);
    return { x: auto.x, y: auto.y };
}

// The colour popover: nine colour dots, a divider and the S, M and L sizes.
// Rectangles are relative to the popover's top left corner.
var POPOVER_PADDING = 12;
var POPOVER_DOT = 20;
var POPOVER_DOT_GAP = 8;
var POPOVER_GAP = 8;

function inkPopover() {
    var pad = POPOVER_PADDING;
    var count = COLORS.length;
    var contentWidth = count * POPOVER_DOT + (count - 1) * POPOVER_DOT_GAP;
    var colors = COLORS.map(function (color, i) {
        return { index: i, x: pad + i * (POPOVER_DOT + POPOVER_DOT_GAP) - 2, y: pad - 2, width: POPOVER_DOT + 4, height: POPOVER_DOT + 4 };
    });
    var line = pad + POPOVER_DOT + 12;
    var track = rect(pad, line + 1 + 12, contentWidth, 32);
    var segment = (contentWidth - 4) / SIZES.length;
    var sizes = SIZES.map(function (entry, i) {
        return { index: i, size: entry.size, label: entry.label, x: track.x + 2 + i * segment, y: track.y + 2, width: segment, height: 28 };
    });
    return {
        width: contentWidth + pad * 2,
        height: track.y + track.height + pad,
        colors: colors,
        divider: rect(pad, line, contentWidth, 1),
        track: track,
        sizes: sizes
    };
}

// The popover opens above the bar when there is room, otherwise below it, and is
// centred on the button that opened it.
function popoverPosition(work, bar, anchor, size) {
    var centre = anchor.x + anchor.width / 2;
    var above = bar.y - POPOVER_GAP - size.height;
    var y = above >= work.y + BAR_MARGIN ? above : bar.y + bar.height + POPOVER_GAP;
    return clampPoint(work, centre - size.width / 2, y, size.width, size.height, BAR_MARGIN);
}

// The diameter of the colour button's dot, which also shows the line size.
function dotDiameter(size) {
    return clamp(8 + 1.3 * size, 9, 19);
}

// Clear needs two presses within CLEAR_ARM_MS. The first arms it, the second
// clears. Moving off the button, choosing a tool or the timeout disarms it.
function clearPress(armed) {
    return armed ? { armed: false, clear: true } : { armed: true, clear: false };
}

// ---- strokes (strokes.rs) -----------------------------------------------

var ARROW_HALF_ANGLE = Math.PI / 5;
var HIGHLIGHTER_ALPHA = 0.35;
var HIGHLIGHTER_WIDTH = 6;
// A freehand stroke is cut into two at this many points, as the classic tool does.
var MAX_POINTS = 2000;
// Pencil samples closer than this many physical pixels are skipped.
var MIN_SAMPLE = 0.5;
// Pencil widths are grouped in steps of this many logical pixels, so a long
// stroke becomes a few polylines.
var WIDTH_STEP = 0.5;

function newStroke(tool, color, size, x, y) {
    return { tool: tool, color: color, size: size, x1: x, y1: y, x2: x, y2: y, points: [] };
}

function strokeBounds(stroke) {
    return rect(Math.min(stroke.x1, stroke.x2), Math.min(stroke.y1, stroke.y2),
        Math.abs(stroke.x2 - stroke.x1), Math.abs(stroke.y2 - stroke.y1));
}

function isFreehand(tool) {
    var entry = toolById(tool);
    return !!entry && entry.freehand;
}

// A draft is a stroke being drawn, with the pencil's speed state.
function startDraft(tool, color, size, x, y) {
    var stroke = newStroke(tool, color, size, x, y);
    var draft = { stroke: stroke, speed: size, lastX: x, lastY: y };
    if (isFreehand(tool))
        stroke.points.push({ x: x, y: y, w: size });
    return draft;
}

// The pencil is thinner when it moves fast: the width falls from 1.6 times the
// size to 0.35 times (at least 1) as the smoothed speed rises to 20 px per sample.
function pencilWidth(size, speed) {
    var minWidth = Math.max(size * 0.35, 1);
    var maxWidth = size * 1.6;
    var t = Math.min(speed, 20) / 20;
    return maxWidth - t * (maxWidth - minWidth);
}

// Moves the pointer. `scale` is the device pixel ratio, which is only used to
// skip samples closer than half a physical pixel. Returns { changed, done }.
// `done` is a finished stroke the caller must commit, when the draft reached
// MAX_POINTS and carries on in a new stroke from its last point.
function moveDraft(draft, x, y, scale) {
    var stroke = draft.stroke;
    if (!isFreehand(stroke.tool)) {
        stroke.x2 = x;
        stroke.y2 = y;
        return { changed: true, done: null };
    }
    var dx = x - draft.lastX;
    var dy = y - draft.lastY;
    var distance = Math.sqrt(dx * dx + dy * dy);
    if (distance * (scale > 0 ? scale : 1) < MIN_SAMPLE)
        return { changed: false, done: null };
    var width = stroke.size;
    if (stroke.tool === "pencil") {
        draft.speed = draft.speed * 0.7 + distance * 0.3;
        width = pencilWidth(stroke.size, draft.speed);
    }
    draft.lastX = x;
    draft.lastY = y;
    stroke.points.push({ x: x, y: y, w: width });
    if (stroke.points.length > MAX_POINTS) {
        var done = stroke;
        var next = newStroke(done.tool, done.color, done.size, x, y);
        next.points.push({ x: x, y: y, w: width });
        draft.stroke = next;
        return { changed: true, done: done };
    }
    return { changed: true, done: null };
}

// Nothing to commit for a shape that was never dragged: it would be an invisible
// entry on the undo stack. A freehand click is a dot and is kept.
function isEmpty(stroke) {
    if (isFreehand(stroke.tool))
        return stroke.points.length === 0;
    var dx = Math.abs(stroke.x2 - stroke.x1);
    var dy = Math.abs(stroke.y2 - stroke.y1);
    return dx < 1 && dy < 1;
}

// ---- history -------------------------------------------------------------

function emptyHistory() {
    return { strokes: [], redo: [] };
}

function canUndo(history) {
    return history.strokes.length > 0;
}

function canRedo(history) {
    return history.redo.length > 0;
}

// Each function returns a new object, so a QML binding on the result updates.
function commit(history, stroke) {
    return { strokes: history.strokes.concat([stroke]), redo: [] };
}

function undo(history) {
    if (!canUndo(history))
        return history;
    return { strokes: history.strokes.slice(0, -1), redo: history.redo.concat([history.strokes[history.strokes.length - 1]]) };
}

function redo(history) {
    if (!canRedo(history))
        return history;
    return { strokes: history.strokes.concat([history.redo[history.redo.length - 1]]), redo: history.redo.slice(0, -1) };
}

// Clear removes everything and, as in the classic tool, cannot be undone.
function clearAll() {
    return emptyHistory();
}

// ---- geometry ------------------------------------------------------------

function mid(a, b) {
    return { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 };
}

// A freehand path through the samples: it starts at the first, curves through
// the midpoints of consecutive samples (each sample is the control point of a
// quadratic curve) and ends at the last sample. Returns the flattened vertices
// and, for every segment between two vertices, the width of the sample that
// ends it.
function smoothPath(points) {
    var count = points.length;
    var vertices = [];
    var widths = [];
    if (count === 0)
        return { vertices: vertices, widths: widths };
    vertices.push({ x: points[0].x, y: points[0].y });
    var start = vertices[0];
    for (var j = 1; j < count - 1; j++) {
        var control = points[j];
        var end = mid(points[j], points[j + 1]);
        var span = Math.hypot(control.x - start.x, control.y - start.y) + Math.hypot(end.x - control.x, end.y - control.y);
        var steps = clamp(Math.ceil(span / 3), 1, 8);
        for (var s = 1; s <= steps; s++) {
            var t = s / steps;
            var u = 1 - t;
            vertices.push({
                x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
                y: u * u * start.y + 2 * u * t * control.y + t * t * end.y
            });
            widths.push(points[j + 1].w);
        }
        start = end;
    }
    if (count > 1) {
        var last = points[count - 1];
        vertices.push({ x: last.x, y: last.y });
        widths.push(last.w);
    }
    return { vertices: vertices, widths: widths };
}

// Polylines of equal (stepped) width that together draw the pencil stroke. Runs
// share their joining vertex, and the round caps hide the seam.
function widthRuns(path) {
    var runs = [];
    for (var i = 0; i < path.widths.length; i++) {
        var width = Math.round(path.widths[i] / WIDTH_STEP) * WIDTH_STEP;
        var run = runs.length > 0 ? runs[runs.length - 1] : null;
        if (!run || run.width !== width) {
            run = { width: width, points: [path.vertices[i]] };
            runs.push(run);
        }
        run.points.push(path.vertices[i + 1]);
    }
    return runs;
}

// The arrow's shaft end and head triangle for a stroke from (x1, y1) to
// (x2, y2). The head is max(size x 3.5, 10) long with a half angle of pi/5. An
// arrow shorter than 2 px draws nothing.
function arrowGeometry(stroke) {
    var dx = stroke.x2 - stroke.x1;
    var dy = stroke.y2 - stroke.y1;
    var length = Math.sqrt(dx * dx + dy * dy);
    if (length < 2)
        return null;
    var angle = Math.atan2(dy, dx);
    var head = Math.max(stroke.size * 3.5, 10);
    var base = Math.max(1 - head / length, 0);
    return {
        head: head,
        shaftEnd: { x: stroke.x1 + dx * base, y: stroke.y1 + dy * base },
        triangle: [
            { x: stroke.x2, y: stroke.y2 },
            { x: stroke.x2 - head * Math.cos(angle - ARROW_HALF_ANGLE), y: stroke.y2 - head * Math.sin(angle - ARROW_HALF_ANGLE) },
            { x: stroke.x2 - head * Math.cos(angle + ARROW_HALF_ANGLE), y: stroke.y2 - head * Math.sin(angle + ARROW_HALF_ANGLE) }
        ]
    };
}

// The ellipse a circle stroke draws: centred where the drag began, with the drag
// distance as its radii (at least 1). Null while it has no extent.
function ellipseGeometry(stroke) {
    var rx = Math.abs(stroke.x2 - stroke.x1);
    var ry = Math.abs(stroke.y2 - stroke.y1);
    if (!(rx > 0 || ry > 0))
        return null;
    return { cx: stroke.x1, cy: stroke.y1, rx: Math.max(rx, 1), ry: Math.max(ry, 1) };
}

function rectPoints(stroke) {
    var b = strokeBounds(stroke);
    return [
        { x: b.x, y: b.y }, { x: b.x + b.width, y: b.y },
        { x: b.x + b.width, y: b.y + b.height }, { x: b.x, y: b.y + b.height },
        { x: b.x, y: b.y }
    ];
}

// The drawing instructions for one stroke, in painting order. The renderer
// (Annotations.qml) turns each into a QtQuick Shape:
//   polyline { points, width, color, alpha, cap: "round" | "square" }
//   polygon  { points, color }
//   ellipse  { cx, cy, rx, ry, width, color }
//   dot      { cx, cy, r, color }
function primitives(stroke) {
    var color = stroke.color;
    var list = [];
    switch (stroke.tool) {
    case "pencil":
        if (stroke.points.length === 1) {
            list.push({ kind: "dot", cx: stroke.points[0].x, cy: stroke.points[0].y, r: stroke.points[0].w / 2, color: color });
        } else if (stroke.points.length > 1) {
            widthRuns(smoothPath(stroke.points)).forEach(function (run) {
                list.push({ kind: "polyline", points: run.points, width: run.width, color: color, alpha: 1, cap: "round" });
            });
        }
        break;
    case "highlighter":
        if (stroke.points.length > 1) {
            list.push({
                kind: "polyline", points: smoothPath(stroke.points).vertices, width: stroke.size * HIGHLIGHTER_WIDTH,
                color: color, alpha: HIGHLIGHTER_ALPHA, cap: "square"
            });
        }
        break;
    case "line":
        list.push({ kind: "polyline", points: [{ x: stroke.x1, y: stroke.y1 }, { x: stroke.x2, y: stroke.y2 }], width: stroke.size, color: color, alpha: 1, cap: "round" });
        break;
    case "arrow":
        var arrow = arrowGeometry(stroke);
        if (arrow) {
            if (arrow.shaftEnd.x !== stroke.x1 || arrow.shaftEnd.y !== stroke.y1) {
                list.push({ kind: "polyline", points: [{ x: stroke.x1, y: stroke.y1 }, arrow.shaftEnd], width: stroke.size, color: color, alpha: 1, cap: "round" });
            }
            list.push({ kind: "polygon", points: arrow.triangle, color: color });
        }
        break;
    case "rect":
        list.push({ kind: "polyline", points: rectPoints(stroke), width: stroke.size, color: color, alpha: 1, cap: "round" });
        break;
    case "circle":
        var ellipse = ellipseGeometry(stroke);
        if (ellipse)
            list.push({ kind: "ellipse", cx: ellipse.cx, cy: ellipse.cy, rx: ellipse.rx, ry: ellipse.ry, width: stroke.size, color: color });
        break;
    }
    return list;
}
