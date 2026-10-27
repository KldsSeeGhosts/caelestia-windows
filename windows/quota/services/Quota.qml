pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.services

// Quota & Agents usage data service, ported from the Linux overlay.
//
// Periodically collects usage from CPA management via cpa_usage.py, reads
// records from the profile state directory via read_records.py, and parses
// limit windows, models, daily tokens, and balances for the dropdown.
//
// Windows differences from the original:
//   * paths come from QuotaConfig (profile config/state/cache) instead of HOME
//     and XDG_* Linux defaults;
//   * python3 is replaced by the profile Python or the py launcher, with -I;
//   * the GNU `timeout` wrapper is replaced by the QML watchdogs below, so a
//     hung collector or ledger download is killed instead of lingering;
//   * nothing runs unless a CPA management config exists, which keeps a machine
//     without CPA quiet (no process, no error, empty drawer state).
Singleton {
    id: root

    readonly property string updateScript: Quickshell.shellPath("scripts/cpa_usage.py")
    readonly property string readScript: Quickshell.shellPath("scripts/read_records.py")
    readonly property string keepaliveScript: Quickshell.shellPath("scripts/cpa_keepalive.py")

    readonly property int refreshIntervalMs: QuotaConfig.refreshIntervalMs
    readonly property int refreshTimeoutMs: QuotaConfig.refreshTimeoutMs
    readonly property bool configured: QuotaConfig.configured
    readonly property bool enabled: QuotaConfig.enabled

    // The collector and the reader must agree on the record location. Passing
    // XDG_* to the child keeps the upstream scripts' own directory logic.
    readonly property var childEnvironment: ({
        "XDG_STATE_HOME": QuotaConfig.stateHome,
        "XDG_CACHE_HOME": QuotaConfig.cacheHome,
        "HOME": QuotaConfig.home,
        "USERPROFILE": QuotaConfig.home,
        "PYTHONUTF8": "1"
    })

    // Live clock for reset countdowns
    property double nowMs: Date.now()

    property bool loading: false
    property string status: "idle" // idle | unconfigured | loading | ok | partial | error
    property string error: ""
    property double lastUpdatedAt: 0
    property string refreshError: ""
    property bool refreshTimedOut: false
    property bool pendingLogRefresh: false

    property var providers: []
    property string selectedProviderId: ""

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

    // Accounts grouped by provider: one chip per provider, with all accounts
    // of that provider reachable from the group.
    readonly property var providerGroups: {
        const groups = [];
        const byProvider = {};
        for (let i = 0; i < providers.length; i++) {
            const p = providers[i];
            if (!byProvider[p.provider]) {
                byProvider[p.provider] = { provider: p.provider, label: providerDisplayName(p.provider), accounts: [] };
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

    // Full per-account records for the Stack drawer. Pool limits are already
    // present on each account; do not replace its status/freshness with the
    // deliberately smaller poolLimits metadata or reshuffle rows on clicks.
    readonly property var activeGroupAccounts: {
        const p = activeProvider;
        if (!p)
            return [];
        const group = activeGroup ? (activeGroup.accounts || []) : [p];
        return group.map(r => Object.assign({}, r, {accountLabel: r.account || r.name || ""}));
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

    // Aggregates
    property double todayTotalTokens: 0
    property var todayCostUsd: null

    function selectProvider(id: string): void {
        selectedProviderId = id;
    }

    function selectIndex(index: int): void {
        if (providers.length === 0)
            return;
        const wrapped = ((index % providers.length) + providers.length) % providers.length;
        selectedProviderId = providers[wrapped].id;
    }

    function resetToDefault(): void {
        if (providers.length === 0)
            return;
        // Prefer Codex/OpenAI, fallback to first provider (sorted order is already codex-first).
        for (let i = 0; i < providers.length; i++) {
            const p = String(providers[i].provider || "").toLowerCase();
            if (p === "codex" || p === "openai" || p.includes("codex")) {
                selectedProviderId = providers[i].id;
                return;
            }
        }
        selectedProviderId = providers[0].id;
    }

    property bool keepaliveRunning: false
    property int keepaliveDone: 0
    property int keepaliveTotal: 7
    property real keepaliveProgress: keepaliveTotal > 0 ? keepaliveDone / keepaliveTotal : 0
    property string keepaliveError: ""

    function refresh(): void {
        if (!QuotaConfig.enabled || !QuotaConfig.configured) {
            status = QuotaConfig.configured ? "idle" : "unconfigured";
            return;
        }
        if (loading || updateProcess.running)
            return;
        refreshError = "";
        refreshTimedOut = false;
        error = "";
        loading = true;
        refreshWatchdog.restart();
        updateProcess.running = true;
        if (!logProcess.running) {
            logWatchdog.restart();
            logProcess.running = true;
        }
    }

    function triggerKeepalive(): void {
        if (!QuotaConfig.enabled || !QuotaConfig.configured || keepaliveProcess.running)
            return;
        keepaliveRunning = true;
        keepaliveDone = 0;
        keepaliveError = "";
        keepaliveProcess.running = true;
    }

    // 1. Run collector process. The QML watchdog replaces GNU timeout.
    Process {
        id: updateProcess
        command: [QuotaConfig.python, "-I", root.updateScript, "--cpa-config", QuotaConfig.cpaConfigPath, "--cached-log"]
        environment: root.childEnvironment

        onExited: (exitCode, exitStatus) => {
            refreshWatchdog.stop();
            if (root.refreshTimedOut)
                root.refreshError = qsTr("Quota refresh timed out. Showing saved data.");
            else if (exitCode !== 0)
                root.refreshError = qsTr("Quota refresh failed. Showing saved data.");
            root.loading = false;
            readProcess.running = true;
            if (root.pendingLogRefresh) {
                root.pendingLogRefresh = false;
                logApplyTimer.restart();
            }
        }
    }

    // Download the large token ledger separately so quotas can finish first.
    Process {
        id: logProcess
        command: [QuotaConfig.python, "-I", root.updateScript, "--cpa-config", QuotaConfig.cpaConfigPath, "--refresh-log-only"]
        environment: root.childEnvironment

        onExited: (exitCode, exitStatus) => {
            logWatchdog.stop();
            if (exitCode !== 0) return;
            if (root.loading) root.pendingLogRefresh = true;
            else logApplyTimer.restart();
        }
    }

    // Windows has no GNU timeout; bound the background ledger download here.
    Timer {
        id: logWatchdog
        interval: 50000
        onTriggered: logProcess.running = false
    }

    Timer {
        id: logApplyTimer
        interval: 100
        onTriggered: {
            if (root.loading) { root.pendingLogRefresh = true; return; }
            if (!QuotaConfig.configured) return;
            root.loading = true;
            root.refreshError = "";
            root.error = "";
            root.refreshTimedOut = false;
            refreshWatchdog.restart();
            updateProcess.running = true;
        }
    }

    // 2. Read records directly via read_records.py
    Process {
        id: readProcess
        command: [QuotaConfig.python, "-I", root.readScript]
        environment: root.childEnvironment

        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root.applyRecords(text)
        }
    }

    // 3. Keepalive: ping Codex/Antigravity/Zai accounts to keep the 5-hour
    //    window active. The script emits NDJSON progress lines (one per ping)
    //    so the bolt icon can fill progressively. Only an explicit click runs
    //    it, and nothing runs without a CPA config.
    Process {
        id: keepaliveProcess
        command: [QuotaConfig.python, "-I", root.keepaliveScript, "--cpa-config", QuotaConfig.cpaConfigPath]
        environment: root.childEnvironment

        stdout: SplitParser {
            splitMarker: "\n"
            onRead: data => {
                const line = String(data).trim();
                if (!line) return;
                try {
                    const msg = JSON.parse(line);
                    if (msg && msg.type === "progress" && typeof msg.done === "number") {
                        root.keepaliveDone = Math.max(0, Math.min(msg.total || root.keepaliveTotal, msg.done));
                        if (msg.total) root.keepaliveTotal = msg.total;
                    } else if (msg && typeof msg.ok === "boolean" && msg.ok === false) {
                        root.keepaliveError = msg.error || "Keepalive failed";
                    }
                } catch (e) {}
            }
        }

        onExited: (exitCode, exitStatus) => {
            // Ensure the ring completes even if the script was fast and progress lines were coalesced.
            if (root.keepaliveDone < root.keepaliveTotal) root.keepaliveDone = root.keepaliveTotal;
            root.keepaliveRunning = false;
            // Re-read records and refresh quota so the panel reflects the new window.
            root.refresh();
        }
    }

    function chipTitleFor(rec: var, list: var): string {
        const prov = String(rec.provider || "").toLowerCase();
        let base = rec.tierLabel || rec.provider || "Agent";

        // Count how many accounts share this same tierLabel or provider
        let sameCount = 0;
        for (let i = 0; i < list.length; i++) {
            const other = list[i];
            if ((other.tierLabel === rec.tierLabel) || (other.provider === rec.provider))
                sameCount++;
        }

        if (sameCount > 1 && rec.account) {
            // Extract short user part from email
            const userPart = rec.account.split("@")[0];
            if (userPart)
                return `${base} (${userPart})`;
        }
        return base;
    }

    function applyRecords(jsonText: string): void {
        // Remember whether the user had explicitly picked a provider before this refresh.
        // On first load selectedProviderId is "" and we do initialize below.
        // On later refreshes we preserve the scroll/selection.
        const hadSelection = selectedProviderId !== "" && providers.length > 0;
        const priorSelection = selectedProviderId;

        try {
            const rawRecords = JSON.parse(jsonText);
            if (!Array.isArray(rawRecords))
                return;

            let totalTokensToday = 0;
            const parsed = [];

            for (let i = 0; i < rawRecords.length; i++) {
                const rec = rawRecords[i];
                if (!rec || typeof rec !== "object")
                    continue;

                const recent = rec.recentDays || [];
                let tokensToday = 0;
                let reqsToday = 0;
                if (recent.length > 0) {
                    const todayEntry = recent[recent.length - 1];
                    tokensToday = Number(todayEntry.tokens || todayEntry.tokenCount || todayEntry.messageCount || 0);
                    reqsToday = Number(todayEntry.requests || todayEntry.requestCount || 0);
                }
                // Pooled records all carry the leader's ledger; only the
                // leader contributes so the global total is not multiplied.
                if (!rec.poolMemberOf)
                    totalTokensToday += tokensToday;

                parsed.push({
                    id: rec.id || ("p-" + i),
                    name: rec.name || rec.account || rec.tierLabel || "Agent",
                    account: rec.account || rec.accountLabel || "",
                    provider: rec.provider || "cpa",
                    tierLabel: rec.tierLabel || rec.provider || "Subscription",
                    chipLabel: "",
                    status: rec.status || "active",
                    statusMessage: rec.statusMessage || rec.errorText || "",
                    usageStatusText: rec.usageStatusText || "",
                    errorText: rec.errorText || "",
                    unavailable: !!rec.unavailable,
                    disabled: !!rec.disabled,
                    cooldowns: rec.cooldowns || [],
                    cooldownUntil: rec.cooldownUntil || "",
                    limits: rec.limits || [],
                    lastUsedAt: rec.lastUsedAt || "",
                    poolGroup: rec.poolGroup || null,
                    poolAccounts: rec.poolAccounts || [],
                    poolLimits: rec.poolLimits || [],
                    balance: rec.balance || null,
                    recentDays: recent,
                    modelUsage: rec.modelUsage || {},
                    allTime: rec.allTime || null,
                    updatedAt: rec.updatedAt || "",
                    quotaUpdatedAt: rec.quotaUpdatedAt || "",
                    quotaCheckedAt: rec.quotaCheckedAt || "",
                    quotaError: rec.quotaError || "",
                    quotaAuthRequired: !!rec.quotaAuthRequired,
                    dailyMetric: rec.dailyMetric || "tokens",
                    tokensToday: tokensToday,
                    requestsToday: reqsToday
                });
            }

            // Assign unique, informative chip titles
            for (let i = 0; i < parsed.length; i++) {
                parsed[i].chipLabel = chipTitleFor(parsed[i], parsed);
            }

            // Stable sort: codex, claude, antigravity, cursor, opencode-go, vertex, kimi
            parsed.sort((a, b) => {
                const pOrder = ["codex", "claude", "antigravity", "cursor", "zai", "opencode-go", "vertex", "kimi"];
                const aIdx = pOrder.indexOf(a.provider.toLowerCase());
                const bIdx = pOrder.indexOf(b.provider.toLowerCase());
                const aRank = aIdx >= 0 ? aIdx : 99;
                const bRank = bIdx >= 0 ? bIdx : 99;
                if (aRank !== bRank)
                    return aRank - bRank;
                return a.name.localeCompare(b.name);
            });

            providers = parsed;
            todayTotalTokens = totalTokensToday;
            // Reading cached files is not a successful upstream refresh.
            lastUpdatedAt = parsed.reduce((latest, p) => Math.max(latest, Date.parse(p.updatedAt) || 0), 0);
            error = refreshError;
            status = error ? "error" : (parsed.some(p => p.unavailable || p.errorText) ? "partial" : "ok");

            if (!selectedProviderId && parsed.length > 0)
                selectedProviderId = parsed[0].id;
            else if (hadSelection) {
                // Refresh preserved the sorting; verify the prior selection still exists.
                let stillExists = false;
                for (let i = 0; i < parsed.length; i++) {
                    if (parsed[i].id === priorSelection) { stillExists = true; break; }
                }
                if (!stillExists && parsed.length > 0)
                    selectedProviderId = parsed[0].id;
            }
        } catch (e) {
            error = qsTr("Could not read saved quota data.");
            status = "error";
            console.warn("Error parsing agent usage records:", e);
        }
    }

    // Read completed account records while slower providers are still running.
    Timer {
        interval: 2000
        running: root.loading
        repeat: true
        onTriggered: if (!readProcess.running) readProcess.running = true
    }

    Timer {
        id: refreshWatchdog
        interval: root.refreshTimeoutMs + 5000
        onTriggered: {
            root.refreshTimedOut = true;
            root.refreshError = qsTr("Quota refresh timed out. Showing saved data.");
            root.error = root.refreshError;
            root.status = "error";
            updateProcess.running = false;
            logProcess.running = false;
            logWatchdog.stop();
            root.loading = false;
        }
    }

    // Refresh timers. They stay inert until a CPA config exists.
    Timer {
        id: autoRefreshTimer
        interval: root.refreshIntervalMs
        running: root.configured && QuotaConfig.enabled
        repeat: true
        onTriggered: root.refresh()
    }

    Timer {
        id: clockTimer
        interval: 10000 // 10 seconds tick
        running: true
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
            root.refresh();
        }
    }

    // The probe is asynchronous, so the first load can arrive after this
    // component was created. React once to its result instead of polling.
    onConfiguredChanged: {
        if (!root.configured)
            return;
        if (!readProcess.running)
            readProcess.running = true;
        if (QuotaConfig.enabled)
            root.refresh();
    }

    onEnabledChanged: {
        if (root.enabled && root.configured)
            root.refresh();
    }

    Component.onCompleted: {
        if (!root.configured) {
            root.status = "unconfigured";
            return;
        }
        readProcess.running = true;
        if (QuotaConfig.enabled)
            root.refresh();
    }
}
