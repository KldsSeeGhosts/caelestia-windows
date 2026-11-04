// Hub mode's pure parts, run as shipped in a vm: provider order, the summary and
// hub merge (dedupe by identity), the identities sent to the helper, and the
// usage rows the drawer builds from a hub read's history.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const test = require("node:test");

function load(file) {
    const context = vm.createContext({});
    vm.runInContext(fs.readFileSync(path.resolve(__dirname, file), "utf8").replace(/^\.pragma library\s*$/m, ""), context);
    return (name, ...args) => {
        const out = vm.runInContext(`${name}.apply(null, args)`, Object.assign(context, { args }));
        return out === undefined ? out : JSON.parse(JSON.stringify(out));
    };
}
const hub = load("../quota/services/QuotaHub.js");
const logic = load("../quota/modules/quota/QuotaLogic.js");

const row = (provider, id, extra = {}) => Object.assign({ id: provider + ":" + id, provider, tierLabel: "Plan", planReported: true, limits: [] }, extra);

test("order is codex-first, then the rest in first-seen order", () => {
    const out = hub("order", [row("zai", "z"), row("mystery", "m"), row("claude", "c1"), row("codex", "x"), row("claude", "c2")]);
    assert.deepEqual(out.map(r => r.id), ["codex:x", "claude:c1", "claude:c2", "zai:z", "mystery:m"]);
});

test("a hub account matched to a summary row adds its detail instead of a second row", () => {
    const summary = [row("codex", "codex-hub-row", { limits: [{ title: "5-hour", percent: 0.3 }] }), row("claude", "s1")];
    const history = { days: { "2026-11-04": { totals: { tokens: 5 } } } };
    const resets = { count: 2, expiries: ["2026-11-06T00:00:00Z"] };
    const hubRows = [
        row("codex", "hub-aaa", { summaryRef: "codex:codex-hub-row", history, resetCredits: resets, limits: [{ title: "x" }] }),
        row("antigravity", "hub-bbb", { summaryRef: "" }),
        row("claude", "hub-ccc", { summaryRef: "claude:gone" }),
    ];
    const out = hub("order", hub("merge", summary, hubRows));
    assert.deepEqual(out.map(r => r.id), ["codex:codex-hub-row", "claude:s1", "claude:hub-ccc", "antigravity:hub-bbb"]);
    assert.deepEqual(out[0].history, history);
    assert.deepEqual(out[0].resetCredits, resets);
    // The summary's own windows stay.
    assert.deepEqual(out[0].limits, [{ title: "5-hour", percent: 0.3 }]);
    // The inputs are not changed.
    assert.equal(summary[0].history, undefined);
});

test("a hub plan fills only a summary row that reported none", () => {
    const out = hub("merge", [row("codex", "a", { tierLabel: "Codex", planReported: false }), row("codex", "b")],
        [row("codex", "h1", { summaryRef: "codex:a", tierLabel: "Pro 200" }), row("codex", "h2", { summaryRef: "codex:b", tierLabel: "Pro 200" })]);
    assert.deepEqual(out.map(r => r.tierLabel), ["Pro 200", "Plan"]);
});

test("identities name each summary row by its drawer id and reported identity", () => {
    const out = hub("identities", { providers: [
        { id: "Open_Code", accounts: [{ id: "a1", label: "me@example.test" }, null, { id: "", label: "" }] },
        null,
        { id: "codex", accounts: [{ id: "c1", label: "c@example.test", email: "c@example.test" }] },
    ] });
    assert.deepEqual(out, [
        { ref: "open-code:a1", provider: "open-code", keys: ["me@example.test", "a1"] },
        { ref: "codex:c1", provider: "codex", keys: ["c@example.test", "c1", "c@example.test"] },
    ]);
    assert.deepEqual(hub("identities", null), []);
});

const NOW = Date.parse("2026-11-04T12:00:00Z");
const day = (tokens, input, cached, output, models) => ({ totals: { tokens, input, cached, output, turns: 3 }, byModel: models });
const account = days => ({ history: { days } });

