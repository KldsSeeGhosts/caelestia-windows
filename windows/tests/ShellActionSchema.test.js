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
    assert.equal(context.validateShellAction({ verb: "open", aumid: "Example_abc123!App" }).ok, true);
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

test("terminal launch refuses raw command text", () => {
    const result = context.terminalAction(["wt.exe"], {
        execString: "\"C:/Tools/demo app.exe\" --flag %U",
        workingDirectory: "C:/Tools"
    });
    assert.equal(result.ok, false);
});

test("endpoint kinds and syntax are validated strictly", () => {
    assert.equal(context.validateShellAction({ verb: "open", target: "https://example.test" }).ok, false);
    assert.equal(context.validateShellAction({ verb: "open", aumid: "not-an-aumid" }).ok, false);
    assert.equal(context.validateShellAction({ verb: "open", uri: "not a uri" }).ok, false);
    assert.equal(context.validateShellAction({ verb: "open", target: "C:/Program Files/App/app.exe" }).ok, true);
    assert.equal(context.validateShellAction({ verb: "open", target: "C:\\Program Files\\App\\app.exe" }).ok, true);
    assert.equal(context.validateShellAction({ verb: "open", target: "app.lnk" }).ok, false);
    assert.equal(context.validateShellAction({ verb: "open", uri: "https://example.test/%xyz" }).ok, false);
    assert.equal(context.validateShellAction({ verb: "open", aumid: "apps/family!App" }).ok, false);
});

test("executable targets and unrestricted protocols are dangerous", () => {
    assert.equal(context.isDangerousShellAction({ verb: "open", target: "wt.exe" }), true);
    assert.equal(context.isDangerousShellAction({ verb: "open", uri: "https://example.test" }), true);
    assert.equal(context.isDangerousShellAction({ verb: "open", uri: "ms-settings:display" }), false);
    assert.equal(context.isDangerousShellAction({ verb: "open", aumid: "Example_abc123!App" }), true);
    assert.equal(context.isDangerousShellAction({ verb: "open", uri: "ms-settings:display?x=y" }), true);
    assert.equal(context.isDangerousShellAction({ verb: "runas", aumid: "Example_abc123!App" }), true);
});

test("request ids do not confuse boolean acceptance with a pending result", () => {
    assert.equal(context.launchRequestId(true), "");
    assert.equal(context.launchRequestId(false), "");
    assert.equal(context.launchRequestId(0), "");
    assert.equal(context.launchRequestId(42), "42");
    assert.equal(context.launchRequestId({requestId: "fixture"}), "fixture");
});
