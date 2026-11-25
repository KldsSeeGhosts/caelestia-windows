const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const test = require("node:test");

const source = fs.readFileSync(path.resolve(__dirname, "../services/apps/ShellActionSchema.js"), "utf8")
    .replace(/^\s*\.(?:pragma library|import[^\r\n]*)\s*$/gm, "");
const context = vm.createContext({});
vm.runInContext(source, context, { filename: "ShellActionSchema.js" });

test("open and runas actions validate with exactly one endpoint", () => {
    for (const verb of ["open", "runas"]) {
        const result = context.validateShellAction({ verb, target: "wt.exe", args: ["cmd"], workingDir: "C:/" });
        assert.equal(result.ok, true);
        assert.deepEqual(JSON.parse(JSON.stringify(result.action)), { verb, target: "wt.exe", args: ["cmd"], workingDir: "C:/" });
    }
    assert.equal(context.validateShellAction({ verb: "open", aumid: "Example_a1b2c3" }).ok, true);
    assert.equal(context.validateShellAction({ verb: "open", uri: "ms-settings:" }).ok, true);
});

test("shell actions reject unsupported verbs and ambiguous or missing endpoints", () => {
    const badTarget = "bad" + String.fromCharCode(10) + "name";
    for (const value of [
        null, {}, { verb: "exec", target: "wt.exe" },
        { verb: "open" }, { verb: "open", target: "wt.exe", uri: "ms-settings:" },
        { verb: "open", target: "" }, { verb: "open", target: badTarget }
    ]) {
        assert.equal(context.validateShellAction(value).ok, false);
    }
});

test("shell action arguments and working directories are strict string data", () => {
    const badDir = "bad" + String.fromCharCode(9) + "dir";
    assert.equal(context.validateShellAction({ verb: "open", target: "wt.exe", args: "cmd" }).ok, false);
    assert.equal(context.validateShellAction({ verb: "open", target: "wt.exe", args: ["cmd", 3] }).ok, false);
    assert.equal(context.validateShellAction({ verb: "open", target: "wt.exe", workingDir: badDir }).ok, false);
    assert.equal(context.hasShellAction({ verb: "open", target: "wt.exe" }), true);
    assert.equal(context.hasShellAction({}), false);
});

test("terminal actions combine the configured terminal with the entry command", () => {
    const result = context.terminalAction(["wt.exe", "-M"], {
        command: ["C:/Tools/demo.exe", "--flag"],
        workingDirectory: "C:/Tools"
    });
    assert.equal(result.ok, true);
    assert.deepEqual(JSON.parse(JSON.stringify(result.action)), {
        verb: "open",
        target: "wt.exe",
        args: ["-M", "C:/Tools/demo.exe", "--flag"],
        workingDir: "C:/Tools"
    });
});

test("terminal actions fail closed without a terminal or command", () => {
    assert.equal(context.terminalAction([], { command: ["demo.exe"] }).ok, false);
    assert.equal(context.terminalAction(["wt.exe"], {}).ok, false);
    assert.equal(context.terminalAction(["wt.exe"], { command: [3] }).ok, false);
});
