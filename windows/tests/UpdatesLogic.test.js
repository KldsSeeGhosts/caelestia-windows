const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const {test} = require("node:test");
const logic = vm.createContext({});
vm.runInContext(fs.readFileSync(path.join(__dirname,
    "../shell/adapters/modules/nexus/pages/UpdatesLogic.js"), "utf8"), logic);
const manual = "https://github.com/KldsSeeGhosts/caelestia-windows/releases";

test("current status separates manual destination, unknown latest and retained rollback", () => {
    const current = logic.parseStatus(0, JSON.stringify({schema: 1, versioned: true,
        current: "current-fixture", sourceRevision: "abc123", previous: "retained-fixture",
        previousRevision: "def456", canRollback: true, manualReleaseUrl: manual,
        automaticUpdatesAvailable: false, remoteVersionChecked: false, latestVersion: null}));
    assert.equal(current.current, "current-fixture");
    assert.equal(current.sourceRevision, "abc123");
    assert.equal(current.previousRevision, "def456");
    assert.equal(current.canRollback, true);
    assert.equal(current.manualReleaseUrl, manual);
    assert.equal(current.automaticUpdatesAvailable, false);
    assert.equal(current.remoteVersionChecked, false);
    assert.equal(current.latestVersion, null);
});
test("current status without a retained version cannot offer rollback", () => {
    for (const value of [{versioned: true, previous: "", canRollback: true},
        {versioned: true, previous: "old", canRollback: false},
        {versioned: false, previous: "old", canRollback: true}]) {
        assert.equal(logic.normalize(value).canRollback, false);
    }
});
test("legacy and partial objects retain a useful manual destination", () => {
    for (const value of [null, {}, {schema: 1}, {schema: 1, downloadChannelAvailable: false},
        {current: 1, previous: {}, canRollback: "true"}]) {
        const result = logic.normalize(value);
        assert.equal(result.manualReleaseUrl, manual);
        assert.equal(result.canRollback, false);
        assert.equal(result.latestVersion, null);
        assert.equal(result.automaticUpdatesAvailable, false);
    }
    assert.equal(logic.parseStatus(0, '{"schema":1}').manualReleaseUrl, manual);
});
test("unavailable, invalid and unsupported status commands do not invent a release result", () => {
    for (const [code, output] of [[1, '{"schema":1}'], [0, ""], [0, "not json"],
        [0, '{"schema":2}'], [0, "null"], [0, "{}"]]) {
        assert.equal(logic.parseStatus(code, output), null);
    }
    assert.equal(logic.normalize(null).manualReleaseUrl, manual);
});
test("legacy releasesUrl is supported but arbitrary or executable links are refused", () => {
    const preview = manual + "/tag/v0.1.0-preview.2";
    assert.equal(logic.normalize({releasesUrl: preview}).manualReleaseUrl, preview);
    for (const url of ["javascript:alert(1)", manual + ".evil", manual + "/tag/../settings",
        "https://example.invalid/releases", manual + "?redirect=elsewhere"]) {
        assert.equal(logic.normalize({manualReleaseUrl: url}).manualReleaseUrl, manual);
    }
});
test("a download link or claimed future capability is not proof of an implemented updater", () => {
    const status = logic.normalize({latestVersion: "new", remoteVersionChecked: true,
        automaticUpdatesAvailable: true, downloadChannelAvailable: true, releasesUrl: manual});
    assert.equal(status.latestVersion, null);
    assert.equal(status.remoteVersionChecked, false);
    assert.equal(status.automaticUpdatesAvailable, false);
});
test("configured capability is explicit; channel and build identities remain separate", () => {
    const result = logic.normalize({updatesConfigured: true, automaticUpdatesAvailable: true,
        channel: "stable", releaseVersion: "1.0.0-dev.1.5.1", displayVersion: "1.0.0"});
    assert.equal(result.automaticUpdatesAvailable, true);
    assert.equal(result.channel, "stable");
    assert.equal(result.releaseVersion, "1.0.0-dev.1.5.1");
    assert.equal(result.displayVersion, "1.0.0");
    assert.equal(result.remoteVersionChecked, false);
    assert.equal(logic.normalize({channel: "evil"}).channel, "preview");
});
test("checks validate states, identities, bounds and release links", () => {
    const available = {buildVersion: "0.2.0-dev.1.57.1", displayVersion: "0.2.0-preview.1",
        bundle: {size: 1024}, notesUrl: "javascript:alert(1)"};
    const data = {schema: 1, state: "available", channel: "preview", available};
    assert.equal(logic.parseCheck(0, JSON.stringify(data)).available.notesUrl, manual);
    for (const state of ["not-newer", "not-configured", "offline", "http", "too-large",
        "bad-signature", "bad-metadata", "expired", "clock", "replay", "unsupported", "busy"]) {
        const result = logic.parseCheck(0, JSON.stringify({...data, state}));
        assert.equal(result.state, state);
        assert.equal(result.available, null);
        assert.equal(typeof logic.checkLabel(state), "string");
    }
    for (const mutation of [
        {...data, state: "invented"}, {...data, channel: "arbitrary"}, {...data, schema: 2},
        {...data, available: {...available, buildVersion: "0.2.0-dev.01.57.1"}},
        {...data, available: {...available, bundle: {size: 0}}},
        {...data, available: {...available, bundle: {size: 1073741825}}}
    ]) assert.equal(logic.parseCheck(0, JSON.stringify(mutation)), null);
    assert.equal(logic.parseCheck(1, JSON.stringify(data)), null);
});

