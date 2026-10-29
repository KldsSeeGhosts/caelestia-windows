// Runs the real VramMeter.js and the real Gpu facade expressions in a vm with
// fake backend data. This is not a render or live-hardware check.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const test = require("node:test");
const repo = path.resolve(__dirname, "../..");
const read = file => fs.readFileSync(path.join(repo, file), "utf8").replace(/\r\n/g, "\n");
const GIB = 1024 ** 3;
const gpuFacade = "windows/combined-prototype/adapters/imports/Caelestia/Services/Gpu.qml";
const heroCard = "windows/combined-prototype/adapters/modules/dashboard/performance/HeroCard.qml";

const meter = {};
// The QML-only ".pragma library" line is the one thing Node cannot parse.
vm.runInNewContext(
    read("windows/combined-prototype/adapters/modules/dashboard/performance/VramMeter.js")
        .replace(/^\.pragma library\r?$/m, ""), meter);
const evaluate = (used, total) => JSON.parse(JSON.stringify(meter.evaluate(used, total)));

// Builds the facade's readonly properties from the QML source, so the test
// follows the shipped expressions. A real property is NaN when it is missing.
function facade(monitor) {
    const context = vm.createContext({ SystemMonitor: monitor });
    const object = {};
    for (const [, type, name, expression] of read(gpuFacade)
        .matchAll(/^\s*readonly property (\w+) (\w+): (.+)$/gm)) {
        Object.defineProperty(context, name, {
            get: () => vm.runInContext(expression, context),
        });
        Object.defineProperty(object, name, {
            get: () => {
                const value = vm.runInContext(expression, context);
                return type === "real" ? (value === null || value === undefined ? NaN : Number(value)) : value;
            },
        });
    }
    return object;
}

test("zero used is a real empty meter", () => {
    assert.deepEqual(evaluate(0, 8 * GIB), { valid: true, ratio: 0, usedBytes: 0, totalBytes: 8 * GIB });
});

test("partial and full usage fill the bar in proportion", () => {
    assert.equal(evaluate(2 * GIB, 8 * GIB).ratio, 0.25);
    const full = evaluate(8 * GIB, 8 * GIB);
    assert.equal(full.ratio, 1);
    assert.equal(full.valid, true);
});

test("overflow clamps the bar only and keeps the true figures", () => {
    const over = evaluate(9 * GIB, 8 * GIB);
    assert.equal(over.valid, true);
    assert.equal(over.ratio, 1);
    assert.equal(over.usedBytes, 9 * GIB);
    assert.equal(over.totalBytes, 8 * GIB);
});

test("missing, null, negative, non-finite and zero-total data is rejected", () => {
    const rejected = [
        [undefined, 8 * GIB], [0, undefined], [null, 8 * GIB], [0, null],
        [NaN, 8 * GIB], [0, NaN], [Infinity, 8 * GIB], [0, Infinity], [-Infinity, 8 * GIB],
        [-1, 8 * GIB], [0, -1], [0, 0], [4 * GIB, 0],
        ["4", 8 * GIB], [4 * GIB, "8"], [{}, 8 * GIB],
    ];
    for (const [used, total] of rejected) {
        const result = evaluate(used, total);
        assert.equal(result.valid, false, `${String(used)} / ${String(total)}`);
        assert.equal(result.ratio, 0, "no fabricated fill");
    }
});

test("VRAM comes from the same adapter as the name and usage", () => {
    const first = { name: "Primary", usage: 0.4, temperature: 51, vramUsed: 3 * GIB, vramTotal: 24 * GIB, sharedUsed: 7 * GIB };
    const second = { name: "Other", usage: 0.9, temperature: 80, vramUsed: 1 * GIB, vramTotal: 4 * GIB };
    const gpu = facade({ ready: true, gpus: [first, second] });
    assert.equal(gpu.name, "Primary");
    assert.equal(gpu.percentage, 0.4);
    assert.equal(gpu.vramUsed, 3 * GIB);
    assert.equal(gpu.vramTotal, 24 * GIB);
    // Shared system memory is a separate counter and is never added.
    assert.notEqual(gpu.vramUsed, first.vramUsed + first.sharedUsed);
});

