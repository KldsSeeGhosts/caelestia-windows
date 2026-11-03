const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const path = require("node:path");
const logic = {};
vm.runInNewContext(fs.readFileSync(path.join(__dirname, "../shell/adapters/modules/drawers/WindowsHover.js"), "utf8"), logic);
let assertions = 0;
function equal(actual, expected, label) {
    assertions++;
    assert.deepEqual(JSON.parse(JSON.stringify(actual)), expected, label);
}
const leftDisplay = { x: -3840, y: 0, width: 2194, height: 1234, devicePixelRatio: 1.75 };
const rightDisplay = { x: 0, y: 0, width: 2560, height: 1440, devicePixelRatio: 1.5 };
equal(logic.intervals(leftDisplay, [leftDisplay, rightDisplay], "right"), [{start: 0, end: 1234}], "mixed-DPR left display");
equal(logic.intervals(leftDisplay, [leftDisplay, rightDisplay], "bottom"), [], "left display bottom");
equal(logic.intervals(rightDisplay, [leftDisplay, rightDisplay], "right"), [], "right display outer edge");
equal(logic.intervals(rightDisplay, [rightDisplay], "right"), [], "single monitor");
equal(logic.intervals(rightDisplay, [rightDisplay], "bottom"), [], "single monitor bottom");

const upper = { x: -1200, y: -1800, width: 800, height: 1200, devicePixelRatio: 1.5 };
const lower = { x: -1200, y: 0, width: 960, height: 720, devicePixelRatio: 1.25 };
equal(logic.intervals(upper, [upper, lower], "bottom"), [{start: 0, end: 800}], "vertical stack");
equal(logic.intervals(upper, [upper, lower], "right"), [], "stack outer edge");
equal(logic.intervals(lower, [upper, lower], "bottom"), [], "lower outer edge");
equal(logic.intervals(upper, [upper, {x: 0, y: 0, width: 100, height: 100}], "bottom"), [], "corner contact");
equal(logic.intervals(leftDisplay, [leftDisplay, {...rightDisplay, x: 10}], "right"), [], "gap");
const partialRight = {...rightDisplay, y: 175, height: 400}; // physical y 175..775
equal(logic.intervals(leftDisplay, [leftDisplay, partialRight], "right"), [{start: 100, end: 442}], "partial right, inward rounding");
const partialBottom = {x: -900, y: 0, width: 240, height: 720, devicePixelRatio: 1.25};
equal(logic.intervals(upper, [upper, partialBottom], "bottom"), [{start: 200, end: 400}], "partial bottom");
equal(logic.extraWidth(undefined), 12, "default");
equal(logic.extraWidth(-1), 0, "disabled");
equal(logic.extraWidth(100), 48, "cap");
equal(logic.extraWidth("12"), 12, "invalid value");

function rects(screen, neighbours, border, osdY = 100, osdHeight = 600, utilX = 1600, utilWidth = 594) {
    return logic.triggerRects(screen, [screen, ...neighbours], screen.width, screen.height,
        border, 2, 25, osdY, osdHeight, utilX, utilWidth, 12, true, true);
}
function maskContains(rectangles, x, y) {
    return rectangles.some(r => x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height);
}
// Check every point around the actual rectangle boundary, with independent
// mask interpretation and the production predicate, for both displays.
function agree(rectangles, xStart, xEnd, yStart, yEnd, label) {
    for (let x = xStart; x <= xEnd; x++)
        for (let y = yStart; y <= yEnd; y++)
            equal(logic.contains(rectangles, x, y), maskContains(rectangles, x, y), label);
}
for (const border of [10, 0, 30]) {
    const zones = rects(leftDisplay, [rightDisplay], border);
    const left = 2194 - Math.max(2, border) - 12;
    equal(zones.osd[0].x, left, `OSD baseline ${border}`);
    equal(logic.contains(zones.osd, left, 200), true, "OSD starts at mask");
    equal(logic.contains(zones.osd, left - 1, 200), false, "OSD outside mask");
    equal(zones.utilities[0].x, left, `corner baseline ${border}`);
    equal(logic.contains(zones.utilities, left, 1233), true, "corner starts at mask");
    equal(logic.contains(zones.utilities, left - 1, 1233), false, "corner outside mask");
    agree(zones.osd, left - 1, left + 1, 73, 78, "OSD mask/hover");
    agree(zones.utilities, left - 1, left + 1, 1231, 1234, "corner mask/hover");
}
const partial = rects(leftDisplay, [partialRight], 10);
equal(logic.contains(partial.osd, 2176, 100), true, "partial right shared");
equal(logic.contains(partial.osd, 2176, 99), false, "partial right outer");
equal(logic.contains(partial.osd, 2176, 442), false, "partial right end");
equal(partial.utilities.length, 0, "partial right does not reach corner");
const bottomZones = rects(upper, [partialBottom], 10, 100, 200, 100, 600);
equal(logic.contains(bottomZones.utilities, 200, 1153), true, "partial bottom shared");
equal(logic.contains(bottomZones.utilities, 199, 1153), false, "partial bottom outer");
equal(logic.contains(bottomZones.utilities, 400, 1153), false, "partial bottom end");
agree(bottomZones.utilities, 198, 201, 1152, 1155, "bottom corner mask/hover");
equal(rects(leftDisplay, [], 10).osd.length, 0, "no extra region on outer edge");
console.log(`Windows hover adjacency and zones: PASS ${assertions}`);
