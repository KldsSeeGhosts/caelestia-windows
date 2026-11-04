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

// After OpenUsage: a Priority | All Usage switch on top, one scroll of provider
// sections (a bold title, then a card of accounts on a shared column grid), and
// a footer that floats over the scroll with the update status and a menu.
Item {
    id: root
    objectName: "quotaContent"
    property bool loading: false
    property bool hasError: false
    property string error: ""
    property bool revealed: false
    readonly property string family: Tokens.font.body.small.family
    readonly property color muted: Colours.palette.m3onSurfaceVariant
    readonly property double staleAfter: Math.max(180000, Quota.refreshIntervalMs * 3)
    // The chosen view lives in the service, so it outlasts the drawer closing.
    readonly property string view: Quota.usageView
    readonly property var priority: Logic.priorityRows(Quota.providers)

    // One grid for every row: label, bar, % left, reset. At the 280 dp minimum
    // the bar column shrinks to 30% and the label elides.
    readonly property bool narrow: width < 320
    readonly property int cardPad: narrow ? 12 : 16
    readonly property real inner: width - cardPad * 2
    readonly property var grid: ({
        bar: Math.round(inner * (narrow ? 0.30 : 0.40)),
        pct: narrow ? 36 : 42,
        reset: narrow ? 52 : 50,
        gap: narrow ? 6 : 8
    })

    implicitWidth: QuotaConfig.panelWidth - Tokens.padding.large * 2
    implicitHeight: Math.min(segments.height + 12 + stack.implicitHeight + footer.height - 8,
        QuotaConfig.panelHeight - Tokens.padding.large * 2)

    // Called when the drawer hides: back to the top.
    function resetScroll(): void {
        body.contentY = 0;
        menu.open = false;
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
        return qsTr("Ends in %1h %2m").arg(Math.floor(mins / 60)).arg(mins % 60);
    }
    function money(value: real): string {
        return "$" + Number(value).toLocaleString(Qt.locale("en_US"), "f", 2);
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

    QuotaSegments {
        id: segments
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        family: root.family
        current: root.view
        model: [
            { key: "priority", label: qsTr("Priority") },
            { key: "all", label: qsTr("All Usage") }
        ]
        onActivated: key => Quota.usageView = key
    }

    StyledFlickable {
        id: body
        objectName: "quotaBody"
        anchors.top: segments.bottom
        anchors.topMargin: 12
        anchors.left: parent.left
        anchors.right: parent.right
        // The scroll bar sits in the drawer's outer padding, not over the cards.
        anchors.rightMargin: -Tokens.padding.small
        anchors.bottom: parent.bottom
        clip: true
        activeFocusOnTab: true
        contentWidth: root.width
        // The footer floats over the end of the scroll, so leave room under it.
        contentHeight: stack.implicitHeight + footer.height - 8
        flickableDirection: Flickable.VerticalFlick
        boundsBehavior: Flickable.StopAtBounds
        StyledScrollBar.vertical: StyledScrollBar {
            objectName: "quotaScrollBar"
            flickable: body
        }

        // A focus ring, so the keyboard can see which part is scrolling.
        Rectangle {
            parent: body
            anchors.fill: parent
            anchors.rightMargin: Tokens.padding.small
            visible: body.activeFocus
            z: 2
            radius: Tokens.rounding.large
            color: "transparent"
            border.width: 2
            border.color: Colours.palette.m3primary
        }

        function scrollBy(delta: real): void {
            contentY = Math.max(0, Math.min(Math.max(0, contentHeight - height), contentY + delta));
        }
        Keys.onUpPressed: scrollBy(-48)
        Keys.onDownPressed: scrollBy(48)
        Keys.onPressed: event => {
            if (event.key === Qt.Key_PageUp) scrollBy(-height * 0.9);
            else if (event.key === Qt.Key_PageDown) scrollBy(height * 0.9);
            else if (event.key === Qt.Key_Home) scrollBy(-contentHeight);
            else if (event.key === Qt.Key_End) scrollBy(contentHeight);
            else return;
            event.accepted = true;
        }

        Column {
            id: stack
            objectName: "quotaStack"
            width: root.width
            spacing: 20

            Rectangle {
                visible: Quota.providerGroups.length === 0
                width: parent.width
                height: emptyText.implicitHeight
                radius: Tokens.rounding.large
                color: Colours.palette.m3surfaceContainer
                border.width: 1
                border.color: Colours.palette.m3outlineVariant
                Label {
                    id: emptyText
                    width: parent.width
                    text: Quota.status === "unconfigured" ? qsTr("Not configured. Add cpa-agents.json to the shell config folder.") : qsTr("No agent usage records found.")
                    wrapMode: Text.WordWrap
                    color: root.muted
                    padding: root.cardPad
                }
            }

            // Priority: the account that runs out first, at the top.
            Column {
                objectName: "quotaPriority"
                visible: root.view === "priority" && root.priority.length > 0
                width: parent.width
                spacing: 8
                Rectangle {
                    width: parent.width
                    height: priorityRows.implicitHeight + root.cardPad * 2
                    radius: Tokens.rounding.large
                    color: Colours.palette.m3surfaceContainer
                    border.width: 1
                    border.color: Colours.palette.m3outlineVariant
                    Column {
                        id: priorityRows
                        x: root.cardPad
                        y: root.cardPad
                        width: parent.width - root.cardPad * 2
                        spacing: 16
                        Repeater {
                            model: root.view === "priority" ? root.priority : []
                            delegate: QuotaPriorityRow {
                                required property var modelData
                                width: priorityRows.width
                                entry: modelData
                                nowMs: Quota.nowMs
                                grid: root.grid
                                family: root.family
                                logo: root.providerIconSource(modelData.account.provider)
                                providerLabel: modelData.account.providerLabel || Quota.providerDisplayName(modelData.account.provider)
                                accountLabel: root.accountName(modelData.account)
                            }
                        }
                    }
                }
            }

            Repeater {
                model: root.view === "all" ? Quota.providerGroups : []
                delegate: Column {
                    id: section
                    required property var modelData
                    readonly property var spendRows: [
                        { key: "today", label: qsTr("Today") },
                        { key: "yesterday", label: qsTr("Yesterday") },
                        { key: "month", label: qsTr("Last 30 Days") }
                    ].map(r => ({ label: r.label, cost: Logic.spendFor(Quota.spend, r.key, modelData.provider) }))
                        .filter(r => r.cost !== null)
                    readonly property string peak: modelData.provider === "zai" ? root.zaiPeakText() : ""
                    objectName: "quotaSection"
                    width: stack.width
                    spacing: 8

                    RowLayout {
                        width: parent.width
                        height: 32
                        spacing: 8
                        Label {
                            objectName: "quotaSectionTitle"
                            Layout.fillWidth: true
                            Layout.minimumWidth: 0
                            leftPadding: 4
                            text: section.modelData.label
                            elide: Text.ElideRight
                            font.pixelSize: 20
                            font.weight: Font.Bold
                        }
                        QuotaLogo {
                            Layout.rightMargin: 4
                            implicitWidth: 22
                            implicitHeight: 22
                            source: root.providerIconSource(section.modelData.provider)
                            fallback: section.modelData.label
                        }
                    }
                    Rectangle {
                        width: parent.width
                        height: card.implicitHeight + root.cardPad * 2
                        radius: Tokens.rounding.large
                        color: Colours.palette.m3surfaceContainer
                        border.width: 1
                        border.color: Colours.palette.m3outlineVariant
                        Column {
                            id: card
                            x: root.cardPad
                            y: root.cardPad
                            width: parent.width - root.cardPad * 2
                            spacing: 20

                            Repeater {
                                model: section.modelData.accounts
                                delegate: Column {
                                    id: account
                                    required property var modelData
                                    readonly property string quotaState: root.accountState(modelData)
                                    readonly property string notice: root.accountNotice(modelData, quotaState)
                                    readonly property string tier: root.tierName(modelData)
                                    width: card.width
                                    spacing: 10

                                    RowLayout {
                                        width: parent.width
                                        spacing: 8
                                        Label {
                                            objectName: "quotaAccountName"
                                            Layout.fillWidth: true
                                            Layout.minimumWidth: 0
                                            text: root.accountName(account.modelData)
                                            color: root.muted
                                            font.weight: Font.DemiBold
                                            elide: Text.ElideRight
                                        }
                                        Rectangle {
                                            objectName: "quotaPlan"
                                            visible: account.tier !== "" && account.tier !== root.accountName(account.modelData)
                                            Layout.maximumWidth: parent.width * 0.5
                                            implicitWidth: planText.implicitWidth + 16
                                            implicitHeight: planText.implicitHeight + 6
                                            radius: height / 2
                                            color: Colours.palette.m3surfaceContainerHighest
                                            Label {
                                                id: planText
                                                anchors.centerIn: parent
                                                width: Math.min(implicitWidth, parent.width - 16)
                                                text: account.tier
                                                color: root.muted
                                                elide: Text.ElideRight
                                                font.pixelSize: 11
                                                font.weight: Font.Medium
                                            }
                                        }
                                    }
                                    QuotaValueRow {
                                        visible: account.notice !== ""
                                        width: parent.width
                                        family: root.family
                                        value: account.notice
                                        error: account.quotaState === "auth"
                                    }
                                    Repeater {
                                        model: Logic.accountWindows(account.modelData)
                                        delegate: QuotaMeter {
                                            required property var modelData
                                            width: account.width
                                            limit: modelData
                                            nowMs: Quota.nowMs
                                            grid: root.grid
                                            family: root.family
                                            provider: section.modelData.label
                                        }
                                    }
                                }
                            }
                            // What the data really has: a notice and the provider's spend.
                            QuotaValueRow {
                                visible: section.peak !== ""
                                width: parent.width
                                family: root.family
                                label: qsTr("Peak hours")
                                value: section.peak
                            }
                            Column {
                                objectName: "quotaSpend"
                                visible: section.spendRows.length > 0
                                width: parent.width
                                spacing: 10
                                Repeater {
                                    model: section.spendRows
                                    delegate: QuotaValueRow {
                                        id: spendRow
                                        required property var modelData
                                        width: card.width
                                        family: root.family
                                        label: modelData.label
                                        value: root.money(modelData.cost)
                                        HoverHandler { id: spendHover }
                                        QuotaToolTip {
                                            visible: spendHover.hovered
                                            text: qsTr("API-equivalent cost from CPA Manager's usage analytics.")
                                            boundsItem: root
                                            family: root.family
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // The footer floats over the scroll: the content fades out beneath it.
    Item {
        id: footer
        objectName: "quotaFooter"
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: 56

        Rectangle {
            anchors.fill: parent
            gradient: Gradient {
                GradientStop { position: 0; color: Qt.alpha(Colours.palette.m3surface, 0) }
                GradientStop { position: 0.25; color: Qt.alpha(Colours.palette.m3surface, 1) }
                GradientStop { position: 1; color: Qt.alpha(Colours.palette.m3surface, 1) }
            }
        }
        Label {
            id: status
            objectName: "quotaStatus"
            anchors.left: parent.left
            anchors.leftMargin: 4
            anchors.right: more.left
            anchors.rightMargin: 8
            anchors.verticalCenter: more.verticalCenter
            text: root.loading ? qsTr("Updating…")
                : root.hasError ? qsTr("Refresh failed, showing saved data")
                : Quota.keepaliveRunning ? qsTr("Keepalive %1/%2").arg(Quota.keepaliveDone).arg(Quota.keepaliveTotal)
                : root.nextUpdateText !== "" ? root.nextUpdateText
                : qsTr("No reading yet")
            color: root.hasError && !root.loading ? Colours.palette.m3error : root.muted
            elide: Text.ElideRight
            HoverHandler { id: statusHover }
            QuotaToolTip { visible: statusHover.hovered && root.hasError; text: root.error; boundsItem: root; family: root.family }
        }
        // Refresh and keepalive, both explicit; opening or closing anything never refreshes.
        AbstractButton {
            id: more
            objectName: "quotaMore"
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 6
            width: 36
            height: 36
            hoverEnabled: true
            onClicked: menu.open ? menu.hide() : menu.show()
            Keys.onReturnPressed: more.click()
            Keys.onEnterPressed: more.click()
            Accessible.name: qsTr("More actions")
            background: Rectangle {
                radius: height / 2
                color: Qt.alpha(Colours.palette.m3onSurface, more.down ? 0.16 : more.hovered || menu.open ? 0.12 : 0.08)
                border.width: more.activeFocus ? 2 : 0
                border.color: Colours.palette.m3primary
            }
            contentItem: MaterialIcon {
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                text: "more_horiz"
                color: Colours.palette.m3onSurface
            }
        }
    }

    QuotaMenu {
        id: menu
        anchors.right: parent.right
        anchors.bottom: footer.bottom
        anchors.bottomMargin: 48
        z: 3
        family: root.family
        returnFocusTo: more
        entries: [
            { key: "refresh", label: qsTr("Refresh now"), icon: "refresh", enabled: !root.loading && Quota.configured },
            { key: "keepalive", label: qsTr("Keepalive"), icon: "bolt", enabled: !Quota.keepaliveRunning && Quota.configured }
        ]
        onChosen: key => key === "refresh" ? Quota.refresh(true) : Quota.triggerKeepalive()
    }
}
