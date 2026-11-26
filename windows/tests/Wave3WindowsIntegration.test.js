// Focused Wave 3 integration checks. UI files are inspected structurally here;
// pure logic is executed directly and the HyprService allowlist has a separate
// offscreen QML fixture.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { test } = require("node:test");

const repo = path.resolve(__dirname, "../..");
const read = file => fs.readFileSync(path.join(repo, file), "utf8").replace(/\r\n/g, "\n");
const json = file => JSON.parse(read(file));

const appItem = read("windows/shell/adapters/modules/launcher/items/AppItem.qml");
const launcherContent = read("windows/shell/adapters/modules/launcher/Content.qml");
const appInfo = read("windows/shell/adapters/modules/nexus/pages/apps/AppInfo.qml");
const activeWindowPopout = read("windows/shell/adapters/modules/bar/popouts/ActiveWindow.qml");
const activeWindowContent = read("modules/bar/popouts/ActiveWindow.qml");
const popoutState = read("modules/bar/popouts/PopoutState.qml");
const popoutWrapper = read("windows/shell/adapters/modules/bar/popouts/Wrapper.qml");
const activeWindowComponent = read("windows/shell/adapters/modules/bar/components/ActiveWindow.qml");
const hyprService = read("windows/services/hypr/HyprService.qml");
const hyprFacade = read("windows/services/hypr/Hypr.qml");
const nativeHyprBackend = read("windows/services/hypr/NativeHyprBackend.qml");
const windowInfo = read("windows/shell/adapters/modules/windowinfo/WindowInfo.qml");
const windowInfoPreview = read("windows/shell/adapters/modules/windowinfo/Preview.qml");
const windowInfoDetails = read("windows/shell/adapters/modules/windowinfo/Details.qml");
const windowInfoButtons = read("windows/shell/adapters/modules/windowinfo/Buttons.qml");
const windowInfoFactory = read("windows/shell/adapters/modules/windowinfo/WindowInfoFactory.qml");
const shell = read("windows/shell/shell.qml");
const staging = json("windows/shell/sources.json");

function elevationLogic() {
    const source = read("windows/services/apps/ElevationLogic.js").replace(/^\.pragma library\s*/m, "");
    return vm.runInNewContext(`${source}
;({ canonicalStatus, errorText, runAsAdminDetailed, report, shellExecutableForEntry, inlineSudoSpec, isInlineSudoEnabled, launchInlineSudo, isCtrlShiftEnter })`, {});
}

test("ElevationLogic normalizes statuses and passes the live owner before result handling", () => {
    const logic = elevationLogic();
    const owner = { kind: "qquick-item-owner" };
    const calls = [];
    const backend = {
        runAsAdminDetailed(id, parent) {
            calls.push([id, parent]);
            return { status: "started" };
        }
    };
    const result = logic.runAsAdminDetailed(backend, "app.exe", owner, true);
    assert.equal(result.status, "started");
    assert.deepEqual(calls, [["app.exe", owner]]);

    for (const [input, expected] of [
        ["started", "started"], ["cancelled", "cancelled"],
        ["notsupported", "notSupported"], ["notSupported", "notSupported"],
        ["refused", "refused"], ["unexpected", "refused"]
    ]) {
        assert.equal(logic.canonicalStatus({ status: input }), expected);
    }

    const seen = [];
    logic.report({ status: "cancelled", error: "cancelled by user" }, {
        started: () => seen.push("started"),
        cancelled: error => seen.push(["cancelled", error]),
        refused: () => seen.push("refused")
    });
    assert.deepEqual(seen, [["cancelled", "cancelled by user"]]);

    seen.length = 0;
    logic.report({ status: "notSupported", error: "not here" }, {
        started: () => seen.push("started"),
        cancelled: () => seen.push("cancelled"),
        refused: (error, status) => seen.push(["refused", error, status])
    });
    assert.deepEqual(seen, [["refused", "not here", "notSupported"]]);

    const missing = logic.runAsAdminDetailed({}, "app.exe", owner, true);
    assert.equal(missing.status, "notSupported");

    const blockedCalls = [];
    const blocked = logic.runAsAdminDetailed({
        runAsAdminDetailed: () => blockedCalls.push("elevated")
    }, "app.exe", owner, false);
    assert.equal(blocked.status, "refused");
    assert.match(blocked.error, /launching is disabled/);
    assert.deepEqual(blockedCalls, [], "browse-only elevation never reaches the backend");
});

