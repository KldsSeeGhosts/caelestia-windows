const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const {test} = require("node:test");
const logic = vm.createContext({});
vm.runInContext(fs.readFileSync(path.join(__dirname,
    "../services/wallpaperengine/DesktopControl.js"), "utf8"), logic);

test("startup waits for settings and discovery, then only OFF requests a command", () => {
    assert.equal(logic.startup(false, true, false, true), null);
    assert.equal(logic.startup(true, false, false, true), null);
    assert.equal(logic.startup(true, true, true, true), "");
    assert.equal(logic.startup(true, true, false, true), "stop");
    assert.equal(logic.startup(true, true, false, false), "");
});

test("the toggle uses the documented reversible all-display playback commands", () => {
    assert.equal(logic.toggle(false), "stop");
    assert.equal(logic.toggle(true), "play");
    for (const action of ["stop", "play"]) {
        assert.deepEqual(Array.from(logic.command("C:/python.exe", "C:/helper.py",
            action, true)), ["C:/python.exe", "C:/helper.py", action]);
    }
});

test("smoke/write gates and unsupported commands dispatch nothing", () => {
    for (const [python, action, allowed] of [
        ["", "stop", true], ["python", "stop", false],
        ["python", "exit", true],
    ]) {
        assert.equal(logic.command(python, "helper", action, allowed).length, 0);
    }
});
