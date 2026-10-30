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
const panelsAdapter = read("windows/combined-prototype/adapters/modules/drawers/Panels.qml");

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
    assert.match(read("windows/shell-prototype/adapters/modules/drawers/Panels.qml"),
        /readonly property bool quotaHoverBlocked: false/);
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
