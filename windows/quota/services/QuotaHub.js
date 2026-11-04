.pragma library

// Pure helpers for Quota.qml: provider order, and the merge of CPA Manager's
// summary rows with the accounts the CLIProxyAPI hub helper reads.

// The original drawer's codex-first order; unknown providers keep their order at the end.
var PREFERRED = ["codex", "claude", "antigravity", "cursor", "zai", "opencode-go", "vertex", "kimi"];

function order(records) {
    const groups = [];
    for (const record of records) {
        if (groups.indexOf(record.provider) < 0)
            groups.push(record.provider);
    }
    const rank = id => {
        const at = PREFERRED.indexOf(id);
        return at >= 0 ? at : 99;
    };
    const sorted = groups.map((id, i) => ({ id: id, i: i })).sort((a, b) => (rank(a.id) - rank(b.id)) || (a.i - b.i));
    const out = [];
    for (const group of sorted) {
        for (const record of records) {
            if (record.provider === group.id)
                out.push(record);
        }
    }
    return out;
}

// A hub account the helper matched to a summary row by identity (email or
// account id, compared inside the helper) adds its detail to that row: token
// history and limit resets, and a plan when the summary has none. Every other
// hub account is a row of its own. The summary row's windows and status stay.
function merge(summary, hub) {
    const out = (summary || []).map(r => Object.assign({}, r));
    const byId = {};
    for (const record of out)
        byId[record.id] = record;
    for (const record of hub || []) {
        const target = record.summaryRef ? byId[record.summaryRef] : null;
        if (!target) {
            out.push(record);
            continue;
        }
        if (record.history)
            target.history = record.history;
        if (record.resetCredits)
            target.resetCredits = record.resetCredits;
        if (!target.planReported && record.planReported)
            target.tierLabel = record.tierLabel;
    }
    return out;
}

// What the helper needs to recognise a summary row: its drawer id and the
// identity strings the manager reported for it. Sent over stdin only.
function identities(summary) {
    const out = [];
    for (const provider of (summary && summary.providers) || []) {
        if (!provider || typeof provider !== "object")
            continue;
        const id = String(provider.id || "").trim().toLowerCase().replace(/_/g, "-");
        for (const account of provider.accounts || []) {
            if (!account || typeof account !== "object")
                continue;
            const keys = [account.label, account.id, account.email, account.accountId].filter(k => typeof k === "string" && k.trim() !== "");
            if (keys.length)
                out.push({ ref: id + ":" + String(account.id || ""), provider: id, keys: keys });
        }
    }
    return out;
}
