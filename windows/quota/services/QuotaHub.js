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

// -- Refused keys ------------------------------------------------------------
// A key CLIProxyAPI rejected (401) or banned is remembered as
// { salt, fingerprint, code, until }, the same record providers/hub.py writes:
// fingerprint = the first 16 hex digits of SHA-256(salt + "\0" + key). The key
// itself is never stored. QML has no SHA-256, hence the small one below.

var K256 = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
];

function sha256Hex(text) {
    const bytes = [];
    const utf8 = unescape(encodeURIComponent(String(text)));
    for (let i = 0; i < utf8.length; i++)
        bytes.push(utf8.charCodeAt(i));
    const bits = bytes.length * 8;
    bytes.push(0x80);
    while (bytes.length % 64 !== 56)
        bytes.push(0);
    for (let i = 7; i >= 0; i--)
        bytes.push(i >= 4 ? Math.floor(bits / Math.pow(2, 8 * i)) & 0xff : (bits >>> (8 * i)) & 0xff);
    const h = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
    const w = new Array(64);
    const rotr = (x, n) => (x >>> n) | (x << (32 - n));
    for (let off = 0; off < bytes.length; off += 64) {
        for (let i = 0; i < 16; i++)
            w[i] = (bytes[off + 4 * i] << 24) | (bytes[off + 4 * i + 1] << 16) | (bytes[off + 4 * i + 2] << 8) | bytes[off + 4 * i + 3];
        for (let i = 16; i < 64; i++) {
            const s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >>> 3);
            const s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >>> 10);
            w[i] = (w[i - 16] + s0 + w[i - 7] + s1) | 0;
        }
        let [a, b, c, d, e, f, g, k] = h;
        for (let i = 0; i < 64; i++) {
            const t1 = (k + (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) + ((e & f) ^ (~e & g)) + K256[i] + w[i]) | 0;
            const t2 = ((rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) + ((a & b) ^ (a & c) ^ (b & c))) | 0;
            k = g; g = f; f = e; e = (d + t1) | 0; d = c; c = b; b = a; a = (t1 + t2) | 0;
        }
        const next = [a, b, c, d, e, f, g, k];
        for (let i = 0; i < 8; i++)
            h[i] = (h[i] + next[i]) | 0;
    }
    return h.map(x => (x >>> 0).toString(16).padStart(8, "0")).join("");
}

function fingerprint(salt, key) {
    return sha256Hex(String(salt) + "\0" + String(key)).slice(0, 16);
}

var CLOSES_GATE = ["key_rejected", "banned"];

function refusalMatches(record, key) {
    return !!record && typeof record === "object" && typeof record.salt === "string" && !!key
        && CLOSES_GATE.indexOf(record.code) >= 0 && record.fingerprint === fingerprint(record.salt, key);
}

function refusal(code, key, nowMs) {
    let salt = "";
    for (let i = 0; i < 16; i++)
        salt += Math.floor(Math.random() * 16).toString(16);
    return { salt: salt, fingerprint: fingerprint(salt, key), code: code,
             until: code === "banned" ? nowMs + 30 * 60000 : 0 };
}

// What a management answer means for the key: "key_rejected", "banned" or "".
function refusalCode(status, body) {
    if (status === 401)
        return "key_rejected";
    if (status !== 403)
        return "";
    let message = "";
    try {
        const parsed = JSON.parse(body);
        message = String(parsed && parsed.error || "").toLowerCase();
    } catch (e) {}
    return message.indexOf("ip banned") === 0 ? "banned" : "";
}
