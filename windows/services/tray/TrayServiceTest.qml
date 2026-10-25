pragma ComponentBehavior: Bound

import QtQuick

// Standalone fixture for the Windows tray boundary. Imports no Quickshell,
// native SystemTray, configuration or hardware module; it never constructs
// Tray.qml, NativeTrayBackend.qml or the real launcher. The fake items are
// plain QtObjects whose command methods only count calls.
//
// Runner: powershell -NoProfile -File windows/scripts/Test-TrayService.ps1 -QtPrefix <Windows Qt prefix>
// The runner copies only TrayService.qml and this file into an offscreen stage.
QtObject {
    id: test

    component FakeItem: QtObject {
        property string id: ""
        property string title: ""
        property bool hasMenu: true
        property var menu: null
        property int status: 1
        property int activateCalls: 0
        property int secondaryCalls: 0
        property int displayCalls: 0
        property int scrollCalls: 0
        property var lastDisplay: []

        function activate() {
            activateCalls++;
        }
        function secondaryActivate() {
            secondaryCalls++;
        }
        function display(parentWindow, x, y) {
            displayCalls++;
            lastDisplay = [parentWindow, x, y];
        }
        function scroll(delta, horizontal) {
            scrollCalls++;
        }
    }

    component FakeModel: QtObject {
        property var values: []
    }

    component FakeBackend: QtObject {
        property var items: null
    }

    readonly property TrayService service: TrayService {}
    readonly property FakeBackend fixture: FakeBackend {}
    readonly property FakeModel model: FakeModel {}

    readonly property FakeItem spotify: FakeItem {
        id: "spotify"
        title: "Spotify"
    }
    readonly property FakeItem discord: FakeItem {
        id: "discord"
        title: "Discord"
        status: 2
    }
    readonly property FakeItem bare: FakeItem {
        id: "bare"
        title: ""
        hasMenu: false
    }

    property int assertions: 0

    function check(condition, message): void {
        assertions++;
        if (!condition)
            throw new Error(message);
    }

    function setItems(items): void {
        model.values = items;
    }

    function expectStatus(expected, message): void {
        check(service.status === expected,
            message + ": status " + service.status + " != " + expected + " (" + service.reason + ")");
    }

    function run(): void {
        // --- Safe construction ------------------------------------------------
        check(service.enabled === false && service.activationEnabled === false
            && service.backend === null && service.backendError === "",
            "safe construction defaults");
        expectStatus("disabled", "explicit disabled state");
        check(service.reason === "Windows tray observation is disabled.", "disabled reason");
        check(!service.ready && service.count === 0 && service.list.length === 0
            && service.titles.length === 0 && service.ids.length === 0,
            "disabled observes nothing");
        check(service.lastError === "", "disabled has no error");
        check(service.interceptionEnabled === false, "interception is never enabled by this slice");
        check(service.menuMode === "native" && service.menuCoordinatesSupported === false
            && service.scrollSupported === false && service.scrollResult === "unsupported",
            "native-only menu and unsupported scroll policy");
        check(!service.semanticMenuAvailable, "disabled has no semantic menu");
        check(service.listResets === 0 && service.listGeneration === 0, "disabled has no list history");

        // Every command is refused and nothing is forwarded.
        check(!service.activate(spotify) && !service.secondaryActivate(spotify)
            && !service.openMenu(spotify, null, 1, 2) && !service.scroll(spotify, 120, false),
            "disabled refuses every command");
        check(spotify.activateCalls === 0 && spotify.secondaryCalls === 0
            && spotify.displayCalls === 0 && spotify.scrollCalls === 0,
            "disabled forwarded no native request");
        check(service.lastActivationResult === "refused" && service.lastActivationReason.length > 0,
            "disabled records the activation refusal");
        check(service.lastMenuResult === "refused" && service.lastMenuReason.length > 0,
            "disabled records the menu refusal");

        // --- Pure projections -------------------------------------------------
        check(service.itemId(null) === "" && service.itemTitle(null) === "",
            "null items project empty values");
        check(service.itemId(spotify) === "spotify" && service.itemTitle(spotify) === "Spotify",
            "item identity and title read");
        check(service.itemId({id: 4}) === "" && service.itemTitle({title: 7}) === "",
            "non-string identity and title are rejected");
        check(!service.isListed(spotify) && !service.hasMenu(spotify)
            && service.menuHandle(spotify) === null && !service.hasRenderableMenu(spotify),
            "unobserved items have no menu projection");

        // --- Initializing -----------------------------------------------------
        service.enabled = true;
        expectStatus("initializing", "enabled before the backend exists");
        check(service.reason === "Waiting for the Windows tray backend.", "initializing reason");
        check(!service.ready && service.lastError === "", "initializing is not ready and has no error");
        check(service.activationRefusal(spotify).indexOf("has not settled") >= 0,
            "initializing refuses activation");

        // A known component failure is an explicit unavailable state.
        service.backendError = "Fixture facade failed to load";
        expectStatus("unavailable", "known component failure");
        check(service.lastError === service.backendError
            && service.reason.indexOf(service.backendError) >= 0,
            "component failure is reported verbatim");
        check(!service.ready && service.list.length === 0, "failed backend observes nothing");
        service.backendError = "";

        // --- Backend shapes ---------------------------------------------------
        service.backend = {};
        expectStatus("unavailable", "backend without an item model is unavailable");
        check(service.lastError.indexOf("item model") >= 0, "missing model is named");
        service.backend = {items: null};
        expectStatus("unavailable", "backend with a null item model is unavailable");
        service.backend = {items: {values: null}};
        expectStatus("unavailable", "backend with null values is unavailable");

        // --- Empty observation ------------------------------------------------
        service.backend = fixture;
        fixture.items = model;
        setItems([]);
        expectStatus("not-observable", "no items without interception is not an observation");
        check(!service.ready && service.reason.indexOf("interception is disabled") >= 0,
            "not-observable is not ready and names the disabled interception");
        service.interceptionEnabled = true;
        expectStatus("empty", "healthy observation with no items");
        check(service.ready && service.count === 0 && service.lastError === "",
            "empty is ready without an error");
        check(service.reason.indexOf("no tray items") >= 0, "empty reason is distinct");
        check(!service.semanticMenuAvailable, "empty observation has no semantic menu");
        service.activationEnabled = true;
        check(service.activationRefusal(spotify).indexOf("no longer observed") >= 0,
            "an absent item is stale even while observation is ready");
        service.activationEnabled = false;
        service.interceptionEnabled = false;

        // --- Ready with observed items ---------------------------------------
        setItems([spotify, discord]);
        expectStatus("ready", "items arrive reactively");
        check(service.ready && service.count === 2, "ready count");
        check(service.list[0] === spotify && service.list[1] === discord, "model order is preserved");
        check(service.titles[0] === "Spotify" && service.titles[1] === "Discord", "titles project in order");
        check(service.ids[0] === "spotify" && service.ids[1] === "discord", "ids project in order");
        check(service.reason.indexOf("2 item") >= 0, "ready reason carries the count");

        // --- hasMenu=true with menu=null --------------------------------------
        check(spotify.hasMenu && service.hasMenu(spotify), "native hasMenu is reported");
        check(service.menuHandle(spotify) === null, "native menu handle is null");
        check(!service.hasRenderableMenu(spotify), "a null handle is not renderable");
        check(!service.semanticMenuAvailable, "no item exposes a semantic menu");
        check(service.menuMode === "native", "open menu routes to the native menu");

        // --- Activation refused without the opt-in ----------------------------
        service.activationEnabled = false;
        const refusedBefore = service.activationRefusals;
        check(!service.activate(spotify) && service.activate(spotify) === false,
            "activation is refused without the opt-in");
        check(!service.secondaryActivate(spotify), "secondary activation is refused without the opt-in");
        check(service.activationRefusals === refusedBefore + 3, "refusals are counted");
        check(service.lastActivationReason.indexOf("disabled by policy") >= 0,
            "refusal names the missing opt-in");
        check(spotify.activateCalls === 0 && spotify.secondaryCalls === 0,
            "refused activation forwarded nothing");
        check(!service.openMenu(spotify, null, 10, 20), "the native menu is refused without the opt-in");
        check(spotify.displayCalls === 0, "refused menu forwarded nothing");
        check(service.lastMenuReason.indexOf("disabled by policy") >= 0,
            "menu refusal names the missing opt-in");
        check(service.lastMenuCoordinates[0] === 10 && service.lastMenuCoordinates[1] === 20,
            "requested coordinates are recorded even when refused");

        // The opt-in cannot outlive observation.
        service.enabled = false;
        service.activationEnabled = true;
        expectStatus("disabled", "activation opt-in without observation is still disabled");
        check(!service.activate(spotify) && spotify.activateCalls === 0,
            "activation opt-in cannot outlive observation");
        check(service.lastActivationReason.indexOf("observation is disabled") >= 0,
            "disabled refusal is explicit");
        service.enabled = true;

        // --- Explicit activation ---------------------------------------------
        service.activationEnabled = true;
        setItems([spotify, discord]);
        expectStatus("ready", "observation is restored");
        check(service.activate(spotify), "activation is sent under the opt-in");
        check(spotify.activateCalls === 1, "activate() reached the item once");
        check(service.lastActivationAction === "activate" && service.lastActivationResult === "sent",
            "activation result records the action");
        check(service.lastActivationReason.indexOf("no per-action result") >= 0,
            "activation does not claim confirmation");
        check(service.secondaryActivate(discord), "secondary activation is sent");
        check(discord.secondaryCalls === 1, "secondaryActivate() reached the item once");
        check(service.activationRequests === 2, "permitted requests are counted");

        check(service.openMenu(spotify, null, 40.6, -12.2), "native menu is sent under the opt-in");
        check(spotify.displayCalls === 1, "display() reached the item once");
        check(spotify.lastDisplay.length === 3 && spotify.lastDisplay[0] === null
            && spotify.lastDisplay[1] === 41 && spotify.lastDisplay[2] === -12,
            "coordinates are rounded and a null parent window is forwarded");
        check(service.menuSent === 1 && service.lastMenuResult === "sent",
            "menu result is recorded");
        check(service.lastMenuReason.indexOf("ignores the requested coordinates") >= 0,
            "menu result records the ignored coordinates");
        check(service.lastMenuCoordinates[0] === 41 && service.lastMenuCoordinates[1] === -12,
            "rounded coordinates are recorded");
        check(!service.menuCoordinatesSupported, "coordinates remain unsupported");

        // Invalid coordinate input is clamped to zero rather than forwarded as NaN.
        check(service.openMenu(spotify, null, NaN, undefined), "invalid coordinates are still routed");
        check(spotify.lastDisplay[0] === null && spotify.lastDisplay[1] === 0
            && spotify.lastDisplay[2] === 0, "non-finite coordinates become zero");

        // Foreign and malformed items are refused.
        const foreign = {id: "foreign", hasMenu: true, activate: function () {} };
        const refusalsBefore = service.activationRefusals;
        const staleBefore = service.staleRequests;
        check(!service.activate(foreign), "an unobserved item cannot be activated");
        check(service.activationRefusals === refusalsBefore + 1, "foreign refusal is counted");
        check(service.staleRequests === staleBefore + 1, "a foreign item is counted as stale");
        check(service.lastActivationReason.indexOf("no longer observed") >= 0,
            "stale refusal is explicit");

        // --- Scroll is a silently consumed unsupported state ------------------
        const scrollBefore = service.scrollRequests;
        check(!service.scroll(spotify, 120, false) && !service.scroll(spotify, -120, true),
            "scroll reports unsupported");
        check(spotify.scrollCalls === 0, "scroll never reaches the backend stub");
        check(service.scrollRequests === scrollBefore + 2, "scroll attempts are counted");

        // --- Items without the expected command methods -----------------------
        const methodless = {id: "methodless", title: "No methods", hasMenu: false};
        setItems([methodless]);
        expectStatus("ready", "methodless item is observed");
        check(!service.activate(methodless), "an item without activate() is refused");
        check(service.lastActivationReason.indexOf("does not implement activate") >= 0,
            "missing activation method is named");
        check(!service.openMenu(methodless, null, 0, 0), "an item without display() is refused");
        check(service.lastMenuReason.indexOf("does not implement display") >= 0,
            "missing display method is named");
        check(!service.hasMenu(methodless) && !service.hasRenderableMenu(methodless),
            "an item without hasMenu has no menu");

        // --- Stale item removal ----------------------------------------------
        // Removal is only an observation while interception enumerates items;
        // without it an emptied list is not-observable rather than stale.
        service.interceptionEnabled = true;
        setItems([spotify, discord]);
        check(service.isListed(spotify), "item is observed before removal");
        setItems([]);
        check(!service.isListed(spotify), "removed item is no longer observed");
        const staleRemovalBefore = service.staleRequests;
        check(!service.openMenu(spotify, null, 5, 5), "a menu request for a removed item is refused");
        check(!service.activate(spotify), "an activation for a removed item is refused");
        check(service.staleRequests === staleRemovalBefore + 2, "removed-item requests count as stale");
        service.interceptionEnabled = false;
        check(service.lastMenuResult === "refused"
            && service.lastMenuReason.indexOf("no longer observed") >= 0,
            "stale menu refusal is explicit");
        check(spotify.displayCalls === 2 && spotify.activateCalls === 1,
            "stale requests sent nothing new");

        // A replaced item instance is not the observed object even with the same
        // identity strings, so it is refused until the model publishes it.
        const replacement = {id: "spotify", title: "Spotify", hasMenu: true,
            activate: function () { replacement.activateCalls++; }, activateCalls: 0,
            display: function () { replacement.displayCalls++; }, displayCalls: 0};
        setItems([replacement]);
        check(!service.isListed(spotify), "the old object instance is stale after replacement");
        check(!service.activate(spotify), "a stale instance cannot be activated");
        check(service.activate(replacement), "the published replacement is controllable");

        // --- A real handle is not hidden --------------------------------------
        const handle = {objectName: "fixture-menu"};
        const withMenu = {id: "menu-item", title: "Menu item", hasMenu: true, menu: handle};
        setItems([withMenu]);
        check(service.menuHandle(withMenu) === handle, "a future menu handle is exposed");
        check(service.hasRenderableMenu(withMenu), "a future handle is renderable");
        check(service.semanticMenuAvailable, "a future handle makes the semantic menu available");
        setItems([spotify]);

        // --- List reset observation -------------------------------------------
        setItems([]);
        setItems([spotify, discord]);
        setItems([bare]);
        const resetsBefore = service.listResets;
        setItems([]);
        check(service.listResets === resetsBefore + 1, "an emptied item list is a reset");
        check(service.lastResetKind === "empty" && service.lastResetPreviousCount === 1,
            "empty reset records its shape");
        const generationAfterEmpty = service.listGeneration;
        setItems([spotify, discord]);
        check(service.listGeneration === generationAfterEmpty, "repopulation alone is not a reset");
        const newA = {id: "new-a", title: "New A", hasMenu: false};
        const newB = {id: "new-b", title: "New B", hasMenu: false};
        setItems([newA, newB]);
        check(service.listResets === resetsBefore + 2, "a complete identity replacement is a reset");
        check(service.lastResetKind === "replaced" && service.lastResetPreviousCount === 2,
            "replacement reset records its shape");
        check(service.peakCount >= 2, "peak observation count is tracked");
        check(service.listGeneration === resetsBefore + 2, "generation advances with resets");

        // A partial change is not a reset and retains shared objects.
        setItems([newB, newA]);
        check(service.listResets === resetsBefore + 2, "reordering is not a reset");
        check(service.listGeneration === resetsBefore + 2, "reordering does not advance generation");

        // --- Disable clears every observation and command ---------------------
        service.enabled = false;
        expectStatus("disabled", "disable returns to disabled");
        check(!service.ready && service.list.length === 0 && service.count === 0
            && service.previousList.length === 0, "disable clears observed state");
        check(service.listResets === 0 && service.listGeneration === 0 && service.peakCount === 0
            && service.lastResetKind === "", "disable clears observation history");
        check(service.menuSent === 0 && service.menuRequests === 0
            && service.activationRequests === 0 && service.staleRequests === 0
            && service.scrollRequests === 0 && service.lastMenuResult === ""
            && service.lastActivationResult === "", "disable clears request accounting");
        check(service.activationEnabled, "the opt-in flag itself is preserved");
        check(!service.activate(spotify), "disabled observation cannot send activation");
        check(!service.openMenu(spotify, null, 0, 0), "disabled observation cannot open a menu");

        console.log("CAELESTIA_TRAY_FIXTURE_PASS " + JSON.stringify({assertions: assertions}));
        Qt.quit();
    }

    Component.onCompleted: Qt.callLater(() => {
        try {
            test.run();
        } catch (error) {
            console.error("CAELESTIA_TRAY_FIXTURE_FAIL " + error.message);
            Qt.exit(1);
        }
    })
}
