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

// Select stands on its own. The other tools sit behind three group buttons:
// draw, shapes and annotations. The bar stays compact on small monitors, and
// each group opens as a small flyout.
var TOOLS = [
    { id: "select", key: 0x56, label: "Select", icon: "select", group: -1, freehand: false },
    { id: "pencil", key: 0x50, label: "Pencil", icon: "edit", group: 0, freehand: true },
    { id: "highlighter", key: 0x48, label: "Highlighter", icon: "ink_highlighter", group: 0, freehand: true },
    // Material Symbols has no plain diagonal line, so the dash is turned.
    { id: "line", key: 0x4C, label: "Line", icon: "remove", rotation: -45, group: 1, freehand: false },
    { id: "arrow", key: 0x41, label: "Arrow", icon: "north_east", group: 1, freehand: false },
    { id: "rect", key: 0x52, label: "Rectangle", icon: "crop_square", group: 1, freehand: false },
    { id: "circle", key: 0x43, label: "Circle", icon: "circle", group: 1, freehand: false },
    { id: "text", key: 0x54, label: "Text", icon: "text_fields", group: 2, freehand: false },
    { id: "step", key: 0x4E, label: "Step", icon: "filter_1", group: 2, freehand: false },
    { id: "blur", key: 0x42, label: "Blur", icon: "blur_on", group: 2, freehand: false }
];

var GROUPS = [
    { group: 0, label: "Draw tools" },
    { group: 1, label: "Shape tools" },
    { group: 2, label: "Annotation tools" }
];

var COLORS = ["#FF4444", "#FF8C00", "#FFD700", "#44FF88", "#44AAFF", "#CC44FF", "#FF44CC", "#FFFFFF", "#000000"];
var SIZES = [{ size: 2, label: "S" }, { size: 4, label: "M" }, { size: 7, label: "L" }];
var FILLS = [{ id: "outline" }, { id: "filled" }];

var DEFAULT_TOOL = "pencil";
var DEFAULT_COLOR = COLORS[0];
// The classic default. It is none of S, M and L, so none is highlighted at first.
var DEFAULT_SIZE = 3;

// Qt.Key_Escape, and the letters whose key codes equal their capital ASCII code.
var KEY_ESCAPE = 0x01000000;
var KEY_C = 0x43;
var KEY_F = 0x46;
var KEY_S = 0x53;
var KEY_BACKSPACE = 0x01000003;
var KEY_DELETE = 0x01000007;
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

function groupForTool(id) {
    var tool = toolById(id);
    return tool ? tool.group : -2;
}

