import QtQuick
import qs.modules.launcher.services
import qs.modules.nexus
import qs.modules.nexus.pages.apps

// Exercises the staged Nexus AppInfo page with fake catalog and native action
// backends. The production page, launcher facade and elevation logic run; only
// the Windows endpoints are recording fakes.
QtObject {
    id: test

    property int assertions: 0
    property var page: null

    readonly property NexusState nState: NexusState {}
    readonly property Component entryComponent: Component {
        QtObject {
            property string id
            property string name
            property string comment
            property string execString
            property var command: []
            property string icon
        }
    }
    property var terminalEntry: null
    readonly property Window host: Window {
        width: 560
        height: 700
        visible: false
    }
    readonly property Component pageComponent: Component {
        AppInfo {}
    }

    component FakeCatalog: QtObject {
        property var applications: ({ values: [] })
        property bool scanCompleted: false
        property string scanError: ""
        property int executions: 0
        property string lastExecutedId: ""

        function lookup(appId): var {
            for (const entry of applications.values ?? []) {
                if (entry?.id === appId)
                    return entry;
            }
            return null;
        }

        function execute(entry): var {
            executions++;
            lastExecutedId = entry?.id ?? "";
            return true;
        }
    }

    component FakeStore: QtObject {
        property int increments: 0

        function frequencyFor(id): int {
            return 0;
        }

        function increment(id): int {
            increments++;
            return increments;
        }
    }

    component FakeActions: QtObject {
        property var actionInfo: ({})
        property bool inlineSudoEnabled: false
        property int runAsAdminCalls: 0
        property int launches: 0
        property int openPropertiesCalls: 0
        property string lastEntryId: ""
        property var lastSpec: null

        function info(appId): var {
            return actionInfo;
        }

        function runAsAdminDetailed(appId, ownerWindow): var {
            runAsAdminCalls++;
            lastEntryId = appId;
            return ({ status: "started" });
        }

        function isInlineSudoEnabled(): bool {
            return inlineSudoEnabled;
        }

        function launchShellAction(spec, ownerWindow): var {
            launches++;
            lastSpec = spec;
            return ({ status: "started" });
        }

        function openProperties(appId, ownerWindow): bool {
            openPropertiesCalls++;
            lastEntryId = appId;
            return true;
        }
    }

    readonly property FakeCatalog catalog: FakeCatalog {}
    readonly property FakeStore store: FakeStore {}
    readonly property FakeActions actions: FakeActions {}

    function check(value, message): void {
        assertions++;
        if (!value)
            throw new Error(message);
    }

    function findObject(object, name): var {
        if (!object)
            return null;
        if (object.objectName === name)
            return object;
        for (const child of object.children ?? []) {
            const found = findObject(child, name);
            if (found)
                return found;
        }
        return null;
    }

    function fail(error): void {
        console.error("CAELESTIA_APPINFO_ACTIONS_FAIL " + error);
        Qt.exit(1);
    }

    function setup(): void {
        try {
            terminalEntry = entryComponent.createObject(test, {
                id: "windows-terminal",
                name: "Windows Terminal",
                comment: "Terminal",
                execString: "wt.exe",
                command: ["wt.exe"],
                icon: "utilities-terminal"
            });
            check(terminalEntry !== null, "fixture desktop entry is created");
            actions.actionInfo = ({
                canRunAsAdmin: true,
                canOpenLocation: true,
                canOpenProperties: true,
                packaged: true,
                canUninstall: true
            });
            actions.inlineSudoEnabled = true;
            catalog.applications = ({ values: [terminalEntry] });
            catalog.scanCompleted = true;
            Apps.catalogOverride = catalog;
            Apps.frequencyStoreOverride = store;
            Apps.enabledOverride = true;
            Apps.launchEnabledOverride = false;
            page = pageComponent.createObject(host.contentItem, {
                nState: nState,
                width: host.contentItem.width,
                height: host.contentItem.height
            });
            check(page !== null, "staged AppInfo page loads");
            page.appActions = actions;
            page.app = terminalEntry;
            check(Apps.ready === true, "injected catalog makes the Apps facade ready");
            Qt.callLater(runDisabledPhase);
        } catch (error) {
            fail(error);
        }
    }

    function runDisabledPhase(): void {
        try {
            const run = findObject(page, "appInfoRun");
            const admin = findObject(page, "appInfoRunAsAdmin");
            const inline = findObject(page, "appInfoInlineSudo");
            const properties = findObject(page, "appInfoOpenProperties");
            check(run !== null && admin !== null && inline !== null && properties !== null,
                "all AppInfo action rows exist");
            check(run.visible === false && admin.visible === false && inline.visible === false,
                "launch-disabled hides Run, Run as administrator and inline sudo");
            check(properties.visible === true, "launch-disabled keeps capability-gated Properties visible");

            const adminCalls = actions.runAsAdminCalls;
            const shellLaunches = actions.launches;
            const propertyCalls = actions.openPropertiesCalls;
            page.runAsAdmin();
            page.launchInlineSudo();
            page.openProperties();
            check(actions.runAsAdminCalls === adminCalls,
                "launch-disabled Run as administrator does not reach Windows");
            check(actions.launches === shellLaunches,
                "launch-disabled inline sudo does not reach Windows");
            check(actions.openPropertiesCalls === propertyCalls + 1,
                "launch-disabled Properties still opens through Windows");

            Apps.launchEnabledOverride = true;
            check(run.visible === true && admin.visible === true && inline.visible === true,
                "launch-enabled shows Run, Run as administrator and inline sudo");
            check(properties.visible === true, "launch-enabled keeps Properties visible");

            const launchRequests = Apps.launchRequests;
            run.activate();
            check(Apps.launchRequests === launchRequests + 1,
                "Run reaches the Apps facade");
            check(catalog.executions === 1 && catalog.lastExecutedId === terminalEntry.id,
                "Run launches the selected app through the injected catalog");
            check(store.increments === 1, "confirmed Run records launch frequency");

            admin.activate();
            check(actions.runAsAdminCalls === adminCalls + 1,
                "Run as administrator reaches Windows elevation");
            check(actions.lastEntryId === terminalEntry.id,
                "Run as administrator uses the selected app id");

            inline.activate();
            check(actions.launches === shellLaunches + 1,
                "inline sudo reaches the Windows shell action backend");
            check(actions.lastSpec?.target === "wt.exe"
                && (actions.lastSpec?.args ?? []).indexOf("--inline") >= 0,
                "inline sudo uses Windows Terminal inline sudo arguments");

            properties.activate();
            check(actions.openPropertiesCalls === propertyCalls + 2,
                "Properties reaches Windows while launching is enabled");

            Apps.launchEnabledOverride = false;
            check(run.visible === false && admin.visible === false && inline.visible === false,
                "removing launch opt-in hides every launch action again");
            check(properties.visible === true, "removing launch opt-in leaves Properties visible");
            properties.activate();
            check(actions.openPropertiesCalls === propertyCalls + 3,
                "Properties still works after the launch opt-in is removed");

            Apps.launchEnabledOverride = null;
            Apps.enabledOverride = null;
            Apps.catalogOverride = null;
            Apps.frequencyStoreOverride = null;
            page.destroy();
            host.destroy();
            console.log("CAELESTIA_APPINFO_ACTIONS_PASS " + assertions);
            Qt.quit();
        } catch (error) {
            fail(error);
        }
    }

    Component.onCompleted: Qt.callLater(setup)
}
