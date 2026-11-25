const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const test = require("node:test");

function load(name) {
    const source = fs.readFileSync(path.resolve(__dirname, "../shell/adapters/daemons", name), "utf8")
        .replace(/^\s*\.pragma library\s*$/gm, "");
    const context = vm.createContext({});
    vm.runInContext(source, context, {filename: name});
    return context;
}
const battery = load("BatteryLogic.js");
const idle = load("IdleLogic.js");

test("battery warnings rearm only after a two-point recovery", () => {
    const levels = [{level: 20}, {level: 10, critical: true}];
    let result = battery.warnings({}, 20, levels, 3);
    assert.equal(result.warning.level, 20);
    for (const percentage of [19, 21, 20]) {
        result = battery.warnings(result.notified, percentage, levels, 3);
        assert.equal(result.warning, null);
    }
    result = battery.warnings(result.notified, 22, levels, 3);
    assert.equal(battery.warnings(result.notified, 20, levels, 3).warning.level, 20);
    result = battery.warnings({}, 3, battery.sortedLevels(levels), 3);
    assert.equal(result.warning.level, 10);
    assert.equal(result.critical, true);
    assert.equal(battery.warnings(result.notified, 2, levels, 3).critical, false);
});

test("idle actions map Linux contract values to safe Windows operations", () => {
    assert.deepEqual(JSON.parse(JSON.stringify(idle.normalizeAction("lock"))), {kind: "lock"});
    assert.deepEqual(JSON.parse(JSON.stringify(idle.normalizeAction("dpms off"))), {kind: "displayOff"});
    assert.deepEqual(JSON.parse(JSON.stringify(idle.normalizeAction(["suspendThenHibernate"]))), {kind: "session", action: "suspend"});
    assert.equal(idle.normalizeAction(["rm", "-rf"]), null);
});

test("idle timeout transitions fire once and reset when input returns", () => {
    const entries = [{timeout: 10, idleAction: "lock"}, {timeout: 20, idleAction: "dpms off"}];
    let result = idle.transitions(entries, {}, 10, false, false, false, true, false);
    assert.equal(result.actions.length, 1);
    result = idle.transitions(entries, result.fired, 11, false, false, false, true, false);
    assert.equal(result.actions.length, 0);
    result = idle.transitions(entries, result.fired, 0, false, false, false, true, false);
    assert.deepEqual(JSON.parse(JSON.stringify(result.fired)), {"0": false, "1": false});
});

test("the Windows idle hold prevents all idle actions", () => {
    const entries = [{timeout: 10, idleAction: "lock"}, {timeout: 10, idleAction: "lock", respectInhibitors: false}];
    const result = idle.transitions(entries, {}, 10, true, false, false, true, false);
    assert.equal(result.actions.length, 0);
});
