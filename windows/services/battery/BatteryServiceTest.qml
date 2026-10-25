pragma ComponentBehavior: Bound

import QtQuick

// Standalone fixture. Imports no Quickshell/native UPower/configuration module,
// reads no environment or hardware, and never constructs Battery.qml.
// Intended runner: powershell -NoProfile -File windows/scripts/Test-BatteryService.ps1 -QtPrefix <Windows Qt prefix>
// The runner uses Qt qml.exe offscreen with only this file and BatteryService.qml.
QtObject {
    id: test

    component FakeDevice: QtObject {
        property bool isAvailable: true
        property bool isPresenceKnown: true
        property bool isPresent: false
        property bool isLaptopBattery: false
        property bool isPercentageKnown: true
        // Untyped so guards can receive invalid native-shaped values; the
        // adapter, not the fixture, must reject them.
        property var percentage: 0
        property var state: 0
        property var timeToEmpty: 0
        property var iconName: ""
    }

    component FakeBackend: QtObject {
        property bool ready: false
        property bool onBattery: false
        property bool onBatteryKnown: true
        property var displayDevice: null
    }

    readonly property BatteryService service: BatteryService {}
    readonly property FakeBackend fixture: FakeBackend {}
    readonly property FakeDevice absent: FakeDevice {
        isPercentageKnown: false
    }
    readonly property FakeDevice unavailable: FakeDevice {
        isAvailable: false
        isPresenceKnown: false
        isPercentageKnown: false
        // Stale-shaped values: the adapter must not project any of them.
        percentage: 0.77
        state: 1
        timeToEmpty: 900
        iconName: "battery-good-charging-symbolic"
    }
    readonly property FakeDevice unknownPresence: FakeDevice {
        isPresenceKnown: false
        isPercentageKnown: false
        percentage: 0.5
    }
    readonly property FakeDevice battery: FakeDevice {
        isPresent: true
        isLaptopBattery: true
        percentage: 0.63
        state: 2
        timeToEmpty: 5400
        iconName: "battery-good-symbolic"
    }
    readonly property FakeDevice replacement: FakeDevice {
        isPresent: true
        isLaptopBattery: true
        percentage: 0.12
        state: 1
        iconName: "battery-good-charging-symbolic"
    }

    property int assertions: 0

    function check(condition, message): void {
        assertions++;
        if (!condition)
            throw new Error(message);
    }

    function close(actual, expected, message): void {
        check(Math.abs(actual - expected) < 0.000001, message + ": " + actual + " != " + expected);
    }

    function run(): void {
        check(service.enabled === false && service.backend === null && service.backendError === "",
            "safe construction defaults");
        check(service.status === "disabled" && service.reason.length > 0, "explicit disabled state");
        check(!service.backendReady && service.displayDevice === null, "disabled has no device");
        check(!service.nativeReadAvailable && !service.presenceKnown && !service.observationAvailable,
            "disabled has no observation capability");
        check(!service.present && !service.absent && !service.laptopBattery && !service.hasBattery,
            "disabled absence");
        check(!service.percentageKnown && !service.onBatteryKnown, "disabled capabilities");
        close(service.percentage, 0, "disabled percentage");
        check(service.state === 0 && !service.charging, "disabled state and charging");
        close(service.timeToEmpty, 0, "disabled time estimate");
        check(service.iconName === "" && !service.onBattery && !service.ready, "disabled remaining projections");

        // The adapter is read-only by construction: introspect its members and
        // require that no mutating name exists at all.
        const members = Object.keys(service).concat(Object.getOwnPropertyNames(service));
        check(members.length > 0, "introspection enumerates adapter members");
        const mutating = members.filter(key =>
            /^(set|select|apply|write|cycle|request|toggle|increment|decrement)/i.test(key));
        check(mutating.length === 0, "adapter exposes no write methods: " + JSON.stringify(mutating));
        check(service.setProfile === undefined && service.setPercentage === undefined
            && service.selectProfile === undefined && service.writePlan === undefined
            && service.setCharging === undefined && service.setIdleSettings === undefined,
            "no known mutation entry point exists");

        service.enabled = true;
        check(service.status === "initializing" && service.reason.length > 0, "backend loading state");
        check(!service.backendReady && service.displayDevice === null, "initializing has no device");
        check(!service.nativeReadAvailable && !service.observationAvailable, "initializing observation");
        service.backendError = "Fixture component initialization failed";
        check(service.status === "unavailable" && service.reason === service.backendError, "known initialization failure");
        check(!service.present && !service.absent && !service.hasBattery && !service.onBattery,
            "failed load reports no observation");
        service.backendError = "";

        service.backend = fixture;
        check(service.status === "unavailable" && !service.backendReady && service.reason.indexOf("not ready") >= 0,
            "unready backend is honest");
        check(service.displayDevice === null && !service.hasBattery, "unready backend has no device");

        // A ready backend without a usable display device must not invent one.
        fixture.ready = true;
        check(service.status === "unavailable" && service.backendReady, "ready backend with no device is unavailable");
        check(service.displayDevice === null && !service.nativeReadAvailable
            && !service.observationAvailable && !service.present && !service.absent && !service.hasBattery,
            "missing device stays unobserved");
        close(service.percentage, 0, "missing device reads no percentage");
        check(service.state === 0 && !service.charging && service.iconName === "", "missing device reads unknown state");
        close(service.timeToEmpty, 0, "missing device reads no time estimate");
        check(service.onBattery === false && service.onBatteryKnown === false,
            "missing device cannot claim a battery source");

        // A failed native read is unavailable, not proven absence, and stale
        // native values must not be projected.
        fixture.displayDevice = unavailable;
        fixture.onBattery = true;
        fixture.onBatteryKnown = false;
        check(service.status === "unavailable" && !service.nativeReadAvailable
            && !service.presenceKnown && !service.observationAvailable,
            "failed native read is unavailable");
        check(!service.present && !service.absent && !service.hasBattery,
            "failed native read is not proven absence");
        check(!service.percentageKnown && service.percentage === 0, "failed read clears stale percentage");
        check(service.state === 0 && !service.charging && service.timeToEmpty === 0
            && service.iconName === "", "failed read clears stale projections");
        check(!service.onBatteryKnown && !service.onBattery, "stale onBattery is rejected on failed read");
        check(service.reason.indexOf("could not be read") >= 0, "failed read reason");

        // A successful read with the Win32 "unknown" battery flag cannot prove
        // presence either, though the AC source itself remains known.
        fixture.displayDevice = unknownPresence;
        fixture.onBatteryKnown = true;
        check(service.status === "unavailable" && service.nativeReadAvailable
            && !service.presenceKnown && !service.observationAvailable,
            "unknown presence is unavailable");
        check(!service.present && !service.absent && !service.hasBattery, "unknown presence is not absence");
        check(service.percentage === 0 && !service.percentageKnown, "unknown presence has no level");
        check(service.onBatteryKnown, "AC source remains observable with unknown presence");
        check(service.reason.indexOf("unknown battery presence") >= 0, "unknown presence reason");
        fixture.onBattery = false;

        // A successful read that proves no battery is a distinct ready state.
        fixture.displayDevice = absent;
        check(service.status === "ready" && service.nativeReadAvailable
            && service.presenceKnown && service.observationAvailable,
            "proven absence is ready");
        check(!service.present && service.absent && !service.hasBattery, "proven absence is explicit");
        check(!service.percentageKnown && service.percentage === 0, "absent battery has no fake percentage");
        check(service.state === 0 && !service.charging, "absent battery state is unknown");
        close(service.timeToEmpty, 0, "absent battery has no time estimate");
        check(service.iconName === "" && !service.onBattery, "absent battery icon and source");
        check(service.reason.indexOf("No battery detected") >= 0, "absent battery reason");

        fixture.displayDevice = battery;
        fixture.onBattery = true;
        check(service.present && service.laptopBattery && service.hasBattery && !service.absent,
            "battery arrival is reactive");
        check(service.status === "ready" && service.observationAvailable, "battery arrival keeps ready status");
        check(service.percentageKnown, "known native percentage capability");
        close(service.percentage, 0.63, "native percentage read");
        check(service.state === 2 && !service.charging, "discharging state read");
        close(service.timeToEmpty, 5400, "native time estimate read");
        check(service.iconName === "battery-good-symbolic", "native icon read");
        check(service.onBatteryKnown && service.onBattery, "on-battery source read");

        battery.state = 1;
        check(service.state === 1 && service.charging, "charging state gates");
        check(service.onBattery, "charging while on battery is observed");
        fixture.onBattery = false;
        battery.state = 4;
        check(service.charging && !service.onBattery, "fully charged counts as charging without line power");
        battery.state = 5;
        check(service.charging, "pending charge counts as charging");
        battery.state = 2;
        check(!service.charging, "discharging is not charging");
        battery.state = 0;
        check(!service.charging && service.state === 0, "unknown state is not charging");
        battery.state = 3;
        check(!service.charging, "empty is not charging");
        battery.state = 6;
        check(!service.charging, "pending discharge is not charging");
        battery.state = 2;
        fixture.onBattery = true;

        // Win32 BATTERY_PERCENTAGE_UNKNOWN must stay unknown even when a prior
        // reading or a stale device object still carries a number.
        battery.isPercentageKnown = false;
        check(service.present && service.hasBattery && !service.percentageKnown,
            "unknown percentage keeps presence");
        check(service.percentage === 0, "unknown percentage never becomes zero percent");
        check(service.state === 2 && !service.charging, "state remains independent of level");
        battery.isPercentageKnown = true;
        close(service.percentage, 0.63, "known percentage restored");

        battery.percentage = 1;
        close(service.percentage, 1, "full percentage read");
        battery.percentage = 1.5;
        close(service.percentage, 1, "over-range percentage is bounded");
        battery.percentage = -0.2;
        close(service.percentage, 0, "negative percentage is bounded");
        for (const value of [NaN, Infinity, -Infinity, undefined, null, true, "0.5", {}]) {
            battery.percentage = value;
            close(service.percentage, 0, "invalid percentage " + String(value) + " reads zero");
        }
        battery.percentage = 0.63;

        for (const value of ["Charging", 7, -1, NaN, null, undefined]) {
            battery.state = value;
            check(service.state === 0 && !service.charging, "invalid state " + String(value) + " reads unknown");
        }
        battery.state = 2;

        for (const value of [NaN, Infinity, -Infinity, -5, "100", null, undefined]) {
            battery.timeToEmpty = value;
            close(service.timeToEmpty, 0, "invalid time estimate " + String(value) + " reads zero");
        }
        battery.timeToEmpty = 5400;

        for (const value of [null, undefined, 7, {}]) {
            battery.iconName = value;
            check(service.iconName === "", "invalid icon " + String(value) + " reads empty");
        }
        battery.iconName = "battery-good-symbolic";

        // Upstream gates all battery display on the battery-type check; a
        // present non-battery-type device must not display as a battery.
        battery.isLaptopBattery = false;
        check(service.present && !service.laptopBattery && !service.hasBattery, "non-battery-type device is not a battery");
        close(service.percentage, 0.63, "non-battery-type device still reports its guarded level");
        battery.isLaptopBattery = true;
        check(service.hasBattery, "battery-type restored");

        battery.isPresent = false;
        check(service.present === false && !service.hasBattery && service.absent, "device withdrawal is proven absence");
        close(service.percentage, 0, "withdrawn battery has no percentage");
        battery.isPresent = true;
        check(service.hasBattery && !service.absent, "battery re-arrival is reactive");
        close(service.percentage, 0.63, "re-arrival percentage");

        // A failed read on an otherwise present device clears every projection
        // instead of reusing the previous battery reading.
        battery.isAvailable = false;
        check(!service.nativeReadAvailable && !service.observationAvailable && !service.present
            && !service.absent && !service.hasBattery, "withdrawal of observation is not absence");
        check(service.percentage === 0 && !service.percentageKnown && service.state === 0
            && service.timeToEmpty === 0 && service.iconName === "",
            "failed read clears prior battery projections");
        battery.isAvailable = true;
        check(service.observationAvailable && service.hasBattery, "observation recovery restores battery");

        // A stale/replacement device object is observed, never remembered.
        fixture.displayDevice = replacement;
        check(service.displayDevice === replacement && service.hasBattery, "replacement device observed");
        close(service.percentage, 0.12, "replacement percentage read");
        check(service.charging && service.iconName === "battery-good-charging-symbolic", "replacement projections");

        fixture.ready = false;
        check(service.status === "unavailable" && service.displayDevice === null, "backend becomes unready");
        check(!service.present && !service.absent && !service.hasBattery && !service.onBattery,
            "unready backend clears projections");
        close(service.percentage, 0, "unready backend reads no percentage");
        fixture.ready = true;
        check(service.displayDevice === replacement, "backend recovery restores observation");

        service.backendError = "Fixture access denied";
        check(service.status === "unavailable" && service.reason === "Fixture access denied", "explicit denied fixture");
        check(service.displayDevice === null && !service.hasBattery && !service.absent, "denied adapter reports no observation");
        service.backendError = "";

        // Capability fields are required: an old-shaped device cannot be
        // assumed observable merely because it has a percentage.
        service.backend = { ready: true, onBattery: false, displayDevice: { isPresent: true, isLaptopBattery: true, percentage: 0.4, state: 2 } };
        check(service.status === "unavailable" && !service.nativeReadAvailable
            && !service.observationAvailable && !service.present && !service.absent,
            "missing capability fields are unavailable");
        check(service.percentage === 0 && !service.onBatteryKnown, "missing capabilities project no level or source");
        service.backend = {
            ready: true, onBattery: true, onBatteryKnown: true,
            displayDevice: {
                isAvailable: true, isPresenceKnown: true, isPresent: true,
                isLaptopBattery: true, isPercentageKnown: true,
                percentage: 0.4, state: 2
            }
        };
        check(service.status === "ready" && service.hasBattery, "explicit capability backend accepted");
        close(service.percentage, 0.4, "explicit backend percentage");
        check(!service.charging && service.onBatteryKnown && service.onBattery, "explicit backend projections");
        service.backend = { ready: false };
        check(service.status === "unavailable", "plain object without readiness is unavailable");
        service.backend = {};
        check(service.status === "unavailable" && service.displayDevice === null, "absent backend shape is unavailable");

        service.backend = fixture;
        service.enabled = false;
        check(service.status === "disabled" && !service.backendReady && service.displayDevice === null,
            "disable clears observed state");
        check(!service.hasBattery && service.percentage === 0 && !service.onBattery
            && !service.nativeReadAvailable && !service.observationAvailable, "disable clears battery projection");
        console.log("CAELESTIA_BATTERY_FIXTURE_PASS " + JSON.stringify({ assertions: assertions }));
        Qt.quit();
    }

    Component.onCompleted: Qt.callLater(() => {
        try {
            test.run();
        } catch (error) {
            console.error("CAELESTIA_BATTERY_FIXTURE_FAIL " + error.message);
            Qt.exit(1);
        }
    })
}
