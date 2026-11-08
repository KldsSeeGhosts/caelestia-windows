// Pure logic for the shell screenshot editor (windows.capture.ui = "shell"). No
// QML types, files, clipboard or clock: callers pass in what they read, so node
// can test every rule. There is no .pragma line because node loads this file as
// a plain script.
//
// Coordinates. The editor works in one screen's logical (device independent)
// pixels. Rectangles are { x, y, width, height }. A stroke's coordinates are
// relative to the selection's top left corner, and sizes are logical pixels, so
// a stroke looks the same at any scale. The drawing rules (pencil width, arrow
// head, history) follow the classic capture tool's behaviour. The toolbar has no
// sizes of its own. The shell passes in the measured sizes of its Caelestia
// controls and the Tokens spacing, and this file places everything on whole
// device pixels.

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

// ---- placement -----------------------------------------------------------

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

// ---- device pixels --------------------------------------------------------

// Rounds to a whole device pixel. `scale` is the device pixel ratio (1.25 at 125%
// scaling). Text and one pixel edges stay sharp only on whole device pixels.
function snap(value, scale) {
    var s = scale > 0 ? scale : 1;
    return Math.round(value * s) / s;
}

// Rounds up to a whole device pixel, for a size that must not clip its content.
// The small subtraction keeps 35.000000001 device pixels from becoming 36.
function snapUp(value, scale) {
    var s = scale > 0 ? scale : 1;
    return Math.ceil(value * s - 1e-6) / s;
}

// Rounds a point to whole device pixels without leaving the work area.
function snapPoint(work, point, width, height, scale) {
    var right = work.x + work.width - width;
    var bottom = work.y + work.height - height;
    return {
        x: clamp(snap(point.x, scale), work.x, Math.max(work.x, right)),
        y: clamp(snap(point.y, scale), work.y, Math.max(work.y, bottom))
    };
}

// ---- toolbar ----------------------------------------------------------------

var CLEAR_ARM_MS = 2400;

// The shell passes the numbers that decide the toolbar's size, and none of them
// is fixed here:
//   metrics: { scale, padding, spacing, groupSpacing, separatorSpacing,
//              separatorInset, gap, margin } from Tokens. `gap` is the distance
//              from the selection and from the bar to the popover, `margin` the
//              distance kept from the work area's edge.
//   button, clear, copy: { width, height }, the implicit sizes of the controls.
//              Clear's size is its current one, so it grows when armed.

// Lays the bar's items out along one row. Positions are relative to the bar's top
// left corner and sit on whole device pixels. A size is rounded up so the control
// keeps room for its content.
// Options: { metrics, button, clear, copy, showOptions }
function barLayout(options) {
    var opts = options || {};
    var m = opts.metrics || {};
    var scale = m.scale;
    var button = opts.button || { width: 0, height: 0 };
    var clear = opts.clear || button;
    var copy = opts.copy || button;
    var padding = m.padding || 0;
    var spacing = m.spacing || 0;
    var tallest = Math.max(button.height, clear.height, copy.height);
    var height = snapUp(tallest + 2 * padding, scale);
    var items = [];
    var gap = 0;
    var position = padding;
    function add(id, width, h) {
        position += items.length === 0 ? 0 : gap;
        var w = snapUp(width, scale);
        var hh = snapUp(h, scale);
        items.push({ id: id, x: snap(position, scale), y: snap((height - hh) / 2, scale), width: w, height: hh });
        position = items[items.length - 1].x + w;
        gap = spacing;
    }
    function separator() {
        gap = m.separatorSpacing || 0;
        add("separator", 1 / (scale > 0 ? scale : 1), Math.max(0, button.height - 2 * (m.separatorInset || 0)));
        gap = m.separatorSpacing || 0;
    }
    for (var g = 0; g < groupCount(); g++) {
        if (g > 0)
            gap = m.groupSpacing || 0;
        toolsInGroup(g).forEach(function (tool) { add("tool:" + tool.id, button.width, button.height); });
    }
    if (opts.showOptions !== false) {
        separator();
        add("color", button.width, button.height);
    }
    separator();
    add("undo", button.width, button.height);
    add("redo", button.width, button.height);
    add("clear", clear.width, clear.height);
    separator();
    add("save", button.width, button.height);
    add("copy", copy.width, copy.height);
    add("close", button.width, button.height);
    return { width: snapUp(position + padding, scale), height: height, items: items };
}

function itemRect(layout, id) {
    for (var i = 0; i < layout.items.length; i++) {
        if (layout.items[i].id === id)
            return layout.items[i];
    }
    return null;
}

