pragma Singleton
import QtQuick
// Stand-in for the quota service in the keyboard fixture: enough accounts that
// the drawer scrolls, and counters for what the keyboard asked for.
QtObject {
    id: root

    function account(provider, label, name, tier, used): var {
        const stamp = new Date().toISOString();
        const titles = ["5-hour", "Weekly", "Opus · Weekly"];
        return {
            id: provider + ":" + name, provider: provider, providerLabel: label, name: name, accountLabel: name,
            tierLabel: tier, status: "ok", unavailable: false, disabled: false, quotaAuthRequired: false,
            updatedAt: stamp, quotaUpdatedAt: stamp,
            limits: used.map((p, i) => ({
                title: titles[i], label: titles[i], percent: p,
                resetsAt: new Date(Date.now() + (i + 1) * 3 * 3600000).toISOString()
            }))
        };
    }

    property var providers: [
        account("codex", "Codex", "one", "Pro", [0.4, 0.2]),
        account("codex", "Codex", "two", "Plus", [0.7, 0.5]),
        account("claude", "Claude", "three", "Max", [0.7, 0.3, 0.9]),
        account("claude", "Claude", "four", "Pro", [0.2, 0.6]),
        account("zai", "Z.ai", "five", "GLM", [0.1, 0.05])
    ]
    readonly property var providerGroups: {
        const groups = [];
        for (const p of providers) {
            let group = groups.find(g => g.provider === p.provider);
            if (!group) {
                group = { provider: p.provider, label: p.providerLabel, accounts: [] };
                groups.push(group);
            }
            group.accounts.push(p);
        }
        return groups;
    }

    property string usageView: "all"
    property int viewChanges: 0
    onUsageViewChanged: viewChanges++
    property int refreshes: 0
    property int keepalives: 0
    property int refreshIntervalMs: 60000
    property int effectiveRefreshMs: 60000
    property double nowMs: Date.now()
    property double lastUpdatedAt: Date.now()
    property bool configured: true
    property string status: "ok"
    property var todayCostUsd: null
    property var spend: ({})
    property bool keepaliveRunning: false
    property int keepaliveDone: 0
    property int keepaliveTotal: 0
    function selectGroup(provider): void {}
    function refresh(force): void { refreshes++; }
    function triggerKeepalive(): void { keepalives++; }
    function providerDisplayName(provider): string { return provider; }
}
