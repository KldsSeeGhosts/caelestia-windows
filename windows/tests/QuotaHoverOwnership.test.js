// Runs the real Interactions.qml quota/dashboard hover block and the real
// Panels adapter binding and handler in a vm, against fake panels. The fakes
// model only requested state, visibility and the signal order. This is not
// native pointer delivery or a live check.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const test = require("node:test");
const repo = path.resolve(__dirname, "../..");
const read = file => fs.readFileSync(path.join(repo, file), "utf8").replace(/\r\n/g, "\n");

const interactions = read("modules/drawers/Interactions.qml");
const panelsAdapter = read("windows/shell/adapters/modules/drawers/Panels.qml");

function between(text, start, end) {
    const from = text.indexOf(start);
    assert.ok(from >= 0, `missing: ${start}`);
    const to = text.indexOf(end, from);
    assert.ok(to > from, `missing: ${end}`);
    return text.slice(from, to);
}

// Production code, taken verbatim from the shipped files.
const hoverBlock = between(interactions, "        const inQuotaZone", "        // Show/hide dashboard on drag");
const blockedExpression = panelsAdapter.match(/readonly property bool quotaHoverBlocked: (.+)\n/)[1];
const blockedHandler = panelsAdapter.match(/onQuotaHoverBlockedChanged: \{\n([\s\S]*?)\n    \}\n/)[1];

const QUOTA = { x: [700, 1000], bottom: 200 };
const DASHBOARD = { x: [400, 700], bottom: 120 };

// A drawer as Panels sees it: shouldBeActive is the request, visible is the
// slide animation (visible while offsetScale < 1, so it outlives the request).
function drawer() {
    return { shouldBeActive: false, visible: false };
}

function rig({ quotaEnabled = true, dashboardOnHover = true } = {}) {
    const state = {
        sidebar: drawer(),
        session: drawer(),
        screenState: { quota: false, dashboard: false },
        dashboardShortcutActive: false,
    };
    const panelsContext = vm.createContext({ sidebar: state.sidebar, session: state.session });
    const blocked = () => vm.runInContext(blockedExpression, panelsContext);
    const panels = { quotaEnabled, quota: "quota", dashboard: "dashboard" };
    Object.defineProperty(panels, "quotaHoverBlocked", { get: blocked });
    const context = vm.createContext({
        panels,
        screenState: state.screenState,
        Config: { dashboard: { enabled: true, showOnHover: dashboardOnHover } },
        dashboardShortcutActive: false,
        inTopPanel: (panel, x, y) => {
            const zone = panel === "quota" ? QUOTA : DASHBOARD;
            return x >= zone.x[0] && x < zone.x[1] && y < zone.bottom;
        },
    });
    // Same order as QML: the "...Changed" handler runs as soon as the binding flips.
    let wasBlocked = blocked();
    const handlerContext = vm.createContext({ get quotaHoverBlocked() { return blocked(); }, screenState: state.screenState });
    state.change = fn => {
        fn(state);
        const now = blocked();
        if (now !== wasBlocked) vm.runInContext(blockedHandler, handlerContext);
        wasBlocked = now;
    };
    state.move = (x, y) => {
        Object.assign(context, { x, y });
        vm.runInContext(`(function () {\n${hoverBlock}\n})()`, context);
        state.dashboardShortcutActive = context.dashboardShortcutActive;
    };
    state.setShortcut = value => { context.dashboardShortcutActive = value; };
    return state;
}

const inQuota = [850, 40];
const inDashboard = [550, 40];
const elsewhere = [100, 600];

test("normal quota and dashboard hover are unchanged", () => {
    const r = rig();
    r.move(...inQuota);
    assert.equal(r.screenState.quota, true);
    assert.equal(r.screenState.dashboard, false, "dashboard stays out of the quota strip");
    r.move(...inDashboard);
    assert.equal(r.screenState.quota, false);
    assert.equal(r.screenState.dashboard, true);
    r.move(...elsewhere);
    assert.equal(r.screenState.quota, false);
    assert.equal(r.screenState.dashboard, false);
});

test("a disabled quota drawer is left alone", () => {
    const r = rig({ quotaEnabled: false });
    r.move(...inQuota);
    assert.equal(r.screenState.quota, false);
});

