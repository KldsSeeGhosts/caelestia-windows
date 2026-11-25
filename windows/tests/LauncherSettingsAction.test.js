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
const model = [{name: "Settings", description: "Open Caelestia settings (Nexus)", icon: "settings", command: ["settings"]}];
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
    assert.match(source, /Migration\.migrateActions\(GlobalConfig\.launcher\.actions\.values\)\.filter/);
    assert.match(source, /GlobalConfig\.launcher\.enableDangerousActions/);
    assert.match(source, /ShellActionSchema\.validateShellAction/);
    assert.match(read("plugin/src/Caelestia/Config/launcherconfig.hpp"), /u"Settings"_s[\s\S]*QStringList\{ u"settings"_s \}/);
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

test("Settings transfers foreground to Nexus before closing the launcher, without executing a process", () => {
    const list = { screenState: { launcher: true }, search: { text: ">settings" } };
    let opens = 0;
    const context = {
        command: model.find(action => action.name === "Settings").command,
        enabled: true,
        GlobalConfig: {launcher: {enableDangerousActions: false}},
        modelData: model[0],
        root: {isDangerous: () => false},
        hasShellAction: false,
        runShellAction() { assert.fail("the legacy settings command must not use shell-action dispatch"); },
        WindowFactory: {
            create() {
                assert.equal(list.screenState.launcher, true);
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
    assert.equal(list.screenState.launcher, false);
    assert.equal(list.search.text, ">settings");
    // Reopening uses the same route, whose factory owns window reuse/activation.
    list.screenState.launcher = true;
    context.onClicked(list);
    assert.equal(opens, 2);
    assert.match(read("windows/shell/adapters/daemons/Shortcuts.qml"),
        /name: "nexus"[\s\S]*?WindowFactory\.create\(\)/);
});

test("dangerous session aliases and elevated actions cannot bypass the toggle", () => {
    const schemaSource = read("windows/services/apps/ShellActionSchema.js")
        .replace(/^\.pragma library\s*/m, "");
    const schema = vm.runInNewContext(schemaSource + "\n;({isDangerousShellAction})", {});
    const context = {
        ShellActionSchema: schema,
        SessionManager: {
            resolveCommand(command) { return command?.[0] === "poweroff" ? "shutdown" : ""; }
        }
    };
    vm.createContext(context);
    vm.runInContext(qmlFunction(source, "isDangerous"), context);
    assert.equal(context.isDangerous({dangerous: false, command: ["poweroff"]}), true);
    assert.equal(context.isDangerous({verb: "runas", target: "tools.exe"}), true);
    assert.equal(context.isDangerous({verb: "open", target: "tools.exe"}), true);
    assert.equal(context.isDangerous({verb: "open", uri: "https://example.test"}), true);
    assert.equal(context.isDangerous({verb: "open", uri: "ms-settings:display"}), false);
});

function migrationApi() {
    const code = read("windows/shell/adapters/modules/launcher/services/LauncherActionMigration.js")
        .replace(/^\.pragma library\s*/m, "");
    return vm.runInNewContext(code + "\n;({migrateActions, isStockLinuxList, translatedCommand, stockLinuxMetadata})", {});
}

test("exact stock Linux action lists migrate to the Windows defaults", () => {
    const api = migrationApi();
    const stock = [
        ["autocomplete", "calc"], ["autocomplete", "scheme"], ["autocomplete", "wallpaper"],
        ["autocomplete", "variant"], ["caelestia", "wallpaper", "-r"], ["setMode", "light"],
        ["setMode", "dark"], ["poweroff"], ["reboot"], ["logout"],
        ["loginctl", "lock-session"], ["suspendThenHibernate"], ["caelestia", "shell", "nexus", "open"]
    ].map((command, index) => {
        const [name, icon, description, dangerous] = api.stockLinuxMetadata[index];
        return {enabled: true, name, icon, description, command, dangerous};
    });
    assert.equal(api.isStockLinuxList(stock), true);
    const migrated = JSON.parse(JSON.stringify(api.migrateActions(stock)));
    const commands = migrated.map(action => action.command.join(" "));
    assert.ok(commands.includes("screenshot"));
    assert.ok(commands.includes("settings"));
    assert.ok(commands.includes("suspend"));
    assert.ok(!commands.includes("suspendThenHibernate"));
    assert.ok(!commands.includes("caelestia shell nexus open"));
    assert.equal(migrated.length, 18);
    stock[12].name = "Custom settings name";
    assert.equal(api.isStockLinuxList(stock), false);
    assert.equal(api.migrateActions(stock).length, 13);
    assert.equal(api.migrateActions(stock)[12].name, "Custom settings name");
    stock[12].decodeValid = false;
    assert.equal(api.migrateActions(stock)[12].decodeValid, false);
});

test("custom Linux action lists are preserved while known commands translate exactly", () => {
    const api = migrationApi();
    const custom = [
        {enabled: true, name: "Mine", icon: "custom", description: "custom", command: ["caelestia", "shell", "nexus", "open"]},
        {enabled: true, name: "Sleep", icon: "bedtime", description: "sleep", command: ["suspendThenHibernate"]},
        {enabled: true, name: "Custom", icon: "star", description: "custom", command: ["setMode", "light"]}
    ];
    const migrated = JSON.parse(JSON.stringify(api.migrateActions(custom)));
    assert.equal(migrated.length, 3);
    assert.deepEqual(migrated[0].command, ["settings"]);
    assert.deepEqual(migrated[1].command, ["suspend"]);
    assert.deepEqual(migrated[2].command, ["setMode", "light"]);
    assert.ok(!migrated.some(action => action.command[0] === "screenshot"));
});

test("unsupported legacy actions refuse in place without closing the launcher", () => {
    const list = {screenState: {launcher: true}, search: {text: ">random"}};
    let toasts = 0;
    const context = {
        enabled: true,
        command: ["caelestia", "wallpaper", "-r"],
        modelData: {
            enabled: true,
            command: ["caelestia", "wallpaper", "-r"],
            icon: "casino"
        },
        root: {isDangerous: () => false},
        hasShellAction: false,
        GlobalConfig: {launcher: {enableDangerousActions: false}},
        Tr: {tr: text => text},
        refuseShellAction(message) {
            assert.match(message, /not supported/);
            toasts++;
        },
        SessionManager: {
            resolveCommand() { return ""; },
            request() { assert.fail("unsupported legacy action must not execute"); }
        },
        WindowFactory: {create() { assert.fail("unsupported legacy action must not open settings"); }}
    };
    vm.createContext(context);
    vm.runInContext(qmlFunction(source, "onClicked"), context);
    context.onClicked(list);
    assert.equal(toasts, 1);
    assert.equal(list.screenState.launcher, true);
});
