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