test("usage rows sum a provider's accounts per UTC range, with Top Models", () => {
    const accounts = [
        account({ "2026-11-04": day(100, 10, 80, 10, { a: { tokens: 60 }, b: { tokens: 40 } }),
                  "2026-11-03": day(50, 5, 40, 5, { a: { tokens: 50 } }),
                  "2026-10-01": day(999, 0, 0, 0, {}) }),
        account({ "2026-11-04": day(100, 10, 80, 10, { b: { tokens: 100 } }) }),
        { history: null },
    ];
    const today = logic("usageFor", accounts, "today", NOW);
    assert.equal(today.tokens, 200);
    assert.deepEqual(today.models, [{ name: "b", tokens: 140 }, { name: "a", tokens: 60 }]);
    assert.equal(logic("usageFor", accounts, "yesterday", NOW).tokens, 50);
    // Thirty days back from today, so October 1 is out.
    assert.equal(logic("usageFor", accounts, "month", NOW).tokens, 250);
    assert.equal(logic("usageFor", [{}, { history: {} }], "today", NOW), null);
    // An account with history but nothing today reads 0, not missing.
    assert.equal(logic("usageFor", [account({})], "today", NOW).tokens, 0);
});

test("the usage detail has the cost, tokens, mix and model shares", () => {
    const usage = logic("usageFor", [account({ "2026-11-04": day(16.1e6, 1.2e6, 14.3e6, 0.6e6, { m1: { tokens: 12e6 }, m2: { tokens: 4.1e6 } }) })], "today", NOW);
    const detail = logic("usageDetail", "Today", 4.82, usage);
    assert.deepEqual(detail.figures, ["$4.82", "16.1M tokens"]);
    assert.deepEqual(detail.tokenParts.map(p => p.title), ["Input", "Cache Read", "Output"]);
    assert.equal(detail.fillsTotal, true);
    assert.deepEqual(detail.models, [{ name: "m1", value: "75%" }, { name: "m2", value: "25%" }]);
    // Spend alone (CPA Manager without a hub) keeps the old detail.
    assert.deepEqual(logic("usageDetail", "Today", 1.5, null), { title: "Today", figures: ["$1.50"] });
    // Parts that do not add up to the total draw no mix bar.
    const partial = logic("usageFor", [account({ "2026-11-04": { totals: { tokens: 100, output: 10 } } })], "today", NOW);
    const partialDetail = logic("usageDetail", "Today", null, partial);
    assert.equal(partialDetail.fillsTotal, false);
    assert.deepEqual(partialDetail.tokenParts, [{ title: "Output", number: 10 }]);
    assert.deepEqual(partialDetail.models, []);
});

test("a refused key is remembered by a salted SHA-256 fingerprint, the same one the helper writes", () => {
    const crypto = require("node:crypto");
    for (const key of ["", "k", "SENTINEL-ADMIN-KEY-5d0b3e", "ключ-🔑", "x".repeat(200)]) {
        const expected = crypto.createHash("sha256").update("salt01\0" + key, "utf8").digest("hex").slice(0, 16);
        assert.equal(hub("fingerprint", "salt01", key), expected);
    }
    const record = hub("refusal", "key_rejected", "the-key", 1000);
    assert.equal(record.code, "key_rejected");
    assert.equal(record.until, 0);
    assert.ok(!JSON.stringify(record).includes("the-key"));
    assert.equal(hub("refusalMatches", record, "the-key"), true);
    assert.equal(hub("refusalMatches", record, "a-new-key"), false);
    assert.equal(hub("refusalMatches", record, ""), false);
    assert.equal(hub("refusal", "banned", "k", 1000).until, 1000 + 30 * 60000);
    // A record written by providers/hub.py (salt "a1b2", key "test-admin-key-0001").
    const python = { salt: "a1b2", code: "key_rejected", until: 0,
                     fingerprint: crypto.createHash("sha256").update("a1b2\0test-admin-key-0001").digest("hex").slice(0, 16) };
    assert.equal(hub("refusalMatches", python, "test-admin-key-0001"), true);
});

test("only a 401 or an IP ban closes the gate", () => {
    assert.equal(hub("refusalCode", 401, ""), "key_rejected");
    assert.equal(hub("refusalCode", 403, '{"error":"IP banned due to too many failed attempts"}'), "banned");
    assert.equal(hub("refusalCode", 403, '{"error":"remote management disabled"}'), "");
    assert.equal(hub("refusalCode", 404, ""), "");
    assert.equal(hub("refusalCode", 200, "{}"), "");
});