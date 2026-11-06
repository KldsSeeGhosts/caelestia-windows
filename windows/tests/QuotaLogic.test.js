// The drawer's pure logic, QuotaLogic.js, run as shipped in a vm: the Priority
// board, severity, the row grid, money, reset countdowns and per-provider spend.
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

const board = (accounts, noticeOf) => call("priorityBoard", accounts, noticeOf);

test("Priority lists every window at 30% left or less, least left first, as OpenUsage does", () => {
    const b = board([
        account("claude", "a", [limit("5-hour", 0.72), limit("Weekly", 0.36)]),
        account("codex", "b", [limit("5-hour", 0.9), limit("Weekly", 0.95)]),
        account("zai", "c", [limit("Monthly", 0.7)]),
        account("claude", "d", [limit("Weekly", 0.5)]),
    ]);
    assert.equal(b.summary, "listed");
    assert.deepEqual(b.attention.map(i => i.account.accountLabel + ":" + i.limit.title), ["b:Weekly", "b:5-hour", "a:5-hour", "c:Monthly"]);
    assert.deepEqual(b.attention.map(i => i.severity), ["critical", "critical", "warning", "warning"]);
    assert.deepEqual(b.usedUp, []);
    assert.equal(b.showsClearRow, false);
});

test("used-up windows go under Used Up, soonest reset first", () => {
    const b = board([
        account("codex", "late", [limit("Weekly", 1, later(3 * DAY))]),
        account("codex", "soon", [limit("5-hour", 0.996, later(2 * HOUR))]),
    ]);
    assert.deepEqual(b.usedUp.map(i => i.account.accountLabel), ["soon", "late"], "0.4% left rounds to used up");
    assert.equal(b.attention.length, 0);
    assert.equal(b.showsClearRow, true, "nothing running out, so the All Clear row shows above Used Up");
});

test("the Priority summary: all clear, no limits, unreadable, ties in drawer order", () => {
    assert.equal(board([account("codex", "x", [limit("Weekly", 0.5)])]).summary, "allClear");
    assert.equal(board([account("codex", "x", [limit("Weekly", null)])]).summary, "noReportedLimits");
    const unreadable = vm.runInContext("(a => a.accountLabel === 'x' ? 'Reconnect' : '')", Logic);
    const u = board([account("codex", "x", [limit("Weekly", 0.5)])], unreadable);
    assert.equal(u.summary, "unavailable");
    assert.deepEqual(u.notices.map(n => n.message), ["Reconnect"]);
    assert.equal(u.showsClearRow, false);
    const tie = board([account("codex", "first", [limit("Weekly", 0.8)]), account("claude", "second", [limit("Weekly", 0.8)])]);
    assert.deepEqual(tie.attention.map(i => i.account.accountLabel), ["first", "second"]);
});

test("severity: warning at 30% left or less, critical at 10% or less", () => {
    assert.equal(call("severity", 0.31), "normal");
    assert.equal(call("severity", 0.30), "warning");
    assert.equal(call("severity", 0.11), "warning");
    assert.equal(call("severity", 0.10), "critical");
    assert.equal(call("severity", 0), "critical");
    assert.equal(call("severity", null), "normal");
});

test("the row grid is OpenUsage's 90 / bar / 52 / 48 with 8 gaps, and keeps a 48 dp bar when narrow", () => {
    // OpenUsage's 340 pt panel: 340 - 12 * 2 margin - 12 * 2 card padding.
    assert.deepEqual(call("grid", 292), { label: 90, value: 52, reset: 48, gap: 8, bar: 78 });
    assert.deepEqual(call("grid", 336), { label: 90, value: 52, reset: 48, gap: 8, bar: 122 });
    const narrow = call("grid", 232);
    assert.equal(narrow.bar, 48);
    assert.equal(narrow.label + narrow.bar + narrow.value + narrow.reset + narrow.gap * 3, 232);
});

test("dollars read like an OpenUsage row", () => {
    assert.equal(call("money", 4), "$4");
    assert.equal(call("money", 4.82), "$4.82");
    assert.equal(call("money", 182.4), "$182.40");
    assert.equal(call("money", 0), "$0");
    assert.equal(call("money", 1234), "$1.2K");
    assert.equal(call("money", 2500000), "$2.5M");
});

test("reset countdowns read like OpenUsage's", () => {
    assert.equal(call("resetShort", later(6 * DAY + 23 * HOUR + 5 * MIN), NOW), "6d 23h");
    assert.equal(call("resetShort", later(4 * HOUR + 10 * MIN), NOW), "4h 10m");
    assert.equal(call("resetShort", later(4 * HOUR + 9 * MIN + 1000), NOW), "4h 10m", "minutes round up");
    assert.equal(call("resetShort", later(12 * MIN), NOW), "12m");
    assert.equal(call("resetShort", later(2 * HOUR), NOW), "2h");
    assert.equal(call("resetShort", later(5 * MIN), NOW), "soon");
    assert.equal(call("resetShort", later(-MIN), NOW), "soon");
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

test("token counts read like OpenUsage's", () => {
    assert.equal(call("count", 331.4e6), "331.4M");
    assert.equal(call("count", 16.1e6), "16.1M");
    assert.equal(call("count", 1.2e6), "1.2M");
    assert.equal(call("count", 3.3e9), "3.3B");
    assert.equal(call("count", 842), "842");
    assert.equal(call("count", 1500), "1.5K");
});

test("reset credits: earliest first, numbered, absolute time, countdown and expiry colour", () => {
    const local = (y, m, d, h, min) => new Date(y, m, d, h, min).getTime();
    const now = local(2026, 10, 4, 16, 0);
    const entries = call("resetEntries", [
        new Date(local(2026, 10, 30, 15, 32)).toISOString(),
        new Date(local(2026, 10, 6, 18, 51)).toISOString(),
        new Date(local(2026, 10, 4, 16, 3)).toISOString(),
    ], now);
    assert.deepEqual(entries.map(e => e.number), [1, 2, 3]);
    assert.equal(entries[0].time, "Expiring soon", "within five minutes");
    assert.equal(entries[0].countdown, "");
    assert.equal(entries[0].severity, "critical");
    assert.equal(entries[1].time, "Nov 6 at 6:51 PM");
    assert.equal(entries[1].countdown, "2d 2h");
    assert.equal(entries[1].severity, "warning", "within 7 days");
    assert.equal(entries[2].time, "Nov 30 at 3:32 PM");
    assert.equal(entries[2].severity, "normal");
    assert.equal(call("whenAbsolute", local(2026, 10, 4, 20, 5), now), "today at 8:05 PM");
    assert.equal(call("whenAbsolute", local(2026, 10, 5, 9, 0), now), "tomorrow at 9:00 AM");
});