test("ElevationLogic builds a real inline sudo command and rechecks the opt-in", () => {
    const logic = elevationLogic();
    assert.equal(logic.shellExecutableForEntry({ name: "Command Prompt", execString: "cmd.exe" }), "cmd.exe");
    assert.equal(logic.shellExecutableForEntry({ name: "PowerShell 7", execString: "pwsh.exe" }), "pwsh.exe");
    assert.equal(logic.shellExecutableForEntry({ name: "Windows Terminal", execString: "wt.exe" }), "powershell.exe");

    for (const [entry, shell] of [
        [{ id: "cmd.lnk", name: "Command Prompt", command: ["cmd.exe"] }, "cmd.exe"],
        [{ id: "pwsh.lnk", name: "PowerShell 7", command: ["pwsh.exe"] }, "pwsh.exe"],
        [{ id: "wt.exe", name: "Windows Terminal", command: ["wt.exe"] }, "powershell.exe"]
    ]) {
        assert.deepEqual(JSON.parse(JSON.stringify(logic.inlineSudoSpec(entry))), {
            verb: "open",
            target: "wt.exe",
            args: ["new-tab", "--", "sudo.exe", "--inline", shell]
        });
    }

    const calls = [];
    let inlineEnabled = true;
    const backend = {
        isInlineSudoEnabled: () => inlineEnabled,
        launchShellAction(spec, owner) {
            calls.push([spec, owner]);
            return { status: "queued", requestId: "req-1" };
        }
    };
    const owner = { owner: true };
    const entry = { id: "terminal", name: "Windows Terminal" };
    const queued = logic.launchInlineSudo(backend, entry, owner, true);
    assert.equal(queued.status, "queued");
    assert.equal(calls.length, 1);
    assert.equal(JSON.stringify(calls[0][0].args), JSON.stringify(["new-tab", "--", "sudo.exe", "--inline", "powershell.exe"]));
    assert.equal(calls[0][1], owner);

    inlineEnabled = false;
    const refused = logic.launchInlineSudo(backend, entry, owner, true);
    assert.equal(refused.status, "refused");
    assert.equal(refused.inlineSudoEnabled, false);
    assert.equal(calls.length, 1, "click-time recheck blocks dispatch when inline sudo is off");

    const browseOnly = logic.launchInlineSudo(backend, entry, owner, false);
    assert.equal(browseOnly.status, "refused");
    assert.equal(calls.length, 1, "browse-only inline sudo never reaches the backend");
});

test("ElevationLogic keypad helper accepts Return and numeric keypad Enter", () => {
    const logic = elevationLogic();
    const keys = {
        returnKey: 0x01000004,
        enterKey: 0x01000005,
        controlModifier: 0x04000000,
        shiftModifier: 0x02000000,
        keypadModifier: 0x20000000
    };
    const ctrlShift = keys.controlModifier | keys.shiftModifier;
    assert.equal(logic.isCtrlShiftEnter(keys.returnKey, ctrlShift, keys), true);
    assert.equal(logic.isCtrlShiftEnter(keys.enterKey, ctrlShift | keys.keypadModifier, keys), true);
    assert.equal(logic.isCtrlShiftEnter(keys.enterKey, ctrlShift, keys), true);
    assert.equal(logic.isCtrlShiftEnter(keys.returnKey, ctrlShift | keys.keypadModifier, keys), true);
    assert.equal(logic.isCtrlShiftEnter(keys.returnKey, keys.controlModifier, keys), false);
    assert.equal(logic.isCtrlShiftEnter(0x20, ctrlShift, keys), false);
});