test("friendly versions are presentation only and share one formatter", () => {
    for (const [input, expected] of [
        ["0.2.0-dev.1.283.1", "0.2.0 · Dev build 283"],
        ["0.2.0-dev.2.283.4", "0.2.0 · Dev build 283"],
        ["0.2.0-preview.3", "0.2.0 · Preview 3"],
        ["1.0.0-rc.2", "1.0.0 · RC 2"],
        ["1.0.0", "1.0.0"], ["retained-fixture", "retained-fixture"],
        ["", "Unknown"], [null, "Unknown"]
    ]) assert.equal(logic.formatVersion(input), expected);
    const version = "0.2.0-dev.1.283.1";
    const status = logic.normalize({current: version, releaseVersion: version,
        displayVersion: version, previousDisplayVersion: "0.2.0-preview.1"});
    logic.formatVersion(status.displayVersion);
    assert.equal(status.current, version);
    assert.equal(status.releaseVersion, version);
    assert.equal(status.previousDisplayVersion, "0.2.0-preview.1");
});

test("one primary action maps every maintenance and check state", () => {
    const available = {displayVersion: "0.2.0-dev.1.283.1"};
    assert.equal(logic.primaryState({}).label, "Check for updates");
    const update = logic.primaryState({available});
    assert.equal(update.label, "Update now");
    assert.equal(update.action, "update");
    assert.equal(update.disabled, false);
    assert.equal(update.status, "Update available: 0.2.0 · Dev build 283");
    assert.equal(logic.primaryState({result: {state: "not-newer"}}).status, "Up to date");
    for (const step of ["checking", "downloading", "verifying", "installing", "restarting", ""]) {
        const running = logic.primaryState({operationState: "waiting", operationKind: "update", step, available});
        assert.equal(running.disabled, true);
        assert.match(running.status, /…$/);
        assert.equal(running.label, running.status);
    }
    for (const operationState of ["unconfirmed", "complete"])
        assert.equal(logic.primaryState({operationState, available}).disabled, true);
    assert.match(logic.primaryState({operationState: "failed"}).status, /could not complete/);
    assert.equal(logic.primaryState({checking: true}).disabled, true);
    assert.equal(logic.primaryState({operationState: "failed", checking: true}).label, "Checking…");
    assert.equal(logic.primaryState({available, blocked: true}).disabled, true);
    assert.equal(logic.primaryState({operationState: "waiting", operationKind: "rollback"}).label, "Restarting…");
    for (const state of ["offline", "bad-signature", "expired", "clock", "replay", "bad-metadata", "unsupported", "busy", "not-configured"]) {
        const result = logic.primaryState({result: {state}});
        assert.equal(result.label, "Check for updates");
        assert.equal(result.status, logic.checkLabel(state));
        assert.notEqual(result.status, "Up to date");
    }
});

test("bridge accepts legacy and plain build identities without formatting them", () => {
    for (const buildVersion of ["0.2.0-dev.1.283.1", "0.3.0", "0.3.1", "1.0.0"]) {
        const available = {buildVersion, displayVersion: buildVersion, bundle: {size: 1}};
        const data = {schema: 1, state: "available", channel: "development", available};
        assert.equal(logic.parseCheck(0, JSON.stringify(data)).available.buildVersion, buildVersion);
        for (const invalid of ["0.03.0", "0.3.0+meta", "0.3.0-preview.1", "0.3.0\n", "0.2.0-dev.0.283.1"]) {
            assert.equal(logic.parseCheck(0, JSON.stringify({...data,
                available: {...available, buildVersion: invalid}})), null);
        }
    }
});