test("the sidebar blocks quota hover from the moment it is requested", () => {
    const r = rig();
    // Requested, not yet visible: the hover trigger and the quota strip share a corner.
    r.change(s => { s.sidebar.shouldBeActive = true; });
    r.move(...inQuota);
    assert.equal(r.screenState.quota, false, "requested");
    r.change(s => { s.sidebar.visible = true; });
    r.move(...inQuota);
    assert.equal(r.screenState.quota, false, "open");
});

test("the session drawer blocks quota hover the same way", () => {
    const r = rig();
    r.change(s => { s.session.shouldBeActive = true; s.session.visible = true; });
    r.move(...inQuota);
    assert.equal(r.screenState.quota, false);
});

test("the closing animation still blocks, and only a fresh move reopens quota", () => {
    const r = rig();
    r.change(s => { s.sidebar.shouldBeActive = true; s.sidebar.visible = true; });
    r.move(...inQuota);
    // Closing: request cleared, panel still sliding out.
    r.change(s => { s.sidebar.shouldBeActive = false; });
    r.move(...inQuota);
    assert.equal(r.screenState.quota, false, "closing");
    // Fully hidden, pointer parked in the strip: nothing reopens by itself.
    r.change(s => { s.sidebar.visible = false; });
    assert.equal(r.screenState.quota, false, "no reopen from stale hover");
    r.move(...inQuota);
    assert.equal(r.screenState.quota, true, "fresh hover opens it");
});

test("either drawer alone keeps the block while the other is gone", () => {
    const r = rig();
    r.change(s => { s.sidebar.visible = true; s.session.shouldBeActive = true; s.session.visible = true; });
    r.change(s => { s.sidebar.visible = false; });
    r.move(...inQuota);
    assert.equal(r.screenState.quota, false, "session still requested");
    r.change(s => { s.session.shouldBeActive = false; });
    r.move(...inQuota);
    assert.equal(r.screenState.quota, false, "session still sliding out");
    r.change(s => { s.session.visible = false; });
    r.move(...inQuota);
    assert.equal(r.screenState.quota, true);
});

test("an already open quota drawer yields at once, without waiting for a pointer move", () => {
    const r = rig();
    r.move(...inQuota);
    assert.equal(r.screenState.quota, true);
    r.change(s => { s.sidebar.shouldBeActive = true; });
    assert.equal(r.screenState.quota, false);
    r.move(...inQuota);
    assert.equal(r.screenState.quota, false);
});

test("the takeover handler only touches quota and fires only on the way in", () => {
    const r = rig();
    r.screenState.dashboard = true;
    r.screenState.quota = true;
    r.change(s => { s.session.shouldBeActive = true; });
    assert.equal(r.screenState.quota, false);
    assert.equal(r.screenState.dashboard, true, "no other drawer is dismissed");
    // Releasing the block does not write quota back open.
    r.change(s => { s.session.shouldBeActive = false; s.session.visible = false; });
    assert.equal(r.screenState.quota, false);
    assert.match(blockedHandler, /^\s*if \(quotaHoverBlocked\)\n\s*screenState\.quota = false;\s*$/);
    assert.doesNotMatch(blockedHandler, /sidebar|session/);
});

test("the dashboard still cannot open inside the quota strip while it is blocked", () => {
    const r = rig();
    r.change(s => { s.sidebar.shouldBeActive = true; s.sidebar.visible = true; });
    r.move(...inQuota);
    assert.equal(r.screenState.dashboard, false);
    // A dashboard opened by shortcut still leaves shortcut mode on a strip hover.
    r.screenState.dashboard = true;
    r.setShortcut(true);
    r.move(...inQuota);
    assert.equal(r.screenState.dashboard, false);
    assert.equal(r.dashboardShortcutActive, false);
});

test("the block is exactly requested-or-visible for either drawer", () => {
    for (let bits = 0; bits < 16; bits++) {
        const sidebar = { shouldBeActive: !!(bits & 1), visible: !!(bits & 2) };
        const session = { shouldBeActive: !!(bits & 4), visible: !!(bits & 8) };
        const actual = vm.runInNewContext(blockedExpression, { sidebar, session });
        assert.equal(actual, bits !== 0, `sidebar ${JSON.stringify(sidebar)} session ${JSON.stringify(session)}`);
    }
});