test("the facade never reads shared memory", () => {
    const code = read(gpuFacade).replace(/^\s*\/\/.*$/gm, "");
    assert.doesNotMatch(code, /sharedUsed/);
});

test("the facade reports NaN, not zero, when the adapter or a counter is missing", () => {
    const none = facade({ ready: true, gpus: [] });
    assert.ok(Number.isNaN(none.vramUsed) && Number.isNaN(none.vramTotal));
    const bare = facade({ ready: true, gpus: [{ name: "No counters" }] });
    assert.ok(Number.isNaN(bare.vramUsed) && Number.isNaN(bare.vramTotal));
    const nulled = facade({ ready: true, gpus: [{ name: "Null", vramUsed: null, vramTotal: null }] });
    assert.ok(Number.isNaN(nulled.vramUsed) && Number.isNaN(nulled.vramTotal));
    // The NaN the backend reports without a counter reaches the meter as invalid.
    assert.equal(evaluate(none.vramUsed, none.vramTotal).valid, false);
    assert.equal(evaluate(facade({ ready: true, gpus: [{ vramUsed: 0, vramTotal: 8 * GIB }] }).vramUsed, 8 * GIB).valid, true);
});

test("backend byte semantics: dedicated usage and DXGI dedicated total", () => {
    const source = read("windows/deps/quickshell/src/windows/system/system_monitor.cpp");
    assert.match(source, /gpu\.vramTotal = static_cast<qint64>\(desc\.DedicatedVideoMemory\)/);
    assert.match(source, /insert\(QStringLiteral\("vramUsed"\), memoryValue\(dedicated, this->gpuDedicated\)\)/);
    assert.match(source, /insert\(QStringLiteral\("sharedUsed"\), memoryValue\(shared, this->gpuShared\)\)/);
});

test("only the GPU card is wired to the meter, and Linux still loads", () => {
    const performance = read("modules/dashboard/Performance.qml");
    const gpuCard = performance.match(/id: gpuCard[\s\S]*?sourceComponent: HeroCard \{([\s\S]*?)\n                    \}\n/);
    const cpuCard = performance.match(/id: cpuCard[\s\S]*?sourceComponent: HeroCard \{([\s\S]*?)\n                    \}\n/);
    assert.ok(gpuCard && cpuCard);
    assert.match(gpuCard[1], /memorySource: Gpu\b/);
    assert.doesNotMatch(cpuCard[1], /memorySource/);
    // The shared upstream card accepts the property without drawing anything.
    assert.match(read("modules/dashboard/performance/HeroCard.qml"), /property var memorySource: null/);
    assert.doesNotMatch(read("modules/dashboard/performance/HeroCard.qml"), /vramUsed|vramTotal|memory_alt/);
});

test("the Windows card shows used / total GiB, an Unavailable state and the temperature bar style", () => {
    const card = read(heroCard);
    assert.match(card, /import "VramMeter\.js" as Vram/);
    assert.match(card, /Vram\.evaluate\(memorySource\.vramUsed, memorySource\.vramTotal\)/);
    assert.match(card, /Units\.formatKibUsage\(root\.vram\.usedBytes \/ 1024, root\.vram\.totalBytes \/ 1024\)/);
    assert.match(card, /root\.vram\?\.valid \? Units\.formatKibUsage[^\n]*: Tr\.tr\("Unavailable"\)/);
    const bars = [...card.matchAll(/StyledProgressBar \{([\s\S]*?)\n        \}/g)].map(match => match[1]);
    assert.equal(bars.length, 2);
    const [temperature, memory] = bars;
    for (const property of ["implicitHeight: Tokens.padding.small", "fgColour: root.accent"]) {
        assert.ok(temperature.includes(property) && memory.includes(property), property);
    }
    assert.match(memory, /visible: root\.vram\?\.valid \?\? false/);
    assert.match(memory, /value: root\.vram\?\.ratio \?\? 0/);
    const manifest = JSON.parse(read("windows/combined-prototype/sources.d/dashboard.json"));
    assert.equal(
        manifest["windows/combined-prototype/adapters/modules/dashboard/performance/VramMeter.js"],
        "modules/dashboard/performance/VramMeter.js");
});
