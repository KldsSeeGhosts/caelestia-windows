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

test("battery warnings stay latched through upward fluctuations while discharging", () => {
    const levels = [{level: 20}, {level: 10, critical: true}];
    let result = battery.warnings({}, 20, levels, 3);
    assert.equal(result.warning.level, 20);
    for (const percentage of [19, 25, 20]) {
        result = battery.warnings(result.notified, percentage, levels, 3);
        assert.equal(result.warning, null);
    }
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

test("delayed polling still observes a new idle cycle above the old timeout", () => {
    const entries = [{timeout: 2, idleAction: "dpms off", returnAction: "dpms on"}];
    const result = idle.transitions(entries, {"0": true}, 4, false, false, false, false, false, true);
    assert.equal(result.actions[0].kind, "return");
    assert.equal(result.fired["0"], false);
});

test("respectInhibitors false bypasses only the Windows idle hold", () => {
    const entries = [{timeout: 10, idleAction: "lock"}, {timeout: 10, idleAction: "lock", respectInhibitors: false}];
    const result = idle.transitions(entries, {}, 10, true, false, false, true, false);
    assert.equal(result.actions.length, 1);
    assert.equal(result.actions[0].index, 1);
});

test("return actions run when input returns and stay inside the Windows allowlist", () => {
    const entries = [{timeout: 10, idleAction: "dpms off", returnAction: "dpms on"}];
    let result = idle.transitions(entries, {}, 10, false, false, false, false, false);
    assert.equal(result.actions.length, 1);
    assert.equal(result.actions[0].kind, "idle");
    result = idle.transitions(entries, result.fired, 0, false, false, false, false, false);
    assert.equal(result.actions.length, 1);
    assert.equal(result.actions[0].kind, "return");
    assert.deepEqual(JSON.parse(JSON.stringify(result.actions[0].action)), {kind: "displayOn"});
    assert.equal(idle.normalizeAction("unlock"), null);
    assert.equal(idle.normalizeAction(["cmd.exe", "/c", "echo bad"]), null);
});

test("charging inhibition uses known AC power rather than active charging", () => {
    const entries = [{timeout: 10, idleAction: "lock", inhibitWhenCharging: true}];
    const pluggedPaused = idle.transitions(entries, {}, 10, false, false, true, false, false);
    assert.equal(pluggedPaused.actions.length, 0);
    const desktopOrBattery = idle.transitions(entries, {}, 10, false, false, false, false, false);
    assert.equal(desktopOrBattery.actions.length, 1);
});

test("transient unknown power readings do not create AC transitions or rearm warnings", () => {
    let transition = battery.powerTransition(-1, true, true);
    assert.equal(transition.event, "seed");
    assert.equal(transition.source, 1);
    transition = battery.powerTransition(transition.source, false, false);
    assert.equal(transition.event, "unknown");
    assert.equal(transition.source, 1);
    transition = battery.powerTransition(transition.source, true, true);
    assert.equal(transition.event, "unchanged");
    assert.equal(transition.source, 1);
    transition = battery.powerTransition(transition.source, true, false);
    assert.equal(transition.event, "plugged");
    assert.equal(transition.source, 0);
    transition = battery.powerTransition(transition.source, false, true);
    assert.equal(transition.event, "unknown");
    assert.equal(transition.source, 0);
});