test("the production wiring exists on all Panels variants", () => {
    assert.match(read("modules/drawers/Panels.qml"), /readonly property bool quotaHoverBlocked: false/);
    assert.match(panelsAdapter, /readonly property alias sidebar: sidebar/);
    assert.match(panelsAdapter, /readonly property alias session: session/);
    // The block reads the real shouldBeActive flags, which the wrappers define.
    for (const wrapper of ["modules/sidebar/Wrapper.qml", "modules/session/Wrapper.qml"]) {
        const source = read(wrapper);
        assert.match(source, /readonly property bool shouldBeActive: screenState\.\w+ && Config\.\w+\.enabled/);
        assert.match(source, /visible: offsetScale < 1/);
    }
    assert.match(interactions, /const inQuotaArea = inQuotaZone && !panels\.quotaHoverBlocked;/);
});

test("per-screen State exposes only the requested panel flags", () => {
    const source = read("windows/shell/shell.qml");
    const match = source.match(/panels: \{([\s\S]*?)\n                \}/);
    assert.ok(match);
    const panelState = {
        dashboard: false, quota: false, sidebar: true, session: true,
        account: "private-sentinel",
    };
    const actual = vm.runInNewContext(`({${match[1]}})`, {
        scope: { window: { screenState: panelState } },
    });
    assert.deepEqual(JSON.parse(JSON.stringify(actual)), {
        dashboard: false, quota: false, sidebar: true, session: true,
    });
});

// -- The "Agent usage panel" setting (Nexus > Services, windows.quota.enabled) --
const quotaConfig = read("windows/quota/services/QuotaConfig.qml");
const quotaService = read("windows/quota/services/Quota.qml");
const regions = read("modules/drawers/Regions.qml");
const servicesPage = read("windows/shell/adapters/modules/nexus/pages/ServicesPage.qml");

const expr = (text, pattern) => text.match(pattern)[1].replace(/\broot\./g, "");
const windowsQuotaExpr = expr(quotaConfig, /readonly property var windowsQuota: (.+)\n/);
const panelOnExpr = expr(quotaConfig, /readonly property bool panelOn: (.+)\n/);
const enabledExpr = expr(quotaConfig, /readonly property bool enabled: (.+)\n/);

// QuotaConfig.enabled as shipped, for a given shell.json "windows" map and the
// two older inputs (a CPA config on disk, quota.json "enabled").
function configEnabled(windows, { configured = true, settingPresent = false, settingEnabled = false } = {}) {
    const context = vm.createContext({ GlobalConfig: { windows }, configured, settingPresent, settingEnabled });
    context.windowsQuota = vm.runInContext(windowsQuotaExpr, context);
    context.panelOn = vm.runInContext(panelOnExpr, context);
    return vm.runInContext(enabledExpr, context);
}

test("the setting is on unless windows.quota.enabled is switched off", () => {
    assert.equal(configEnabled(undefined), true, "absent: on, as before");
    assert.equal(configEnabled({}), true);
    assert.equal(configEnabled({ quota: {} }), true);
    assert.equal(configEnabled({ quota: { enabled: true } }), true);
    assert.equal(configEnabled({ quota: { enabled: false } }), false);
    assert.equal(configEnabled({ tiling: { enabled: true }, quota: { enabled: false } }), false, "other windows keys do not matter");
});

test("the setting never enables the panel by itself", () => {
    assert.equal(configEnabled({ quota: { enabled: true } }, { configured: false }), false, "still needs cpa-agents.json");
    assert.equal(configEnabled(undefined, { configured: false, settingPresent: true, settingEnabled: true }), true, "quota.json can still opt in");
    assert.equal(configEnabled(undefined, { configured: true, settingPresent: true, settingEnabled: false }), false, "quota.json can still opt out");
    assert.equal(configEnabled({ quota: { enabled: false } }, { configured: true, settingPresent: true, settingEnabled: true }), false, "off wins");
});

test("with the setting off the hover path never asks for the drawer", () => {
    assert.match(panelsAdapter, /readonly property bool quotaEnabled: QuotaConfig\.enabled\n/);
    const off = rig({ quotaEnabled: configEnabled({ quota: { enabled: false } }) });
    for (const [x, y] of [inQuota, inDashboard, elsewhere]) {
        off.move(x, y);
        assert.equal(off.screenState.quota, false, `no quota at ${x},${y}`);
    }
    off.move(...inDashboard);
    assert.equal(off.screenState.dashboard, true, "the dashboard hover is untouched");
    const on = rig({ quotaEnabled: configEnabled(undefined) });
    on.move(...inQuota);
    assert.equal(on.screenState.quota, true, "on: unchanged");
});

