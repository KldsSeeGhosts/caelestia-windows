const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const test = require("node:test");

const read = relative => fs.readFileSync(path.resolve(__dirname, relative), "utf8");
const loadQmlScript = (relative, context) => {
    const source = read(relative)
        .replace(/^\s*\.(?:pragma library|import[^\r\n]*)\s*$/gm, "");
    vm.runInContext(source, context, { filename: relative });
};

const context = vm.createContext({});
loadQmlScript("../shell/adapters/utils/FileUrls.js", context);
context.FileUrls = {
    isFileUrl: context.isFileUrl,
    encodePathSegments: context.encodePathSegments,
    fromLocalPath: context.fromLocalPath,
    fromPathOrUrl: context.fromPathOrUrl,
    toLocalPath: context.toLocalPath
};
loadQmlScript("../services/clipboard/ClipboardHistory.js", context);

const urls = context.FileUrls;

test("ordinary drive paths retain their normal file URL spelling", () => {
    assert.equal(urls.fromLocalPath("C:\\Pictures\\photo.png"), "file:///C:/Pictures/photo.png");
    assert.equal(urls.toLocalPath("file:///C:/Pictures/photo.png"), "C:/Pictures/photo.png");
});

test("raw reserved characters are escaped per path segment and round-trip exactly", () => {
    const cases = [
        ["C:/Pictures/photo#draft.png", "file:///C:/Pictures/photo%23draft.png"],
        ["C:/Pictures/100% complete.png", "file:///C:/Pictures/100%25%20complete.png"],
        ["C:/Pictures/photo draft.png", "file:///C:/Pictures/photo%20draft.png"],
        ["C:/Pictures/été 雪.png", "file:///C:/Pictures/%C3%A9t%C3%A9%20%E9%9B%AA.png"],
        ["C:/Pictures/q?uery#part%.png", "file:///C:/Pictures/q%3Fuery%23part%25.png"]
    ];
    for (const [localPath, fileUrl] of cases) {
        assert.equal(urls.fromLocalPath(localPath), fileUrl);
        assert.equal(urls.toLocalPath(fileUrl), localPath);
    }
});

test("UNC share roots and reserved characters retain host and share boundaries", () => {
    const localPath = "\\\\server\\share\\photo#draft %.png";
    const fileUrl = "file://server/share/photo%23draft%20%25.png";
    assert.equal(urls.fromLocalPath(localPath), fileUrl);
    assert.equal(urls.toLocalPath(fileUrl), "//server/share/photo#draft %.png");
    assert.equal(urls.fromLocalPath("//server"), "");
});

test("already-encoded URLs are preserved and decoded exactly once", () => {
    const fileUrl = "file:///C:/Pictures/literal%2523.png";
    assert.equal(urls.fromPathOrUrl(fileUrl), fileUrl);
    assert.equal(urls.toLocalPath(fileUrl), "C:/Pictures/literal%23.png");
    assert.equal(urls.fromPathOrUrl(urls.toLocalPath(fileUrl)), fileUrl);
    assert.equal(urls.toLocalPath("file://localhost/C:/Pictures/photo%23draft.png"),
        "C:/Pictures/photo#draft.png");
});

test("unsupported and malformed inputs fail closed", () => {
    assert.equal(urls.fromLocalPath("relative/photo.png"), "");
    assert.equal(urls.fromPathOrUrl("https://example.test/photo.png"), "");
    assert.equal(urls.fromPathOrUrl("file:///C:/Pictures/photo%ZZ.png"), "");
    assert.equal(urls.toLocalPath("file:///C:/Pictures/photo#draft.png"), "");
    assert.equal(urls.toLocalPath("file://server/"), "");
});

test("clipboard rows use the shared URL and decode helpers for file previews", () => {
    const localPath = "C:/Pictures/photo#draft.png";
    const fileUrl = urls.fromLocalPath(localPath);
    assert.equal(context.decodeFileUri(fileUrl), localPath);
    assert.equal(context.fileUrl(localPath), fileUrl);
    assert.equal(context.fileUrl(fileUrl), fileUrl);
    const rows = context.displayRows([
        { id: "synthetic-file", kind: "text", text: fileUrl }
    ], "", 10);
    assert.equal(rows.length, 1);
    assert.equal(rows[0].path, localPath);
    assert.equal(rows[0].previewImage, fileUrl);
});

test("active leased QML path boundaries call the shared Paths converter", () => {
    assert.match(read("../shell/adapters/modules/dashboard/dash/User.qml"),
        /customPicture:\s*Paths\.absolutePath\(/);
    assert.match(read("../shell/adapters/modules/dashboard/Wrapper.qml"),
        /const target = Paths\.absolutePath\(/);
    assert.match(read("../shell/adapters/modules/nexus/pages/wallandstyle/WallpaperCategory.qml"),
        /Paths\.absolutePath\(String\(modelData\.preview\)\)/);
    assert.match(read("../shell/adapters/modules/nexus/pages/wallandstyle/WallpaperSelect.qml"),
        /Paths\.absolutePath\(String\(modelData\.preview\)\)/);
});