test("launcher app rows expose native actions and close only after elevation starts", () => {
    for (const marker of [
        'objectName: "appItemContextMenu"',
        'objectName: "appItemRun"',
        'objectName: "appItemRunAsAdmin"',
        'objectName: "appItemOpenFileLocation"',
        'objectName: "appItemOpenProperties"',
        'objectName: "appItemOpenSettings"',
        'objectName: "appItemUninstall"',
        "root.actionInfo.canRunAsAdmin === true",
        "root.actionInfo.canOpenLocation === true",
        "root.actionInfo.packaged === true",
        "root.actionInfo.canUninstall === true",
        "Boolean(root.actionInfo.canOpenProperties)",
        "Native.AppActions.openProperties(root.modelData.id, root.elevationOwner())",
        "Apps.launchEnabled === true",
        "root.elevationOwner()",
        "root.ListView.view ?? root"
    ]) {
        assert.ok(appItem.includes(marker), `AppItem contains ${marker}`);
    }

    const reportBody = appItem.match(/function reportElevation\(result\): bool \{([\s\S]*?)\n    \}/)?.[1] ?? "";
    const started = reportBody.indexOf("started: function()");
    const close = reportBody.indexOf("root.screenState.launcher = false", started);
    const cancelled = reportBody.indexOf("cancelled: function()");
    const refused = reportBody.indexOf("refused: function");
    assert.ok(started >= 0 && close > started, "started closes the launcher");
    assert.ok(cancelled > close && refused > cancelled, "cancelled/refused leave the launcher open");

    const launchBody = appItem.match(/function launchElevated\(\): bool \{([\s\S]*?)\n    \}/)?.[1] ?? "";
    assert.ok(launchBody.indexOf("runAsAdminDetailed") < launchBody.indexOf("reportElevation"),
        "the backend receives the owner before the started handler can close the launcher");
    assert.ok(launchBody.includes("Apps.launchEnabled === true"),
        "launcher elevation passes the browse-only launch gate");
    const normalBody = appItem.match(/function launchNormal\(\): void \{([\s\S]*?)\n    \}/)?.[1] ?? "";
    assert.ok(normalBody.includes("if (Apps.launchEnabled !== true)"),
        "the Run helper refuses before dispatch while launching is disabled");
});

test("launcher Ctrl+Shift+Enter and Ctrl+Shift+Return invoke only app-row elevation", () => {
    assert.ok(launcherContent.includes("function launchCurrentAppElevated(): bool"));
    assert.ok(launcherContent.includes('view?.state !== "apps"'));
    assert.ok(launcherContent.includes('typeof item.launchElevated !== "function"'));
    assert.ok(launcherContent.includes("function isElevationKeyEvent(event): bool"));
    assert.ok(launcherContent.includes("keypadModifier: Qt.KeypadModifier"));
    assert.ok(launcherContent.includes("root.isElevationKeyEvent(event)"));
    assert.ok(launcherContent.includes("if (Apps.launchEnabled !== true)"));
    assert.ok(launcherContent.includes("!event.isAutoRepeat"));
});

