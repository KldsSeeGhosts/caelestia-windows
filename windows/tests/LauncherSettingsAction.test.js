// Headless checks of the production QML's JavaScript, not a QML/live UI test.
// Run: node --test windows/tests/LauncherSettingsAction.test.js
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { test } = require("node:test");

const repo = path.resolve(__dirname, "../..");
const adapter = "windows/shell/adapters/modules/launcher/services/Actions.qml";
const read = file => fs.readFileSync(path.join(repo, file), "utf8");
const source = read(adapter);
const searcher = read("utils/Searcher.qml");
const model = vm.runInNewContext(source.match(/model: (\[[\s\S]*?\n        \])/)[1]);
// Only strip QML type annotations from the selected production function.
function qmlFunction(text, name) {
    const match = text.match(new RegExp(`^( +)function ${name}\\(([^)]*)\\): \\w+ \\{([\\s\\S]*?)\\n\\1\\}`, "m"));
    assert.ok(match, `QML function ${name} exists`);
    return `function ${name}(${match[2].replace(/: \w+/g, "")}) {${match[3]}\n}`;
}
function script(file, exports) {
    return vm.runInNewContext(
        read(file).replace(/^\.pragma library\s*/, "") + `\n;(${exports})`);
}

test("production stages the Windows Settings action and existing action delegate", () => {
    const manifest = JSON.parse(read("windows/shell/sources.json"));
    assert.equal(manifest[adapter], "modules/launcher/services/Actions.qml");
    assert.equal(manifest["modules/launcher/items/ActionItem.qml"], "modules/launcher/items/ActionItem.qml");
    assert.match(source, /^import qs\.modules\.nexus$/m);
    const settings = model.filter(action => action.name === "Settings");
    assert.equal(settings.length, 1);
    assert.deepEqual(Array.from(settings[0].command), ["settings"]);
    assert.equal(settings[0].icon, "settings");
    assert.match(settings[0].description, /Caelestia settings/);
});

test(">settings resolves through the original searcher with both search modes and a custom prefix", () => {
    const Fzf = script("utils/scripts/fzf.js", "{ Finder }");
    const Fuzzy = script("utils/scripts/fuzzysort.js", "{ prepare, go }");
    for (const prefix of [">", ":"]) {
        for (const useFuzzy of [false, true]) {
            const context = {
                GlobalConfig: { launcher: { actionPrefix: prefix } },
                list: model, key: "name", keys: ["name"], weights: [1],
                useFuzzy, extraOpts: {}, Fuzzy
            };
            vm.createContext(context);
            vm.runInContext([
                qmlFunction(source, "transformSearch"),
                qmlFunction(searcher, "selector"),
                qmlFunction(searcher, "query")
            ].join("\n"), context);
            context.fzf = new Fzf.Finder(model, { selector: context.selector });
            context.fuzzyPrepped = model.map(item => ({ _item: item, name: Fuzzy.prepare(item.name) }));
            const results = context.query(`${prefix}settings`);
            assert.equal(results.length, 1);
            assert.equal(results[0].name, "Settings");
        }
    }
});

test("Settings closes the launcher before calling the existing Nexus route, without executing a process", () => {
    const list = { screenState: { launcher: true }, search: { text: ">settings" } };
    let opens = 0;
    const context = {
        command: model.find(action => action.name === "Settings").command,
        WindowFactory: {
            create() {
                assert.equal(list.screenState.launcher, false);
                opens++;
            }
        },
        // Any unintended dispatch to these services fails the test.
        SessionManager: { exec() { assert.fail("Settings must not execute a session command"); } },
        Quickshell: { execDetached() { assert.fail("Settings must not launch a process"); } }
    };
    vm.createContext(context);
    vm.runInContext(qmlFunction(source, "onClicked"), context);
    context.onClicked(list);
    assert.equal(opens, 1);
    assert.equal(list.search.text, ">settings");
    // Reopening uses the same route, whose factory owns window reuse/activation.
    list.screenState.launcher = true;
    context.onClicked(list);
    assert.equal(opens, 2);
    assert.match(read("windows/shell/adapters/daemons/Shortcuts.qml"),
        /name: "nexus"[\s\S]*?WindowFactory\.create\(\)/);
});
