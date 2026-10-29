const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

const repo = path.resolve(__dirname, "../..");
const read = file => fs.readFileSync(path.join(repo, file), "utf8");
const adapterRoot = "windows/combined-prototype/adapters/";
const content = read("modules/bar/popouts/AudioPopout.qml");
const adapter = read(`${adapterRoot}modules/bar/popouts/AudioPopout.qml`);
const wrapper = read(`${adapterRoot}modules/bar/popouts/Wrapper.qml`);

test("audio popout keeps the upstream settings action without an inline mixer", () => {
    assert.match(adapter, /settingsEnabled:\s*true/);
    assert.match(content, /visible:\s*root\.settingsEnabled/);
    assert.match(content, /onClicked:\s*root\.popouts\.detachRequested\("audio"\)/);
    assert.doesNotMatch(content, /property Component mixer|sourceComponent:\s*root\.mixer/);
    assert.doesNotMatch(adapter, /\bmixer\s*:|AudioMixer\s*\{/);

    const sources = JSON.parse(read("windows/combined-prototype/sources.d/bar.json"));
    assert.equal(sources["modules/bar/popouts/AudioPopout.qml"], "modules/bar/popouts/AudioPopoutContent.qml");
    assert.equal(Object.keys(sources).some(key => key.endsWith("/AudioMixer.qml")), false);
    assert.equal(fs.existsSync(path.join(repo, adapterRoot, "modules/bar/popouts/AudioMixer.qml")), false);
});

test("the existing Windows detach route opens Nexus Audio and closes the popout", () => {
    const pages = JSON.parse(wrapper.match(/detachedPages:\s*(\[[^\]]+\])/)[1]);
    const body = wrapper.match(/function detach\(mode: string\): void \{([\s\S]*?)\n    \}/)[1];
    const opened = [];
    const animations = [];
    const context = {
        root: { detachedPages: pages, hasCurrent: true },
        detachedMode: "audio",
        setAnims: value => animations.push(value),
        WindowFactory: { openPage: index => opened.push(index) },
    };
    vm.createContext(context);
    vm.runInContext(`function detach(mode) {${body}\n}\ndetach("audio");`, context);

    assert.equal(pages.indexOf("audio"), 3);
    assert.deepEqual(opened, [3]);
    assert.deepEqual(animations, [true, false]);
    assert.equal(context.root.hasCurrent, false);
    assert.equal(context.detachedMode, "");
});

test("Nexus retains upstream-style stream controls on its App volumes sub-page", () => {
    const page = read(`${adapterRoot}modules/nexus/pages/AudioPage.qml`);
    const volumes = read(`${adapterRoot}modules/nexus/pages/audio/AppVolumes.qml`);
    assert.match(page, /text:\s*Tr\.tr\("App volumes"\)/);
    assert.match(page, /onClicked:\s*root\.nState\.openSubPage\(1\)/);
    assert.match(volumes, /values:\s*\[\.\.\.Audio\.streams\]/);
    assert.match(volumes, /delegate:\s*SliderRow\s*\{/);
    assert.match(volumes, /readonly property bool controllable:\s*Audio\.canControl\(stream\.modelData\)/);
    assert.match(volumes, /onMoved:\s*v => Audio\.setStreamVolume\(stream\.modelData, v\)/);
});