function groupTool(group, activeTool) {
    var tools = toolsInGroup(group);
    var active = toolById(activeTool);
    if (active && active.group === group)
        return active;
    return tools.length > 0 ? tools[0] : null;
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
    if (key === KEY_BACKSPACE || key === KEY_DELETE)
        return { action: "delete" };
    if (key === KEY_F)
        return { action: "fill" };
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
    var done = opts.done;
    var tallest = Math.max(button.height, clear.height, copy.height, done?.height || 0);
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
    add("tool:select", button.width, button.height);
    for (var g = 0; g < groupCount(); g++) {
        gap = m.groupSpacing || 0;
        add("group:" + g, button.width, button.height);
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
    if (done)
        add("done", done.width, done.height);
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

// One tool group's flyout: a compact row of that group's tools. Rectangles are
// relative to the flyout and use the same measured icon button as the bar.
// Options: { metrics, group, button }
function toolFlyout(options) {
    var opts = options || {};
    var m = opts.metrics || {};
    var scale = m.scale;
    var button = opts.button || { width: 0, height: 0 };
    var padding = m.padding || 0;
    var spacing = m.spacing || 0;
    var tools = toolsInGroup(opts.group === undefined ? 0 : opts.group);
    var width = snapUp(button.width, scale);
    var height = snapUp(button.height, scale);
    var items = [];
    for (var i = 0; i < tools.length; i++) {
        items.push({
            id: "tool:" + tools[i].id, tool: tools[i].id,
            x: snap(padding + i * (width + spacing), scale), y: padding,
            width: width, height: height
        });
    }
    return {
        width: snapUp((tools.length > 0 ? tools.length * width + (tools.length - 1) * spacing : 0) + 2 * padding, scale),
        height: snapUp(height + 2 * padding, scale),
        items: items
    };
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
    var fillSegment = opts.fillSegment || segment;
    var padding = m.padding || 0;
    var spacing = m.spacing || 0;
    var separatorSpacing = m.separatorSpacing || 0;
    var hairline = 1 / (scale > 0 ? scale : 1);
    var cellWidth = snapUp(cell.width, scale);
    var cellHeight = snapUp(cell.height, scale);
    var rowWidth = count > 0 ? count * cellWidth + (count - 1) * spacing : 0;
    var sizeWidth = sizeCount > 0 ? sizeCount * segment.width + (sizeCount - 1) * spacing : 0;
    var fillWidth = FILLS.length * fillSegment.width + (FILLS.length - 1) * spacing;
    // No row gets narrower than its buttons need, even if the colours are few.
    var contentWidth = snapUp(Math.max(rowWidth, sizeWidth, fillWidth), scale);
    var colors = [];
    var slack = count > 1 ? (contentWidth - count * cellWidth) / (count - 1) : 0;
    for (var i = 0; i < count; i++)
        colors.push({ index: i, x: snap(padding + i * (cellWidth + (count > 1 ? slack : 0)), scale), y: padding, width: cellWidth, height: cellHeight });
    var line = snap(padding + cellHeight + separatorSpacing, scale);
    var trackY = snap(line + hairline + separatorSpacing, scale);
    var segmentWidth = sizeCount > 0 ? snapUp((contentWidth - (sizeCount - 1) * spacing) / sizeCount, scale) : 0;
    var segmentHeight = snapUp(segment.height, scale);
    var sizes = [];
    for (var j = 0; j < sizeCount; j++) {
        var entry = SIZES[j] || {};
        sizes.push({ index: j, size: entry.size, label: entry.label, x: snap(padding + j * (segmentWidth + spacing), scale), y: trackY, width: segmentWidth, height: segmentHeight });
    }
    var fillLine = snap(trackY + segmentHeight + separatorSpacing, scale);
    var fillY = snap(fillLine + hairline + separatorSpacing, scale);
    var fillWidthEach = snapUp((contentWidth - (FILLS.length - 1) * spacing) / FILLS.length, scale);
    var fillHeight = snapUp(fillSegment.height, scale);
    var fills = [];
    for (var f = 0; f < FILLS.length; f++) {
        fills.push({
            index: f, id: FILLS[f].id,
            x: snap(padding + f * (fillWidthEach + spacing), scale), y: fillY,
            width: fillWidthEach, height: fillHeight
        });
    }
    return {
        width: snapUp(contentWidth + 2 * padding, scale),
        height: snapUp(fillY + fillHeight + padding, scale),
        colors: colors,
        divider: { x: padding, y: line, width: contentWidth, height: hairline },
        fillDivider: { x: padding, y: fillLine, width: contentWidth, height: hairline },
        sizes: sizes,
        fills: fills
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

var NEXT_STROKE_ID = 1;

function noteId(stroke) {
    if (stroke && Number.isFinite(stroke.id))
        NEXT_STROKE_ID = Math.max(NEXT_STROKE_ID, stroke.id + 1);
    return stroke;
}

function copyStroke(stroke) {
    var id = Number.isFinite(stroke.id) && stroke.id > 0 ? stroke.id : NEXT_STROKE_ID++;
    var copy = {
        id: id, tool: stroke.tool, color: stroke.color, size: stroke.size,
        x1: stroke.x1, y1: stroke.y1, x2: stroke.x2, y2: stroke.y2,
        fill: stroke.fill === true, text: stroke.text || "", step: stroke.step || 0,
        points: (stroke.points || []).map(function (p) { return { x: p.x, y: p.y, w: p.w }; })
    };
    return noteId(copy);
}

function newStroke(tool, color, size, x, y, fill) {
    return { id: NEXT_STROKE_ID++, tool: tool, color: color, size: size, x1: x, y1: y, x2: x, y2: y, fill: fill === true, text: "", step: 0, points: [] };
}

function textStroke(color, size, x, y, text) {
    var stroke = newStroke("text", color, size, x, y, false);
    stroke.text = text;
    var b = textBounds(stroke);
    stroke.x2 = b.x + b.width;
    stroke.y2 = b.y + b.height;
    return stroke;
}

function stepStroke(color, size, x, y) {
    return newStroke("step", color, size, x, y, false);
}

function strokeBounds(stroke) {
    if (stroke.tool === "text")
        return textBounds(stroke);
    if (stroke.tool === "step") {
        var r = stepRadius(stroke.size);
        return rect(stroke.x1 - r, stroke.y1 - r, 2 * r, 2 * r);
    }
    if (stroke.tool === "circle") {
        var ellipse = ellipseGeometry(stroke);
        if (!ellipse)
            return rect(stroke.x1, stroke.y1, 0, 0);
        return rect(ellipse.cx - ellipse.rx, ellipse.cy - ellipse.ry, 2 * ellipse.rx, 2 * ellipse.ry);
    }
    if (isFreehand(stroke.tool)) {
        if (!stroke.points.length)
            return rect(stroke.x1, stroke.y1, 0, 0);
        var left = Infinity;
        var top = Infinity;
        var right = -Infinity;
        var bottom = -Infinity;
        stroke.points.forEach(function (p) {
            var half = p.w / 2;
            left = Math.min(left, p.x - half);
            top = Math.min(top, p.y - half);
            right = Math.max(right, p.x + half);
            bottom = Math.max(bottom, p.y + half);
        });
        return rect(left, top, right - left, bottom - top);
    }
    return rect(Math.min(stroke.x1, stroke.x2), Math.min(stroke.y1, stroke.y2),
        Math.abs(stroke.x2 - stroke.x1), Math.abs(stroke.y2 - stroke.y1));
}

function isFreehand(tool) {
    var entry = toolById(tool);
    return !!entry && entry.freehand;
}

// A draft is a stroke being drawn, with the pencil's speed state.
function startDraft(tool, color, size, x, y, fill) {
    var stroke = newStroke(tool, color, size, x, y, fill);
    var draft = { stroke: stroke, speed: size, lastX: x, lastY: y };
    if (isFreehand(tool))
        stroke.points.push({ x: x, y: y, w: size });
    return draft;
}

// Shift-constrained drawing. Rectangles, ellipses and redaction rectangles keep
// equal width and height in the dragged direction. Lines and arrows snap their
// angle to a multiple of 45 degrees while keeping the drag distance.
function constrainPoint(tool, x1, y1, x, y) {
    var dx = x - x1;
    var dy = y - y1;
    if (tool === "rect" || tool === "circle" || tool === "blur") {
        var side = Math.max(Math.abs(dx), Math.abs(dy));
        return { x: x1 + (dx < 0 ? -side : side), y: y1 + (dy < 0 ? -side : side) };
    }
    if (tool === "line" || tool === "arrow") {
        var length = Math.sqrt(dx * dx + dy * dy);
        if (length === 0)
            return { x: x, y: y };
        var angle = Math.atan2(dy, dx);
        var snapped = Math.round(angle / (Math.PI / 4)) * (Math.PI / 4);
        return { x: x1 + length * Math.cos(snapped), y: y1 + length * Math.sin(snapped) };
    }
    return { x: x, y: y };
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
function moveDraft(draft, x, y, scale, constrain) {
    var stroke = draft.stroke;
    if (!isFreehand(stroke.tool)) {
        var end = constrain ? constrainPoint(stroke.tool, stroke.x1, stroke.y1, x, y) : { x: x, y: y };
        stroke.x2 = end.x;
        stroke.y2 = end.y;
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
        var next = newStroke(done.tool, done.color, done.size, x, y, done.fill);
        next.points.push({ x: x, y: y, w: width });
        draft.stroke = next;
        return { changed: true, done: done };
    }
    return { changed: true, done: null };
}

// Nothing to commit for a shape that was never dragged: it would be an invisible
// entry on the undo stack. A freehand click is a dot and is kept. Text and step
// strokes are committed by their own click or editing path, never as empty shapes.
function isEmpty(stroke) {
    if (stroke.tool === "text")
        return !stroke.text;
    if (stroke.tool === "step")
        return false;
    if (isFreehand(stroke.tool))
        return stroke.points.length === 0;
    var dx = Math.abs(stroke.x2 - stroke.x1);
    var dy = Math.abs(stroke.y2 - stroke.y1);
    return dx < 1 && dy < 1;
}

// ---- annotation geometry, hit testing and editing -------------------------

function textPixelSize(size) {
    return size * 4 + 4;
}

// The logic cannot measure a font. This width is only for hit testing and the
// selection bounds, and errs wide enough for the shell's UI font.
function textWidth(text, size) {
    var length = String(text || "").length;
    return Math.max(1, length) * textPixelSize(size) * 0.62;
}

function textBounds(stroke) {
    var h = textPixelSize(stroke.size) * 1.25;
    return rect(stroke.x1, stroke.y1, textWidth(stroke.text, stroke.size), h);
}

function stepRadius(size) {
    return size * 2 + 8;
}

function contrastColor(color) {
    var hex = String(color || "").replace("#", "");
    if (hex.length !== 6)
        return "#FFFFFF";
    var r = parseInt(hex.slice(0, 2), 16) / 255;
    var g = parseInt(hex.slice(2, 4), 16) / 255;
    var b = parseInt(hex.slice(4, 6), 16) / 255;
    return (0.2126 * r + 0.7152 * g + 0.0722 * b) > 0.58 ? "#000000" : "#FFFFFF";
}

function translateStroke(stroke, dx, dy) {
    var copy = copyStroke(stroke);
    copy.x1 += dx;
    copy.y1 += dy;
    copy.x2 += dx;
    copy.y2 += dy;
    copy.points = copy.points.map(function (p) { return { x: p.x + dx, y: p.y + dy, w: p.w }; });
    return copy;
}

function distanceToSegment(x, y, ax, ay, bx, by) {
    var dx = bx - ax;
    var dy = by - ay;
    var lengthSquared = dx * dx + dy * dy;
    var t = lengthSquared === 0 ? 0 : clamp(((x - ax) * dx + (y - ay) * dy) / lengthSquared, 0, 1);
    var px = ax + t * dx;
    var py = ay + t * dy;
    return Math.hypot(x - px, y - py);
}

function hitFreehand(stroke, x, y) {
    if (!stroke.points.length)
        return false;
    var tolerance = Math.max(5, stroke.size / 2 + 3);
    if (stroke.points.length === 1)
        return Math.hypot(x - stroke.points[0].x, y - stroke.points[0].y) <= Math.max(tolerance, stroke.points[0].w / 2 + 3);
    for (var i = 1; i < stroke.points.length; i++) {
        var width = Math.max(stroke.points[i - 1].w, stroke.points[i].w);
        if (distanceToSegment(x, y, stroke.points[i - 1].x, stroke.points[i - 1].y, stroke.points[i].x, stroke.points[i].y) <= width / 2 + 4)
            return true;
    }
    return false;
}

function pointInPolygon(x, y, points) {
    var inside = false;
    for (var i = 0, j = points.length - 1; i < points.length; j = i++) {
        var xi = points[i].x;
        var yi = points[i].y;
        var xj = points[j].x;
        var yj = points[j].y;
        if ((yi > y) !== (yj > y) && x < (xj - xi) * (y - yi) / (yj - yi) + xi)
            inside = !inside;
    }
    return inside;
}

function hitShape(stroke, x, y) {
    var b = strokeBounds(stroke);
    var tolerance = Math.max(5, stroke.size / 2 + 3);
    if (stroke.tool === "blur")
        return contains(rect(b.x - 2, b.y - 2, b.width + 4, b.height + 4), x, y);
    if (stroke.tool === "rect") {
        var inside = contains(b, x, y);
        if (!inside)
            return false;
        if (stroke.fill)
            return true;
        return x - b.x <= tolerance || b.x + b.width - x <= tolerance || y - b.y <= tolerance || b.y + b.height - y <= tolerance;
    }
    if (stroke.tool === "circle") {
        var ellipse = ellipseGeometry(stroke);
        if (!ellipse)
            return false;
        var nx = (x - ellipse.cx) / Math.max(ellipse.rx, 1);
        var ny = (y - ellipse.cy) / Math.max(ellipse.ry, 1);
        var distance = Math.sqrt(nx * nx + ny * ny);
        if (stroke.fill)
            return distance <= 1.05;
        var edge = Math.min(0.35, tolerance / Math.max(Math.min(ellipse.rx, ellipse.ry), 1));
        return Math.abs(distance - 1) <= Math.max(edge, 0.08);
    }
    if (stroke.tool === "line")
        return distanceToSegment(x, y, stroke.x1, stroke.y1, stroke.x2, stroke.y2) <= tolerance;
    if (stroke.tool === "arrow") {
        if (distanceToSegment(x, y, stroke.x1, stroke.y1, stroke.x2, stroke.y2) <= tolerance)
            return true;
        var arrow = arrowGeometry(stroke);
        return !!arrow && pointInPolygon(x, y, arrow.triangle);
    }
    if (stroke.tool === "text")
        return contains(textBounds(stroke), x, y);
    if (stroke.tool === "step")
        return Math.hypot(x - stroke.x1, y - stroke.y1) <= stepRadius(stroke.size) + 3;
    return false;
}

function hitStroke(stroke, x, y) {
    if (!stroke)
        return false;
    return isFreehand(stroke.tool) ? hitFreehand(stroke, x, y) : hitShape(stroke, x, y);
}

// Topmost first: the newest stroke is the first one a click can hit.
function hitTest(strokes, x, y) {
    for (var i = strokes.length - 1; i >= 0; i--) {
        if (hitStroke(strokes[i], x, y))
            return i;
    }
    return -1;
}

function indexOfId(strokes, id) {
    for (var i = 0; i < strokes.length; i++) {
        if (strokes[i].id === id)
            return i;
    }
    return -1;
}

// A selection outline needs breathing room around line caps and text.
function selectionBounds(stroke) {
    if (!stroke)
        return null;
    var b = strokeBounds(stroke);
    var pad = stroke.tool === "text" || stroke.tool === "step" ? 3 : Math.max(3, stroke.size / 2 + 2);
    return rect(b.x - pad, b.y - pad, b.width + 2 * pad, b.height + 2 * pad);
}

// ---- history -------------------------------------------------------------

// Steps are ordinal annotations, not fixed labels. Every change renumbers them
// in drawing order, so undo, erase and delete never leave gaps.
function renumber(strokes) {
    var step = 0;
    return strokes.map(function (stroke) {
        var copy = copyStroke(stroke);
        if (copy.tool === "step")
            copy.step = ++step;
        return copy;
    });
}

function emptyHistory() {
    return { strokes: [], undo: [], redo: [] };
}

function scaleStrokes(strokes, ratio) {
    return renumber(strokes.map(function (stroke) {
        var copy = copyStroke(stroke);
        copy.size *= ratio;
        copy.x1 *= ratio;
        copy.y1 *= ratio;
        copy.x2 *= ratio;
        copy.y2 *= ratio;
        copy.points = copy.points.map(function (p) { return { x: p.x * ratio, y: p.y * ratio, w: p.w * ratio }; });
        return copy;
    }));
}

function canUndo(history) {
    return (history.undo || []).length > 0;
}

function canRedo(history) {
    return history.redo.length > 0;
}

// Replace the visible strokes without an undo entry. The move preview uses this;
// committing that move uses changeStrokes with the original array as `before`.
function replaceCurrent(history, strokes) {
    return { strokes: renumber(strokes), undo: history.undo || [], redo: history.redo || [] };
}

// Every undoable edit is one transition between two complete stroke arrays.
// That model covers add, delete, move and style changes with the same rules.
function changeStrokes(history, before, after) {
    return { strokes: renumber(after), undo: (history.undo || []).concat([before]), redo: [] };
}

function commit(history, stroke) {
    return changeStrokes(history, history.strokes, history.strokes.concat([stroke]));
}

function replaceStroke(history, index, stroke) {
    if (index < 0 || index >= history.strokes.length)
        return history;
    var next = history.strokes.slice();
    next[index] = stroke;
    return changeStrokes(history, history.strokes, next);
}

function removeStroke(history, index) {
    if (index < 0 || index >= history.strokes.length)
        return history;
    var next = history.strokes.slice();
    next.splice(index, 1);
    return changeStrokes(history, history.strokes, next);
}

function undo(history) {
    if (!canUndo(history))
        return history;
    var undoStack = history.undo.slice();
    var previous = undoStack.pop();
    return { strokes: previous, undo: undoStack, redo: history.redo.concat([history.strokes]) };
}

function redo(history) {
    if (!canRedo(history))
        return history;
    var redoStack = history.redo.slice();
    var next = redoStack.pop();
    return { strokes: next, undo: history.undo.concat([history.strokes]), redo: redoStack };
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
        if (stroke.fill)
            list.push({ kind: "polygon", points: rectPoints(stroke).slice(0, 4), color: color });
        else
            list.push({ kind: "polyline", points: rectPoints(stroke), width: stroke.size, color: color, alpha: 1, cap: "round" });
        break;
    case "circle":
        var ellipse = ellipseGeometry(stroke);
        if (ellipse)
            list.push({ kind: "ellipse", cx: ellipse.cx, cy: ellipse.cy, rx: ellipse.rx, ry: ellipse.ry, width: stroke.size, color: color, fill: stroke.fill === true });
        break;
    case "text":
        if (stroke.text)
            list.push({ kind: "text", x: stroke.x1, y: stroke.y1, text: stroke.text, pixelSize: textPixelSize(stroke.size), color: color });
        break;
    case "step":
        list.push({
            kind: "step", cx: stroke.x1, cy: stroke.y1, r: stepRadius(stroke.size), color: color,
            textColor: contrastColor(color), label: String(stroke.step || 1), pixelSize: stepRadius(stroke.size) * 1.05
        });
        break;
    case "blur":
        var box = strokeBounds(stroke);
        if (box.width >= 1 && box.height >= 1)
            list.push({ kind: "blur", x: box.x, y: box.y, width: box.width, height: box.height, pixelSize: 20 });
        break;
    }
    return list;
}
