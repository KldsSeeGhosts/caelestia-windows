pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.services
import "QuotaHub.js" as Hub

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
//
// Hub mode: stock CLIProxyAPI has no quota/summary (404), and CPA Manager's
// summary has no token history or limit resets. In either case, when the
// summary is missing or "Detailed usage via CLIProxyAPI" (windows.quota.cpaHub)
// is on, providers/quota_providers.py reads each hub login through the hub's
// api-call tunnel. It runs only while the panel is on, gets the key over stdin
// and answers with masked accounts; QuotaHub.js merges them with the summary.
//
// A refused key (401 or IP ban) is remembered in the cache as a salted
// fingerprint, never the key. While it matches the key in cpa-agents.json no
// management request of any kind goes out, here or in the helper, across panel
// toggles, reloads and restarts; CLIProxyAPI bans after five wrong keys.
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
    // The best-effort spend reads in flight, so switching the panel off can abort them.
    property var spendRequests: []

    property var providers: []
    property string selectedProviderId: ""
    // "priority" | "all". Kept here, not in the drawer, so the choice outlasts
    // the drawer closing; nothing is saved to disk.
    property string usageView: "all"
    property var todayCostUsd: null
    // { today | yesterday | month: { total, rows: [{ provider, cost }] } }
    property var spend: ({})

    // Hub mode (see above). summaryRecords and hubRecords are the two sources;
    // providers is their merge.
    property var summaryRecords: []
    property var hubRecords: []
    property var summaryIdentities: []
    // quota/summary answered 404: stock CLIProxyAPI, so the hub is the only source.
    property bool summaryMissing: false
    // The helper's view of the hub: "" (not started), ok, key_rejected, banned,
    // insecure, unreachable, management_off, remote_off, ...
    property string hubState: ""
    property bool hubStarting: false
    property double hubNextDueAt: 0
    property double hubUpdatedAt: 0
    // The helper's persisted state (Claude 429 windows by opaque account tag).
    property var hubSaved: ({})
    // quota/summary answered with this key, so the helper may use it too. One
    // source probes a new key first; the helper never doubles its strikes.
    property bool summaryAnswered: false
    // The cache has been read (or found missing), so a saved refusal is known
    // before the first request.
    property bool cacheReady: false
    // { salt, fingerprint, code, until } of the last refused key (QuotaHub.js).
    property var keyRefusal: null
    readonly property bool keyRefused: Hub.refusalMatches(root.keyRefusal, root.adminKey)
    // The same key's banned window has passed: it may be asked again explicitly.
    readonly property bool keyBanExpired: Hub.refusalExpired(root.keyRefusal, root.adminKey, root.nowMs)
    // Stable tag of the configured key, carried by every request in flight.
    readonly property string keyTag: Hub.requestTag(root.adminKey)
    // "Detailed usage via CLIProxyAPI" on, with a plain-http hub off this PC (the
    // local network or Tailscale). The summary read is loopback-only, so the hub
    // is the only source. Unlike summaryMissing, this ends with the setting.
    readonly property bool hubHttpOptIn: QuotaConfig.cpaHub && /^http:\/\//i.test(root.baseUrl) && !root.loopbackHttp(root.baseUrl)
    // No summary to read: the hub helper is the only source.
    readonly property bool hubOnly: root.summaryMissing || root.hubHttpOptIn
    readonly property bool hubWanted: root.enabled && root.endpointLoaded && root.baseUrl !== "" && root.adminKey !== ""
        && root.cacheReady && !root.keyRefused
        && (root.hubOnly || (QuotaConfig.cpaHub && root.summaryAnswered))
    readonly property string hubScript: Quickshell.shellPath("providers/quota_providers.py")
    // Read by the offscreen smoke to prove the helper is gone once switched off.
    readonly property var hubProcessId: hubProcess.processId
    readonly property double nextUpdateAt: root.hubOnly ? root.hubNextDueAt
        : root.lastUpdatedAt > 0 ? root.lastUpdatedAt + root.effectiveRefreshMs : 0

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
        if (!QuotaConfig.enabled || !QuotaConfig.configured || keepaliveProcess.running || root.keyRefused)
            return; // keepalive lists the hub's logins with the key too
        keepaliveRunning = true;
        keepaliveDone = 0;
        keepaliveError = "";
        keepaliveProcess.running = true;
        if (!keepaliveProcess.running) {
            // FailedToStart clears running without emitting exited. Use the
            // same deferred single-handler shape as onRunningChanged below, so
            // keepaliveRunning is released outside the Process's own state
            // change and both paths can never report twice.
            keepaliveStartCheck.start();
        }
    }

    // Deferred spawn-failure report. Owned by this object rather than queued
    // with Qt.callLater, so destroying the service (for example a QML reload)
    // cancels a pending check instead of running it on a dead object.
    Timer {
        id: keepaliveStartCheck
        interval: 0
        repeat: false
        onTriggered: {
            if (!keepaliveProcess.running && root.keepaliveRunning)
                root.keepaliveStartFailed();
        }
    }

    // The asynchronous FailedToStart case: running can drop right after the
    // assignment above without an exited emission.
    function keepaliveStartFailed(): void {
        if (!root.keepaliveRunning)
            return;
        root.keepaliveRunning = false;
        root.keepaliveError = qsTr("Keepalive helper failed to start");
    }

    Process {
        id: keepaliveProcess
        command: QuotaConfig.pythonCommand.concat(["-I", root.keepaliveScript, "--cpa-config", QuotaConfig.cpaConfigPath])
        environment: root.keepaliveEnvironment

        stdout: SplitParser {
            splitMarker: "\n"
            onRead: data => {
                const line = String(data).trim();
                if (!line)
                    return;
                try {
                    const msg = JSON.parse(line);
                    if (msg && msg.type === "refused") {
                        // The hub refused the key Keepalive read from cpa-agents.json.
                        root.adoptRefusal(msg.refusal);
                    } else if (msg && msg.type === "progress" && typeof msg.done === "number") {
                        root.keepaliveDone = Math.max(0, Math.min(msg.total || root.keepaliveTotal, msg.done));
                        if (msg.total)
                            root.keepaliveTotal = msg.total;
                    } else if (msg && typeof msg.failed === "number") {
                        root.applyKeepaliveSummary(msg);
                    } else if (msg && typeof msg.ok === "boolean" && msg.ok === false) {
                        root.keepaliveError = msg.error || "Keepalive failed";
                    }
                } catch (e) {}
            }
        }

        onRunningChanged: {
            if (!keepaliveProcess.running && root.keepaliveRunning && QuotaConfig.enabled) {
                // Defer so onExited wins for a process that did run; a failed
                // spawn never emits it.
                keepaliveStartCheck.start();
            }
        }

        onExited: (exitCode, exitStatus) => {
            // Ensure the ring completes even if the script was fast and progress lines were coalesced.
            if (root.keepaliveDone < root.keepaliveTotal)
                root.keepaliveDone = root.keepaliveTotal;
            root.keepaliveRunning = false;
            // Refresh so the panel reflects the newly-active window, unless the
            // panel was switched off while the helper ran.
            if (QuotaConfig.enabled)
                root.refresh(true);
        }
    }

    function applyKeepaliveSummary(message: var): void {
        if (message.failed > 0 || message.fallback > 0)
            root.keepaliveError = qsTr("Keepalive: %1 inference succeeded, %2 quota reads only, %3 failed")
                .arg(message.succeeded).arg(message.fallback).arg(message.failed);
    }

    // -- Endpoint and cache --------------------------------------------------

    // Contents are read here and never logged or exposed as a file dump.
    FileView {
        id: endpointFile

        // Off means the key is not even read into memory; on reads it again.
        path: root.enabled ? QuotaConfig.cpaConfigPath : ""
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

        onLoaded: {
            root.loadCache(cacheFile.text());
            root.cacheChecked();
        }
        onLoadFailed: root.cacheChecked()
    }

    function cacheChecked(): void {
        if (root.cacheReady)
            return;
        root.cacheReady = true;
        root.maybeRefresh();
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
        if (previous !== base + "\n" + key) {
            // Another endpoint: nothing already in flight is about it. Abort so
            // its late answer cannot be read as this key's, then ask again.
            root.abortRequests();
            // Find out again whether it has a summary.
            root.summaryMissing = false;
            root.summaryAnswered = false;
            root.sendHubConfig();
            root.refresh(true);
        } else {
            root.maybeRefresh();
        }
    }

    function loadCache(raw: string): void {
        let cached = null;
        try {
            cached = JSON.parse((raw || "").replace(/^\uFEFF/, ""));
        } catch (e) {
            return;
        }
        if (cached && cached.refusal && typeof cached.refusal === "object" && !root.keyRefusal)
            root.keyRefusal = cached.refusal;
        // A live response always wins over the cache, even if it arrives first.
        if (root.providers.length > 0 || root.lastUpdatedAt > 0)
            return;
        if (!cached || !Array.isArray(cached.providers) || cached.providers.length === 0)
            return;
        root.providers = cached.providers;
        root.lastUpdatedAt = Number(cached.lastUpdatedAt) || 0;
        root.ttlMs = Number(cached.ttlMs) || 0;
        root.todayCostUsd = (typeof cached.todayCostUsd === "number" && Number.isFinite(cached.todayCostUsd))
            ? cached.todayCostUsd : null;
        if (cached.spend && typeof cached.spend === "object" && Object.keys(root.spend).length === 0)
            root.spend = cached.spend;
        if (cached.hub && typeof cached.hub === "object" && Object.keys(root.hubSaved).length === 0)
            root.hubSaved = cached.hub;
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
            providerRank: rec.providerRank,
            // Hub detail: aggregates and expiry times only.
            resetCredits: rec.resetCredits ? { count: Number(rec.resetCredits.count) || 0, expiries: (rec.resetCredits.expiries || []).map(String) } : null,
            history: rec.history && rec.history.days ? { days: rec.history.days } : null
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
                hub: root.hubSaved,
                refusal: root.keyRefusal,
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
        if (!root.enabled)
            return;
        if (!root.cacheReady)
            return;
        // The one gate for every management request made with this key.
        if (root.keyRefused) {
            root.showRefusal();
            return;
        }
        // Refresh now also asks the helper, which skips accounts read in the
        // last minute, and starts it again if it stopped on its own.
        if (force && root.hubWanted && !hubProcess.running)
            root.startHub();
        else if (force)
            root.hubCommand({ type: "refresh", force: true });
        if (root.inFlight)
            return;
        // Stock CLIProxyAPI has no summary to poll; only Refresh now or a new
        // endpoint asks again.
        if (!force && root.hubOnly)
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
        if (!/^https:\/\//i.test(root.baseUrl) && !root.loopbackHttp(root.baseUrl)) {
            // With "Detailed usage via CLIProxyAPI" on, the hub helper may use
            // plain http on the local network or Tailscale; it resolves the host
            // and checks every address itself. The summary read stays loopback-only.
            if (root.hubHttpOptIn) {
                root.useHubOnly();
                return;
            }
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

        root.inFlight = true;
        root.loading = true;
        root.requestTimedOut = false;
        root.lastRequestAt = Date.now();
        root.activeRequest = request;
        // What this request was sent with: a late answer for a replaced key is
        // not about the configured one and must not close the gate.
        const tag = root.keyTag;
        watchdog.restart();

        request.onload = function () {
            if (root.activeRequest !== request)
                return;
            if (tag !== root.keyTag) {
                root.finishRequest();
                return;
            }
            try {
                const refused = Hub.refusalCode(request.status, request.responseText);
                if (refused) {
                    root.finishRequest();
                    root.recordRefusal(refused);
                    return;
                }
                if (request.status >= 200 && request.status < 300) {
                    if (!root.applySummary(request.responseText)) {
                        root.failRefresh(false);
                        return;
                    }
                    root.finishRequest();
                    // Spend goes out only once the summary accepted the key.
                    root.refreshSpend();
                    return;
                }
                if (request.status === 404) {
                    // Stock CLIProxyAPI: no summary, so the hub helper reads it all.
                    root.finishRequest();
                    root.summaryMissing = true;
                    root.useHubOnly();
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
        if (root.keyRefused)
            return;
        let request = null;
        try {
            request = new XMLHttpRequest();
        } catch (e) {
            return;
        }
        root.spendRequests.push(request);
        const tag = root.keyTag;
        const settle = function () {
            const at = root.spendRequests.indexOf(request);
            if (at >= 0)
                root.spendRequests.splice(at, 1);
        };
        request.onload = function () {
            settle();
            // A late answer for a key that has been replaced says nothing about
            // the configured one, either for the figures or for the gate.
            if (tag !== root.keyTag)
                return;
            const refused = Hub.refusalCode(request.status, request.responseText);
            if (refused)
                root.recordRefusal(refused);
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
        // Best effort, like the summary above: a transport failure or timeout
        // keeps the last good figures, sets no drawer error and logs nothing
        // (no body or key is read here).
        request.onerror = settle;
        request.ontimeout = settle;
        try {
            request.open("POST", root.baseUrl + root.analyticsUrlSuffix);
            request.setRequestHeader("Authorization", "Bearer " + root.adminKey);
            request.setRequestHeader("Content-Type", "application/json");
            request.setRequestHeader("Accept", "application/json");
            request.timeout = root.requestTimeoutMs;
            request.send(JSON.stringify({ from_ms: fromMs, to_ms: toMs, include: { channel_share: true } }));
        } catch (e) {}
    }

    // Switched off from Nexus: abort anything in flight so no request or watchdog
    // outlives the setting. The cached summary stays for when it is switched on.
    function suspend(): void {
        watchdog.stop();
        // The off switch also ends Keepalive: it sends inference requests.
        keepaliveStartCheck.stop();
        // signal(9) kills; `running = false` only terminates, which does not stop the Python helper on Windows.
        if (keepaliveProcess.running)
            keepaliveProcess.signal(9);
        root.keepaliveRunning = false;
        root.stopHub();
        root.abortRequests();
    }

    function abortRequests(): void {
        const aborting = root.spendRequests.concat([root.activeRequest]);
        root.spendRequests = [];
        root.activeRequest = null;
        root.inFlight = false;
        root.loading = false;
        for (const request of aborting) {
            try {
                if (request)
                    request.abort();
            } catch (e) {}
        }
    }

    function loopbackHttp(url: string): bool {
        return /^http:\/\/(127\.0\.0\.1|localhost|\[::1\])(:\d+)?(\/|$)/i.test(url);
    }

    // The hub helper or Keepalive was refused: adopt its record when it is for
    // this key, which closes the gate (hubWanted then stops the helper).
    function adoptRefusal(record: var): bool {
        if (!Hub.refusalMatches(record, root.adminKey))
            return false;
        if (!root.keyRefused) {
            root.keyRefusal = record;
            root.writeCache();
        }
        root.abortRequests();
        root.showRefusal();
        return true;
    }

    // The hub refused this key: close the gate (which also stops the helper
    // through hubWanted), remember it and say what to do.
    function recordRefusal(code: string): void {
        if (!root.keyRefused) {
            root.keyRefusal = Hub.refusal(code, root.adminKey, Date.now());
            root.writeCache();
        }
        root.abortRequests();
        root.showRefusal();
    }

    // A ban's 30 minutes have passed: ask once more with the same key, only
    // because the user asked. A 401 is not retried this way.
    // One probe per click: in hub mode the helper is the only source, so let
    // onHubWantedChanged start it. Otherwise keep hubWanted false until one
    // summary request answers; that answer starts the helper on success.
    function retryRefusedKey(): void {
        if (!root.keyBanExpired)
            return;
        if (!root.hubOnly)
            root.summaryAnswered = false;
        root.keyRefusal = null;
        root.error = "";
        root.status = "idle";
        root.writeCache();
        if (!root.hubOnly)
            root.refresh(true);
    }

    function showRefusal(): void {
        root.error = root.friendlyError(root.keyRefusal ? root.keyRefusal.code : "key_rejected");
        root.status = "error";
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
        case "hub_key":
        case "key_rejected":
            return qsTr("CLIProxyAPI rejected the management key. Update cpa-agents.json.");
        case "hub_banned":
        case "banned":
            return qsTr("CLIProxyAPI blocked this PC after too many wrong keys. Update cpa-agents.json, then wait 30 minutes.");
        case "insecure":
            return qsTr("Use https for CLIProxyAPI. Plain http is only used for addresses on this PC, the local network or Tailscale.");
        case "unreachable":
            return qsTr("Can't reach CLIProxyAPI.");
        case "management_off":
            return qsTr("CLIProxyAPI's management API is off. Set a management key in its config.");
        case "remote_off":
            return qsTr("CLIProxyAPI only allows management from its own machine. Turn on allow-remote.");
        case "helper_failed":
            return qsTr("The usage helper stopped. Refresh to start it again.");
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
            providerRank: providerRank,
            planReported: plan !== ""
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

        const records = [];
        let rank = 0;
        for (let i = 0; i < summary.providers.length; i++) {
            const provider = summary.providers[i];
            if (!provider || typeof provider !== "object")
                continue;
            const id = root.normalizeProviderId(provider.id);
            if (!id)
                continue;
            const accounts = Array.isArray(provider.accounts) ? provider.accounts : [];
            const providerError = root.errorCode(provider.error);
            for (let j = 0; j < accounts.length; j++) {
                if (accounts[j] && typeof accounts[j] === "object")
                    records.push(root.mapAccount(provider, accounts[j], rank, stampIso, providerError));
            }
            rank++;
        }
        // Stable provider order, codex-first like the original drawer. Unknown
        // providers keep the manager's own order at the end.
        const ordered = Hub.order(records);

        const summaryCode = root.errorCode(summary.error);
        const summaryError = summaryCode ? root.friendlyError(summaryCode) : "";
        root.summaryMissing = false;
        root.summaryAnswered = true;
        root.summaryRecords = ordered;
        root.summaryIdentities = Hub.identities(summary);
        root.hubCommand({ type: "summary", accounts: root.summaryIdentities });
        root.todayCostUsd = (typeof summary.todayCostUsd === "number" && Number.isFinite(summary.todayCostUsd))
            ? summary.todayCostUsd : null;
        root.lastUpdatedAt = stamp;
        root.error = ordered.length === 0 && summaryError ? summaryError : "";
        const degraded = ordered.some(a => a.unavailable)
            || (typeof summary.status === "string" && summary.status !== "ok")
            || (summaryError !== "" && ordered.length > 0);
        root.status = root.error !== "" ? "error" : degraded ? "partial" : "ok";
        root.rebuild();
        return true;
    }

    // providers = the summary rows with the hub's detail merged in, plus the
    // hub accounts the summary does not have. Keeps the selected provider.
    function rebuild(): void {
        const prior = root.selectedProviderId;
        let priorProvider = "";
        for (let i = 0; i < root.providers.length; i++) {
            if (root.providers[i].id === prior) {
                priorProvider = root.providers[i].provider;
                break;
            }
        }
        const merged = Hub.order(Hub.merge(root.summaryRecords, root.hubRecords));
        // Source transitions and failed reads can briefly have no rows. Keep
        // the last useful reading, including one restored from disk.
        if (merged.length === 0 && root.providers.length > 0)
            return;
        root.providers = merged;
        if (!merged.some(r => r.id === prior)) {
            // A cached summary uses display-only ids. Keep the same provider
            // when the first live summary replaces it.
            const fallback = priorProvider ? merged.find(r => r.provider === priorProvider) : null;
            root.selectedProviderId = fallback ? fallback.id : root.defaultProviderId();
        }
        root.writeCache();
    }

    // -- Hub mode --------------------------------------------------------------

    // No summary (stock CPA, or an opted-in LAN/Tailscale http hub): the hub is the only source.
    function useHubOnly(): void {
        root.summaryRecords = [];
        root.summaryIdentities = [];
        root.applyHubStatus();
        root.rebuild();
    }

    function applyHubStatus(): void {
        if (!root.hubOnly)
            return;
        const bad = root.hubState !== "" && root.hubState !== "ok";
        root.error = bad && root.hubRecords.length === 0 ? root.friendlyError(root.hubState) : "";
        root.status = root.error !== "" ? "error"
            : root.hubState === "" ? "loading"
            : (bad || root.hubRecords.some(a => a.unavailable)) ? "partial" : "ok";
        if (root.hubUpdatedAt > 0)
            root.lastUpdatedAt = root.hubUpdatedAt;
    }

    function hubCommand(message: var): void {
        if (hubProcess.running)
            hubProcess.write(JSON.stringify(message) + "\n");
    }

    // The key goes to the helper here, over stdin, and nowhere else.
    function sendHubConfig(): void {
        root.hubCommand({
            type: "configure", baseUrl: root.baseUrl, adminKey: root.adminKey,
            refreshIntervalMs: root.refreshIntervalMs,
            state: Object.assign({}, root.hubSaved, { refusal: root.keyRefusal })
        });
    }

    function startHub(): void {
        if (!hubProcess.running) {
            root.hubStarting = true;
            hubProcess.running = true;
            if (!hubProcess.running)
                hubStartCheck.start();
        }
    }

    function hubFailed(): void {
        root.hubStarting = false;
        if (!root.hubWanted)
            return;
        root.hubState = "helper_failed";
        root.loading = false;
        root.applyHubStatus();
    }

    function stopHub(): void {
        hubTimer.stop();
        hubStartCheck.stop();
        root.hubStarting = false;
        // signal(9) kills; `running = false` only terminates, which does not stop the Python helper on Windows.
        if (hubProcess.running)
            hubProcess.signal(9);
        // Switched off: keep the reading for when it comes back on. Not wanted
        // any more (the setting went off and the summary answers): drop it.
        // A refusal stops requests, not the last-good readings or their cache.
        if (root.enabled && !root.keyRefused && root.hubRecords.length > 0) {
            root.hubRecords = [];
            root.hubState = "";
            root.rebuild();
        }
    }

    function mapHubAccount(account: var): var {
        const stamp = account.readAt || new Date().toISOString();
        const record = root.mapAccount({ id: account.provider, label: account.providerLabel }, account, 0, stamp, "");
        record.resetCredits = account.resetCredits || null;
        record.history = account.history || null;
        record.summaryRef = account.summaryRef || "";
        return record;
    }

    function applyHubSnapshot(message: var): void {
        if (root.adoptRefusal(message.state && message.state.refusal))
            return;
        root.hubState = String(message.hub && message.hub.state || "");
        root.hubRecords = (Array.isArray(message.accounts) ? message.accounts : [])
            .filter(a => a && typeof a === "object" && a.provider)
            .map(a => root.mapHubAccount(a));
        if (message.state && typeof message.state === "object")
            root.hubSaved = message.state;
        root.hubUpdatedAt = Date.now();
        const due = Number(message.nextDueAt);
        root.hubNextDueAt = Number.isFinite(due) && due > 0 ? due : 0;
        hubTimer.stop();
        if (root.hubNextDueAt > 0) {
            // One single-shot timer to the helper's earliest deadline; nothing polls.
            hubTimer.interval = Math.max(1000, root.hubNextDueAt - Date.now());
            hubTimer.start();
        }
        root.applyHubStatus();
        root.rebuild();
    }

    Process {
        id: hubProcess
        command: QuotaConfig.pythonCommand.concat(["-I", root.hubScript, "serve"])
        environment: ({ "PYTHONUTF8": "1", "PYTHONDONTWRITEBYTECODE": "1" })
        stdinEnabled: true

        stdout: SplitParser {
            splitMarker: "\n"
            onRead: data => {
                let message = null;
                try {
                    message = JSON.parse(String(data));
                } catch (e) {
                    return;
                }
                if (message && message.type === "snapshot")
                    root.applyHubSnapshot(message);
            }
        }
        // Drained, never shown: the helper writes only short redacted diagnostics.
        stderr: SplitParser {
            splitMarker: "\n"
        }

        onRunningChanged: {
            if (hubProcess.running) {
                root.sendHubConfig();
                if (!root.hubOnly)
                    root.hubCommand({ type: "summary", accounts: root.summaryIdentities });
            } else if (root.hubStarting) {
                hubStartCheck.start();
            }
        }
        onStarted: root.hubStarting = false
        onExited: (exitCode, exitStatus) => {
            hubTimer.stop();
            // Still wanted: it failed on its own. No blind restart; the next
            // Refresh now or setting change starts it again.
            root.hubFailed();
        }
    }

    Timer {
        id: hubStartCheck
        interval: 0
        repeat: false
        onTriggered: {
            if (!hubProcess.running && root.hubStarting)
                root.hubFailed();
        }
    }

    Timer {
        id: hubTimer
        repeat: false
        onTriggered: root.hubCommand({ type: "refresh", force: false })
    }

    onHubWantedChanged: {
        if (root.hubWanted)
            root.startHub();
        else
            root.stopHub();
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
    // Detailed usage switched: a plain-http hub off this PC starts or stops being a source.
    readonly property bool cpaHub: QuotaConfig.cpaHub
    onCpaHubChanged: {
        // Switching hub mode on makes the helper the only source straight away;
        // the summary rows from the previous endpoint must not sit beside it.
        if (root.hubHttpOptIn)
            root.useHubOnly();
        root.maybeRefresh();
    }
    onEnabledChanged: {
        if (root.enabled)
            root.maybeRefresh();
        else
            root.suspend();
    }

    Component.onCompleted: {
        if (!root.configured) {
            root.status = "unconfigured";
            return;
        }
        // The endpoint FileView and cache FileView load asynchronously.
        root.status = "idle";
    }
}
