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
import "../../utils/FileUrls.js" as FileUrls

// A port of OpenUsage's menu bar panel (github.com/robinebers/openusage, MIT),
// themed with the Caelestia scheme. Every size comes from its SwiftUI source:
// the Priority | All Usage segments on top (Views/PopoverTopBar.swift), one
// scroll with a card of compact provider rows (QuotaProviderRow), each opening
// to its accounts on a shared column grid (DashboardGrid.swift),
// the Priority board (Views/PriorityDashboardView.swift) and a footer with the
// update status and the "…" menu (Views/PopoverFooter.swift). The Wrapper
// supplies the 12 dp panel margin round all of it.
Item {
    id: root
    objectName: "quotaContent"
    property bool loading: false
    property bool hasError: false
    property string error: ""
    property bool revealed: false
    readonly property string family: Tokens.font.body.small.family
    readonly property color muted: Colours.palette.m3onSurfaceVariant
    readonly property color hairline: Qt.alpha(Colours.palette.m3onSurface, Colours.light ? 0.05 : 0.06)
    readonly property double staleAfter: Math.max(180000, Quota.refreshIntervalMs * 3)
    // The chosen view lives in the service, so it outlasts the drawer closing.
    readonly property string view: Quota.usageView
    // Only Priority reads the board. All Usage has its own per-account model.
    readonly property var board: view === "priority"
        ? Logic.priorityBoard(Quota.providers, account => root.readProblem(account))
        : ({ attention: [], usedUp: [], notices: [], showsClearRow: false, summary: "" })

    // OpenUsage metrics (see the metrics table in the PR): content padding 7
    // above and below (DashboardContentView.barGap), sections 14 apart, cards
    // padded 12 / 8 / 10 with accounts 8 apart.
    readonly property int barGap: 7
    readonly property int sectionSpacing: 14
    readonly property int cardPad: 12
    readonly property int cardTop: 8
    readonly property int cardBottom: 10
    readonly property real inner: width - cardPad * 2
    readonly property var grid: Logic.grid(inner)
    // All Usage's card: 6 dp round its account rows.
    readonly property int listPad: 6
    // Accounts opened in All Usage, by account id. Kept while the drawer is
    // hidden, like the chosen view.
    property var expanded: ({})

    function toggleAccount(id: string): void {
        const next = Object.assign({}, root.expanded);
        next[id] = !next[id];
        root.expanded = next;
    }
    // The line under the provider's name: the plan, and the account's name too
    // when the provider has more than one account (or no plan is reported).
    function accountSubtitle(account: var, siblings: int): string {
        const tier = root.tierName(account);
        const name = root.accountName(account);
        if (!tier || tier === name)
            return name;
        return siblings > 1 ? tier + " · " + name : tier;
    }

    implicitWidth: QuotaConfig.panelWidth - Tokens.padding.medium * 2
    implicitHeight: Math.min(segments.height + barGap + body.contentHeight + footer.height,
        QuotaConfig.panelHeight - Tokens.padding.medium * 2)

    // OpenUsage's Accounts and Settings. The drawer has no account screen of
    // its own: quota sources and the panel switch live in Nexus, so the Wrapper
    // closes the drawer and opens Nexus there.
    signal accountsRequested()
    signal settingsRequested()

    // Called when the drawer hides: back to the top.
    function resetScroll(): void {
        body.contentY = 0;
        menu.open = false;
        popover.dismiss();
    }
    // A provider's usage for one range as the breakdown detail: CPA's analytics
    // give a cost per provider and range; a hub read adds the tokens, their
    // mix and Top Models (Logic.usageDetail).

    // OpenUsage's popover keys: Return opens Accounts, Ctrl+, Settings and
    // Ctrl+R refreshes. Keys a focused control uses itself never reach here.
    Keys.onPressed: event => {
        if (event.key === Qt.Key_Escape && popover.open) {
            popover.dismiss();
        } else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && event.modifiers === Qt.NoModifier) {
            root.accountsRequested();
        } else if (event.key === Qt.Key_Comma && event.modifiers === Qt.ControlModifier) {
            root.settingsRequested();
        } else if (event.key === Qt.Key_R && event.modifiers === Qt.ControlModifier) {
            if (!root.loading && Quota.configured)
                Quota.refresh(true);
        } else {
            return;
        }
        event.accepted = true;
    }

    Component {
        id: breakdownDetail
        QuotaBreakdown { family: root.family }
    }
    Component {
        id: resetsDetail
        QuotaResets { family: root.family }
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
    // A stale reading with no error behind it is only old: OpenUsage marks it
    // with a clock, not the warning triangle.
    function onlyOld(account: var, state: string): bool {
        return state === "stale" && !account.unavailable && !account.quotaError && !account.errorText && !root.hasError;
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
    // Why an account's current usage cannot be read, for Priority's Needs
    // Attention (OpenUsage lists accounts whose read failed, not routing states).
    function readProblem(account: var): string {
        const state = root.accountState(account);
        return state === "auth" || (state === "stale" && !root.onlyOld(account, state)) ? root.accountNotice(account, state) : "";
    }
    // Provider marks are not shipped (their redistribution terms are not
    // settled): they come from the user's own provider-icons folder as
    // <provider>.svg, with an optional <provider>-light.svg for light schemes.
    // QuotaLogo shows the provider's initials when the file is missing.
    function providerIconSource(providerId: string): url {
        const name = Logic.iconName(providerId);
        if (!name || !QuotaConfig.providerIconsDir)
            return "";
        return FileUrls.fromLocalPath(QuotaConfig.providerIconsDir + "/" + name + (Colours.light ? "-light.svg" : ".svg"));
    }
    function providerIconAlt(providerId: string): url {
        const name = Logic.iconName(providerId);
        return name && QuotaConfig.providerIconsDir && Colours.light ? FileUrls.fromLocalPath(QuotaConfig.providerIconsDir + "/" + name + ".svg") : "";
    }
    function providerName(account: var): string {
        return account.providerLabel || Quota.providerDisplayName(account.provider);
    }
    function zaiPeakText(): string {
        const now = new Date(Quota.nowMs);
        if (now.getUTCHours() < 1 || now.getUTCHours() >= 15) return "";
        const end = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate(), 15);
        const mins = Math.max(1, Math.floor((end - Quota.nowMs) / 60000));
        return qsTr("Ends in %1h %2m").arg(Math.floor(mins / 60)).arg(mins % 60);
    }
    // OpenUsage's footer countdown: minutes rounded up from a minute out, then seconds.
    readonly property string nextUpdateText: {
        if (Quota.nextUpdateAt <= 0) return "";
        const secs = Math.ceil((Quota.nextUpdateAt - Quota.nowMs) / 1000);
        if (secs <= 0) return qsTr("Update due");
        return secs >= 60 ? qsTr("Next update in %1m").arg(Math.ceil(secs / 60)) : qsTr("Next update in %1s").arg(secs);
    }

    component Label: StyledText {
        font.family: root.family
        font.pixelSize: 12
        font.features: ({"tnum": 1})
    }
    // PriorityBoardList.sectionLabel: 11 semibold, muted, 4 in, 2 above the rows.
    component SectionLabel: StyledText {
        x: 4
        bottomPadding: 2
        color: root.muted
        font.family: root.family
        font.pixelSize: 11
        font.weight: Font.DemiBold
        Accessible.role: Accessible.Heading
        Accessible.name: text
    }
    // AccountStatus.glyph: a 10 dp warning triangle, or a clock for a reading
    // that is only old, with the notice in a tooltip and for screen readers.
    component NoticeGlyph: MaterialIcon {
        id: glyph
        property string notice: ""
        property bool old: false
        objectName: "quotaNotice"
        visible: notice !== ""
        text: old ? "schedule" : "warning"
        fill: old ? 0 : 1
        color: old ? Qt.alpha(root.muted, 0.6) : Colours.palette.m3tertiary
        fontStyle: Tokens.font.icon.builders.small.scale(0.6).build()
        Accessible.role: Accessible.StaticText
        Accessible.name: notice
        HoverHandler { id: glyphHover }
        QuotaToolTip { visible: glyphHover.hovered; text: glyph.notice; boundsItem: root; family: root.family }
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
        anchors.topMargin: root.barGap
        anchors.left: parent.left
        anchors.right: parent.right
        // The scroll bar sits in the drawer's outer margin, not over the cards.
        anchors.rightMargin: -Tokens.padding.small
        anchors.bottom: footer.top
        clip: true
        activeFocusOnTab: true
        contentWidth: root.width
        contentHeight: stack.implicitHeight + root.barGap * 2
        flickableDirection: Flickable.VerticalFlick
        boundsBehavior: Flickable.StopAtBounds
        // A detail belongs to the figure it points at; scrolling moves that away.
        onContentYChanged: if (!popover.explicit) popover.dismiss()
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
            radius: Tokens.rounding.medium
            color: "transparent"
            border.width: 2
            border.color: Colours.palette.m3primary
        }

        function scrollBy(delta: real): void {
            contentY = Math.max(0, Math.min(Math.max(0, contentHeight - height), contentY + delta));
        }
        // Keeps a row the keyboard reached in view.
        function ensureVisible(target: Item): void {
            const top = target.mapToItem(contentItem, 0, 0).y;
            if (top < contentY) scrollBy(top - contentY);
            else if (top + target.height > contentY + height) scrollBy(top + target.height - contentY - height);
        }
        Keys.onUpPressed: scrollBy(-44)
        Keys.onDownPressed: scrollBy(44)
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
            y: root.barGap
            width: root.width
            spacing: root.sectionSpacing

            // EmptyDashboardView: 19 semibold title, 12 muted message at most
            // 230 wide, padded 16 / 22 / 26. Accounts live in CPA Manager, so
            // there is no app icon or Add Account button here.
            Column {
                objectName: "quotaEmpty"
                visible: Quota.providerGroups.length === 0
                width: parent.width
                topPadding: 22
                bottomPadding: 26
                StyledText {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    bottomPadding: 7
                    text: Quota.status === "unconfigured" ? qsTr("Not Configured")
                        : Quota.keyRefused ? qsTr("Key Rejected") : qsTr("No Usage Yet")
                    color: Colours.palette.m3onSurface
                    font.family: root.family
                    font.pixelSize: 19
                    font.weight: Font.DemiBold
                }
                Label {
                    id: emptyText
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: Math.min(230, parent.width - 32)
                    horizontalAlignment: Text.AlignHCenter
                    text: Quota.status === "unconfigured" ? qsTr("Add cpa-agents.json to the shell config folder.")
                        : Quota.keyRefused ? root.error : qsTr("No agent usage records found.")
                    wrapMode: Text.WordWrap
                    color: root.muted
                }
            }

            // Priority: what is running out, then what is used up, then the
            // accounts that cannot be read.
            Column {
                objectName: "quotaPriority"
                visible: root.view === "priority" && Quota.providerGroups.length > 0
                width: parent.width
                spacing: Tokens.spacing.medium

                Column {
                    visible: root.board.attention.length > 0 || root.board.showsClearRow
                    width: parent.width
                    SectionLabel { text: qsTr("Running Out") }
                    Item {
                        objectName: "quotaAllClear"
                        visible: root.board.attention.length === 0
                        x: 4
                        width: parent.width - 8
                        height: 46
                        Accessible.role: Accessible.StaticText
                        Accessible.name: qsTr("All Clear, nothing is running out.")
                        Rectangle {
                            id: clearDisc
                            anchors.verticalCenter: parent.verticalCenter
                            width: 32
                            height: 32
                            radius: 16
                            color: Qt.alpha(Colours.palette.m3success, 0.16)
                            MaterialIcon {
                                anchors.centerIn: parent
                                text: "check"
                                color: Colours.palette.m3success
                                fontStyle: Tokens.font.icon.builders.small.weight(Font.DemiBold).scale(0.8).build()
                            }
                        }
                        Column {
                            anchors.left: clearDisc.right
                            anchors.leftMargin: 10
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 1
                            StyledText {
                                text: qsTr("All Clear")
                                color: Colours.palette.m3onSurface
                                font.family: root.family
                                font.pixelSize: 13
                                font.weight: Font.Medium
                            }
                            StyledText {
                                text: qsTr("Nothing is running out.")
                                color: root.muted
                                font.family: root.family
                                font.pixelSize: 11
                            }
                        }
                    }
                    Repeater {
                        model: root.view === "priority" ? root.board.attention : []
                        delegate: QuotaPriorityRow {
                            required property var modelData
                            x: 4
                            width: stack.width - 8
                            entry: modelData
                            nowMs: Quota.nowMs
                            family: root.family
                            logo: root.providerIconSource(modelData.account.provider)
                            providerLabel: root.providerName(modelData.account)
                            accountLabel: root.accountName(modelData.account)
                        }
                    }
                }

                // Used Up: 28 dp rows at half strength.
                Column {
                    visible: root.board.usedUp.length > 0
                    width: parent.width
                    opacity: 0.5
                    SectionLabel { text: qsTr("Used Up") }
                    Repeater {
                        model: root.view === "priority" ? root.board.usedUp : []
                        delegate: RowLayout {
                            id: usedRow
                            required property var modelData
                            readonly property string reset: Logic.resetShort(modelData.limit.resetsAt, Quota.nowMs)
                            objectName: "quotaUsedUpRow"
                            x: 4
                            width: stack.width - 8
                            height: 28
                            spacing: 8
                            Accessible.role: Accessible.StaticText
                            Accessible.name: [root.providerName(modelData.account), root.accountName(modelData.account),
                                Logic.title(modelData.limit), qsTr("used up"),
                                reset ? qsTr("resets in %1").arg(Logic.resetSpoken(modelData.limit.resetsAt, Quota.nowMs)) : ""].filter(s => s).join(", ")
                            QuotaLogo {
                                Layout.preferredWidth: 16
                                implicitWidth: 15
                                implicitHeight: 15
                                source: root.providerIconSource(usedRow.modelData.account.provider)
                                fallback: root.providerName(usedRow.modelData.account)
                            }
                            StyledText {
                                text: Logic.title(usedRow.modelData.limit)
                                color: Colours.palette.m3onSurface
                                font.family: root.family
                                font.pixelSize: 13
                            }
                            StyledText {
                                Layout.fillWidth: true
                                Layout.minimumWidth: 0
                                text: root.accountName(usedRow.modelData.account)
                                elide: Text.ElideMiddle
                                color: root.muted
                                font.family: root.family
                                font.pixelSize: 11
                            }
                            StyledText {
                                text: usedRow.reset
                                color: Colours.palette.m3onSurface
                                font.family: root.family
                                font.pixelSize: 12
                                font.features: ({"tnum": 1})
                            }
                        }
                    }
                }

                // Needs Attention: accounts whose usage cannot be read now.
                Column {
                    visible: root.board.notices.length > 0
                    width: parent.width
                    Row {
                        spacing: 2
                        SectionLabel { text: qsTr("Needs Attention") }
                        MaterialIcon {
                            text: "warning"
                            fill: 1
                            color: Colours.palette.m3tertiary
                            fontStyle: Tokens.font.icon.builders.small.scale(0.6).build()
                            Accessible.ignored: true
                        }
                    }
                    Repeater {
                        model: root.view === "priority" ? root.board.notices : []
                        delegate: RowLayout {
                            id: noticeRow
                            required property var modelData
                            objectName: "quotaNoticeRow"
                            x: 4
                            width: stack.width - 8
                            height: 28
                            spacing: 8
                            Accessible.role: Accessible.StaticText
                            Accessible.name: [root.providerName(modelData.account), root.accountName(modelData.account), modelData.message].join(", ")
                            QuotaLogo {
                                Layout.preferredWidth: 16
                                implicitWidth: 15
                                implicitHeight: 15
                                source: root.providerIconSource(noticeRow.modelData.account.provider)
                                fallback: root.providerName(noticeRow.modelData.account)
                            }
                            StyledText {
                                text: root.providerName(noticeRow.modelData.account)
                                color: Colours.palette.m3onSurface
                                font.family: root.family
                                font.pixelSize: 13
                                font.weight: Font.DemiBold
                            }
                            StyledText {
                                Layout.fillWidth: true
                                Layout.minimumWidth: 0
                                text: root.accountName(noticeRow.modelData.account)
                                elide: Text.ElideMiddle
                                color: root.muted
                                font.family: root.family
                                font.pixelSize: 11
                            }
                            HoverHandler { id: noticeHover }
                            QuotaToolTip { visible: noticeHover.hovered; text: noticeRow.modelData.message; boundsItem: root; family: root.family }
                        }
                    }
                }

                // No Reported Limits, with a link to All Usage.
                Column {
                    objectName: "quotaNoLimits"
                    visible: root.board.summary === "noReportedLimits"
                    width: parent.width
                    topPadding: 6
                    bottomPadding: 6
                    spacing: 4
                    StyledText {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: qsTr("No Reported Limits")
                        color: Colours.palette.m3onSurface
                        font.family: root.family
                        font.pixelSize: 13
                        font.weight: Font.Medium
                    }
                    Label {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: qsTr("View All Usage")
                        color: Colours.palette.m3primary
                        TapHandler { onTapped: Quota.usageView = "all" }
                    }
                }
            }

            // All Usage: one card with a compact row per account, grouped by
            // provider. A row opens to that account's meters and reset credits,
            // then its provider's peak hours and spend.
            Rectangle {
                objectName: "quotaCard"
                visible: root.view === "all" && Quota.providerGroups.length > 0
                width: stack.width
                height: list.implicitHeight + root.listPad * 2
                radius: Tokens.rounding.large
                color: Colours.palette.m3surfaceContainer
                border.width: 1
                border.color: root.hairline

                Column {
                    id: list
                    x: root.listPad
                    y: root.listPad
                    width: parent.width - root.listPad * 2
                    spacing: 2

                    Repeater {
                        model: root.view === "all" ? Quota.providerGroups : []
                        delegate: Column {
                            id: section
                            required property var modelData
                            readonly property var spendRows: [
                                { key: "today", label: qsTr("Today") },
                                { key: "yesterday", label: qsTr("Yesterday") },
                                { key: "month", label: qsTr("Last 30 Days") }
                            ].map(r => ({
                                label: r.label,
                                cost: Logic.spendFor(Quota.spend, r.key, modelData.provider),
                                usage: Logic.usageFor(modelData.accounts, r.key, Quota.nowMs)
                            })).filter(r => r.cost !== null || r.usage !== null)
                            readonly property string peak: modelData.provider === "zai" ? root.zaiPeakText() : ""
                            objectName: "quotaSection"
                            width: list.width
                            spacing: 2

                            Repeater {
                                model: section.modelData.accounts
                                delegate: Column {
                                    id: account
                                    required property var modelData
                                    readonly property string quotaState: root.accountState(modelData)
                                    readonly property bool expanded: root.expanded[modelData.id] === true
                                    objectName: "quotaAccount"
                                    width: section.width

                                    QuotaProviderRow {
                                        width: parent.width
                                        summary: Logic.providerSummary([account.modelData])
                                        nowMs: Quota.nowMs
                                        label: section.modelData.label
                                        subtitle: root.accountSubtitle(account.modelData, section.modelData.accounts.length)
                                        provider: section.modelData.provider
                                        logo: root.providerIconSource(section.modelData.provider)
                                        logoAlt: root.providerIconAlt(section.modelData.provider)
                                        notice: root.accountNotice(account.modelData, account.quotaState)
                                        noticeOld: root.onlyOld(account.modelData, account.quotaState)
                                        expanded: account.expanded
                                        family: root.family
                                        boundsItem: root
                                        onClicked: root.toggleAccount(account.modelData.id)
                                        onActiveFocusChanged: if (activeFocus) body.ensureVisible(this)
                                    }
                                    Loader {
                                        // Collapsed accounts need only their summary row.
                                        active: account.expanded
                                        visible: active
                                        x: root.cardPad - root.listPad
                                        width: root.inner

                                        sourceComponent: Column {
                                            id: card
                                            objectName: "quotaDetail"
                                            topPadding: 2
                                            bottomPadding: root.cardBottom

                                            Repeater {
                                                model: Logic.accountWindows(account.modelData)
                                                delegate: QuotaMeter {
                                                    required property var modelData
                                                    width: card.width
                                                    limit: modelData
                                                    nowMs: Quota.nowMs
                                                    grid: root.grid
                                                    family: root.family
                                                    provider: section.modelData.label
                                                }
                                            }
                                            // OpenUsage's "Limit Resets" row, shown only when the
                                            // data reports reset credits (DashboardFamilies.swift:39).
                                            // Its figure warns in the colour of the next to expire.
                                            QuotaValueRow {
                                                readonly property var credits: account.modelData.resetCredits ?? null
                                                readonly property int creditCount: Number(credits?.count ?? (credits?.expiries ?? []).length) || 0
                                                readonly property var next: Logic.resetEntries(credits?.expiries ?? [], Quota.nowMs)[0] ?? null
                                                objectName: "quotaLimitResets"
                                                visible: creditCount > 0
                                                width: card.width
                                                family: root.family
                                                label: qsTr("Limit Resets")
                                                value: qsTr("%1 available").arg(creditCount)
                                                severity: next && next.severity === "warning" ? "warning" : next && next.severity === "critical" ? "critical" : "normal"
                                                hasDetail: true
                                                lit: popover.open && popover.anchorItem === figure
                                                readonly property var detailData: ({ count: creditCount, expiries: credits?.expiries ?? [], nowMs: Quota.nowMs })
                                                onDetailHover: (anchor, active) => popover.hover(anchor, resetsDetail, detailData, active)
                                                onDetailClicked: anchor => popover.openFor(anchor, resetsDetail, detailData)
                                            }
                                            // The provider's own figures: peak hours and spend,
                                            // for all of its accounts together.
                                            Column {
                                                objectName: "quotaSpend"
                                                visible: section.peak !== "" || section.spendRows.length > 0
                                                width: card.width
                                                topPadding: 6
                                                SectionLabel {
                                                    x: 0
                                                    visible: section.modelData.accounts.length > 1
                                                    text: qsTr("%1 · all accounts").arg(section.modelData.label)
                                                }
                                                QuotaValueRow {
                                                    visible: section.peak !== ""
                                                    width: parent.width
                                                    family: root.family
                                                    label: qsTr("Peak hours")
                                                    value: section.peak
                                                }
                                                Repeater {
                                                    model: section.spendRows
                                                    delegate: QuotaValueRow {
                                                        required property var modelData
                                                        readonly property var detailData: Logic.usageDetail(modelData.label, modelData.cost, modelData.usage)
                                                        width: card.width
                                                        family: root.family
                                                        label: modelData.label
                                                        // Spend when the manager reports it; tokens from a hub read otherwise.
                                                        value: modelData.cost !== null ? Logic.money(modelData.cost) : qsTr("%1 tokens").arg(Logic.count(modelData.usage.tokens))
                                                        hasDetail: true
                                                        lit: popover.open && popover.anchorItem === figure
                                                        onDetailHover: (anchor, active) => popover.hover(anchor, breakdownDetail, detailData, active)
                                                        onDetailClicked: anchor => popover.openFor(anchor, breakdownDetail, detailData)
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
            }
        }
    }

    // PopoverFooter: a 1 dp divider across the panel, 7 above 26 dp controls
    // (the Wrapper's 12 dp margin is below), the status 4 in from each side.
    Item {
        id: footer
        objectName: "quotaFooter"
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: 1 + root.barGap + 26

        // The scroll content stops above this band, so the footer needs no
        // opaque backing: it keeps the drawer surface's own transparency
        // (ContentWindow paints Colours.tPalette.m3surface).
        Rectangle {
            objectName: "quotaFooterBacking"
            anchors.fill: parent
            anchors.leftMargin: -Tokens.padding.medium
            anchors.rightMargin: -Tokens.padding.medium
            color: Colours.tPalette.m3surface
        }
        Rectangle {
            objectName: "quotaFooterDivider"
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: -Tokens.padding.medium
            anchors.rightMargin: -Tokens.padding.medium
            height: 1
            color: Qt.alpha(Colours.palette.m3onSurface, Colours.light ? 0.1 : 0.12)
        }
        // The status refreshes on a click, behind OpenUsage's hover chip. The
        // keyboard reaches the same action through the menu's Refresh now.
        Label {
            id: status
            objectName: "quotaStatus"
            anchors.left: parent.left
            anchors.leftMargin: 4
            anchors.right: retry.visible ? retry.left : more.left
            anchors.rightMargin: 8
            anchors.verticalCenter: more.verticalCenter
            text: root.loading ? qsTr("Updating…")
                // A refused key is not a failed refresh: say what to change
                // (the full line is in the tooltip and the empty state).
                : Quota.keyBanExpired ? qsTr("CLIProxyAPI ban ended.")
                : Quota.keyRefused ? qsTr("Management key rejected. Update cpa-agents.json.")
                : root.hasError ? qsTr("Refresh failed, showing saved data")
                : Quota.keepaliveRunning ? qsTr("Keepalive %1/%2").arg(Quota.keepaliveDone).arg(Quota.keepaliveTotal)
                : root.nextUpdateText !== "" ? root.nextUpdateText
                : qsTr("No reading yet")
            color: root.hasError && !root.loading ? Colours.palette.m3error : root.muted
            elide: Text.ElideRight
            Rectangle {
                z: -1
                x: -6
                y: -2
                width: Math.min(status.width, status.contentWidth) + 12
                height: status.height + 4
                radius: 6
                color: Qt.alpha(Colours.palette.m3onSurface, 0.08)
                opacity: statusHover.hovered && !root.loading && Quota.configured ? 1 : 0
                Behavior on opacity {
                    NumberAnimation {
                        duration: 120
                        easing.type: Easing.OutQuad
                    }
                }
            }
            HoverHandler { id: statusHover }
            TapHandler { onTapped: if (!root.loading && Quota.configured) Quota.refresh(true) }
            QuotaToolTip {
                visible: statusHover.hovered
                text: root.hasError ? root.error : qsTr("Refresh now")
                boundsItem: root
                family: root.family
            }
        }
        // A ban ends on its own, but the key stays withheld until the user asks
        // again: this is that one explicit retry, using the same key.
        AbstractButton {
            id: retry
            objectName: "quotaRetry"
            visible: Quota.keyBanExpired
            anchors.right: more.left
            anchors.rightMargin: 8
            anchors.verticalCenter: more.verticalCenter
            width: retryLabel.implicitWidth + 16
            height: 20
            hoverEnabled: true
            Accessible.name: qsTr("Retry the management key")
            onClicked: Quota.retryRefusedKey()
            Keys.onReturnPressed: retry.click()
            Keys.onEnterPressed: retry.click()
            background: Rectangle {
                radius: height / 2
                color: Colours.palette.m3secondaryContainer
                border.width: retry.activeFocus ? 2 : 0
                border.color: Colours.palette.m3primary
            }
            contentItem: Label {
                id: retryLabel
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                text: qsTr("Retry")
                color: Colours.palette.m3onSecondaryContainer
                font.pixelSize: 11
                font.weight: Font.DemiBold
            }
        }
        // Refresh and keepalive, both explicit; opening or closing anything never refreshes.
        AbstractButton {
            id: more
            objectName: "quotaMore"
            anchors.right: parent.right
            anchors.rightMargin: 4
            anchors.bottom: parent.bottom
            width: 26
            height: 26
            hoverEnabled: true
            onClicked: menu.open ? menu.hide() : menu.show()
            Keys.onReturnPressed: more.click()
            Keys.onEnterPressed: more.click()
            Accessible.name: qsTr("More actions")
            background: Rectangle {
                radius: height / 2
                color: Colours.palette.m3surfaceContainerHigh
                border.width: more.activeFocus ? 2 : 0
                border.color: Colours.palette.m3primary
            }
            contentItem: MaterialIcon {
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                text: "more_horiz"
                color: Colours.palette.m3onSurface
                fontStyle: Tokens.font.icon.builders.small.weight(Font.DemiBold).scale(0.85).build()
            }
        }
    }

    QuotaMenu {
        id: menu
        anchors.right: parent.right
        anchors.bottom: footer.bottom
        anchors.bottomMargin: 32
        z: 3
        family: root.family
        returnFocusTo: more
        // OpenUsage's menu (Views/PopoverFooter.swift) keeps Accounts (Return)
        // and Settings (Ctrl+,); the drawer's own Refresh now and Keepalive sit
        // above them. Check for Updates, Report an Issue, About and Quit are
        // app-level: the shell has its own updater, about page and session.
        entries: [
            { key: "refresh", label: qsTr("Refresh now"), shortcut: qsTr("Ctrl+R"), enabled: !root.loading && Quota.configured },
            { key: "keepalive", label: qsTr("Keepalive"), enabled: !Quota.keepaliveRunning && Quota.configured },
            { separator: true },
            { key: "accounts", label: qsTr("Accounts"), shortcutIcon: "keyboard_return", enabled: true },
            { key: "settings", label: qsTr("Settings"), shortcut: qsTr("Ctrl+,"), enabled: true }
        ]
        onChosen: key => {
            if (key === "refresh") Quota.refresh(true);
            else if (key === "keepalive") Quota.triggerKeepalive();
            else if (key === "accounts") root.accountsRequested();
            else if (key === "settings") root.settingsRequested();
        }
    }

    QuotaPopover {
        id: popover
        boundsItem: root
    }
}
