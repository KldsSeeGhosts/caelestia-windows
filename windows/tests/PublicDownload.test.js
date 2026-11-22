const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const {test} = require("node:test");

const releaseRoot = path.join(__dirname, "../release");
const script = fs.readFileSync(path.join(releaseRoot, "release-download.js"), "utf8");
const repo = "KldsSeeGhosts/caelestia-windows";
const github = `https://github.com/${repo}/releases`;
const metadata = JSON.parse(fs.readFileSync(path.join(releaseRoot, "update-trust.json"), "utf8"));
const version = "0.5.0";
const tag = `v${version}-development`;
const name = `caelestia-windows-${version}-windows-x64.zip`;
const url = `${github}/download/${tag}/${name}`;
const notes = `${github}/tag/${tag}`;
const sha256 = "a".repeat(64);

function pointer() {
    return {
        type: "caelestia-update-channel", schema: 1, repository: repo, channel: "development",
        expires: new Date(Date.now() + 60000).toISOString(),
        release: {releaseId: version, buildVersion: version, displayVersion: version, tag, notesUrl: notes,
            bundle: {name, url, sha256}}
    };
}

function envelope(value) {
    return {payloadType: "application/vnd.caelestia.update-channel+json",
        payload: Buffer.from(JSON.stringify(value)).toString("base64")};
}

async function resolve(fetch) {
    const context = vm.createContext({fetch, atob, AbortSignal});
    vm.runInContext(script, context);
    return await context.CaelestiaDownloads.current();
}

test("the website reads the same pointer as Nexus and displays the plain build number", async () => {
    const result = await resolve(async address => {
        assert.equal(address, metadata.metadataBase + "development.dsse.json");
        return {ok: true, json: async () => envelope(pointer())};
    });
    assert.deepEqual({...result}, {version, url, notes, sha256});
});

test("the website never offers another channel, a malformed pointer or an unapproved link", async () => {
    for (const mutate of [
        x => x.channel = "preview",
        x => x.repository = "example/injected",
        x => x.expires = "2001-01-01T00:00:00Z",
        x => x.release.displayVersion = "0.5.0-preview",
        x => x.release.bundle.url = "https://example.invalid/" + name,
        x => x.release.notesUrl += "?redirect=elsewhere",
        x => x.release.bundle.sha256 += "\n",
        x => x.release.bundle.sha256 = "unusable"
    ]) {
        const value = pointer();
        mutate(value);
        assert.equal(await resolve(async () => ({ok: true, json: async () => envelope(value)})), null);
    }
    assert.equal(await resolve(async () => ({ok: true, json: async () => ({...envelope(pointer()), payload: "a"})})), null);
    assert.equal(await resolve(async () => ({ok: false})), null);
    assert.equal(await resolve(async () => { throw new Error("offline"); }), null);
});
