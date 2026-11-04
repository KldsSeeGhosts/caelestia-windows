.pragma library

// The rules below follow OpenUsage (github.com/robinebers/openusage, MIT):
// Models/PriorityLimits.swift, Models/WidgetData.swift, Models/PriorityBoard.swift
// and Support/Formatters.swift.

// The % left at or under which a limit turns warning and critical.
var WARNING_LEFT = 30;
var CRITICAL_LEFT = 10;

function title(limit) {
    return String(limit.title || limit.label || "Quota");
}

function remaining(limit) {
    if (limit.percent === null || limit.percent === undefined || limit.percent === "")
        return null;
    const used = Number(limit.percent);
    return Number.isFinite(used) ? Math.max(0, Math.min(1, 1 - used)) : null;
}

// "normal", "warning" or "critical", from what is left alone (time plays no part).
function severity(left) {
    if (left === null || left === undefined)
        return "normal";
    const percent = Math.round(left * 100);
    return percent <= CRITICAL_LEFT ? "critical" : percent <= WARNING_LEFT ? "warning" : "normal";
}

// Nothing left at display precision.
function isUsedUp(left) {
    return left !== null && left !== undefined && Math.round(left * 100) <= 0;
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

// The Priority board. Every window that is used up goes under Used Up, every
// other window at warning or worse under Running Out, least left first; used-up
// windows sort by their reset. Ties keep the drawer order. `noticeOf(account)`
// returns why an account cannot be read right now, or "". OpenUsage's "burning
// fast" tier needs a usage pace, which CPA does not report, so it is left out.
// summary: "listed", "unavailable", "allClear" or "noReportedLimits".
function priorityBoard(accounts, noticeOf) {
    const items = [];
    const notices = [];
    let bounded = false;
    for (const account of accounts || []) {
        const notice = noticeOf ? noticeOf(account) : "";
        if (notice)
            notices.push({account: account, message: notice});
        for (const limit of accountWindows(account)) {
            const left = remaining(limit);
            if (left === null)
                continue;
            bounded = true;
            const usedUp = isUsedUp(left);
            const level = usedUp ? "critical" : severity(left);
            if (level === "normal")
                continue;
            const reset = Date.parse(limit.resetsAt || "");
            items.push({
                account: account, limit: limit, remaining: left, severity: level, usedUp: usedUp,
                closeness: usedUp ? (Number.isFinite(reset) ? reset : Infinity) : left,
                order: items.length
            });
        }
    }
    items.sort((a, b) => (a.usedUp - b.usedUp) || (a.closeness - b.closeness) || (a.order - b.order));
    const attention = items.filter(i => !i.usedUp);
    const usedUp = items.filter(i => i.usedUp);
    const summary = items.length ? "listed" : notices.length ? "unavailable" : bounded ? "allClear" : "noReportedLimits";
    return {
        attention: attention, usedUp: usedUp, notices: notices, summary: summary,
        showsClearRow: notices.length === 0 && attention.length === 0 && (summary === "listed" || summary === "allClear")
    };
}

// OpenUsage's row grid (Views/DashboardGrid.swift): label 90, value 52, reset
// 48, gaps 8, the bar takes the rest. OpenUsage is always 340 wide; this drawer
// can be narrower, so below that the label gives way to keep a 48 dp bar.
var GRID = {label: 90, value: 52, reset: 48, gap: 8, minBar: 48};

function grid(inner) {
    const fixed = GRID.value + GRID.reset + GRID.gap * 3;
    const label = Math.max(0, Math.min(GRID.label, inner - fixed - GRID.minBar));
    return {label: label, value: GRID.value, reset: GRID.reset, gap: GRID.gap, bar: Math.max(0, inner - fixed - label)};
}

// Dollars as an OpenUsage row: "$4", "$4.82", "$1.2K" (Support/MetricFormatter.swift).
function money(value) {
    const n = Number(value) || 0;
    const sign = n < 0 ? "-" : "";
    const abs = Math.abs(n);
    if (abs >= 1000) {
        const units = [[1e12, "T"], [1e9, "B"], [1e6, "M"], [1e3, "K"]];
        const unit = units.find(u => abs >= u[0]);
        return sign + "$" + String(Math.round(abs / unit[0] * 10) / 10) + unit[1];
    }
    const whole = Math.round(abs * 100) % 100 === 0;
    return sign + "$" + (whole ? String(Math.round(abs)) : abs.toFixed(2));
}

// A count as an OpenUsage row: "16.1M", "331.4M", "842", "3.5"
// (Support/MetricFormatter.swift, `.count`).
function count(value) {
    const n = Number(value) || 0;
    const abs = Math.abs(n);
    const units = [[1e12, "T"], [1e9, "B"], [1e6, "M"], [1e3, "K"]];
    const unit = units.find(u => abs >= u[0]);
    const scaled = unit ? n / unit[0] : n;
    return String(Math.round(scaled * 10) / 10) + (unit ? unit[1] : "");
}

// A reset credit's expiry colour: critical within 48 hours, warning within 7
// days (Models/WidgetData.swift, expirySeverity).
function expirySeverity(seconds) {
    return seconds <= 48 * 3600 ? "critical" : seconds <= 7 * 86400 ? "warning" : "normal";
}

var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

function clock(d) {
    const h = d.getHours() % 12 || 12;
    return h + ":" + String(d.getMinutes()).padStart(2, "0") + " " + (d.getHours() >= 12 ? "PM" : "AM");
}

// "today at 6:51 PM", "tomorrow at …", "Nov 6 at 6:51 PM"; "soon" once due
// (Support/Formatters.swift, whenLabel .absolute).
function whenAbsolute(at, now) {
    const d = new Date(at);
    if (!Number.isFinite(d.getTime()))
        return "";
    if (d.getTime() <= now)
        return "soon";
    const n = new Date(now);
    const days = Math.round((new Date(d.getFullYear(), d.getMonth(), d.getDate()) - new Date(n.getFullYear(), n.getMonth(), n.getDate())) / 86400000);
    if (days <= 0)
        return "today at " + clock(d);
    if (days === 1)
        return "tomorrow at " + clock(d);
    return MONTHS[d.getMonth()] + " " + d.getDate() + " at " + clock(d);
}

// The Limit Resets timeline (Views/RateLimitResetsDetail+Timeline.swift):
// earliest first, numbered from 1, each with its absolute time, a countdown
// and an expiry colour. Within five minutes it reads "Expiring soon" with no
// countdown.
function resetEntries(expiries, now) {
    return (expiries || []).map(e => Date.parse(e)).filter(t => Number.isFinite(t)).sort((a, b) => a - b).map((t, i) => {
        const relative = resetShort(new Date(t).toISOString(), now);
        const imminent = relative === "" || relative === "soon";
        return {
            number: i + 1, at: t, severity: expirySeverity((t - now) / 1000),
            time: imminent ? "Expiring soon" : whenAbsolute(t, now),
            countdown: imminent ? "" : relative
        };
    });
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

// Whole minutes to the reset, rounded up; 0 within five minutes or once it has
// passed ("soon"); null when CPA gave no reset.
function resetMinutes(resetAt, now) {
    const reset = Date.parse(resetAt || "");
    if (!Number.isFinite(reset))
        return null;
    return reset - now <= 5 * 60000 ? 0 : Math.ceil((reset - now) / 60000);
}

// "6d 23h", "4h 10m", "2h", "12m"; "" when CPA gave no reset, "soon" when it is due.
function resetShort(resetAt, now) {
    const mins = resetMinutes(resetAt, now);
    if (mins === null)
        return "";
    if (mins === 0)
        return "soon";
    const hours = Math.floor(mins / 60);
    if (hours >= 24)
        return Math.floor(hours / 24) + "d " + hours % 24 + "h";
    return hours ? (mins % 60 ? hours + "h " + mins % 60 + "m" : hours + "h") : mins + "m";
}

// The same countdown for a screen reader: "4 hours 53 minutes".
function resetSpoken(resetAt, now) {
    const mins = resetMinutes(resetAt, now);
    if (mins === null)
        return "";
    if (mins === 0)
        return "soon";
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
