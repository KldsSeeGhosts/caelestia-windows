const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { test } = require("node:test");
const repo = path.resolve(__dirname, "../..");
const read = file => fs.readFileSync(path.join(repo, file), "utf8");
const base = "windows/shell/adapters/";

test("Nexus and launcher picks do not infer a target from their window", () => {
    for (const file of [
        "modules/nexus/pages/wallandstyle/WallpaperSelect.qml",
        "modules/nexus/pages/wallandstyle/WallpaperCategory.qml",
    ]) {
        const source = read(base + file);
        assert.doesNotMatch(source, /(?:setWallpaper|setRandom|captureScreen)\([^\n]*, root\.QsWindow/,
            `${file} still scopes a pick to its window`);
        assert.match(source, /Wallpapers\.setWallpaper\([^\n]*root\.nState\.wallpaperTarget/);
    }
    const content = read(base + "modules/launcher/Content.qml");
    const list = read(base + "modules/launcher/WallpaperList.qml");
    const tile = read(base + "modules/launcher/items/WallpaperItem.qml");
    assert.match(content, /list\.currentList\?\.applyCurrent\(\)/);
    assert.match(list, /function applyCurrent\(\): void \{ apply\(highlightedEntry\); \}/);
    assert.match(tile, /onClicked: root\.clicked\(\)/);
    assert.match(list, /onClicked: root\.apply\(tile\.modelData\)/);
    assert.match(list, /Wallpapers\.setWallpaper\(entry\.path, Wallpapers\.defaultPickerTarget\(pickerScreen\)\)/);
    for (const source of [content, tile])
        assert.doesNotMatch(source, /Wallpapers\.setWallpaper\(/);
    assert.match(read(base + "modules/launcher/services/Actions.qml"),
        /Wallpapers\.choose\(Wallpapers\.defaultPickerTarget/);
});

test("Windows stages native Nexus display and engine controls with searchable routes", () => {
    const manifest = JSON.parse(read("windows/shell/sources.json"));
    const main = base + "modules/nexus/pages/WallpaperAndStyle.qml";
    assert.equal(manifest[main], "modules/nexus/pages/WallpaperAndStyle.qml");
    for (const component of ["WallpaperDisplays", "WallpaperEngineSettings"]) {
        assert.equal(manifest[base + `components/wallpaper/${component}.qml`],
            `components/wallpaper/${component}.qml`);
        assert.ok(read(main).includes(`${component} {`));
    }
    assert.doesNotMatch(read(base + "modules/nexus/pages/ServicesPage.qml"), /WallpaperEngine/);
    const registry = read(base + "modules/nexus/PageRegistry.qml");
    const appearance = registry.slice(registry.indexOf('label: Tr.tr("Wallpaper & style")'),
        registry.indexOf("// Connectivity"));
    assert.match(appearance, /label: Tr\.tr\("Wallpaper Engine"\)[^\n]*path: \[\]/);
    assert.match(appearance, /label: Tr\.tr\("Wallpaper displays"\)[^\n]*path: \[\]/);
});
