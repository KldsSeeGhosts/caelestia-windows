pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import Caelestia.Config
import qs.components
import qs.components.containers
import qs.components.controls
import qs.services
import "QuotaLogic.js" as Logic

// Stack: one surface, real provider-window summaries, expandable accounts.
Item {
    id: root
    property bool loading: false
    property bool hasError: false
    property string error: ""
    property string openAccountId: Quota.selectedProviderId
    property bool revealed: false
    property string priorGroup: ""
    readonly property var provider: Quota.activeProvider
    readonly property var accounts: Quota.activeGroupAccounts
    readonly property string family: Tokens.font.body.small.family
    readonly property color muted: Colours.palette.m3onSurfaceVariant
    readonly property color hairline: Qt.alpha(Colours.palette.m3outlineVariant, 0.6)
    readonly property double staleAfter: Math.max(180000, Quota.refreshIntervalMs * 3)

    implicitWidth: QuotaConfig.panelWidth - Tokens.padding.large * 2
    implicitHeight: header.height + 14 + strip.height + 10 + groupTitle.implicitHeight + 8 + 14 + footer.height
        + Math.min(body.contentHeight, Math.max(0, QuotaConfig.panelHeight
            - Tokens.padding.large * 2 - header.height - strip.height - groupTitle.implicitHeight - footer.height - 46))

    function resetScroll(): void {
        body.contentY = 0;
        openAccountId = Quota.selectedProviderId;
    }
    function accountState(account: var): string {
        return Logic.accountState(account, Quota.nowMs, root.staleAfter, root.hasError);
    }
    function percentText(value: var): string {
        return value === null ? "—" : Math.round(value * 100) + "%";
    }
    function relativeTime(stamp: string): string {
        const time = Date.parse(stamp);
        if (!Number.isFinite(time)) return qsTr("Not reported");
        const mins = Math.max(0, Math.floor((Quota.nowMs - time) / 60000));
        if (mins < 1) return qsTr("just now");
        if (mins < 60) return qsTr("%1m ago").arg(mins);
        if (mins < 1440) return qsTr("%1h ago").arg(Math.floor(mins / 60));
        return qsTr("%1d ago").arg(Math.floor(mins / 1440));
    }
    function stateColour(state: string, value: var): color {
        if (state === "auth" || (state === "ok" && value !== null && value <= 0.15))
            return Colours.palette.m3error;
        return state === "ok" ? Colours.palette.m3onSurface : root.muted;
    }
    function accountSummary(account: var): string {
        const state = root.accountState(account);
        if (state === "cooldown") {
            const mins = Math.max(1, Math.ceil((Date.parse(account.cooldownUntil) - Quota.nowMs) / 60000));
            return mins >= 60 ? qsTr("Cooldown %1h %2m").arg(Math.floor(mins / 60)).arg(mins % 60) : qsTr("Cooldown %1m").arg(mins);
        }
        if (state === "disabled") return qsTr("Disabled");
        if (state === "auth") return qsTr("Reconnect");
        const value = Logic.accountRemaining(account);
        if (value === null) return qsTr("No reading");
        const prefix = String(account.provider).toLowerCase() === "cursor" ? "API " : "";
        return prefix + root.percentText(value);
    }
    function accountName(account: var): string {
        const label = String(account.accountLabel || account.name || qsTr("Account"));
        return (label.includes("@") ? label.split("@")[0] : label).replace(/\*{2,}/g, "•••");
    }
    function tierName(account: var): string {
        return String(account.tierLabel || "").split("·").pop().trim();
    }
    function providerIconSource(providerId: string): url {
        const p = String(providerId).toLowerCase();
        let name = "";
        if (p === "codex" || p === "openai") name = Colours.light ? "codex-light.svg" : "codex.svg";
        else if (p === "claude" || p === "anthropic") name = "claude.svg";
        else if (p === "cursor") name = Colours.light ? "cursor-light.svg" : "cursor.svg";
        else if (p === "antigravity") name = Colours.light ? "antigravity-light.svg" : "antigravity.svg";
        else if (p === "zai") name = Colours.light ? "zai-light.svg" : "zai.svg";
        else if (p === "opencode-go") name = Colours.light ? "opencode-light.svg" : "opencode-dark.svg";
        else if (p === "vertex") name = "vertex.svg";
        else if (p === "kimi") name = Colours.light ? "kimi-light.svg" : "kimi-dark.svg";
        return name ? Quickshell.shellPath("assets/provider-icons/" + name) : "";
    }
    readonly property bool zaiIsPeak: root.provider && root.provider.provider === "zai"
        && new Date(Quota.nowMs).getUTCHours() >= 1 && new Date(Quota.nowMs).getUTCHours() < 15
    readonly property string zaiPeakText: {
        if (!root.zaiIsPeak) return "";
        const now = new Date(Quota.nowMs);
        const end = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate(), 15);
        const mins = Math.max(1, Math.floor((end - Quota.nowMs) / 60000));
        return qsTr("Peak hours, ends in %1h %2m").arg(Math.floor(mins / 60)).arg(mins % 60);
    }
    Connections {
        target: Quota
        function onSelectedProviderIdChanged(): void {
            const group = Quota.activeProvider ? Quota.activeProvider.provider : "";
            if (group !== root.priorGroup) {
                root.priorGroup = group;
                root.resetScroll();
            } else {
                root.openAccountId = Quota.selectedProviderId;
            }
        }
    }
    component Label: StyledText {
        font.family: root.family
        font.pixelSize: 13
        font.features: ({"tnum": 1})
    }

    RowLayout {
        id: header
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 32
        spacing: 6
        Label { Layout.fillWidth: true; text: qsTr("Agents"); font.pixelSize: 20; font.weight: Font.DemiBold; font.letterSpacing: -0.2 }
        IconButton {
            implicitWidth: 30
            implicitHeight: 30
            icon: "refresh"
            type: IconButton.Text
            font: Tokens.font.icon.small
            enabled: !root.loading && Quota.configured
            onClicked: Quota.refresh(true)
            Accessible.name: qsTr("Refresh quota")
            QuotaToolTip {
                visible: parent.hovered
                text: qsTr("Refresh quota")
                boundsItem: root
                family: root.family
            }
        }
        IconButton {
            implicitWidth: 30
            implicitHeight: 30
            icon: Quota.keepaliveRunning ? "hourglass_top" : "bolt"
            type: IconButton.Text
            font: Tokens.font.icon.small
            enabled: !Quota.keepaliveRunning && Quota.configured
            onClicked: Quota.triggerKeepalive()
            Accessible.name: qsTr("Keep quota windows active")
            QuotaToolTip {
                visible: parent.hovered
                text: Quota.keepaliveRunning ? qsTr("Keepalive %1/%2").arg(Quota.keepaliveDone).arg(Quota.keepaliveTotal)
                    : qsTr("Send keepalive requests to Codex and Antigravity")
                boundsItem: root
                family: root.family
            }
        }
    }
    Flickable {
        id: strip
        anchors.top: header.bottom
        anchors.topMargin: 14
        anchors.left: parent.left
        anchors.right: parent.right
        height: 56
        clip: true
        contentWidth: providerRow.width
        contentHeight: height
        flickableDirection: Flickable.HorizontalFlick
        boundsBehavior: Flickable.StopAtBounds
        Row {
            id: providerRow
            // Few providers sit together in the centre instead of spreading out.
            x: Math.max(0, (strip.width - width) / 2)
            spacing: 0
            Repeater {
                model: Quota.providerGroups
                delegate: QuotaRing {
                    required property var modelData
                    required property int index
                    width: Math.max(48, Math.min(60, strip.width / Math.max(1, Quota.providerGroups.length)))
                    group: modelData
                    selected: root.provider && root.provider.provider === modelData.provider
                    summary: Logic.providerSummary(modelData)
                    saved: modelData.accounts.some(a => root.accountState(a) !== "ok")
                    iconSource: root.providerIconSource(modelData.provider)
                    revealed: root.revealed
                    family: root.family
                    tooltipBounds: root
                }
            }
        }
    }
    RowLayout {
        id: groupTitle
        anchors.top: strip.bottom
        anchors.topMargin: 10
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: 8
        Label {
            Layout.fillWidth: true
            text: Quota.activeGroup ? Quota.activeGroup.label : qsTr("No providers")
            font.pixelSize: 15
            font.weight: Font.DemiBold
        }
        Label {
            text: root.accounts.length > 1 ? qsTr("%1 accounts").arg(root.accounts.length) : root.accounts.length === 1 ? qsTr("1 account") : ""
            font.pixelSize: 12
            color: root.muted
        }
    }
    StyledFlickable {
        id: body
        anchors.top: groupTitle.bottom
        anchors.topMargin: 8
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: footer.top
        anchors.bottomMargin: 14
        clip: true
        contentWidth: width
        contentHeight: stack.implicitHeight
        flickableDirection: Flickable.VerticalFlick
        boundsBehavior: Flickable.StopAtBounds
        Column {
            id: stack
            width: body.width
            spacing: 0
            Label {
                width: parent.width
                visible: root.zaiIsPeak
                text: root.zaiPeakText
                font.pixelSize: 12
                wrapMode: Text.WordWrap
                color: root.muted
                bottomPadding: 8
            }
            Rectangle {
                width: parent.width
                height: groupColumn.implicitHeight
                radius: 16
                color: Qt.alpha(Colours.palette.m3onSurface, 0.05)
                Column {
                id: groupColumn
                width: parent.width
                Label {
                    width: parent.width
                    visible: root.accounts.length === 0
                    text: Quota.status === "unconfigured" ? qsTr("Not configured. Add cpa-agents.json to the shell config folder.") : qsTr("No agent usage records found.")
                    wrapMode: Text.WordWrap
                    color: root.muted
                    padding: 14
                }
                Repeater {
                model: root.accounts
                delegate: Column {
                    id: accountRow
                    required property var modelData
                    required property int index
                    readonly property string quotaState: root.accountState(modelData)
                    readonly property bool expanded: root.openAccountId === modelData.id
                    width: stack.width
                    spacing: 0
                    AbstractButton {
                        id: accountButton
                        width: parent.width
                        height: 48
                        leftPadding: 14; rightPadding: 12
                        hoverEnabled: true
                        Accessible.name: root.accountName(accountRow.modelData) + ", " + root.accountSummary(accountRow.modelData)
                        onClicked: {
                            const wasOpen = accountRow.expanded;
                            Quota.selectProvider(accountRow.modelData.id);
                            root.openAccountId = wasOpen ? "" : accountRow.modelData.id;
                        }
                        QuotaToolTip {
                            visible: accountButton.hovered
                            text: accountRow.quotaState === "stale" ? qsTr("Saved reading from %1").arg(root.relativeTime(accountRow.modelData.quotaUpdatedAt || accountRow.modelData.updatedAt || "")) : root.accountName(accountRow.modelData) + "\n" + root.tierName(accountRow.modelData)
                            boundsItem: root
                            family: root.family
                        }
                        background: Rectangle {
                            x: 4; width: accountButton.width - 8
                            color: accountButton.hovered || accountButton.down ? Qt.alpha(Colours.palette.m3onSurface, 0.04) : "transparent"
                            radius: 12
                            border.width: accountButton.activeFocus ? 1 : 0
                            border.color: Colours.palette.m3primary
                        }
                        contentItem: RowLayout {
                            spacing: 6
                            Label {
                                Layout.minimumWidth: 0
                                Layout.maximumWidth: accountButton.width * 0.38
                                text: root.accountName(accountRow.modelData)
                                font.pixelSize: 14
                                font.weight: Font.Medium
                                elide: Text.ElideRight
                            }
                            Label {
                                Layout.maximumWidth: 90
                                text: root.tierName(accountRow.modelData)
                                font.pixelSize: 12
                                color: Qt.alpha(root.muted, 0.7)
                                elide: Text.ElideRight
                            }
                            Item { Layout.fillWidth: true }
                            Label {
                                text: root.accountSummary(accountRow.modelData)
                                font.pixelSize: accountRow.quotaState === "ok" || accountRow.quotaState === "stale" ? 14 : 13
                                font.weight: accountRow.quotaState === "ok" ? Font.DemiBold : Font.Normal
                                color: root.stateColour(accountRow.quotaState, Logic.accountRemaining(accountRow.modelData))
                            }
                            MaterialIcon {
                                text: "chevron_right"
                                rotation: accountRow.expanded ? 90 : 0
                                Behavior on rotation { Anim {} }
                                color: Qt.alpha(root.muted, 0.7)
                                fontStyle: Tokens.font.icon.small
                            }
                        }
                    }
                    Item {
                        width: parent.width
                        height: accountRow.expanded ? detail.implicitHeight : 0
                        visible: height > 0
                        clip: true
                        Behavior on height { Anim { type: Anim.FastEffects } }
                        Column {
                            id: detail
                            width: parent.width
                            spacing: 14
                            leftPadding: 14; rightPadding: 14; bottomPadding: 14
                            Rectangle {
                                visible: accountRow.quotaState !== "ok"
                                width: parent.width - 28
                                height: noticeText.implicitHeight + 18
                                radius: 10
                                color: Qt.alpha(accountRow.quotaState === "auth" ? Colours.palette.m3error : Colours.palette.m3onSurface, accountRow.quotaState === "auth" ? 0.10 : 0.06)
                                Label {
                                    id: noticeText
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.top: parent.top
                                    anchors.leftMargin: 10; anchors.rightMargin: 10; anchors.topMargin: 9
                                    font.pixelSize: 12
                                    wrapMode: Text.WordWrap
                                    text: {
                                        const a = accountRow.modelData;
                                        if (accountRow.quotaState === "cooldown")
                                            return qsTr("On cooldown in CPA. Retry after %1.\nSaved limits below; this account is not routable.")
                                                .arg(Qt.formatDateTime(new Date(a.cooldownUntil), "ddd h:mm AP"));
                                        if (accountRow.quotaState === "disabled")
                                            return qsTr("Disabled in CPA. Saved limits below; this account is not routable.")
                                                + (a.statusMessage ? "\n" + a.statusMessage : "");
                                        if (accountRow.quotaState === "auth")
                                            return a.quotaError || qsTr("Reconnect this provider in CPA Manager.");
                                        const message = a.quotaError || a.errorText || a.usageStatusText
                                            || (accountRow.quotaState === "none" ? qsTr("Quota has not been reported for this account.") : qsTr("Showing saved quota."));
                                        const stamp = a.quotaUpdatedAt || a.updatedAt || "";
                                        return message + (stamp && accountRow.quotaState !== "none" ? qsTr("\nReading from %1.").arg(root.relativeTime(stamp)) : "");
                                    }
                                    color: accountRow.quotaState === "auth" ? Colours.palette.m3error : root.muted
                                }
                            }
                            Repeater {
                                model: Logic.orderedWindows(Logic.primaryWindows(accountRow.modelData))
                                delegate: QuotaMeter {
                                    required property var modelData
                                    width: detail.width - 28
                                    limit: modelData
                                    nowMs: Quota.nowMs
                                    quotaState: accountRow.quotaState
                                    family: root.family
                                }
                            }
                            Label {
                                visible: Logic.scopedWindows(accountRow.modelData).length > 0
                                text: qsTr("Model limits")
                                font.pixelSize: 12
                                color: root.muted
                            }
                            Repeater {
                                model: Logic.orderedWindows(Logic.scopedWindows(accountRow.modelData))
                                delegate: QuotaMeter {
                                    required property var modelData
                                    width: detail.width - 28
                                    limit: modelData
                                    nowMs: Quota.nowMs
                                    quotaState: accountRow.quotaState
                                    family: root.family
                                    compact: true
                                }
                            }
                            Label {
                                visible: !!accountRow.modelData.balance
                                width: parent.width - 28
                                wrapMode: Text.WordWrap
                                text: {
                                    const b = accountRow.modelData.balance;
                                    return b ? qsTr("Balance: %1 %2 remaining").arg(b.currency || "USD").arg(Number(b.remaining || 0).toFixed(2)) : "";
                                }
                                font.pixelSize: 12
                                color: root.muted
                            }
                        }
                    }
                    Rectangle { x: 14; width: parent.width - 14; height: accountRow.index < root.accounts.length - 1 ? 1 : 0; color: root.hairline }
                }
            }
            }
            }
        }
    }
    Item {
        id: footer
        anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
        height: 30
        Rectangle { width: parent.width; height: 1; color: root.hairline }
        RowLayout {
            anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
            anchors.topMargin: 13
            spacing: 8
            Label {
                id: footerStatus
                Layout.fillWidth: true; Layout.minimumWidth: 0
                text: root.loading ? qsTr("Refreshing…") : Quota.keepaliveRunning ? qsTr("Keepalive %1/%2").arg(Quota.keepaliveDone).arg(Quota.keepaliveTotal)
                    : root.hasError ? qsTr("Refresh failed, showing saved data")
                    : Quota.lastUpdatedAt > 0 ? qsTr("Updated %1").arg(root.relativeTime(new Date(Quota.lastUpdatedAt).toISOString())) : qsTr("No reading yet")
                color: root.hasError && !root.loading && !Quota.keepaliveRunning ? Colours.palette.m3error : Qt.alpha(root.muted, 0.7)
                font.pixelSize: 12; elide: Text.ElideRight
                HoverHandler { id: statusHover }
                QuotaToolTip { visible: statusHover.hovered && root.hasError; text: root.error; boundsItem: root; family: root.family }
            }
            Row {
                objectName: "quotaFooterCost"
                Label {
                    objectName: "quotaFooterAmount"
                    text: Quota.todayCostUsd === null ? qsTr("Cost not reported") : Quota.usageCostText
                    color: Quota.todayCostUsd === null ? Qt.alpha(root.muted, 0.7) : root.muted
                    font.pixelSize: 12
                    font.weight: Quota.todayCostUsd === null ? Font.Normal : Font.DemiBold
                }
                Label {
                    visible: Quota.todayCostUsd !== null
                    text: qsTr(" today"); color: Qt.alpha(root.muted, 0.7); font.pixelSize: 12
                }
                HoverHandler { id: costHover }
                QuotaToolTip { visible: costHover.hovered; text: qsTr("CPA Manager reports one total for all accounts."); boundsItem: root; family: root.family }
            }
        }
    }
}
