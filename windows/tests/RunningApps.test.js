const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const path = require("node:path");
const context = vm.createContext({ Set });
vm.runInContext(fs.readFileSync(path.join(__dirname, "../services/runningapps/RunningApps.js"), "utf8"), context);
const window = (id, appId, extra = {}) => ({ id, appId, native: {}, minimized: false, active: false, desktop: 1, ...extra });
let state = context.project([
    window("1", "Browser", { active: true }),
    window("2", "browser", { minimized: true }),
    window("3", "Editor", { minimized: true, desktop: 2 })
], [], []);
assert.equal(state.groupIds.join(), "browser,editor");
assert.equal(state.groups.browser.windowIds.join(), "1,2");
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
], state.groupIds, state.windowIds);
assert.equal(state.groupIds.join(), "browser,editor,files", "new apps append, not reorder existing apps");
assert.equal(state.groups.browser.windowIds.join(), "1,2", "window order remains stable");
assert.equal(state.groups.browser.allMinimized, true);
assert.equal(state.groupIds.length, 3, "all minimized apps remain discoverable");
state = context.project([window("2", "Browser"), window("5", "Terminal")], state.groupIds, state.windowIds);
assert.equal(state.groupIds.join(), "browser,terminal");
assert.equal(state.windowIds.join(), "2,5", "closed windows leave the model");
assert.equal(state.byId["1"], undefined);
state = context.project([null, {}, window("6", ""), { id: "7", appId: "no-native" }], state.groupIds, state.windowIds);
assert.equal(state.groupIds.length, 0);
state = context.project([window("8", "__proto__"), window("9", "constructor")], [], []);
assert.equal(state.groupIds.length, 2, "application ids cannot collide with object prototypes");
console.log("RunningApps: grouping, stable ordering, minimize/restore, desktop retention, removal, malformed data and opaque ids passed.");