test("Nexus app info exposes capability-gated actions and the inline sudo warning", () => {
    for (const marker of [
        'text: Tr.tr("Actions")',
        "import qs.modules.launcher.services",
        'objectName: "appInfoRun"',
        'objectName: "appInfoRunAsAdmin"',
        'objectName: "appInfoOpenFileLocation"',
        'objectName: "appInfoOpenProperties"',
        'objectName: "appInfoOpenSettings"',
        'objectName: "appInfoInlineSudo"',
        'objectName: "appInfoUninstall"',
        "property var appActions: Native.AppActions",
        "ElevationLogic.isInlineSudoEnabled(root.appActions)",
        "root.refreshInlineSudoAvailable()",
        "Inline mode shares the console with medium-integrity processes and is less secure than a separate elevated window",
        "ElevationLogic.inlineSudoSpec(root.app)",
        "ElevationLogic.launchInlineSudo(",
        "root.launchActionsEnabled",
        "Boolean(actionInfo.canOpenProperties)",
        "root.appActions.openProperties(root.app.id, root)",
        "onClicked: Apps.launchWithFeedback(root.app, null)",
        "onShellActionFinished"
    ]) {
        assert.ok(appInfo.includes(marker), `AppInfo contains ${marker}`);
    }
    assert.ok(appInfo.indexOf("isInlineSudoEnabled") < appInfo.indexOf("function launchInlineSudo"),
        "inline sudo is gated before launch");
    assert.ok(!appInfo.includes('args: ["sudo", "--inline"]'),
        "inline sudo never invokes Microsoft Sudo without a command");
});

test("default keybinds add terminal elevation and registered escape chords", () => {
    const binds = json("defaults/windows/keybinds.json").binds;
    const byKeys = Object.fromEntries(binds.map(bind => [bind.keys, bind]));

    assert.deepEqual({ ...byKeys["Super+Shift+Space"] }, {
        keys: "Super+Shift+Space",
        action: "global",
        name: "caelestia:launcher",
        register: true,
        since: "2.7.0",
        description: "Toggle the launcher over elevated windows"
    });
    assert.deepEqual({ ...byKeys["Super+T"] }, {
        keys: "Super+T",
        action: "exec",
        id: "terminal",
        command: "wt.exe",
        since: "2.7.0",
        register: true,
        description: "Open Windows Terminal"
    });
    assert.deepEqual({ ...byKeys["Ctrl+Super+Shift+T"] }, {
        keys: "Ctrl+Super+Shift+T",
        action: "exec",
        id: "terminalAdmin",
        command: "wt.exe",
        elevate: true,
        since: "2.7.0",
        register: true,
        description: "Open Windows Terminal as administrator"
    });

    for (const keys of ["Super+K", "Super+Shift+D", "Super+N", "Super+Shift+U", "Super+Shift+N", "Super+Shift+M"])
        assert.equal(byKeys[keys].register, true, `${keys} is registered`);

    assert.equal(byKeys.PrintScreen.register, undefined);
    assert.equal(byKeys["Win+Shift+S"].register, undefined);
    assert.equal(byKeys["Win+Shift+R"].register, undefined);
    assert.equal(byKeys.Super.register, undefined);
    assert.equal(byKeys["Super+L"].register, undefined);

    const docs = read("windows/docs/KEYBINDS.md");
    for (const text of [
        "`Super+Shift+Space` (registered)",
        "`Super+T` (hook-backed while `windows.hideTaskbar` is off; registered while it is on)",
        "`Ctrl+Super+Shift+T` (registered, elevated)",
        "reserves Win+Space for keyboard layout switching",
        "taskbar shortcut owned by the desktop supervisor",
        '"elevate": true',
        "Open Windows Terminal as administrator"
    ]) {
        assert.ok(docs.includes(text), `KEYBINDS.md contains ${text}`);
    }
});

