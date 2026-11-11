const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");
const logic = {};
const source = fs.readFileSync(path.join(__dirname, "../shell/adapters/utils/RecordingDate.js"), "utf8")
    .replace(/^\s*\.pragma library\s*$/gm, "");
vm.runInNewContext(source, logic);

function localParts(value) {
    return [value.getFullYear(), value.getMonth() + 1, value.getDate(),
        value.getHours(), value.getMinutes(), value.getSeconds()];
}

test("recording names parse both formats without rolling month-end dates", () => {
    const cases = [
        // The issue's reproductions: a one-based month passed to Date() and then
        // corrected after construction became February 2 and September 1.
        ["recording_20240131_12-00-00", [2024, 1, 31, 12, 0, 0]],
        ["recording_20240831_12-00-00", [2024, 8, 31, 12, 0, 0]],
        // Glazier's current default format.
        ["recording-2024-01-31_12-00-00", [2024, 1, 31, 12, 0, 0]],
        ["recording-2024-08-31_12-00-00", [2024, 8, 31, 12, 0, 0]],
        ["recording-2024-02-29_23-59-59", [2024, 2, 29, 23, 59, 59]],
        ["recording_20240229_00-00-00", [2024, 2, 29, 0, 0, 0]],
        ["recording-2024-12-31_23-59-59", [2024, 12, 31, 23, 59, 59]],
        // A duplicate name keeps its numeric suffix and still parses.
        ["recording-2024-01-31_12-00-00 (2)", [2024, 1, 31, 12, 0, 0]],
        ["recording_20240131_12-00-00-copy", [2024, 1, 31, 12, 0, 0]],
    ];
    for (const [name, expected] of cases)
        assert.deepEqual(localParts(logic.parse(name)), expected, name);
});

test("non-recording and partial names are not given a fabricated date", () => {
    for (const name of ["recording-2024-01-31", "recording_20240131", "capture_20240131_12-00-00",
        "recording_2024-13-31_12-00-00", "", null, undefined])
        assert.equal(logic.parse(name), null, String(name));
});
