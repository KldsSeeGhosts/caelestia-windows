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
