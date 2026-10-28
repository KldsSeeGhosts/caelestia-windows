.pragma library

function title(limit) {
    return String(limit.title || limit.label || "Quota");
}

function remaining(limit) {
    if (limit.percent === null || limit.percent === undefined || limit.percent === "")
        return null;
    const used = Number(limit.percent);
    return Number.isFinite(used) ? Math.max(0, Math.min(1, 1 - used)) : null;
}

function windowHours(label) {
    const match = String(label).match(/(\d+(?:\.\d+)?)\s*-?\s*hour/i);
    if (match)
        return Number(match[1]);
    return /daily|\bday\b/i.test(label) ? 24 : 0;
}

function windowKey(limit) {
    const label = title(limit);
    if (label.includes("·"))
        return label;
    const hours = windowHours(label);
    if (hours)
        return hours + "h";
    if (/week/i.test(label))
        return "wk";
    if (/month/i.test(label))
        return "mo";
    if (/^api$/i.test(label))
        return "API";
    if (/^auto$/i.test(label))
        return "Auto";
    return label.split("·").pop().trim();
}

function pace(limit, now) {
    const left = timeRemaining(limit, now);
    const remain = remaining(limit);
    const elapsed = 1 - left;
    if (left < 0 || remain === null || elapsed < 0.1 || 1 - remain < 0.02)
        return null;
    const used = 1 - remain;
    const projected = 1 - used / elapsed;
    if (projected >= -1e-9)
        return {left: Math.max(0, Math.round(projected * 100))};
    const span = windowHours(title(limit)) * 3600000 || 604800000;
    const minutes = Math.max(1, Math.round(elapsed * span * remain / used / 60000));
    const hours = Math.floor(minutes / 60);
    return {duration: hours >= 24 ? Math.floor(hours / 24) + "d " + hours % 24 + "h"
        : hours ? hours + "h" : minutes + "m"};
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

function summaryLimits(providerId, limits) {
    if (String(providerId).toLowerCase() === "cursor") {
        const api = limits.filter(l => /^api$/i.test(title(l)));
        if (api.length)
            return api;
    }
    return limits;
}

function accountRemaining(account) {
    const values = summaryLimits(account.provider, primaryWindows(account)).map(remaining).filter(v => v !== null);
    return values.length ? Math.min.apply(null, values) : null;
}

function groupWorstRemain(group) {
    const values = (group.accounts || []).map(a => accountRemaining(Object.assign({}, a, {provider: group.provider}))).filter(v => v !== null);
    return values.length ? Math.min.apply(null, values) : null;
}

// One line per real window category, not a synthetic combined budget.
// Pool ledgers are copied between records; their limits stay per-account.
function providerSummary(group) {
    const buckets = {};
    for (const account of group.accounts || []) {
        for (const limit of primaryWindows(account)) {
            const value = remaining(limit);
            if (value === null)
                continue;
            const key = windowKey(limit);
            if (!buckets[key] || value < buckets[key].remaining)
                buckets[key] = {label: key, remaining: value, title: title(limit)};
        }
    }
    const all = Object.keys(buckets).map(k => buckets[k]);
    if (String(group.provider).toLowerCase() === "cursor") {
        const preferred = ["API", "Auto"].filter(k => buckets[k]).map(k => buckets[k]);
        return preferred.length ? preferred : all.slice(0, 2);
    }
    all.sort((a, b) => {
        function rank(row) {
            if (/^\d+(?:\.\d+)?h$/.test(row.label))
                return Number(row.label.slice(0, -1));
            return row.label === "wk" ? 1000 : row.label === "mo" ? 2000 : 3000;
        }
        return rank(a) - rank(b);
    });
    // If there are multiple short windows, show the shortest plus weekly.
    const weekly = all.find(r => r.label === "wk");
    if (weekly && all.length && all[0] !== weekly)
        return [all[0], weekly];
    return all.slice(0, 2);
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

function timeRemaining(limit, now) {
    const label = title(limit);
    const span = windowHours(label) * 3600000 || (/week/i.test(label) ? 604800000 : 0);
    const reset = Date.parse(limit.resetsAt || "");
    // Calendar months are not all 30 days. Do not invent a pace tick for them.
    if (!span || !Number.isFinite(reset))
        return -1;
    return Math.max(0, Math.min(1, (reset - now) / span));
}

function models(account) {
    return Object.keys(account.modelUsage || {}).map(name => {
        const bucket = account.modelUsage[name] || {};
        return {name: name, tokens: Number(bucket.totalTokens || bucket.tokens || 0)};
    }).filter(r => Number.isFinite(r.tokens) && r.tokens > 0).sort((a, b) => b.tokens - a.tokens);
}
