pragma ComponentBehavior: Bound

import QtQuick
import "AppStoragePath.js" as StoragePath

// Standalone fixture for the Windows app catalog/search state object.
// Imports no Quickshell, native DesktopEntries or Caelestia.Models. The runner
// stages this file, AppsService.qml, AppFrequencyStore.qml, AppStoragePath.js
// and the upstream fzf/fuzzysort libraries, then runs Qt qml.exe offscreen.
// Intended runner: windows/scripts/Test-AppsService.ps1 -QtPrefix <Qt prefix>
QtObject {
    id: test

    component FakeEntry: QtObject {
        property string id: ""
        property string name: ""
        property string comment: ""
        property string execString: ""
        property string startupClass: ""
        property string genericName: ""
        property var categories: []
        property var keywords: []
        property string icon: ""
        property bool runInTerminal: false
        property int executions: 0

        function execute(): void {
            executions++;
        }
    }

    component FakeModel: QtObject {
        property var values: []
    }

    component FakeCatalog: QtObject {
        property var applications: null
        property bool scanCompleted: false
        property string scanError: ""
        property int executions: 0
        property string lastExecutedId: ""

        function execute(entry): bool {
            if (!entry || typeof entry.execute !== "function")
                return false;
            executions++;
            lastExecutedId = entry.id;
            entry.execute();
            return true;
        }
    }

    component FakeStore: QtObject {
        property var frequencies: ({})
        property int increments: 0

        function frequencyFor(id): int {
            const value = frequencies[id];
            return typeof value === "number" && value > 0 ? Math.floor(value) : 0;
        }

        function increment(id): int {
            increments++;
            const next = Object.assign({}, frequencies);
            next[id] = frequencyFor(id) + 1;
            frequencies = next;
            return next[id];
        }

        function set(id, value): void {
            const next = Object.assign({}, frequencies);
            next[id] = value;
            frequencies = next;
        }

        function reset(): void {
            frequencies = {};
            increments = 0;
        }
    }

    component FakeStorage: QtObject {
        property bool available: true
        property string text: ""
        property int writes: 0
        property bool failWrites: false

        function write(value): bool {
            writes++;
            if (failWrites)
                return false;
            text = value;
            return true;
        }
    }

    readonly property AppsService service: AppsService {}
    readonly property FakeModel model: FakeModel {}
    readonly property FakeCatalog catalog: FakeCatalog {
        applications: test.model
    }
    readonly property FakeStore store: FakeStore {}
    readonly property FakeStorage storage: FakeStorage {}
    // Mirrors FileAppFrequencyStore: setText() returns before completion.
    readonly property FakeStorage asyncStorage: FakeStorage {
        readonly property bool asynchronous: true
    }

    // The frequency store under test is the real AppFrequencyStore driven by
    // the fixture storage above.
    readonly property Component storeComponent: Component {
        AppFrequencyStore {}
    }

    // The property name `id` is reserved by the QML object syntax, so entries
    // are created from initial property maps instead of object declarations.
    readonly property Component entryComponent: Component {
        FakeEntry {}
    }

    property FakeEntry firefox: null
    property FakeEntry files: null
    property FakeEntry calculator: null
    property FakeEntry settings: null
    property FakeEntry terminal: null
    property FakeEntry duplicateA: null
    property FakeEntry duplicateB: null

    property int assertions: 0

    function buildFixture(): void {
        firefox = entryComponent.createObject(test, {
            id: "firefox", name: "Firefox", comment: "Web Browser",
            execString: "/usr/bin/firefox", genericName: "Web Browser",
            categories: ["Network", "WebBrowser"], keywords: ["browser", "internet"],
            icon: "firefox"
        });
        files = entryComponent.createObject(test, {
            id: "org.gnome.Nautilus", name: "Files", comment: "File manager",
            execString: "/usr/bin/nautilus", categories: ["Utility"],
            // No icon: the original AppItem falls back to "image-missing".
            icon: ""
        });
        calculator = entryComponent.createObject(test, {
            id: "calc", name: "Calculator", comment: "Do simple maths",
            genericName: "Calculator", categories: ["Utility"], keywords: ["maths"],
            icon: "accessories-calculator"
        });
        settings = entryComponent.createObject(test, {
            id: "settings", name: "Settings", startupClass: "ms-settings",
            icon: "preferences-system"
        });
        terminal = entryComponent.createObject(test, {
            id: "terminal", name: "Terminal", comment: "Command line",
            execString: "/usr/bin/foot", runInTerminal: true, icon: "utilities-terminal"
        });
        duplicateA = entryComponent.createObject(test, {
            id: "dup-a", name: "Duplicate", icon: "appicon:dup-a"
        });
        duplicateB = entryComponent.createObject(test, {
            id: "dup-b", name: "Duplicate", icon: "appicon:dup-b"
        });
    }

    function check(condition, message): void {
        assertions++;
        if (!condition)
            throw new Error(message);
    }

    function expectStatus(expected, message): void {
        check(service.status === expected,
            message + ": status " + service.status + " != " + expected + " (" + service.reason + ")");
    }

    function run(): void {
        // --- Safe construction ------------------------------------------------
        check(service.enabled === false && service.launchEnabled === false,
            "safe construction defaults");
        check(service.catalog === null && service.catalogError === ""
            && service.frequencyStore === null, "no backend is constructed while disabled");
        expectStatus("disabled", "explicit disabled state");
        check(service.reason.indexOf("disabled") >= 0, "disabled reason");
        check(service.statusTitle === "Windows app search is disabled"
            && service.statusDescription.length > 0, "disabled status copy");
        check(!service.ready && !service.scanning && !service.empty && !service.failed
            && service.disabled, "disabled state flags");
        check(service.count === 0 && service.list.length === 0 && service.entries.length === 0,
            "disabled has no applications");
        check(service.lastError === "", "disabled has no error");
        check(service.search("fire").length === 0 && service.query("fire").length === 0,
            "disabled search returns nothing");
        check(service.search("").length === 0, "disabled empty search returns nothing");
        check(service.terminalLaunchSupported === false, "terminal launch is unsupported");
        check(service.canLaunch(firefox) === false, "disabled cannot launch");
        check(service.iconName(firefox) === "firefox" && service.iconName(files) === "image-missing"
            && service.iconName(null) === "image-missing",
            "icon resolution and the original image-missing fallback");
        check(service.nameFor(firefox) === "Firefox" && service.nameFor(null) === "",
            "name resolution");

        // The adapter must expose the preserved launcher members and no
        // Database/AppDb surface.
        for (const name of ["search", "query", "selector", "transformSearch", "launch",
            "canLaunch", "iconName", "nameFor", "matchesFilterList", "isFavourite",
            "frequencyFor", "makeWrapper", "listText", "compareNames", "compareWrappers"]) {
            check(typeof service[name] === "function", "missing preserved member " + name);
        }
        for (const name of ["incrementFrequency", "favouriteAppsRegex", "setPath",
            "setEntries", "path", "uuid"]) {
            check(service[name] === undefined, "adapter exposes excluded AppDb member " + name);
        }

        // --- Failure before a backend exists ---------------------------------
        service.enabled = true;
        expectStatus("scanning", "enabled without a catalog is scanning");
        check(service.reason.indexOf("Scanning") >= 0, "scanning reason");
        check(service.list.length === 0 && service.count === 0, "scanning has no list");
        check(service.search("fire").length === 0, "scanning search returns nothing");
        check(service.launch(firefox) === false && catalog.executions === 0,
            "scanning refuses launch without executing");
        check(service.lastLaunchError.indexOf("read-only") >= 0,
            "read-only refusal is explicit");

        service.catalogError = "Fixture catalog component failed to load";
        expectStatus("failed", "known component failure");
        check(service.lastError === service.catalogError, "component failure is reported verbatim");
        check(service.statusTitle === "App catalog unavailable", "failed status title");
        check(service.list.length === 0, "failed has no list");

        service.catalogError = "";
        service.catalog = catalog;
        model.values = [firefox, files, calculator, settings, terminal];
        expectStatus("scanning", "uncompleted scan hides catalog values");
        check(service.list.length === 0 && service.entries.length === 0,
            "values are hidden until a scan completes");

        catalog.scanError = "AppsFolder enumeration failed (HRESULT 0x80070005)";
        expectStatus("failed", "reported native scan failure");
        check(service.lastError.indexOf("0x80070005") >= 0, "native error is exposed");
        catalog.scanError = "";

        // --- Empty scan -------------------------------------------------------
        model.values = [];
        catalog.scanCompleted = true;
        expectStatus("empty", "completed scan with no applications");
        check(service.empty && !service.ready && !service.failed && service.count === 0,
            "empty scan flags");
        check(service.reason.indexOf("no applications") >= 0, "empty reason is distinct");
        check(service.statusTitle === "No applications found", "empty status title");
        check(service.search("fire").length === 0 && catalog.executions === 0,
            "empty scan search never launches");

        // --- Ready scan -------------------------------------------------------
        model.values = [firefox, files, calculator, settings, terminal];
        expectStatus("ready", "completed scan with applications");
        check(service.ready && !service.empty && service.count === 5,
            "ready count");
        check(service.reason.indexOf("5 application") >= 0
            && service.reason.indexOf("Read-only") >= 0, "ready reason states count and policy");
        check(service.statusTitle === "" && service.statusDescription === "",
            "ready has no empty-state copy");
        check(service.list.length === 5 && service.list[0].entry !== undefined,
            "list projects AppEntry-shaped wrappers");
        check(service.list.every(item => typeof item.frequency === "number"
            && typeof item.id === "string" && typeof item.name === "string"
            && typeof item.comment === "string" && typeof item.execString === "string"
            && typeof item.startupClass === "string" && typeof item.genericName === "string"
            && typeof item.categories === "string" && typeof item.keywords === "string"),
            "wrapper fields match the AppDb contract");
        check(service.list[0].name === "Calculator" && service.list[1].name === "Files"
            && service.list[2].name === "Firefox" && service.list[3].name === "Settings"
            && service.list[4].name === "Terminal",
            "zero-frequency list sorts by name: " + service.list.map(item => item.name).join(","));
        check(service.list.find(item => item.id === "calc").categories === "Utility",
            "categories are a space-joined string like AppEntry");
        check(service.iconName(service.list.find(item => item.id === "org.gnome.Nautilus").entry)
            === "image-missing", "missing icon falls back through the service");

        // Hidden-app and invalid-entry filters.
        service.hiddenApps = ["terminal", "^org\\.gnome\\..*$"];
        check(service.count === 3, "hidden filters remove exact and regex matches");
        check(service.list.every(item => item.id !== "terminal"
            && item.id !== "org.gnome.Nautilus"), "hidden entries are not projected");
        service.hiddenApps = [];
        check(service.count === 5, "clearing hidden filters restores the catalog");

        const validValues = model.values;
        model.values = [null, undefined, {id: ""}, {name: "No id"}, {id: "no-name"},
            firefox, {id: 7, name: "Wrong id type"}];
        expectStatus("ready", "invalid model entries are filtered");
        check(service.count === 1 && service.list[0].entry === firefox,
            "non-object, empty-id and empty-name entries are rejected");
        model.values = validValues;

        // --- Frequency ordering ----------------------------------------------
        service.frequencyStore = store;
        check(service.list[0].frequency === 0, "a fresh store records no frequencies");
        store.set("firefox", 3);
        store.set("org.gnome.Nautilus", 1);
        check(service.list[0].name === "Firefox" && service.list[1].name === "Files",
            "frequency orders the unsearched list");
        store.set("settings", 9);
        check(service.list[0].name === "Settings", "frequency change reorders reactively");
        store.reset();
        service.favouriteApps = ["terminal"];
        check(service.list[0].name === "Terminal", "favourites sort first");
        service.favouriteApps = ["^dup.*$"];
        model.values = [duplicateA, duplicateB, firefox];
        check(service.list[0].id === "dup-a" && service.list[1].id === "dup-b",
            "favourite regex matches and falls back to name for equal entries");
        service.favouriteApps = [];
        model.values = validValues;

        // --- Search -----------------------------------------------------------
        check(service.search("").length === 5, "empty search returns the whole list");
        check(service.search("fire").length === 1 && service.search("fire")[0] === firefox,
            "default name search");
        check(service.search("Fire").length === 1 && service.search("Fire")[0] === firefox,
            "mixed-case query uses smart-case matching");
        check(service.search("  fire  ").length === 1, "query whitespace is normalized");
        check(service.search("fire fox").length === 0,
            "the basic finder treats spaces literally, unlike fzf extended terms");
        check(service.search("zzzz").length === 0, "no match returns an empty list");

        check(service.search("@i fire").length === 1
            && service.search("@i fire")[0] === firefox, "id prefix search");
        check(service.search("@i nautilus").length === 1
            && service.search("@i nautilus")[0] === files, "id prefix matches the full id");
        check(service.search("@c web").length === 1
            && service.search("@c web")[0] === firefox, "category prefix search");
        check(service.search("@d maths").length === 1
            && service.search("@d maths")[0] === calculator, "comment prefix search");
        check(service.search("@e nautilus").length === 1
            && service.search("@e nautilus")[0] === files, "exec prefix search");
        check(service.search("@w ms-settings").length === 1
            && service.search("@w ms-settings")[0] === settings, "startup class prefix search");
        check(service.search("@g calculator").length === 1
            && service.search("@g calculator")[0] === calculator, "generic name prefix search");
        check(service.search("@k internet").length === 1
            && service.search("@k internet")[0] === firefox, "keywords prefix search");
        check(service.search("@t ").length === 1 && service.search("@t ")[0] === terminal,
            "terminal prefix filters terminal entries");
        check(service.search("@t fire").length === 0, "terminal prefix keeps the filter");

        // --- Ranking with frequency ------------------------------------------
        model.values = [duplicateA, duplicateB];
        store.set("dup-b", 4);
        check(service.search("").length === 2 && service.search("")[0] === duplicateB,
            "frequency orders the empty search");
        check(service.search("dup").length === 2 && service.search("dup")[0] === duplicateB,
            "equal relevance keeps the frequency-sorted list order");
        store.set("dup-a", 4);
        check(service.search("dup")[0] === duplicateA,
            "equal relevance and frequency falls back to name/stable order");
        store.reset();
        model.values = validValues;

        service.useFuzzy = true;
        check(service.search("fire").length === 1 && service.search("fire")[0] === firefox,
            "fuzzysort configuration is preserved");
        check(service.search("@c web").length === 1, "fuzzy prefix search");
        check(service.search("@t ").length === 1 && service.search("@t ")[0] === terminal,
            "fuzzy terminal prefix filter");
        service.useFuzzy = false;

        // Enumeration and search must never issue a launch.
        check(catalog.executions === 0, "enumeration/search never call catalog.execute");
        for (const entry of [firefox, files, calculator, settings, terminal])
            check(entry.executions === 0, "enumeration/search never call DesktopEntry.execute");

        // --- Frequency store --------------------------------------------------
        check(storage.available === true && storage.text === "" && storage.writes === 0,
            "fixture storage starts empty");

        const storeA = storeComponent.createObject(test, {storage: storage});
        check(storeA.persistent === true && storeA.loaded === true,
            "missing file loads as an empty persistent store");
        check(storeA.frequencies !== null && Object.keys(storeA.frequencies).length === 0,
            "missing file has no frequencies");
        check(storeA.corrupt === false && storeA.lastError === "",
            "a missing file is not an error");

        storeA.increment("firefox");
        storeA.increment("firefox");
        check(storeA.frequencyFor("firefox") === 2, "increment updates the frequency");
        check(storeA.writes === 2 && storage.writes === 2, "each increment writes once");
        check(JSON.parse(storage.text).frequencies.firefox === 2,
            "the written document carries the increment");
        check(storeA.frequencyFor("") === 0 && storeA.frequencyFor(null) === 0,
            "invalid ids have no frequency");
        check(storeA.increment("") === 0 && storeA.lastError.length > 0,
            "increment without an id is refused");

        storage.text = storeA.savedText;
        const storeB = storeComponent.createObject(test, {storage: storage});
        check(storeB.frequencyFor("firefox") === 2, "persistence round trip reloads the count");
        check(storeB.writes === 0 && storage.writes === 2, "loading does not write");

        // Corrupt document.
        storage.text = "{ not json";
        const storeC = storeComponent.createObject(test, {storage: storage});
        check(storeC.loaded && storeC.corrupt === true, "corrupt JSON is tolerated");
        check(Object.keys(storeC.frequencies).length === 0, "corrupt JSON starts empty");
        check(storeC.lastError.indexOf("corrupt") >= 0, "corrupt JSON is reported");
        storeC.increment("calc");
        check(JSON.parse(storage.text).frequencies.calc === 1,
            "the next increment replaces a corrupt document");

        // Wrong-shaped and invalid values.
        storage.text = JSON.stringify({version: 1, frequencies: []});
        const storeD = storeComponent.createObject(test, {storage: storage});
        check(storeD.corrupt === true && Object.keys(storeD.frequencies).length === 0,
            "a non-object frequencies document is rejected");
        storage.text = JSON.stringify({frequencies: {
            good: 3, negative: -2, text: "4", nope: null, fractional: 2.9, zero: 0
        }});
        const storeE = storeComponent.createObject(test, {storage: storage});
        check(storeE.frequencyFor("good") === 3 && storeE.frequencyFor("fractional") === 2,
            "valid counts are kept and floored");
        check(storeE.frequencyFor("negative") === 0 && storeE.frequencyFor("text") === 0
            && storeE.frequencyFor("nope") === 0 && storeE.frequencyFor("zero") === 0,
            "invalid counts are dropped");
        check(storeE.corrupt === false, "partially invalid values are not corrupt");

        // Memory-only and failed writes.
        const memoryStore = storeComponent.createObject(test);
        check(memoryStore.persistent === false, "no storage keeps the store memory-only");
        memoryStore.increment("firefox");
        check(memoryStore.frequencyFor("firefox") === 1, "memory-only increments still work");
        check(memoryStore.lastError.indexOf("memory-only") >= 0,
            "memory-only limitation is reported");
        storage.failWrites = true;
        const beforeWrites = storage.writes;
        const failedStore = storeComponent.createObject(test, {storage: storage});
        failedStore.increment("terminal");
        check(storage.writes === beforeWrites + 1, "a failed write is attempted");
        check(failedStore.lastError.indexOf("could not be written") >= 0,
            "a failed write is reported");
        check(failedStore.frequencyFor("terminal") === 1, "state is kept after a failed write");
        storage.failWrites = false;

        // Asynchronous storage counts a write only after it reports completion.
        const asyncStore = storeComponent.createObject(test, {storage: asyncStorage});
        asyncStore.increment("editor");
        check(asyncStore.writes === 0 && asyncStore.writesPending === 1,
            "an asynchronous write is pending, not confirmed");
        asyncStore.writeFinished(false, "access denied");
        check(asyncStore.writes === 0 && asyncStore.writesPending === 0,
            "a failed asynchronous write is not counted");
        check(asyncStore.lastError.indexOf("could not be written") >= 0
            && asyncStore.lastError.indexOf("access denied") >= 0,
            "an asynchronous write failure is reported");
        asyncStore.increment("editor");
        asyncStore.writeFinished(true, "");
        check(asyncStore.writes === 1 && asyncStore.writesPending === 0,
            "a confirmed asynchronous write is counted");

        // --- Path confinement -------------------------------------------------
        check(StoragePath.frequenciesPath("") === "", "empty state dir yields no path");
        check(StoragePath.frequenciesPath(null) === "", "null state dir yields no path");
        check(StoragePath.frequenciesPath("relative/state") === "",
            "relative state dir is rejected");
        check(StoragePath.frequenciesPath("\\\\server\\share") === "",
            "UNC state dir is rejected");
        check(StoragePath.frequenciesPath("C:\\profile\\..\\escape") === "",
            "traversing state dir is rejected");
        check(StoragePath.frequenciesPath("C:\\profile\\state") === "C:\\profile\\state\\apps-frequencies.json",
            "drive path gets the profile-local file");
        check(StoragePath.frequenciesPath("C:\\profile\\state\\") === "C:\\profile\\state\\apps-frequencies.json",
            "trailing separators are normalized");
        check(StoragePath.frequenciesPath("C:/profile/state") === "C:\\profile\\state\\apps-frequencies.json",
            "forward slashes are normalized");
        check(StoragePath.isInside("C:\\profile\\state\\apps-frequencies.json", "C:\\profile\\state") === true,
            "the frequency file stays inside the state dir");
        check(StoragePath.isInside("C:\\profile\\state\\..\\apps-frequencies.json", "C:\\profile\\state") === false,
            "a traversing target is outside the state dir");
        check(StoragePath.isInside("D:\\profile\\state\\apps-frequencies.json", "C:\\profile\\state") === false,
            "another drive is outside the state dir");

        // --- Launch refusal without the launch opt-in -------------------------
        resetStoreAndCatalogSupport();
        service.enabled = true;
        service.launchEnabled = false;
        service.catalog = catalog;
        service.frequencyStore = store;
        model.values = [firefox, files, calculator, settings, terminal];
        catalog.scanCompleted = true;
        expectStatus("ready", "bring-up for launch policy");
        const requestsBefore = service.launchRequests;
        check(service.canLaunch(firefox) === false, "read-only cannot launch");
        check(service.launch(firefox) === false, "read-only launch is refused");
        check(service.launchRequests === requestsBefore + 1, "refused launch is counted as a request");
        check(service.launchesIssued === 0 && catalog.executions === 0 && firefox.executions === 0,
            "read-only launch executes nothing");
        check(service.lastLaunchError.indexOf("read-only") >= 0, "read-only launch reason");
        check(store.increments === 0, "refused launch does not record a frequency");
        check(service.search("").map(entry => entry.id).join(",")
            === service.query("").map(item => item.id).join(","),
            "search and query agree on the empty query order");

        // --- Interactive launch policy ---------------------------------------
        service.launchEnabled = true;
        check(service.canLaunch(firefox) === true, "launch opt-in permits a listed entry");
        check(service.canLaunch(terminal) === false, "terminal entries are not launchable");
        check(service.canLaunch({id: "foreign", name: "Foreign"}) === false,
            "foreign entries are not launchable");
        check(service.canLaunch(null) === false, "null entries are not launchable");

        check(service.launch(firefox) === true, "explicit launch is permitted");
        check(catalog.executions === 1 && catalog.lastExecutedId === "firefox"
            && firefox.executions === 1, "launch dispatches exactly one native execute");
        check(service.launchesIssued === 1, "issued launch is counted");
        check(store.increments === 1 && store.frequencyFor("firefox") === 1,
            "permitted launch records the frequency");
        check(service.launch(firefox) === true && store.frequencyFor("firefox") === 2,
            "the next launch increments again");
        check(service.list[0].entry === firefox,
            "the launched application moves to the front of the unsearched list");

        check(service.launch({id: "foreign", name: "Foreign"}) === false,
            "foreign launch is refused");
        check(catalog.executions === 2, "foreign launch did not execute");
        check(service.lastLaunchError.indexOf("not in the current catalog") >= 0,
            "foreign launch reason");

        check(service.launch(terminal) === false, "terminal launch is refused");
        check(terminal.executions === 0 && catalog.executions === 2,
            "terminal launch executes nothing");
        check(service.lastLaunchError.indexOf("Terminal") >= 0, "terminal refusal reason");
        check(store.frequencyFor("terminal") === 0, "terminal refusal records no frequency");

        check(service.launch(null) === false && service.launch("firefox") === false,
            "invalid entries are refused");
        check(service.lastLaunchError.length > 0, "invalid launch has a reason");

        // A stale entry removed by a rescan is refused.
        model.values = [files];
        check(service.canLaunch(firefox) === false, "removed entry is no longer launchable");
        check(service.launch(firefox) === false && catalog.executions === 2,
            "removed entry launch is refused without executing");

        // --- Disable clears every projection ---------------------------------
        model.values = [firefox, files];
        service.enabled = false;
        expectStatus("disabled", "disable returns to disabled");
        check(service.count === 0 && service.list.length === 0 && service.search("fire").length === 0,
            "disable clears the catalog and search");
        check(!service.ready && !service.scanning && !service.empty && !service.failed,
            "disable clears every state flag");
        check(service.lastError === "" && service.lastLaunchError === "",
            "disable clears error strings");
        check(service.canLaunch(firefox) === false, "disable clears launch capability");

        // Final native/no-op invariant across the whole fixture.
        check(catalog.executions === 2, "only the two permitted launches reached the catalog");
        check(firefox.executions === 2, "only explicit launches reached DesktopEntry.execute");

        console.log("CAELESTIA_APPS_FIXTURE_PASS " + JSON.stringify({assertions: assertions}));
        Qt.quit();
    }

    // Fresh launch counters without disturbing the catalog used above.
    function resetStoreAndCatalogSupport(): void {
        store.reset();
        catalog.executions = 0;
        catalog.lastExecutedId = "";
        for (const entry of [firefox, files, calculator, settings, terminal])
            entry.executions = 0;
        service.launchRequests = 0;
        service.launchesIssued = 0;
        service.lastLaunchError = "";
        service.lastLaunchId = "";
    }

    Component.onCompleted: {
        test.buildFixture();
        Qt.callLater(() => {
            try {
                test.run();
            } catch (error) {
                console.error("CAELESTIA_APPS_FIXTURE_FAIL " + error.message);
                Qt.exit(1);
            }
        });
    }
}