test("switching it off closes an open drawer and switching it on does not reopen it", () => {
    const handler = panelsAdapter.match(/onQuotaEnabledChanged: \{\n([\s\S]*?)\n    \}\n/)[1];
    const run = quotaEnabled => {
        const context = vm.createContext({ quotaEnabled, screenState: { quota: true } });
        vm.runInContext(handler, context);
        return context.screenState.quota;
    };
    assert.equal(run(false), false, "off closes it");
    assert.equal(run(true), true, "on leaves it as it is");
    assert.doesNotMatch(handler, /quota = true/);
});

test("with the setting off the drawer has no input region and no blob to deform", () => {
    const region = between(regions, "    R {\n        panel: root.panels.quota", "    R {\n        panel: root.panels.dashboard");
    assert.match(region, /width: root\.panels\.quotaEnabled \? panel\.width : 0/);
    assert.match(region, /height: root\.panels\.quotaEnabled \? .+ : 0/);
    // The drawer never opens, so its offset stays at 1 and the blob never moves.
    assert.match(read("windows/quota/modules/quota/Wrapper.qml"), /shouldBeActive: screenState\.quota && QuotaConfig\.enabled/);
});

test("with the setting off no request, timer or watchdog stays alive", () => {
    // Every way to start one checks the same flag...
    assert.match(quotaService, /readonly property bool enabled: QuotaConfig\.enabled/);
    assert.match(quotaService, /Timer \{\n        id: autoRefreshTimer[\s\S]*?running: root\.configured && root\.enabled/);
    assert.match(quotaService, /Timer \{\n        id: clockTimer[\s\S]*?running: root\.enabled && root\.clockHolders > 0/);
    assert.match(quotaService, /if \(!root\.enabled \|\| root\.inFlight\)\n\s+return;/);
    assert.match(quotaService, /function triggerKeepalive\(\): void \{\n\s+if \(!QuotaConfig\.enabled/);
    // ...the key is not read while it is off...
    assert.match(quotaService, /path: root\.enabled \? QuotaConfig\.cpaConfigPath : ""/);
    // ...and switching off stops what is already running.
    assert.match(quotaService, /onEnabledChanged: \{\n\s+if \(root\.enabled\)\n\s+root\.maybeRefresh\(\);\n\s+else\n\s+root\.suspend\(\);/);
    const suspend = between(quotaService, "    function suspend(): void {", "    function finishRequest()");
    assert.match(suspend, /watchdog\.stop\(\)/);
    assert.match(suspend, /root\.spendRequests\.concat\(\[root\.activeRequest\]\)/);
    assert.match(suspend, /request\.abort\(\)/);
    assert.match(suspend, /root\.inFlight = false;\n\s+root\.loading = false;/);
});

test("Nexus writes windows.quota.enabled without disturbing the rest of windows", () => {
    assert.match(servicesPage, /text: Tr\.tr\("Agent usage panel"\)/);
    assert.match(servicesPage, /checked: root\.agentUsageOn/);
    assert.match(servicesPage, /readonly property bool agentUsageOn: GlobalConfig\.windows\?\.quota\?\.enabled \?\? true/);
    const body = servicesPage.match(/function setAgentUsage\(on: bool\): void \{\n([\s\S]*?)\n    \}\n/)[1];
    const context = vm.createContext({ on: false, GlobalConfig: { windows: { tiling: { enabled: true, mode: "observe" }, quota: { other: 1 } } } });
    vm.runInContext(body, context);
    const written = JSON.parse(JSON.stringify(context.GlobalConfig.windows));
    assert.deepEqual(written, { tiling: { enabled: true, mode: "observe" }, quota: { other: 1, enabled: false } });
    const fresh = vm.createContext({ on: true, GlobalConfig: { windows: undefined } });
    vm.runInContext(body, fresh);
    assert.deepEqual(JSON.parse(JSON.stringify(fresh.GlobalConfig.windows)), { quota: { enabled: true } });
});