test("active-window winfo detach carries only the resolved previewed client", () => {
    assert.ok(activeWindowPopout.includes("readonly property var previewClient"));
    assert.ok(activeWindowPopout.includes("toplevel: root.preview"));
    assert.ok(activeWindowPopout.includes("root.popouts.inspectWindowRequested(root.previewClient)"));
    assert.ok(activeWindowPopout.includes("(Services.Hypr.toplevels?.values ?? []).find(t => t.address === id)"));
    assert.ok(activeWindowPopout.includes("root.popouts.inspectWindowRequested(client)"));
    assert.ok(!activeWindowPopout.includes("WindowInfoFactory.openForClient"), "the popout never falls back to the foreground window");
    assert.ok(activeWindowContent.includes('detachRequested("winfo")'));
    assert.ok(!activeWindowContent.includes("property var client"), "the upstream content keeps its original one-argument detach contract");
    assert.ok(popoutState.includes("signal detachRequested(mode: string)"));
    assert.ok(popoutState.includes("signal inspectWindowRequested(client: var)"));
    assert.ok(popoutWrapper.includes("function detach(mode: string): void"));
    assert.ok(popoutWrapper.includes("function detachWindowInfo(client: var): void"));
    assert.ok(popoutWrapper.includes("if (!client)"));
    assert.ok(popoutWrapper.includes("WindowInfoFactory.openForClient(client)"));
    assert.ok(!popoutWrapper.includes("Services.Hypr.activeToplevel"), "WindowInfo detach has no foreground fallback");
    assert.ok(popoutWrapper.includes("onDetachRequested: mode => root.detach(mode)"));
    assert.ok(popoutWrapper.includes("onInspectWindowRequested: client => root.detachWindowInfo(client)"));
});

test("elevated windows receive badges and native action refusals become warning toasts", () => {
    for (const marker of [
        'objectName: "activeWindowAdminBadge"',
        'objectName: "activeWindowRowAdminBadge"',
        'text: qsTr("Admin")',
        "root.selectedWindow?.elevated === true"
    ]) {
        assert.ok(activeWindowPopout.includes(marker), `ActiveWindow popout contains ${marker}`);
    }
    assert.ok(popoutWrapper.includes("WindowInfoFactory.openForClient(client)"));
    assert.ok(activeWindowComponent.includes('objectName: "activeWindowAdminIndicator"'));
    assert.ok(activeWindowComponent.includes("Services.Hypr.activeToplevel?.elevated === true"));

    assert.ok(nativeHyprBackend.includes("signal actionRefused(string action, string reason, bool elevated)"));
    assert.ok(nativeHyprBackend.includes("function onActionRefused(action, reason, elevated)"));
    assert.ok(nativeHyprBackend.includes("readonly property bool pinSupported"));
    assert.ok(nativeHyprBackend.includes("readonly property bool tilingActive"));
    assert.ok(nativeHyprBackend.includes('typeof Hyprland.pinSupported === "boolean"'));
    assert.ok(nativeHyprBackend.includes('typeof Hyprland.tilingActive === "boolean"'));
    assert.ok(hyprService.includes("signal actionRefused(string action, string reason, bool elevated)"));
    assert.ok(hyprService.includes("readonly property bool pinSupported"));
    assert.ok(hyprService.includes("readonly property bool tilingActive"));
    assert.ok(hyprService.includes("root.backend.pinSupported === true"));
    assert.ok(hyprService.includes("root.backend.tilingActive === true"));
    assert.ok(hyprFacade.includes('Toaster.toast(Tr.tr("Window action blocked")'));
    assert.ok(hyprFacade.includes("because it runs as administrator"));
    assert.ok(hyprFacade.includes("Toast.Warning"));
});

test("HyprService admits only strict togglefloating and pin address forms", () => {
    assert.ok(hyprService.includes("const toggleFloating = /^togglefloating address:0x([0-9a-fA-F]{1,16})$/.exec(request);"));
    assert.ok(hyprService.includes("const pin = /^pin address:0x([0-9a-fA-F]{1,16})$/.exec(request);"));
    assert.ok(hyprService.includes('"togglefloating address:0x" + toggleFloating[1].toLowerCase()'));
    assert.ok(hyprService.includes('"pin address:0x" + pin[1].toLowerCase()'));
    assert.ok(hyprService.includes('case "togglefloating":'));
    assert.ok(hyprService.includes('case "pin":'));

    const fixture = read("windows/services/hypr/HyprServiceTest.qml");
    for (const marker of [
        'expectSend("togglefloating address:0x1A2B"',
        'expectSend("pin address:0xABCD"',
        'expectRefusal("togglefloating address:0xzz", "invalid"',
        'expectRefusal("pin address:1", "invalid"',
        'expectRefusal("togglefloating address:0x1;workspace 2", "injection"',
        "backend actionRefused reaches service consumers"
    ]) {
        assert.ok(fixture.includes(marker), `Hypr fixture contains ${marker}`);
    }
});

