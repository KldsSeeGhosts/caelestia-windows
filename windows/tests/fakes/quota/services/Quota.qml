pragma Singleton
import QtQuick
QtObject {
    property var providerGroups: [
        {provider: "codex", label: "Codex", accounts: []},
        {provider: "claude", label: "Claude", accounts: []}
    ]
    property var activeGroup: providerGroups[0]
    property int selections: 0
    property int refreshIntervalMs: 60000
    property int effectiveRefreshMs: 60000
    property double nowMs: Date.now()
    property double lastUpdatedAt: 0
    property bool configured: false
    property string status: "unconfigured"
    property var todayCostUsd: null
    property var spend: ({})
    property bool keepaliveRunning: false
    property int keepaliveDone: 0
    property int keepaliveTotal: 0
    function selectGroup(provider): void {
        activeGroup = providerGroups.find(group => group.provider === provider);
        selections++;
    }
    function refresh(force): void {}
    function triggerKeepalive(): void {}
    function providerDisplayName(provider): string { return provider; }
}
