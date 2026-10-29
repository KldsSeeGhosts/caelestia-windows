// Source/lifecycle regression checks for the Windows network pages. The native
// backend owns the scan timer; NetworkServiceTest.qml tests its visibility gate
// with an injected backend. These checks exercise the pages' actual handlers.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

const pages = ["NetworkPage.qml", "network/AllNetworksPage.qml"];
const directory = path.resolve(__dirname, "../combined-prototype/adapters/modules/nexus/pages");

for (const page of pages) {
    const source = fs.readFileSync(path.join(directory, page), "utf8").replace(/\r\n/g, "\n");

    test(`${page}: the backend is the only automatic scan scheduler`, () => {
        assert.doesNotMatch(source, /\b(?:rescanWifi|requestScan|scanWifiNetworks)\s*\(/,
            "page polling duplicates the native scan and overwrites command feedback");
    });

    test(`${page}: hidden construction and visibility handoff do not retain owners`, () => {
        const owners = new Set();
        const otherPage = {};
        const root = { visible: false };
        const context = vm.createContext({ root, Nmcli: {
            acquireListVisibility(owner) { owners.add(owner); },
            releaseListVisibility(owner) { owners.delete(owner); },
        } });
        const visibility = source.match(/function setVisibility\(visible: bool\): void \{([\s\S]*?)\n    \}/);
        assert.ok(visibility, "visibility handler exists");
        root.setVisibility = vm.runInContext(`(function (visible) {${visibility[1]}\n})`, context);
        const run = name => {
            const handler = source.match(new RegExp(`${name}: ([^\\n]+)`));
            assert.ok(handler, `${name} exists`);
            vm.runInContext(handler[1], context);
        };

        run("Component.onCompleted");
        assert.equal(owners.size, 0, "a page completed under a hidden parent must not scan");
        root.visible = true;
        run("onVisibleChanged");
        run("Component.onCompleted");
        assert.equal(owners.size, 1, "visible completion is idempotent");
        owners.add(otherPage);
        root.visible = false;
        run("onVisibleChanged");
        assert.deepEqual([...owners], [otherPage], "hiding releases only this page");
        root.visible = true;
        run("onVisibleChanged");
        run("Component.onDestruction");
        assert.deepEqual([...owners], [otherPage], "destruction releases only this page");
        owners.delete(otherPage);
        assert.equal(owners.size, 0, "no owner remains when both pages are gone");
    });
}
