const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const path = require("node:path");

const logic = {};
vm.runInNewContext(fs.readFileSync(path.join(__dirname, "WindowsHover.js"), "utf8"), logic);

// QScreen reports native origins but logical sizes on Windows.
const dell = { x: -3840, y: 0, width: 2194, height: 1234, devicePixelRatio: 1.75 };
const msi = { x: 0, y: 0, width: 2560, height: 1440, devicePixelRatio: 1.5 };
assert.equal(logic.adjacent(dell, [dell, msi], "right"), true);
assert.equal(logic.adjacent(dell, [dell, msi], "bottom"), false);
assert.equal(logic.adjacent(msi, [dell, msi], "right"), false);
assert.equal(logic.adjacent(msi, [msi], "right"), false);
assert.equal(logic.adjacent(msi, [msi], "bottom"), false);

const upper = { x: -1200, y: -1800, width: 800, height: 1200, devicePixelRatio: 1.5 };
const lower = { x: -1200, y: 0, width: 960, height: 720, devicePixelRatio: 1.25 };
assert.equal(logic.adjacent(upper, [upper, lower], "bottom"), true);
assert.equal(logic.adjacent(upper, [upper, lower], "right"), false);
assert.equal(logic.adjacent(lower, [upper, lower], "bottom"), false);
const cornerOnly = { x: 0, y: 1800, width: 100, height: 100, devicePixelRatio: 1 };
assert.equal(logic.adjacent(upper, [upper, cornerOnly], "bottom"), false);
const gap = { ...msi, x: 10 };
assert.equal(logic.adjacent(dell, [dell, gap], "right"), false);

assert.equal(logic.extraWidth(undefined), 12);
assert.equal(logic.extraWidth(-1), 0);
assert.equal(logic.extraWidth(100), 48);
assert.equal(logic.extraWidth("12"), 12);
assert.equal(logic.rightThreshold(2194, 2, 2194, 12), 2180);
assert.equal(logic.rightThreshold(2560, 2, 2560, 0), 2558);
assert.equal(logic.rightThreshold(2560, 2, 2400, 12), 2400);
assert.equal(logic.bottomThreshold(1200, 2, 4, 0, 8, 12), 1176);
assert.equal(logic.bottomThreshold(1200, 2, 4, 0, 8, 0), 1188);
console.log("Windows hover adjacency and zones: PASS");