test("WindowInfo is staged as a Windows adapter with null-safe identity, badge, actions and IPC", () => {
    for (const name of ["WindowInfo.qml", "Preview.qml", "Details.qml", "Buttons.qml", "WindowInfoFactory.qml"]) {
        assert.equal(staging[`windows/shell/adapters/modules/windowinfo/${name}`], `modules/windowinfo/${name}`);
    }

    assert.ok(windowInfo.includes("required property var screen"));
    assert.ok(windowInfo.includes("(screen?.height ?? 800)"));
    assert.ok(windowInfoPreview.includes("captureSource: root.client?.wayland ?? null"));
    assert.ok(windowInfoPreview.includes("mon?.name ??"));
    assert.ok(windowInfoPreview.includes('root.ipcNumber("at", 0, -1)'));

    for (const marker of [
        'objectName: "windowInfoAdminBadge"',
        "root.client?.lastIpcObject?.elevated === true",
        'objectName: "windowInfoImagePath"',
        'objectName: "windowInfoAumid"',
        "root.client?.workspace?.name"
    ]) {
        assert.ok(windowInfoDetails.includes(marker), `WindowInfo Details contains ${marker}`);
    }

    for (const marker of [
        'objectName: "windowInfoFloatTileButton"',
        'objectName: "windowInfoPinButton"',
        "disabled: !Hypr.dispatchEnabled || !Hypr.tilingActive",
        "disabled: !Hypr.dispatchEnabled || !Hypr.pinSupported",
        'Hypr.desktopControlCapability?.availability === "available"',
        "Hypr.desktopControlCapability?.operations?.move === true",
        "disabled: isCurrent || !root.moveWorkspaceAvailable",
        "disabled: !Hypr.dispatchEnabled"
    ]) {
        assert.ok(windowInfoButtons.includes(marker), `WindowInfo buttons contain ${marker}`);
    }

    for (const dispatch of ["movetoworkspace ${wsId},address:0x${root.client?.address}",
        "togglefloating address:0x${root.client?.address}",
        "pin address:0x${root.client?.address}",
        "killwindow address:0x${root.client?.address}"]) {
        assert.ok(windowInfoButtons.includes(dispatch), `WindowInfo dispatches ${dispatch}`);
    }

    assert.ok(windowInfoFactory.includes("function openForClient(client): var"));
    assert.ok(windowInfoFactory.includes("existing.requestActivate()"));
    assert.ok(windowInfoFactory.includes("win.requestActivate()"));
    assert.ok(shell.includes('target: "windowinfo"'));
    assert.ok(shell.includes("WindowInfoModule.WindowInfoFactory.openForClient(client)"));
    assert.ok(shell.includes("WindowInfoModule.WindowInfoFactory.closeAll()"));
});

test("known limitations document administrator protection and UIPI behavior", () => {
    const docs = read("windows/docs/KNOWN-LIMITATIONS.md");
    for (const text of [
        "Administrator protection (KB5120998)",
        "hidden profile-separated system-managed administrator account",
        "do not\n  inherit the user account's Windows Terminal `settings.json` or PowerShell\n  `$PROFILE`",
        "medium-integrity shell cannot close",
        '`"register": true` use'
    ]) {
        assert.ok(docs.includes(text), `KNOWN-LIMITATIONS.md contains ${text}`);
    }
});
