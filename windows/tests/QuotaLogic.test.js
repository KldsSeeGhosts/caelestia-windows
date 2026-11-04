// The drawer's pure logic, QuotaLogic.js, run as shipped in a vm: the Priority
// order, the "nearly spent" threshold, reset countdowns and per-provider spend.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const test = require("node:test");

const source = fs.readFileSync(path.resolve(__dirname, "../quota/modules/quota/QuotaLogic.js"), "utf8")
    .replace(/^\.pragma library\s*$/m, "");
const Logic = vm.createContext({});
vm.runInContext(source, Logic);
// Results are copied out of the vm so deepEqual compares plain local objects.
const call = (name, ...args) => {
    const out = vm.runInContext(`${name}.apply(null, args)`, Object.assign(Logic, { args }));
    return out === undefined ? out : JSON.parse(JSON.stringify(out));
};

const limit = (title, used, resetsAt = "") => ({ title, label: title, percent: used, resetsAt });
const account = (provider, name, limits) => ({ provider, accountLabel: name, limits });
const NOW = Date.parse("2026-11-04T12:00:00Z");
const later = ms => new Date(NOW + ms).toISOString();
const MIN = 60000, HOUR = 3600000, DAY = 86400000;

test("Priority lists each account's most constrained window, least left first", () => {
    const rows = call("priorityRows", [
        account("claude", "a", [limit("5-hour", 0.2), limit("Weekly", 0.36)]),
        account("codex", "b", [limit("5-hour", 0.9), limit("Weekly", 0.1)]),
        account("zai", "c", [limit("Monthly", 0.27)]),
        account("claude", "d", [limit("Weekly", 0.5)]),
    ]);
    assert.deepEqual(rows.map(r => r.account.accountLabel), ["b", "d", "a", "c"]);
    assert.deepEqual(rows.map(r => Math.round(r.remaining * 100)), [10, 50, 64, 73]);
    assert.deepEqual(rows.map(r => r.limit.title), ["5-hour", "Weekly", "Weekly", "Monthly"]);
    for (let i = 1; i < rows.length; i++) assert.ok(rows[i].remaining >= rows[i - 1].remaining, "ascending");
});

test("Priority skips accounts with no reading and keeps the input order on ties", () => {
    const rows = call("priorityRows", [
        account("codex", "none", [limit("5-hour", null), limit("Weekly", "")]),
        account("codex", "first", [limit("Weekly", 0.5)]),
        account("claude", "empty", []),
        account("claude", "second", [limit("Weekly", 0.5)]),
    ]);
    assert.deepEqual(rows.map(r => r.account.accountLabel), ["first", "second"]);
});

test("a window is nearly spent at 10% left or less, and not above it", () => {
    assert.equal(call("isLow", 0), true);
    assert.equal(call("isLow", 0.10), true);
    assert.equal(call("isLow", 0.11), false);
    assert.equal(call("isLow", 0.15), false);
    assert.equal(call("isLow", null), false);
});

test("reset countdowns read like the drawer", () => {
    assert.equal(call("resetShort", later(6 * DAY + 23 * HOUR + 5 * MIN), NOW), "6d 23h");
    assert.equal(call("resetShort", later(4 * HOUR + 10 * MIN), NOW), "4h 10m");
    assert.equal(call("resetShort", later(12 * MIN), NOW), "12m");
    assert.equal(call("resetShort", later(2 * HOUR), NOW), "2h 0m");
    assert.equal(call("resetShort", later(-MIN), NOW), "now");
    assert.equal(call("resetShort", "", NOW), "");
    assert.equal(call("resetShort", "not a date", NOW), "");
});

test("the spoken countdown names its units", () => {
    assert.equal(call("resetSpoken", later(4 * HOUR + 53 * MIN), NOW), "4 hours 53 minutes");
    assert.equal(call("resetSpoken", later(HOUR), NOW), "1 hour");
    assert.equal(call("resetSpoken", later(HOUR + MIN), NOW), "1 hour 1 minute");
    assert.equal(call("resetSpoken", later(45 * MIN), NOW), "45 minutes");
    assert.equal(call("resetSpoken", later(6 * DAY + 23 * HOUR), NOW), "6 days 23 hours");
    assert.equal(call("resetSpoken", later(2 * DAY), NOW), "2 days");
    assert.equal(call("resetSpoken", "", NOW), "");
});

test("spend is one provider's own cost, null until the range loads", () => {
    const spend = {
        today: { rows: [{ provider: "codex", cost: 1.62 }, { provider: "claude", cost: 1.44 }] },
        month: { rows: [] },
    };
    assert.equal(call("spendFor", spend, "today", "claude"), 1.44);
    assert.equal(call("spendFor", spend, "today", "openai"), 1.62, "vendor names fold onto the analytics id");
    assert.equal(call("spendFor", spend, "today", "zai"), 0, "a loaded range without that provider is zero");
    assert.equal(call("spendFor", spend, "yesterday", "claude"), null);
    assert.equal(call("spendFor", {}, "today", "claude"), null);
});

test("an account's windows run shortest first, then weekly, then model-scoped", () => {
    const titles = call("accountWindows", account("claude", "a", [
        limit("Opus · Weekly", 0.5), limit("Weekly", 0.5), limit("5-hour", 0.5),
    ])).map(l => l.title);
    assert.deepEqual(titles, ["5-hour", "Weekly", "Opus · Weekly"]);
});
