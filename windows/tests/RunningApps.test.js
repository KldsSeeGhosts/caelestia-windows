const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const path = require("node:path");
const test = require("node:test");

const context = vm.createContext({ Set });
vm.runInContext(fs.readFileSync(path.join(__dirname, "../services/runningapps/RunningApps.js"), "utf8"), context);
const window = (id, appId, extra = {}) => ({
    id, appId, native: {}, mapped: true, minimized: false, active: false, desktop: 1, ...extra
});
const ids = value => Array.from(value).join();

test("groups apps case-insensitively and keeps minimized and other-desktop windows reachable", () => {
    let state = context.project([
        window("1", "Browser", { active: true }),
        window("2", "browser", { minimized: true }),
        window("3", "Editor", { minimized: true, desktop: 2 })
    ], [], []);
    assert.equal(ids(state.groupIds), "browser,editor");
    assert.equal(ids(state.groups.browser.windowIds), "1,2");
    assert.equal(state.groups.browser.active, true);
    assert.equal(state.groups.browser.minimized, 1);
    assert.equal(state.groups.browser.allMinimized, false);
    assert.equal(state.groups.editor.allMinimized, true);
    assert.equal(state.byId["3"].desktop, 2);

    state = context.project([
        window("4", "Files"),
        window("3", "Editor", { minimized: true }),
        window("2", "Browser", { minimized: true }),
        window("1", "Browser", { minimized: true })
    ], state.groupOrder, state.windowOrder);
    assert.equal(ids(state.groupIds), "browser,editor,files", "new apps append, not reorder existing apps");
    assert.equal(ids(state.groups.browser.windowIds), "1,2", "window order remains stable");
    assert.equal(state.groups.browser.allMinimized, true);
    assert.equal(state.groupIds.length, 3, "all minimized apps remain discoverable");

    state = context.project([window("2", "Browser"), window("5", "Terminal")], state.groupOrder, state.windowOrder);
    assert.equal(ids(state.groupIds), "browser,terminal");
    assert.equal(ids(state.windowIds), "2,5", "closed windows leave the model");
    assert.equal(state.byId["1"], undefined);
});

test("digit-only window and application ids keep their source encounter order", () => {
    let state = context.project([
        window("20", "10"),
        window("3", "2"),
        window("11", "10")
    ], [], []);
    assert.equal(ids(state.windowIds), "20,3,11", "window ids are not numerically sorted");
    assert.equal(ids(state.groupIds), "10,2", "app ids are not numerically sorted");
    assert.equal(ids(state.groups["10"].windowIds), "20,11");

    state = context.project([
        window("3", "2"),
        window("11", "10"),
        window("20", "10"),
        window("1", "1")
    ], state.groupOrder, state.windowOrder);
    assert.equal(ids(state.windowIds), "20,3,11,1");
    assert.equal(ids(state.groupIds), "10,2,1");
});

test("title, focus, minimize and source-enumeration updates never reorder existing entries", () => {
    let state = context.project([
        window("20", "Editor", { title: "first" }),
        window("3", "Browser", { title: "second" }),
        window("11", "Editor", { title: "third" })
    ], [], []);
    assert.equal(ids(state.windowOrder), "20,3,11");
    assert.equal(ids(state.groupOrder), "editor,browser");

    state = context.project([
        window("3", "Browser", { title: "renamed", active: true }),
        window("11", "Editor", { minimized: true }),
        window("20", "Editor", { title: "renamed", active: true })
    ], state.groupOrder, state.windowOrder);
    assert.equal(ids(state.windowOrder), "20,3,11", "state changes do not reorder");
    assert.equal(ids(state.groupOrder), "editor,browser", "app state changes do not reorder");
    assert.equal(ids(state.windowIds), "20,3,11");
    assert.equal(ids(state.groupIds), "editor,browser");
    assert.equal(state.byId["20"].title, "renamed");
    assert.equal(state.groups.browser.active, true);
    assert.equal(state.groups.editor.minimized, 1);
    assert.equal(state.groups.editor.allMinimized, false);
});

