pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.services

// CPA quota data service for the Windows drawer.
//
// CPA Manager publishes one pre-aggregated management response:
//
//   GET <baseUrl>/v0/management/quota/summary
//   Authorization: Bearer <adminKey>
//
// Spend per provider comes from the manager's usage analytics, the same
// source as the panel's Usage Analytics page:
//
//   POST <baseUrl>/v0/management/monitoring/analytics  {channel_share}
//
// This service reads that response with QML XMLHttpRequest, maps providers,
// accounts and windows onto the shape the original drawer components expect,
// and keeps the last good summary on failure. No child process, ledger or
// local usage-record store is involved.
//
// Privacy: baseUrl/adminKey are parsed from cpa-agents.json in memory only.
// The key, the response body, emails and account ids are never logged. Errors
// are mapped from CPA's known codes to short UI strings.
Singleton {
    id: root

    readonly property int refreshIntervalMs: QuotaConfig.refreshIntervalMs
    readonly property int requestTimeoutMs: 15000
    readonly property bool configured: QuotaConfig.configured
    readonly property bool enabled: QuotaConfig.enabled

    readonly property string summaryUrlSuffix: "/v0/management/quota/summary"
    readonly property string analyticsUrlSuffix: "/v0/management/monitoring/analytics"
    readonly property string cachePath: QuotaConfig.cacheHome + "/quota-summary.json"
    readonly property int effectiveRefreshMs: Math.max(root.refreshIntervalMs, root.ttlMs)

    // Endpoint, read from cpa-agents.json by the FileView below.
    property string baseUrl: ""
    property string adminKey: ""
    property bool endpointLoaded: false

    // Live clock for reset countdowns.
    property double nowMs: Date.now()
    // Open drawers holding the 10 s relative-time tick. A count keeps one
    // monitor's open drawer from stopping the clock on another.
    property int clockHolders: 0

    property bool loading: false
    property string status: "idle" // idle | unconfigured | loading | ok | partial | error
    property string error: ""
    property double lastUpdatedAt: 0
    property double lastRequestAt: 0
    property int ttlMs: 0
    property bool inFlight: false
    property bool requestTimedOut: false
    property var activeRequest: null

    property var providers: []
    property string selectedProviderId: ""
    property var todayCostUsd: null
    // { today | yesterday | month: { total, rows: [{ provider, cost }] } }
    property var spend: ({})

    readonly property int providerIndex: {
        for (let i = 0; i < providers.length; i++) {
            if (providers[i].id === selectedProviderId)
                return i;
        }
        return 0;
    }

    readonly property var activeProvider: providers.length > 0 ? providers[providerIndex] : null
    readonly property bool hasData: providers.length > 0
    readonly property bool hasError: error !== ""

    readonly property string usageCostText: root.todayCostUsd === null
        ? qsTr("Not reported") : "$" + Number(root.todayCostUsd).toFixed(2)
    readonly property string usageTodayText: root.todayCostUsd === null
        ? qsTr("Cost not reported today") : qsTr("%1 across all accounts").arg(root.usageCostText)

    // Accounts grouped by provider: one chip per provider, with all accounts
    // of that provider reachable from the group.
    readonly property var providerGroups: {
        const groups = [];
        const byProvider = {};
        for (let i = 0; i < providers.length; i++) {
            const p = providers[i];
            if (!byProvider[p.provider]) {
                byProvider[p.provider] = {
                    provider: p.provider,
                    label: p.providerLabel || providerDisplayName(p.provider),
                    accounts: []
                };
                groups.push(byProvider[p.provider]);
            }
            byProvider[p.provider].accounts.push(p);
        }
        return groups;
    }

    readonly property var activeGroup: {
        const p = activeProvider;
        if (!p)
            return null;
        for (let i = 0; i < providerGroups.length; i++) {
            if (providerGroups[i].provider === p.provider)
                return providerGroups[i];
        }
        return null;
    }

    readonly property var activeGroupAccounts: {
        const p = activeProvider;
        if (!p)
            return [];
        const group = activeGroup ? (activeGroup.accounts || []) : [p];
        return group.map(r => Object.assign({}, r, {accountLabel: r.accountLabel || r.account || r.name || ""}));
    }

    function providerDisplayName(providerId: string): string {
        const p = String(providerId || "").toLowerCase();
        if (p === "opencode-go")
            return "OpenCode Go";
        if (p === "codex" || p === "openai")
            return "Codex";
        if (p === "claude" || p === "anthropic")
            return "Claude";
        if (p === "antigravity")
            return "Antigravity";
        if (p === "cursor")
            return "Cursor";
        if (p === "zai")
            return "Zai";
        if (p === "vertex")
            return "Vertex";
        if (p === "kimi")
            return "Kimi";
        return String(providerId || "Agent").charAt(0).toUpperCase() + String(providerId || "").slice(1);
    }

    function normalizeProviderId(value: string): string {
        return String(value || "").trim().toLowerCase().replace(/_/g, "-");
    }

    // Select a provider group: activates its first account (or the
    // currently-selected one if it already belongs to the group).
    function selectGroup(provider: string): void {
        for (let i = 0; i < providerGroups.length; i++) {
            const g = providerGroups[i];
            if (g.provider !== provider || g.accounts.length === 0)
                continue;
            const current = activeProvider;
            if (current && current.provider === provider)
                selectedProviderId = current.id;
            else
                selectedProviderId = g.accounts[0].id;
            return;
        }
    }

    function selectProvider(id: string): void {
        selectedProviderId = id;
    }

    function selectIndex(index: int): void {
        if (providers.length === 0)
            return;
        const wrapped = ((index % providers.length) + providers.length) % providers.length;
        selectedProviderId = providers[wrapped].id;
    }

    function defaultProviderId(): string {
        for (let i = 0; i < providers.length; i++) {
            const p = String(providers[i].provider || "").toLowerCase();
            if (p === "codex" || p === "openai" || p.includes("codex"))
                return providers[i].id;
        }
        return providers.length > 0 ? providers[0].id : "";
    }

    function resetToDefault(): void {
        selectedProviderId = root.defaultProviderId();
    }

    // -- Keepalive -----------------------------------------------------------
    // The bolt button is the original overlay's explicit keepalive action. It
    // still runs cpa_keepalive.py behind the button (and only then), so the
    // drawer's normal quota path needs no Python.
    property bool keepaliveRunning: false
    property int keepaliveDone: 0
    property int keepaliveTotal: 7
    property real keepaliveProgress: keepaliveTotal > 0 ? keepaliveDone / keepaliveTotal : 0
    property string keepaliveError: ""

    readonly property string keepaliveScript: Quickshell.shellPath("scripts/cpa_keepalive.py")
    readonly property var keepaliveEnvironment: ({
        "HOME": QuotaConfig.home,
        "USERPROFILE": QuotaConfig.home,
        "PYTHONUTF8": "1"
    })

    function triggerKeepalive(): void {
        if (!QuotaConfig.enabled || !QuotaConfig.configured || keepaliveProcess.running)
            return;
        keepaliveRunning = true;
        keepaliveDone = 0;
        keepaliveError = "";
        keepaliveProcess.running = true;
    }

    Process {
        id: keepaliveProcess
        command: [QuotaConfig.python, "-I", root.keepaliveScript, "--cpa-config", QuotaConfig.cpaConfigPath]
        environment: root.keepaliveEnvironment

        stdout: SplitParser {
            splitMarker: "\n"
            onRead: data => {
                const line = String(data).trim();
                if (!line)
                    return;
                try {
                    const msg = JSON.parse(line);
                    if (msg && msg.type === "progress" && typeof msg.done === "number") {
                        root.keepaliveDone = Math.max(0, Math.min(msg.total || root.keepaliveTotal, msg.done));
                        if (msg.total)
                            root.keepaliveTotal = msg.total;
                    } else if (msg && typeof msg.ok === "boolean" && msg.ok === false) {
                        root.keepaliveError = msg.error || "Keepalive failed";
                    }
                } catch (e) {}
            }
        }

        onExited: (exitCode, exitStatus) => {
            // Ensure the ring completes even if the script was fast and progress lines were coalesced.
            if (root.keepaliveDone < root.keepaliveTotal)
                root.keepaliveDone = root.keepaliveTotal;
            root.keepaliveRunning = false;
            // Refresh so the panel reflects the newly-active window.
            root.refresh(true);
        }
    }

    // -- Endpoint and cache --------------------------------------------------

    // Contents are read here and never logged or exposed as a file dump.
    FileView {
        id: endpointFile

        path: QuotaConfig.cpaConfigPath
        printErrors: false
        watchChanges: true

        onTextChanged: root.applyEndpoint(endpointFile.text())
        onLoadFailed: {
            root.endpointLoaded = false;
            root.baseUrl = "";
            root.adminKey = "";
        }
    }

    // Last good mapped summary, no endpoint or key. Loaded once at start so a
    // slow or unreachable manager still shows the previous reading instantly.
    FileView {
        id: cacheFile

        path: root.cachePath
        printErrors: false
        watchChanges: false
        blockWrites: false

        onLoaded: root.loadCache(cacheFile.text())
    }

    function applyEndpoint(raw: string): void {
        let parsed = null;
        try {
            // Notepad and some editors save a UTF-8 BOM; JSON.parse rejects it.
            parsed = JSON.parse((raw || "").replace(/^\uFEFF/, ""));
        } catch (e) {
            parsed = null;
        }
        const base = (parsed && typeof parsed.baseUrl === "string") ? parsed.baseUrl.trim().replace(/\/+$/, "") : "";
        const key = (parsed && typeof parsed.adminKey === "string") ? parsed.adminKey : "";
        const previous = root.baseUrl + "\n" + root.adminKey;
        root.baseUrl = base;
        root.adminKey = key;
        root.endpointLoaded = true;
        if (previous !== base + "\n" + key)
            root.refresh(true);
        else
            root.maybeRefresh();
    }

    function loadCache(raw: string): void {
        // A live response always wins over the cache, even if it arrives first.
        if (root.providers.length > 0 || root.lastUpdatedAt > 0)
            return;
        let cached = null;
        try {
            cached = JSON.parse((raw || "").replace(/^\uFEFF/, ""));
        } catch (e) {
            return;
        }
        if (!cached || !Array.isArray(cached.providers) || cached.providers.length === 0)
            return;
        root.providers = cached.providers;
        root.lastUpdatedAt = Number(cached.lastUpdatedAt) || 0;
        root.ttlMs = Number(cached.ttlMs) || 0;
        root.todayCostUsd = (typeof cached.todayCostUsd === "number" && Number.isFinite(cached.todayCostUsd))
            ? cached.todayCostUsd : null;
        if (cached.spend && typeof cached.spend === "object" && Object.keys(root.spend).length === 0)
            root.spend = cached.spend;
        root.status = root.error !== "" ? "error" : "ok";
        root.selectedProviderId = root.defaultProviderId();
    }

    function displayAccount(value: string): string {
        const text = String(value || "").trim();
        if (!text)
            return "";
        return text.indexOf("@") >= 0 ? text.split("@")[0] : text;
    }

    function cacheRecord(rec: var, index: int): var {
        // Persist only what the drawer draws: display names, provider labels,
        // windows and status. Emails, account ids and manager error text stay
        // in memory.
        return {
            id: rec.provider + ":cached-" + index,
            name: root.displayAccount(rec.name),
            account: "",
            accountLabel: root.displayAccount(rec.accountLabel || rec.name),
            provider: rec.provider,
            providerLabel: rec.providerLabel,
            tierLabel: rec.tierLabel,
            chipLabel: root.displayAccount(rec.chipLabel || rec.name),
            status: rec.status,
            statusMessage: "",
            usageStatusText: "",
            errorText: "",
            unavailable: !!rec.unavailable,
            disabled: !!rec.disabled,
            cooldowns: [],
            cooldownUntil: "",
            limits: rec.limits,
            lastUsedAt: "",
            poolGroup: null,
            poolAccounts: [],
            poolLimits: [],
            balance: null,
            recentDays: [],
            modelUsage: {},
            allTime: null,
            updatedAt: rec.updatedAt,
            quotaUpdatedAt: rec.quotaUpdatedAt,
            quotaCheckedAt: rec.quotaCheckedAt,
            quotaError: "",
            quotaAuthRequired: !!rec.quotaAuthRequired,
            dailyMetric: "tokens",
            tokensToday: 0,
            requestsToday: 0,
            providerRank: rec.providerRank
        };
    }

    function writeCache(): void {
        if (!root.cachePath)
            return;
        try {
            const cachedProviders = [];
            for (let i = 0; i < root.providers.length; i++)
                cachedProviders.push(root.cacheRecord(root.providers[i], i));
            cacheFile.setText(JSON.stringify({
                schemaVersion: 1,
                lastUpdatedAt: root.lastUpdatedAt,
                ttlMs: root.ttlMs,
                todayCostUsd: root.todayCostUsd,
                spend: root.spend,
                providers: cachedProviders
            }));
        } catch (e) {
            // The cache is an optimisation; a failed write must stay silent.
        }
    }

    // -- Refresh -------------------------------------------------------------

    function maybeRefresh(): void {
        if (!root.configured) {
            root.status = "unconfigured";
            root.error = "";
            return;
        }
        if (!root.enabled || !root.endpointLoaded)
            return;
        root.refresh(false);
    }

    function refresh(force): void {
        if (force === undefined)
            force = false;
        if (!root.configured) {
            root.status = "unconfigured";
            return;
        }
        if (!root.enabled || root.inFlight)
            return;
        // Automatic refreshes never outpace the manager's own TTL.
        if (!force && root.lastRequestAt > 0 && root.ttlMs > 0
                && Date.now() - root.lastRequestAt < root.ttlMs)
            return;
        if (!root.endpointLoaded || !root.baseUrl || !root.adminKey) {
            root.error = qsTr("CPA management config is incomplete. Add baseUrl and adminKey to cpa-agents.json.");
            root.status = "error";
            return;
        }
        // The admin key travels as a Bearer header: plain HTTP only to loopback.
        if (!/^https:\/\//i.test(root.baseUrl)
                && !/^http:\/\/(127\.0\.0\.1|localhost|\[::1\])(:\d+)?(\/|$)/i.test(root.baseUrl)) {
            root.error = qsTr("CPA baseUrl must use https. Plain http is only allowed for localhost.");
            root.status = "error";
            return;
        }
        if (typeof XMLHttpRequest === "undefined") {
            root.error = qsTr("Quota refresh failed. Showing saved data.");
            root.status = "error";
            return;
        }

        let request = null;
        try {
            request = new XMLHttpRequest();
        } catch (e) {
            request = null;
        }
        if (!request) {
            root.error = qsTr("Quota refresh failed. Showing saved data.");
            root.status = "error";
            return;
        }

        root.refreshSpend();
        root.inFlight = true;
        root.loading = true;
        root.requestTimedOut = false;
        root.lastRequestAt = Date.now();
        root.activeRequest = request;
        watchdog.restart();

        request.onload = function () {
            if (root.activeRequest !== request)
                return;
            try {
                if (request.status >= 200 && request.status < 300) {
                    if (!root.applySummary(request.responseText)) {
                        root.failRefresh(false);
                        return;
                    }
                    root.finishRequest();
                    return;
                }
            } catch (e) {
                root.failRefresh(false);
                return;
            }
            root.failRefresh(false);
        };
        request.onerror = function () {
            if (root.activeRequest === request)
                root.failRefresh(false);
        };
        request.ontimeout = function () {
            if (root.activeRequest === request) {
                root.requestTimedOut = true;
                root.failRefresh(true);
            }
        };
        request.onabort = function () {
            if (root.activeRequest === request)
                root.failRefresh(root.requestTimedOut);
        };

        try {
            request.open("GET", root.baseUrl + root.summaryUrlSuffix);
            request.setRequestHeader("Authorization", "Bearer " + root.adminKey);
            request.setRequestHeader("Accept", "application/json");
            request.timeout = root.requestTimeoutMs;
            request.send();
        } catch (e) {
            root.failRefresh(false);
        }
    }

    // -- Spend ---------------------------------------------------------------

    // Analytics name OpenAI-compatible and local harness routes after their
    // upstream ("openai-compatible-opencode-go", "devin-local"); fold them in.
    function spendProviderId(raw: string): string {
        const id = root.normalizeProviderId(raw).replace(/^openai-compatible-/, "").replace(/-(local|native)$/, "");
        return id === "openai" ? "codex" : id === "anthropic" ? "claude" : (id || "other");
    }

    // Local calendar days, like the panel; 30 Days is a rolling window.
    function refreshSpend(): void {
        const now = Date.now();
        const midnight = new Date(now);
        midnight.setHours(0, 0, 0, 0);
        const yesterday = new Date(midnight.getTime());
        yesterday.setDate(yesterday.getDate() - 1);
        root.fetchSpend("today", midnight.getTime(), now);
        root.fetchSpend("yesterday", yesterday.getTime(), midnight.getTime());
        root.fetchSpend("month", now - 30 * 86400000, now);
    }

    // Best effort: a failed read keeps the last good figures and never sets
    // the drawer's error line, which belongs to the quota summary.
    function fetchSpend(key: string, fromMs: double, toMs: double): void {
        let request = null;
        try {
            request = new XMLHttpRequest();
        } catch (e) {
            return;
        }
        request.onload = function () {
            if (request.status < 200 || request.status >= 300)
                return;
            let body = null;
            try {
                body = JSON.parse(request.responseText);
            } catch (e) {
                return;
            }
            if (!body || !Array.isArray(body.channel_share))
                return;
            const totals = {};
            for (const row of body.channel_share) {
                const cost = Number(row && row.cost);
                if (!Number.isFinite(cost) || cost <= 0)
                    continue;
                const id = root.spendProviderId(row.auth_provider_snapshot);
                totals[id] = (totals[id] || 0) + cost;
            }
            const rows = Object.keys(totals).filter(id => totals[id] >= 0.005)
                .map(id => ({ provider: id, cost: totals[id] }))
                .sort((a, b) => b.cost - a.cost);
            const next = Object.assign({}, root.spend);
            next[key] = { total: rows.reduce((sum, row) => sum + row.cost, 0), rows: rows };
            root.spend = next;
            root.writeCache();
        };
        try {
            request.open("POST", root.baseUrl + root.analyticsUrlSuffix);
            request.setRequestHeader("Authorization", "Bearer " + root.adminKey);
            request.setRequestHeader("Content-Type", "application/json");
            request.setRequestHeader("Accept", "application/json");
            request.timeout = root.requestTimeoutMs;
            request.send(JSON.stringify({ from_ms: fromMs, to_ms: toMs, include: { channel_share: true } }));
        } catch (e) {}
    }

    function finishRequest(): void {
        watchdog.stop();
        root.inFlight = false;
        root.loading = false;
        root.activeRequest = null;
    }

    function failRefresh(timedOut: bool): void {
        if (!root.inFlight)
            return;
        root.finishRequest();
        root.error = timedOut
            ? qsTr("Quota refresh timed out. Showing saved data.")
            : qsTr("Quota refresh failed. Showing saved data.");
        root.status = "error";
    }

    Timer {
        id: watchdog
        interval: root.requestTimeoutMs + 1000
        repeat: false
        onTriggered: {
            if (!root.inFlight)
                return;
            root.requestTimedOut = true;
            const request = root.activeRequest;
            root.activeRequest = null;
            root.finishRequest();
            if (request) {
                try {
                    request.abort();
                } catch (e) {}
            }
            root.error = qsTr("Quota refresh timed out. Showing saved data.");
            root.status = "error";
        }
    }

    // -- Mapping -------------------------------------------------------------

    function friendlyError(code: string): string {
        switch (String(code || "").toLowerCase()) {
        case "unauthorized":
            return qsTr("Account authorization needs attention in CPA.");
        case "rate_limited":
            return qsTr("The provider rate-limited the quota read.");
        case "timeout":
            return qsTr("The provider did not answer the quota request.");
        case "not_found":
            return qsTr("The provider could not find this account.");
        case "parse_failed":
            return qsTr("CPA could not interpret the provider's quota response.");
        case "not_configured":
        case "setup_required":
            return qsTr("Quota reporting is not configured in CPA.");
        case "no_accounts":
            return qsTr("CPA reported no quota accounts.");
        default:
            return qsTr("CPA could not read this account's quota.");
        }
    }

    function windowBaseLabel(id: string): string {
        const value = String(id || "").toLowerCase();
        if (/five[-_]hour|session/.test(value))
            return qsTr("5-hour");
        if (/seven[-_]day|weekly/.test(value))
            return qsTr("Weekly");
        return qsTr("Quota");
    }

    function windowTitle(providerId: string, window: var): string {
        const label = String(window.label || "").trim();
        // The original collector marked a model-scoped window with "·".
        if (label.indexOf("·") >= 0)
            return label;
        const id = String(window.id || "");
        const match = id.match(/^(?:five[-_]hour|seven[-_]day|weekly|session)[-_](.+)$/i);
        if (match) {
            const scope = match[1].replace(/[-_]+/g, " ").trim();
            if (scope && !/^(window|primary|secondary|weekly|session)$/i.test(scope)) {
                const pretty = scope.split(" ").map(part => {
                    if (/^oauth$/i.test(part))
                        return "OAuth";
                    if (/^api$/i.test(part))
                        return "API";
                    return part.charAt(0).toUpperCase() + part.slice(1);
                }).join(" ");
                return pretty + " · " + (label || root.windowBaseLabel(id));
            }
        }
        return label || root.windowBaseLabel(id);
    }

    function mapWindow(providerId: string, window: var, index: int): var {
        if (!window || typeof window !== "object")
            return null;
        const used = window.usedPercent;
        let percent = null;
        if (used !== null && used !== undefined && Number.isFinite(Number(used)))
            percent = Math.max(0, Math.min(100, Number(used))) / 100;
        else if (window.remainingPercent !== null && window.remainingPercent !== undefined
                && Number.isFinite(Number(window.remainingPercent)))
            percent = Math.max(0, Math.min(100, 100 - Number(window.remainingPercent))) / 100;
        const title = root.windowTitle(providerId, window);
        return {
            id: String(window.id || ("window-" + index)),
            title: title,
            label: title,
            percent: percent,
            resetsAt: String(window.resetAt || ""),
            estimated: !!window.estimated,
            source: String(window.source || "")
        };
    }

    // CPA Manager reports errors as { code } objects (see KSG Code's decoder);
    // accept a bare string too.
    function errorCode(error: var): string {
        if (error === null || error === undefined)
            return "";
        if (typeof error === "object")
            return String(error.code || "error");
        return String(error);
    }

    function mapAccount(provider: var, account: var, providerRank: int, stamp: string, providerError: string): var {
        const providerId = root.normalizeProviderId(provider.id);
        const code = root.errorCode(account.error) || providerError;
        const message = code ? root.friendlyError(code) : "";
        const failed = account.status === "error" || account.status === "unavailable" || code !== "";
        const disabled = account.status === "disabled" || account.status === "inactive";
        const plan = String(account.plan || "").trim();
        const label = String(account.label || "").trim();
        const display = label || plan || String(provider.label || provider.id || "Account");
        const windows = Array.isArray(account.windows)
            ? account.windows.map((window, i) => root.mapWindow(providerId, window, i)).filter(w => w !== null)
            : [];
        return {
            id: providerId + ":" + String(account.id || ("account-" + providerRank + "-" + windows.length)),
            name: display,
            account: label,
            accountLabel: display,
            provider: providerId,
            providerLabel: String(provider.label || provider.id || "Agent"),
            tierLabel: plan || String(provider.label || ""),
            chipLabel: display,
            status: String(account.status || "ok"),
            statusMessage: message,
            usageStatusText: message,
            errorText: message,
            unavailable: failed,
            disabled: disabled,
            cooldowns: [],
            cooldownUntil: "",
            limits: windows,
            lastUsedAt: "",
            poolGroup: null,
            poolAccounts: [],
            poolLimits: [],
            balance: null,
            recentDays: [],
            modelUsage: {},
            allTime: null,
            updatedAt: stamp,
            quotaUpdatedAt: stamp,
            quotaCheckedAt: stamp,
            quotaError: message,
            quotaAuthRequired: /unauthorized|auth_required|reauth/i.test(code),
            dailyMetric: "tokens",
            tokensToday: 0,
            requestsToday: 0,
            providerRank: providerRank
        };
    }

    // Returns false when the body is not a usable summary.
    function applySummary(raw: string): bool {
        let summary = null;
        try {
            summary = JSON.parse(raw);
        } catch (e) {
            return false;
        }
        if (!summary || !Array.isArray(summary.providers))
            return false;
        if (summary.schemaVersion !== undefined && summary.schemaVersion !== 1)
            return false;

        const stampSource = String(summary.refreshedAt || summary.generatedAt || "");
        let stamp = Date.parse(stampSource);
        if (!Number.isFinite(stamp))
            stamp = Date.now();
        const stampIso = new Date(stamp).toISOString();
        const ttl = Number(summary.ttlMs);
        root.ttlMs = (Number.isFinite(ttl) && ttl > 0) ? ttl : 0;

        const groups = [];
        const records = [];
        const prior = root.selectedProviderId;
        let priorProvider = "";
        for (let i = 0; i < root.providers.length; i++) {
            if (root.providers[i].id === prior) {
                priorProvider = root.providers[i].provider;
                break;
            }
        }
        for (let i = 0; i < summary.providers.length; i++) {
            const provider = summary.providers[i];
            if (!provider || typeof provider !== "object")
                continue;
            const id = root.normalizeProviderId(provider.id);
            if (!id)
                continue;
            const accounts = Array.isArray(provider.accounts) ? provider.accounts : [];
            if (!groups.some(group => group.id === id))
                groups.push({ id: id, label: String(provider.label || provider.id), rank: i, order: groups.length });
            const providerError = root.errorCode(provider.error);
            for (let j = 0; j < accounts.length; j++) {
                if (accounts[j] && typeof accounts[j] === "object")
                    records.push(root.mapAccount(provider, accounts[j], groups.length - 1, stampIso, providerError));
            }
        }

        // Stable provider order, codex-first like the original drawer. Unknown
        // providers keep the manager's own order at the end.
        const preferred = ["codex", "claude", "antigravity", "cursor", "zai", "opencode-go", "vertex", "kimi"];
        groups.sort((a, b) => {
            const aIdx = preferred.indexOf(a.id);
            const bIdx = preferred.indexOf(b.id);
            const aRank = aIdx >= 0 ? aIdx : 99;
            const bRank = bIdx >= 0 ? bIdx : 99;
            if (aRank !== bRank)
                return aRank - bRank;
            return a.order - b.order;
        });

        const ordered = [];
        for (let i = 0; i < groups.length; i++) {
            const group = groups[i];
            for (let j = 0; j < records.length; j++) {
                if (records[j].provider === group.id)
                    ordered.push(records[j]);
            }
        }

        const summaryCode = root.errorCode(summary.error);
        const summaryError = summaryCode ? root.friendlyError(summaryCode) : "";
        root.providers = ordered;
        root.todayCostUsd = (typeof summary.todayCostUsd === "number" && Number.isFinite(summary.todayCostUsd))
            ? summary.todayCostUsd : null;
        root.lastUpdatedAt = stamp;
        root.error = ordered.length === 0 && summaryError ? summaryError : "";
        const degraded = ordered.some(a => a.unavailable)
            || (typeof summary.status === "string" && summary.status !== "ok")
            || (summaryError !== "" && ordered.length > 0);
        root.status = root.error !== "" ? "error" : degraded ? "partial" : "ok";

        let exists = false;
        for (let i = 0; i < ordered.length; i++) {
            if (ordered[i].id === prior) {
                exists = true;
                break;
            }
        }
        if (!exists) {
            // A cached summary uses display-only ids. Keep the same provider
            // when the first live summary replaces it.
            let fallback = "";
            for (let i = 0; i < ordered.length && priorProvider; i++) {
                if (ordered[i].provider === priorProvider) {
                    fallback = ordered[i].id;
                    break;
                }
            }
            root.selectedProviderId = fallback || root.defaultProviderId();
        }

        root.writeCache();
        return true;
    }

    // -- Clock ---------------------------------------------------------------

    // Called by an open drawer. Update once immediately so relative times are
    // correct before the next tick.
    function holdClock(): void {
        root.clockHolders++;
        root.nowMs = Date.now();
    }

    function releaseClock(): void {
        root.clockHolders = Math.max(0, root.clockHolders - 1);
    }

    // -- Timers --------------------------------------------------------------

    Timer {
        id: autoRefreshTimer
        interval: root.effectiveRefreshMs
        running: root.configured && root.enabled
        repeat: true
        onTriggered: root.refresh(false)
    }

    Timer {
        id: clockTimer
        interval: 10000 // 10 seconds tick
        // Only tick while a drawer is open; no Quota UI means no countdowns.
        running: root.enabled && root.clockHolders > 0
        repeat: true
        onTriggered: root.nowMs = Date.now()
    }

    IpcHandler {
        target: "agentQuota"

        function selectGroup(provider: string): void {
            root.selectGroup(provider);
        }

        function selectProvider(id: string): void {
            root.selectProvider(id);
        }

        function refresh(): void {
            root.refresh(true);
        }
    }

    onConfiguredChanged: root.maybeRefresh()
    onEnabledChanged: root.maybeRefresh()

    Component.onCompleted: {
        if (!root.configured) {
            root.status = "unconfigured";
            return;
        }
        // The endpoint FileView and cache FileView load asynchronously.
        root.status = "idle";
    }
}
