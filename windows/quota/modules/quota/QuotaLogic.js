.pragma library

// A window with this share or less left reads as nearly spent.
var LOW_LEFT = 0.10;

function title(limit) {
    return String(limit.title || limit.label || "Quota");
}

function remaining(limit) {
    if (limit.percent === null || limit.percent === undefined || limit.percent === "")
        return null;
    const used = Number(limit.percent);
    return Number.isFinite(used) ? Math.max(0, Math.min(1, 1 - used)) : null;
}

function isLow(left) {
    return left !== null && left !== undefined && left <= LOW_LEFT;
}

function windowHours(label) {
    const match = String(label).match(/(\d+(?:\.\d+)?)\s*-?\s*hour/i);
    if (match)
        return Number(match[1]);
    return /daily|\bday\b/i.test(label) ? 24 : 0;
}

function primaryWindows(account) {
    const limits = account.limits || [];
    const unscoped = limits.filter(l => !title(l).includes("·"));
    return unscoped.length ? unscoped : limits;
}

function scopedWindows(account) {
    const limits = account.limits || [];
    return limits.some(l => !title(l).includes("·")) ? limits.filter(l => title(l).includes("·")) : [];
}

function orderedWindows(limits) {
    function rank(l) {
        const label = title(l);
        const hours = windowHours(label);
        if (hours)
            return hours;
        if (/week/i.test(label))
            return 1000;
        if (/^api$/i.test(label))
            return 1100;
        if (/^auto$/i.test(label))
            return 1200;
        if (/month/i.test(label))
            return 2000;
        return 3000;
    }
    return limits.slice().sort((a, b) => rank(a) - rank(b));
}

// Every window of an account in drawer order: main windows, then scoped ones.
function accountWindows(account) {
    return orderedWindows(primaryWindows(account)).concat(orderedWindows(scopedWindows(account)));
}

// The Priority view: each account's single most constrained window, least left
// first. Accounts with no reading are left out; their notice lives in All Usage.
// The sort is stable, so equal readings keep the provider order they came in.
function priorityRows(accounts) {
    const rows = [];
    for (const account of accounts || []) {
        let worst = null;
        for (const limit of account.limits || []) {
            const left = remaining(limit);
            if (left !== null && (worst === null || left < worst.remaining))
                worst = {account: account, limit: limit, remaining: left};
        }
        if (worst)
            rows.push(worst);
    }
    return rows.map((row, order) => ({row: row, order: order}))
        .sort((a, b) => a.row.remaining - b.row.remaining || a.order - b.order)
        .map(entry => entry.row);
}

// Analytics name the upstream; a provider section may use the vendor name.
function spendKey(provider) {
    const id = String(provider || "").toLowerCase();
    return id === "openai" ? "codex" : id === "anthropic" ? "claude" : id;
}

// Cost of one provider in one analytics range, or null while the range is not loaded.
function spendFor(spend, range, provider) {
    const bucket = spend ? spend[range] : null;
    if (!bucket)
        return null;
    const key = spendKey(provider);
    const row = (bucket.rows || []).find(r => spendKey(r.provider) === key);
    return row ? Number(row.cost) : 0;
}

function resetMinutes(resetAt, now) {
    const reset = Date.parse(resetAt || "");
    if (!Number.isFinite(reset))
        return null;
    return reset <= now ? 0 : Math.max(1, Math.floor((reset - now) / 60000));
}

// "6d 23h", "4h 10m", "12m"; "" when CPA gave no reset, "now" once it has passed.
function resetShort(resetAt, now) {
    const mins = resetMinutes(resetAt, now);
    if (mins === null)
        return "";
    if (mins === 0)
        return "now";
    const hours = Math.floor(mins / 60);
    if (hours >= 24)
        return Math.floor(hours / 24) + "d " + hours % 24 + "h";
    return hours ? hours + "h " + mins % 60 + "m" : mins + "m";
}

// The same countdown for a screen reader: "4 hours 53 minutes".
function resetSpoken(resetAt, now) {
    const mins = resetMinutes(resetAt, now);
    if (mins === null)
        return "";
    if (mins === 0)
        return "now";
    const hours = Math.floor(mins / 60);
    function unit(n, word) {
        return n + " " + word + (n === 1 ? "" : "s");
    }
    if (hours >= 24)
        return [unit(Math.floor(hours / 24), "day")].concat(hours % 24 ? [unit(hours % 24, "hour")] : []).join(" ");
    return (hours ? [unit(hours, "hour")] : []).concat(mins % 60 || !hours ? [unit(mins % 60, "minute")] : []).join(" ");
}

function accountState(account, now, staleAfter, refreshFailed) {
    if (account.disabled || account.status === "disabled")
        return Date.parse(account.cooldownUntil || "") > now ? "cooldown" : "disabled";
    if (Date.parse(account.cooldownUntil || "") > now)
        return "cooldown";
    if (account.quotaAuthRequired)
        return "auth";
    if (account.unavailable || account.quotaError || account.errorText || refreshFailed)
        return "stale";
    if (!(account.limits || []).some(l => remaining(l) !== null))
        return "none";
    const stamp = Date.parse(account.quotaUpdatedAt || account.updatedAt || "");
    if (Number.isFinite(stamp) && now - stamp > staleAfter)
        return "stale";
    return "ok";
}