test("a temporarily app-cloaked window keeps its place when it is uncloaked", () => {
    let state = context.project([window("20", "Editor"), window("3", "Browser")], [], []);
    state = context.project([
        window("3", "Browser"),
        window("20", "Editor", { mapped: false }),
        window("1", "Files")
    ], state.groupOrder, state.windowOrder);
    assert.equal(state.byId["20"], undefined, "app-cloaked window stays out of the visible list");
    assert.equal(ids(state.windowIds), "3,1");
    assert.equal(ids(state.windowOrder), "20,3,1", "app cloak retains the hidden slot");
    assert.equal(ids(state.groupIds), "browser,files");

    state = context.project([
        window("1", "Files"),
        window("3", "Browser"),
        window("20", "Editor")
    ], state.groupOrder, state.windowOrder);
    assert.equal(ids(state.windowIds), "20,3,1", "uncloaked window returns to its old slot");
    assert.equal(ids(state.groupIds), "editor,browser,files");
});

test("an actually removed entry releases its slot and a later recreation appends", () => {
    let state = context.project([window("20", "Editor"), window("3", "Browser")], [], []);
    state = context.project([window("3", "Browser")], state.groupOrder, state.windowOrder);
    assert.equal(ids(state.windowOrder), "3");
    assert.equal(ids(state.groupOrder), "browser");

    state = context.project([window("20", "Editor"), window("3", "Browser")], state.groupOrder, state.windowOrder);
    assert.equal(ids(state.windowIds), "3,20", "recreated window is appended");
    assert.equal(ids(state.groupIds), "browser,editor", "recreated app is appended");
});

test("mapped, minimized and other-desktop observations follow backend semantics", () => {
    const toplevel = (address, extra = {}) => ({
        address,
        title: extra.title ?? "Synthetic window",
        activated: extra.active ?? false,
        lastIpcObject: { class: extra.appId ?? "Editor", mapped: extra.mapped ?? true },
        workspace: { id: extra.desktop ?? 1 },
        wayland: { minimized: extra.minimized ?? false }
    });
    const observations = context.observe([
        toplevel("app-cloaked", { mapped: false }),
        toplevel("inherited-cloak", { mapped: false, desktop: 2 }),
        toplevel("other-desktop", { desktop: 2 }),
        toplevel("minimized", { minimized: true }),
        toplevel("focused", { active: true, title: "Focused title" }),
        null,
        {},
        { address: "no-handle", lastIpcObject: { class: "Invalid", mapped: true } }
    ]);
    assert.equal(ids(observations.map(item => item.id)),
        "app-cloaked,inherited-cloak,other-desktop,minimized,focused");
    assert.equal(observations.find(item => item.id === "focused").title, "Focused title");

    const state = context.project(observations, [], []);
    assert.equal(ids(state.windowIds), "other-desktop,minimized,focused");
    assert.equal(state.byId["app-cloaked"], undefined);
    assert.equal(state.byId["inherited-cloak"], undefined);
    assert.equal(state.byId["other-desktop"].desktop, 2);
    assert.equal(state.byId["minimized"].minimized, true);
    assert.equal(state.groups.editor.minimized, 1);
    assert.equal(state.groups.editor.active, true);
});

test("a repeated window handle is ignored instead of duplicating a row", () => {
    const observed = window("20", "Editor", { minimized: true });
    let state = context.project([observed, observed, window("20", "Browser", { mapped: false })], [], []);
    assert.equal(ids(state.windowIds), "20");
    assert.equal(ids(state.groupIds), "editor");
    assert.equal(ids(state.groups.editor.windowIds), "20");
    assert.equal(state.groups.editor.minimized, 1);
    assert.equal(state.groups.editor.allMinimized, true);
    assert.equal(state.byId["20"].appId, "Editor", "the first observation owns the handle");

    state = context.project([
        window("2", "Browser"),
        observed,
        window("2", "Browser")
    ], state.groupOrder, state.windowOrder);
    assert.equal(ids(state.windowIds), "20,2");
    assert.equal(ids(state.groupIds), "editor,browser");
    assert.equal(ids(state.groups.editor.windowIds), "20");
});

test("malformed observations and application ids cannot collide with object prototypes", () => {
    let state = context.project([
        null, {}, window("6", ""), { id: "7", appId: "no-native" }
    ], [], []);
    assert.equal(state.groupIds.length, 0);

    state = context.project([window("8", "__proto__"), window("9", "constructor")], [], []);
    assert.equal(state.groupIds.length, 2, "application ids cannot collide with object prototypes");
});
