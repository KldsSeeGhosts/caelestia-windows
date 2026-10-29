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

// Provider limits first: the provider strip, then the chosen provider's header
// and card of meters, then a collapsed spend row, above a fixed footer that
// holds refresh and keepalive.
Item {
    id: root
    objectName: "quotaContent"
    property bool loading: false
    property bool hasError: false
    property string error: ""
    property bool revealed: false
    readonly property string family: Tokens.font.body.small.family
    readonly property color muted: Colours.palette.m3onSurfaceVariant
    readonly property color cardColour: Qt.alpha(Colours.palette.m3onSurface, 0.05)
    readonly property color hairline: Qt.alpha(Colours.palette.m3outlineVariant, 0.6)
    readonly property double staleAfter: Math.max(180000, Quota.refreshIntervalMs * 3)

    implicitWidth: QuotaConfig.panelWidth - Tokens.padding.large * 2
    implicitHeight: Math.min(stack.implicitHeight, QuotaConfig.panelHeight - Tokens.padding.large * 2 - footer.height - 12)
        + 12 + footer.height

    // Called when the drawer hides: back to the top, spend collapsed on Today.
    function resetScroll(): void {
        body.contentY = 0;
        spend.reset();
    }
    function accountState(account: var): string {
        return Logic.accountState(account, Quota.nowMs, root.staleAfter, root.hasError);
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
    function accountName(account: var): string {
        const label = String(account.accountLabel || account.name || qsTr("Account"));
        return (label.includes("@") ? label.split("@")[0] : label).replace(/\*{2,}/g, "•••");
    }
    function tierName(account: var): string {
        return String(account.tierLabel || "").split("·").pop().trim();
    }
    // Short reason an account is not live, or "" when it is.
    function accountNotice(account: var, state: string): string {
        if (state === "cooldown")
            return qsTr("On cooldown until %1. Not routable.").arg(Qt.formatDateTime(new Date(account.cooldownUntil), "ddd h:mm AP"));
        if (state === "disabled")
            return qsTr("Disabled in CPA. Not routable.") + (account.statusMessage ? " " + account.statusMessage : "");
        if (state === "auth")
            return account.quotaError || qsTr("Reconnect this provider in CPA Manager.");
        if (state === "none")
            return qsTr("Quota has not been reported for this account.");
        if (state === "stale") {
            const stamp = account.quotaUpdatedAt || account.updatedAt || "";
            return (account.quotaError || account.errorText || account.usageStatusText || qsTr("Showing saved quota."))
                + (stamp ? " " + qsTr("Reading from %1.").arg(root.relativeTime(stamp)) : "");
        }
        return "";
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
    function zaiPeakText(): string {
        const now = new Date(Quota.nowMs);
        if (now.getUTCHours() < 1 || now.getUTCHours() >= 15) return "";
        const end = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate(), 15);
        const mins = Math.max(1, Math.floor((end - Quota.nowMs) / 60000));
        return qsTr("Peak hours, ends in %1h %2m").arg(Math.floor(mins / 60)).arg(mins % 60);
    }
    readonly property string nextUpdateText: {
        if (Quota.lastUpdatedAt <= 0) return "";
        const mins = Math.ceil((Quota.lastUpdatedAt + Quota.effectiveRefreshMs - Quota.nowMs) / 60000);
        return mins > 0 ? qsTr("Next update in %1m").arg(mins) : qsTr("Update due");
    }

    component Label: StyledText {
        font.family: root.family
        font.pixelSize: 13
        font.features: ({"tnum": 1})
    }
    // Section title above a card, as in OpenUsage: bold name, muted detail.
    component SectionHeader: RowLayout {
        id: sectionHeader
        property string title
        property string detail
        property url icon
        width: stack.width
        height: 30
        spacing: 8
        Image {
            visible: !!sectionHeader.icon.toString()
            Layout.leftMargin: 4
            Layout.preferredWidth: 18
            Layout.preferredHeight: 18
            source: sectionHeader.icon
            sourceSize: Qt.size(36, 36)
            fillMode: Image.PreserveAspectFit
        }
        Label {
            leftPadding: sectionHeader.icon.toString() ? 0 : 4
            text: sectionHeader.title
            font.pixelSize: 16
            font.weight: Font.DemiBold
        }
        Label {
            Layout.fillWidth: true
            Layout.minimumWidth: 0
            text: sectionHeader.detail
            font.pixelSize: 13
            color: root.muted
            elide: Text.ElideRight
        }
    }

    StyledFlickable {
        id: body
        objectName: "quotaBody"
        // Opening the spend row scrolls its details into view once they are laid out.
        property bool revealSpend: false
        onContentHeightChanged: if (revealSpend) {
            revealSpend = false;
            contentY = Math.max(0, contentHeight - height);
        }
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: footer.top
        anchors.bottomMargin: 12
        clip: true
        contentWidth: width
        contentHeight: stack.implicitHeight
        flickableDirection: Flickable.VerticalFlick
        boundsBehavior: Flickable.StopAtBounds
        Column {
            id: stack
            width: body.width
            spacing: 6

            // One logo per provider with its lowest "% left", so only the
            // chosen provider's card is open instead of one long list.
            Rectangle {
                id: strip
                readonly property real segment: (width - 6) / Math.max(1, Quota.providerGroups.length)
                readonly property int index: Math.max(0, Quota.providerGroups.findIndex(g => Quota.activeGroup && g.provider === Quota.activeGroup.provider))
                visible: Quota.providerGroups.length > 1
                width: parent.width
                height: visible ? 54 : 0
                radius: 16
                color: Qt.alpha(Colours.palette.m3onSurface, 0.06)
                Rectangle {
                    x: 3 + strip.segment * strip.index
                    y: 3
                    width: strip.segment
                    height: strip.height - 6
                    radius: 13
                    color: Colours.light ? Colours.palette.m3surfaceContainerLowest : Qt.alpha(Colours.palette.m3onSurface, 0.14)
                    Behavior on x { Anim { type: Anim.Emphasized } }
                }
                Row {
                    x: 3; y: 3
                    Repeater {
                        model: Quota.providerGroups
                        delegate: AbstractButton {
                            id: tab
                            required property var modelData
                            readonly property bool selected: !!Quota.activeGroup && Quota.activeGroup.provider === modelData.provider
                            readonly property var worst: Logic.groupWorstRemain(modelData)
                            readonly property url logo: root.providerIconSource(modelData.provider)
                            objectName: "quotaProviderTab"
                            width: strip.segment
                            height: strip.height - 6
                            hoverEnabled: true
                            onClicked: Quota.selectGroup(modelData.provider)
                            Accessible.name: modelData.label + ", " + (worst === null ? qsTr("no reading") : qsTr("%1% left").arg(Math.round(worst * 100)))
                            background: Rectangle {
                                radius: 13
                                color: !tab.selected && tab.hovered ? Qt.alpha(Colours.palette.m3onSurface, 0.05) : "transparent"
                                border.width: tab.activeFocus ? 1 : 0
                                border.color: Colours.palette.m3primary
                            }
                            contentItem: Item {
                                Column {
                                    anchors.centerIn: parent
                                    spacing: 4
                                    Item {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        width: 18; height: 18
                                        opacity: tab.selected || tab.hovered ? 1 : 0.7
                                        Image {
                                            anchors.fill: parent
                                            visible: !!tab.logo.toString()
                                            source: tab.logo
                                            sourceSize: Qt.size(36, 36)
                                            fillMode: Image.PreserveAspectFit
                                        }
                                        Label {
                                            anchors.centerIn: parent
                                            visible: !tab.logo.toString()
                                            text: String(tab.modelData.label).slice(0, 2)
                                            font.pixelSize: 11
                                            font.weight: Font.DemiBold
                                        }
                                    }
                                    Label {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        text: tab.worst === null ? "—" : Math.round(tab.worst * 100) + "%"
                                        font.pixelSize: 11
                                        font.weight: tab.selected ? Font.DemiBold : Font.Normal
                                        color: tab.worst !== null && tab.worst <= 0.15 ? Colours.palette.m3error
                                            : tab.selected ? Colours.palette.m3onSurface : root.muted
                                    }
                                }
                            }
                            QuotaToolTip {
                                visible: tab.hovered
                                text: tab.modelData.label + "\n" + (tab.modelData.accounts.length === 1 ? qsTr("Lowest remaining window")
                                    : qsTr("Lowest remaining across %1 accounts").arg(tab.modelData.accounts.length))
                                boundsItem: root
                                family: root.family
                            }
                        }
                    }
                }
            }

            Rectangle {
                visible: Quota.providerGroups.length === 0
                width: parent.width
                height: emptyText.implicitHeight
                radius: 14
                color: root.cardColour
                Label {
                    id: emptyText
                    width: parent.width
                    text: Quota.status === "unconfigured" ? qsTr("Not configured. Add cpa-agents.json to the shell config folder.") : qsTr("No agent usage records found.")
                    wrapMode: Text.WordWrap
                    color: root.muted
                    padding: 16
                }
            }

            Repeater {
                model: Quota.activeGroup ? [Quota.activeGroup] : []
                delegate: Column {
                    id: section
                    required property var modelData
                    readonly property bool single: modelData.accounts.length === 1
                    objectName: "quotaSection"
                    width: stack.width
                    spacing: 4

                    SectionHeader {
                        title: section.modelData.label
                        detail: section.single ? root.tierName(section.modelData.accounts[0])
                            : qsTr("%1 accounts").arg(section.modelData.accounts.length)
                        icon: root.providerIconSource(section.modelData.provider)
                    }
                    Rectangle {
                        width: parent.width
                        height: card.implicitHeight
                        radius: 14
                        color: root.cardColour
                        Column {
                            id: card
                            width: parent.width
                            padding: 14
                            spacing: 12
                            Label {
                                readonly property string peak: section.modelData.provider === "zai" ? root.zaiPeakText() : ""
                                visible: peak !== ""
                                width: card.width - 28
                                text: peak
                                font.pixelSize: 12
                                color: root.muted
                                wrapMode: Text.WordWrap
                            }
                            Repeater {
                                model: section.modelData.accounts
                                delegate: Column {
                                    id: account
                                    required property var modelData
                                    required property int index
                                    readonly property string quotaState: root.accountState(modelData)
                                    readonly property string notice: root.accountNotice(modelData, quotaState)
                                    width: card.width - 28
                                    spacing: 10

                                    // A hairline tells accounts apart without the old tall gap.
                                    Rectangle {
                                        visible: account.index > 0
                                        width: parent.width
                                        height: 1
                                        color: root.hairline
                                    }
                                    // Account caption: only needed to tell several accounts apart, or to flag one.
                                    Column {
                                        visible: !section.single || account.notice !== ""
                                        width: parent.width
                                        spacing: 3
                                        RowLayout {
                                            visible: !section.single
                                            width: parent.width
                                            spacing: 6
                                            // The state mark leads, so a stale or disabled account reads as such first.
                                            MaterialIcon {
                                                visible: account.quotaState !== "ok"
                                                text: account.quotaState === "stale" || account.quotaState === "none" ? "schedule" : "warning"
                                                color: account.quotaState === "auth" ? Colours.palette.m3error : root.muted
                                                fontStyle: Tokens.font.icon.size(10).build()
                                            }
                                            Label {
                                                objectName: "quotaAccountName"
                                                Layout.fillWidth: true
                                                Layout.minimumWidth: 0
                                                text: root.accountName(account.modelData)
                                                font.weight: Font.DemiBold
                                                elide: Text.ElideRight
                                            }
                                            Label {
                                                Layout.maximumWidth: parent.width * 0.4
                                                Layout.minimumWidth: 0
                                                text: root.tierName(account.modelData)
                                                color: root.muted
                                                elide: Text.ElideRight
                                            }
                                        }
                                        Label {
                                            visible: account.notice !== ""
                                            width: parent.width
                                            text: account.notice
                                            font.pixelSize: 12
                                            wrapMode: Text.WordWrap
                                            color: account.quotaState === "auth" ? Colours.palette.m3error : root.muted
                                        }
                                    }
                                    Repeater {
                                        model: Logic.orderedWindows(Logic.primaryWindows(account.modelData))
                                            .concat(Logic.orderedWindows(Logic.scopedWindows(account.modelData)))
                                        delegate: QuotaMeter {
                                            required property var modelData
                                            width: account.width
                                            limit: modelData
                                            nowMs: Quota.nowMs
                                            quotaState: account.quotaState
                                            family: root.family
                                        }
                                    }
                                    Label {
                                        visible: !!account.modelData.balance
                                        width: parent.width
                                        wrapMode: Text.WordWrap
                                        text: {
                                            const b = account.modelData.balance;
                                            return b ? qsTr("Balance: %1 %2 remaining").arg(b.currency || "USD").arg(Number(b.remaining || 0).toFixed(2)) : "";
                                        }
                                        font.pixelSize: 12
                                        color: root.muted
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // Secondary: collapsed to one row until opened.
            QuotaSpend {
                id: spend
                visible: Quota.providerGroups.length > 0 || Quota.todayCostUsd !== null
                width: parent.width
                family: root.family
                onExpandedChanged: body.revealSpend = expanded
            }
        }
    }
    Item {
        id: footer
        anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
        height: 44
        Rectangle { width: parent.width; height: 1; color: root.hairline }
        Column {
            anchors.left: parent.left
            anchors.leftMargin: 4
            anchors.right: refresh.left
            anchors.rightMargin: 4
            anchors.bottom: parent.bottom
            spacing: 1
            Label {
                width: parent.width
                text: root.loading ? qsTr("Refreshing…")
                    : root.hasError ? qsTr("Refresh failed, showing saved data")
                    : Quota.lastUpdatedAt > 0 ? qsTr("Updated %1").arg(root.relativeTime(new Date(Quota.lastUpdatedAt).toISOString())) : qsTr("No reading yet")
                color: root.hasError && !root.loading ? Colours.palette.m3error : root.muted
                font.pixelSize: 11
                elide: Text.ElideRight
                HoverHandler { id: statusHover }
                QuotaToolTip { visible: statusHover.hovered && root.hasError; text: root.error; boundsItem: root; family: root.family }
            }
            Label {
                visible: text !== "" && !root.loading
                width: parent.width
                text: Quota.keepaliveRunning ? qsTr("Keepalive %1/%2").arg(Quota.keepaliveDone).arg(Quota.keepaliveTotal) : root.nextUpdateText
                color: root.muted
                font.pixelSize: 11
                elide: Text.ElideRight
            }
        }
        // Explicit refresh only; opening or closing anything never refreshes.
        IconButton {
            id: refresh
            objectName: "quotaRefresh"
            anchors.right: keepalive.left
            anchors.rightMargin: 4
            anchors.verticalCenter: keepalive.verticalCenter
            implicitWidth: 30
            implicitHeight: 30
            icon: "refresh"
            type: IconButton.Text
            font: Tokens.font.icon.small
            enabled: !root.loading && Quota.configured
            onClicked: Quota.refresh(true)
            Accessible.name: qsTr("Refresh quota")
            QuotaToolTip { visible: parent.hovered; text: qsTr("Refresh now"); boundsItem: root; family: root.family }
        }
        // Keepalive pill, in the place of OpenUsage's Options button. At narrow
        // widths it keeps only its icon so the status text still fits.
        AbstractButton {
            id: keepalive
            objectName: "quotaKeepalive"
            readonly property bool compact: root.width < 320
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: 30
            leftPadding: compact ? 9 : 12; rightPadding: compact ? 9 : 14
            enabled: !Quota.keepaliveRunning && Quota.configured
            hoverEnabled: true
            onClicked: Quota.triggerKeepalive()
            Accessible.name: qsTr("Keep quota windows active")
            background: Rectangle {
                radius: height / 2
                color: Qt.alpha(Colours.palette.m3onSurface, keepalive.down ? 0.12 : keepalive.hovered ? 0.09 : 0.06)
                border.width: keepalive.activeFocus ? 1 : 0
                border.color: Colours.palette.m3primary
            }
            contentItem: Row {
                spacing: 4
                opacity: keepalive.enabled ? 1 : 0.5
                MaterialIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    text: Quota.keepaliveRunning ? "hourglass_top" : "bolt"
                    color: Colours.palette.m3onSurface
                    fontStyle: Tokens.font.icon.size(12).build()
                }
                Label {
                    visible: !keepalive.compact
                    anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("Keepalive")
                    font.weight: Font.DemiBold
                }
            }
            QuotaToolTip {
                visible: keepalive.hovered
                text: qsTr("Send keepalive requests to Codex and Antigravity")
                boundsItem: root
                family: root.family
            }
        }
    }
}
