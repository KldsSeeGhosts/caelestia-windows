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
        "modules/launcher/Content.qml",
        "modules/launcher/items/WallpaperItem.qml"
    ]) {
        const source = read(base + file);
        assert.doesNotMatch(source, /(?:setWallpaper|setRandom|captureScreen)\([^\n]*, root\.QsWindow/,
            `${file} still scopes a pick to its window`);
        if (file.includes("nexus/"))
            assert.match(source, /Wallpapers\.setWallpaper\([^\n]*root\.nState\.wallpaperTarget/);
        else
            assert.match(source, /Wallpapers\.setWallpaper\([^\n]*Wallpapers\.defaultPickerTarget/);
    }
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