// Where the bar sits, on whole device pixels. `userPos` is where the user
// dragged it, or null. `size` is the measured { width, height } of the bar.
// `metrics` is as for barLayout.
function barPosition(work, region, size, userPos, metrics) {
    var m = metrics || {};
    var margin = m.margin || 0;
    var point;
    if (userPos) {
        point = clampPoint(work, userPos.x, userPos.y, size.width, size.height, margin);
    } else {
        var auto = controls(work, region, size.width, size.height, m.gap || 0, margin);
        point = { x: auto.x, y: auto.y };
    }
    return snapPoint(work, point, size.width, size.height, m.scale);
}

// The colour popover: a row of colour cells, a divider and a row of size
// segments. Rectangles are relative to the popover's top left corner.
// Options: { metrics, colors, cell, sizes, segment }
//   colors, sizes: how many of each.
//   cell: { width, height }, the measured size of one colour cell.
//   segment: { width, height }, the measured size of one size button. The
//   segments share the width of the colour row.
function inkPopover(options) {
    var opts = options || {};
    var m = opts.metrics || {};
    var scale = m.scale;
    var count = opts.colors === undefined ? COLORS.length : opts.colors;
    var sizeCount = opts.sizes === undefined ? SIZES.length : opts.sizes;
    var cell = opts.cell || { width: 0, height: 0 };
    var segment = opts.segment || { width: 0, height: 0 };
    var padding = m.padding || 0;
    var spacing = m.spacing || 0;
    var hairline = 1 / (scale > 0 ? scale : 1);
    var cellWidth = snapUp(cell.width, scale);
    var cellHeight = snapUp(cell.height, scale);
    var rowWidth = count > 0 ? count * cellWidth + (count - 1) * spacing : 0;
    // A size button never gets narrower than it needs, even if the colours are few.
    var contentWidth = snapUp(Math.max(rowWidth, sizeCount * segment.width + Math.max(0, sizeCount - 1) * spacing), scale);
    var colors = [];
    var slack = count > 1 ? (contentWidth - count * cellWidth) / (count - 1) : 0;
    for (var i = 0; i < count; i++)
        colors.push({ index: i, x: snap(padding + i * (cellWidth + (count > 1 ? slack : 0)), scale), y: padding, width: cellWidth, height: cellHeight });
    var line = snap(padding + cellHeight + (m.separatorSpacing || 0), scale);
    var trackY = snap(line + hairline + (m.separatorSpacing || 0), scale);
    var segmentWidth = sizeCount > 0 ? snapUp((contentWidth - (sizeCount - 1) * spacing) / sizeCount, scale) : 0;
    var segmentHeight = snapUp(segment.height, scale);
    var sizes = [];
    for (var j = 0; j < sizeCount; j++) {
        var entry = SIZES[j] || {};
        sizes.push({ index: j, size: entry.size, label: entry.label, x: snap(padding + j * (segmentWidth + spacing), scale), y: trackY, width: segmentWidth, height: segmentHeight });
    }
    var last = sizes.length > 0 ? sizes[sizes.length - 1] : null;
    return {
        width: snapUp(Math.max(contentWidth, last ? last.x + last.width - padding : 0) + 2 * padding, scale),
        height: snapUp(trackY + segmentHeight + padding, scale),
        colors: colors,
        divider: { x: padding, y: line, width: contentWidth, height: hairline },
        sizes: sizes
    };
}

// The popover opens above the bar when there is room, otherwise below it, and is
// centred on the button that opened it. It sits on whole device pixels.
function popoverPosition(work, bar, anchor, size, metrics) {
    var m = metrics || {};
    var margin = m.margin || 0;
    var gap = m.gap || 0;
    var centre = anchor.x + anchor.width / 2;
    var above = bar.y - gap - size.height;
    var y = above >= work.y + margin ? above : bar.y + bar.height + gap;
    var point = clampPoint(work, centre - size.width / 2, y, size.width, size.height, margin);
    return snapPoint(work, point, size.width, size.height, m.scale);
}

// The diameter of the colour button's dot, which also shows the line size. It
// runs from a third to two thirds of `available` (the button's height) across
// the sizes S to L, and is rounded to a whole device pixel.
function dotDiameter(size, available, scale) {
    var low = SIZES[0].size;
    var high = SIZES[SIZES.length - 1].size;
    var t = clamp((size - low) / (high - low), 0, 1);
    return snap(available * (1 / 3 + t / 3), scale);
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
