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
    property bool usageOpen: false
    property string priorGroup: ""
    readonly property var provider: Quota.activeProvider
    readonly property var accounts: Quota.activeGroupAccounts
    readonly property string family: Tokens.font.body.small.family
    readonly property color muted: Colours.palette.m3onSurfaceVariant
    readonly property color hairline: Qt.alpha(Colours.palette.m3outlineVariant, 0.5)
    readonly property double staleAfter: Math.max(180000, Quota.refreshIntervalMs * 3)

    implicitWidth: QuotaConfig.panelWidth - Tokens.padding.large * 2
    implicitHeight: header.height + 10 + strip.height + 10 + groupTitle.implicitHeight + 6
        + Math.min(body.contentHeight, Math.max(0, QuotaConfig.panelHeight
            - Tokens.padding.large * 2 - header.height - strip.height - groupTitle.implicitHeight - 26))

    function resetScroll(): void {
        body.contentY = 0;
        openAccountId = Quota.selectedProviderId;
        usageOpen = false;
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
        return (state === "stale" ? qsTr("Saved ") : "") + prefix + root.percentText(value) + qsTr(" left");
    }
    function accountName(account: var): string {
        const label = String(account.accountLabel || account.name || qsTr("Account"));
        return label.includes("@") ? label.split("@")[0] : label;
    }
    function tierName(account: var): string {
        return String(account.tierLabel || "").split("·").pop().trim();
    }
    function providerIconSource(providerId: string): url {
        const p = String(providerId).toLowerCase();
        let name = "";
        if (p === "codex" || p === "openai") name = "codex.png";
        else if (p === "claude" || p === "anthropic") name = "claude.svg";
        else if (p === "cursor") name = "cursor.png";
        else if (p === "antigravity") name = "antigravity.svg";
        else if (p === "zai") name = Colours.light ? "zai-light.svg" : "zai.svg";
        else if (p === "opencode-go") name = Colours.light ? "opencode-light.svg" : "opencode-dark.svg";
        else if (p === "vertex") name = "vertex.svg";
        else if (p === "kimi") name = Colours.light ? "kimi-light.svg" : "kimi-dark.svg";
        return name ? Quickshell.shellPath("assets/provider-icons/" + name) : "";
    }
    function usageSummary(): string {
        return Quota.usageTodayText;
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
        Label { text: qsTr("Agents"); font.pixelSize: 18; font.weight: Font.DemiBold }
        Label {
            Layout.fillWidth: true
            Layout.minimumWidth: 0
            text: root.loading ? qsTr("Refreshing…") : Quota.lastUpdatedAt > 0
                ? qsTr("Updated %1").arg(root.relativeTime(new Date(Quota.lastUpdatedAt).toISOString())) : qsTr("No reading yet")
            font.pixelSize: 11
            color: root.muted
            elide: Text.ElideRight
        }
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
        anchors.topMargin: 10
        anchors.left: parent.left
        anchors.right: parent.right
        height: 74
        clip: true
        contentWidth: providerRow.width
        contentHeight: height
        flickableDirection: Flickable.HorizontalFlick
        boundsBehavior: Flickable.StopAtBounds
        Row {
            id: providerRow
            spacing: 4
            Repeater {
                model: Quota.providerGroups
                delegate: AbstractButton {
                    id: chip
                    required property var modelData
                    required property int index
                    readonly property bool selected: root.provider && root.provider.provider === modelData.provider
                    readonly property var summary: Logic.providerSummary(modelData)
                    readonly property bool saved: modelData.accounts.some(a => root.accountState(a) !== "ok")
                    readonly property string iconSource: root.providerIconSource(modelData.provider)
                    width: Math.max(47, (strip.width - 4 * Math.max(0, Quota.providerGroups.length - 1)) / Math.max(1, Quota.providerGroups.length))
                    height: strip.height
                    padding: 3
                    hoverEnabled: true
                    onClicked: Quota.selectGroup(modelData.provider)
                    Accessible.name: modelData.label + ", " + summary.map(s => s.label + " " + root.percentText(s.remaining) + " remaining").join(", ")
                    QuotaToolTip {
                        visible: chip.hovered
                        text: chip.modelData.label + "\n"
                            + (chip.summary.length ? chip.summary.map(s => s.title + ": " + root.percentText(s.remaining) + " remaining").join("\n") : qsTr("No quota reading"))
                            + (chip.saved ? qsTr("\nSome readings are saved or unavailable.") : "")
                            + qsTr("\nLowest remaining per window across accounts and scopes.")
                        boundsItem: root
                        family: root.family
                    }
                    background: Rectangle {
                        radius: 12
                        color: chip.selected ? Colours.palette.m3secondaryContainer : chip.hovered ? Qt.alpha(Colours.palette.m3onSurface, 0.06) : "transparent"
                        border.width: chip.activeFocus ? 1 : 0
                        border.color: Colours.palette.m3primary
                    }
                    contentItem: Column {
                        spacing: 3
                        Item {
                            width: parent.width
                            height: 22
                            Rectangle {
                                anchors.centerIn: parent
                                width: 22; height: 22; radius: 6
                                color: chip.modelData.provider === "codex" ? Colours.palette.m3inverseSurface : "transparent"
                                Image {
                                    anchors.centerIn: parent
                                    width: 18; height: 18
                                    source: chip.iconSource
                                    sourceSize: Qt.size(24, 24)
                                    fillMode: Image.PreserveAspectFit
                                    smooth: true; mipmap: true
                                }
                            }
                            Label {
                                anchors.centerIn: parent
                                visible: !chip.iconSource
                                text: String(chip.modelData.label).slice(0, 2)
                                font.pixelSize: 11
                            }
                            Rectangle {
                                visible: chip.saved
                                anchors.right: parent.right
                                width: 4; height: 4; radius: 2
                                color: Colours.palette.m3outline
                            }
                        }
                        Repeater {
                            model: chip.summary
                            delegate: Label {
                                required property var modelData
                                width: chip.availableWidth
                                text: modelData.label + " " + root.percentText(modelData.remaining)
                                horizontalAlignment: Text.AlignHCenter
                                font.pixelSize: 10
                                color: chip.saved ? root.muted : root.stateColour("ok", modelData.remaining)
                            }
                        }
                        Label {
                            visible: chip.summary.length === 0
                            width: chip.availableWidth
                            text: "—"
                            horizontalAlignment: Text.AlignHCenter
                            font.pixelSize: 11
                            color: root.muted
                        }
                    }
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
            font.pixelSize: 14
            font.weight: Font.DemiBold
        }
        Label {
            text: root.accounts.length > 1 ? qsTr("%1 accounts").arg(root.accounts.length) : qsTr("Remaining quota")
            font.pixelSize: 11
            color: root.muted
        }
    }
    StyledFlickable {
        id: body
        anchors.top: groupTitle.bottom
        anchors.topMargin: 6
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
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
                visible: root.accounts.length === 0 || root.hasError
                text: root.hasError ? root.error
                    : Quota.status === "unconfigured" ? qsTr("Not configured. Add cpa-agents.json to the shell config folder.")
                    : qsTr("No agent usage records found.")
                wrapMode: Text.WordWrap
                color: root.hasError ? Colours.palette.m3error : root.muted
                topPadding: 8; bottomPadding: 8
            }
            Label {
                width: parent.width
                visible: root.zaiIsPeak
                text: root.zaiPeakText
                font.pixelSize: 11
                color: root.muted
                topPadding: 8; bottomPadding: 8
            }
            Repeater {
                model: root.accounts
                delegate: Column {
                    id: accountRow
                    required property var modelData
                    readonly property string quotaState: root.accountState(modelData)
                    readonly property bool expanded: root.openAccountId === modelData.id
                    width: stack.width
                    spacing: 0
                    AbstractButton {
                        id: accountButton
                        width: parent.width
                        height: 44
                        hoverEnabled: true
                        Accessible.name: root.accountName(accountRow.modelData) + ", " + root.accountSummary(accountRow.modelData)
                        onClicked: {
                            const wasOpen = accountRow.expanded;
                            Quota.selectProvider(accountRow.modelData.id);
                            root.openAccountId = wasOpen ? "" : accountRow.modelData.id;
                        }
                        QuotaToolTip {
                            visible: accountButton.hovered
                            text: accountRow.modelData.accountLabel + "\n" + accountRow.modelData.tierLabel
                            boundsItem: root
                            family: root.family
                        }
                        background: Rectangle {
                            color: accountButton.hovered ? Qt.alpha(Colours.palette.m3onSurface, 0.04) : "transparent"
                            radius: 8
                            border.width: accountButton.activeFocus ? 1 : 0
                            border.color: Colours.palette.m3primary
                        }
                        contentItem: RowLayout {
                            spacing: 6
                            Label {
                                Layout.fillWidth: true
                                Layout.minimumWidth: 0
                                text: root.accountName(accountRow.modelData)
                                font.weight: Font.DemiBold
                                elide: Text.ElideRight
                            }
                            Label {
                                Layout.maximumWidth: 70
                                text: root.tierName(accountRow.modelData)
                                font.pixelSize: 11
                                color: root.muted
                                elide: Text.ElideRight
                            }
                            Label {
                                text: root.accountSummary(accountRow.modelData)
                                font.pixelSize: 11
                                color: root.stateColour(accountRow.quotaState, Logic.accountRemaining(accountRow.modelData))
                            }
                            MaterialIcon {
                                text: accountRow.expanded ? "expand_less" : "expand_more"
                                color: root.muted
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
                            spacing: 12
                            topPadding: 2; bottomPadding: 14
                            Rectangle {
                                visible: accountRow.quotaState !== "ok"
                                width: parent.width
                                height: noticeText.implicitHeight + 16
                                radius: 8
                                color: Qt.alpha(accountRow.quotaState === "auth" ? Colours.palette.m3error : Colours.palette.m3onSurface, 0.07)
                                Label {
                                    id: noticeText
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.top: parent.top
                                    anchors.margins: 8
                                    font.pixelSize: 11
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
                                    width: detail.width
                                    limit: modelData
                                    nowMs: Quota.nowMs
                                    quotaState: accountRow.quotaState
                                    family: root.family
                                }
                            }
                            Label {
                                visible: Logic.scopedWindows(accountRow.modelData).length > 0
                                text: qsTr("Model limits")
                                font.pixelSize: 11
                                color: root.muted
                            }
                            Repeater {
                                model: Logic.orderedWindows(Logic.scopedWindows(accountRow.modelData))
                                delegate: QuotaMeter {
                                    required property var modelData
                                    width: detail.width
                                    limit: modelData
                                    nowMs: Quota.nowMs
                                    quotaState: accountRow.quotaState
                                    family: root.family
                                    compact: true
                                }
                            }
                            Label {
                                visible: !!accountRow.modelData.balance
                                width: parent.width
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
                    Rectangle { width: parent.width; height: 1; color: root.hairline }
                }
            }
            AbstractButton {
                id: usageButton
                width: parent.width
                height: 60
                hoverEnabled: true
                onClicked: root.usageOpen = !root.usageOpen
                Accessible.name: qsTr("Usage today: %1").arg(root.usageSummary())
                background: Rectangle {
                    color: usageButton.hovered ? Qt.alpha(Colours.palette.m3onSurface, 0.04) : "transparent"
                    radius: 8
                    border.width: usageButton.activeFocus ? 1 : 0
                    border.color: Colours.palette.m3primary
                }
                contentItem: RowLayout {
                    spacing: 8
                    Column {
                        Layout.fillWidth: true
                        spacing: 3
                        Label { text: qsTr("Usage today"); font.weight: Font.DemiBold }
                        Label {
                            width: parent.width
                            text: root.usageSummary()
                            font.pixelSize: 11
                            color: root.muted
                            elide: Text.ElideRight
                        }
                    }
                    MaterialIcon {
                        text: root.usageOpen ? "expand_less" : "expand_more"
                        color: root.muted
                        fontStyle: Tokens.font.icon.small
                    }
                }
            }
            Column {
                width: parent.width
                visible: root.usageOpen
                spacing: 8
                bottomPadding: 12
                Label {
                    width: parent.width
                    text: qsTr("CPA Manager reports one cost total for all accounts. Per-account token and request ledgers are not part of the quota summary.")
                    wrapMode: Text.WordWrap
                    font.pixelSize: 11
                    color: root.muted
                }
                RowLayout {
                    width: stack.width
                    spacing: 8
                    Label {
                        Layout.fillWidth: true
                        text: qsTr("Cost today")
                        font.pixelSize: 12
                    }
                    Label {
                        text: Quota.usageCostText
                        font.pixelSize: 12
                        color: root.muted
                    }
                }
            }
        }
    }
}
