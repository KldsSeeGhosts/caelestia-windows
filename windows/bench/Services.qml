import QtQuick
import Quickshell
import Quickshell.Io
import "stage/pure"
import "stage/quota/modules/quota/QuotaLogic.js" as QuotaLogic

// Only pure adapter classes are instantiated. No singleton wrapper, native
// backend, network request, account data, permission or desktop is accessed.
ShellRoot {
    id: root
    ElapsedTimer { id: clock }
    property var retained: []
    property real checksum: 0
    readonly property string area: Quickshell.env("CAELESTIA_BENCH_AREA")
    readonly property string plant: Quickshell.env("CAELESTIA_BENCH_PLANT")
    readonly property real plantPercent: Number(Quickshell.env("CAELESTIA_BENCH_PLANT_PERCENT") || "25")
    readonly property int stackPadDepth: 1 + Math.floor(Math.random() * 64)
    readonly property int heapPadBytes: 64 * (1 + Math.floor(Math.random() * 16384))
    property var heapPad: new Uint8Array(heapPadBytes).fill(1)
    readonly property var plans: [
        {area: "audio", file: "pure/AudioService.qml", count: 500000},
        {area: "media", file: "pure/PlayersService.qml", count: 500000},
        {area: "tray", file: "pure/TrayService.qml", count: 500000},
        {area: "notifications", file: "pure/NotificationsService.qml", count: 5000},
        {area: "quota", file: "", count: 50000}
    ]

    function run(plan): var {
        let service = null;
        clock.restart();
        if (plant === "Qml") {
            // Disposable sensitivity probe: additional load-path CPU work.
            const until = Date.now() + 20;
            while (Date.now() < until) {}
        }
        if (plan.file) {
            const component = Qt.createComponent(Qt.resolvedUrl("stage/" + plan.file), Component.PreferSynchronous);
            if (component.status !== Component.Ready)
                throw new Error(component.errorString());
            service = component.createObject(root);
            if (!service)
                throw new Error("Adapter did not instantiate");
            retained.push(component, service);
        }
        const compileMs = clock.elapsed() * 1000;
        const nodes = Array.from({length: 32}, (_, i) => ({
            ready: true, isStream: false, isSink: true, name: "synthetic-" + i,
            audio: {stateAvailable: true, volume: .5, muted: false}
        }));
        if (plan.area === "audio") {
            service.enabled = true;
            service.backend = {ready: true, nodes: {values: nodes}, defaultAudioSink: nodes[0]};
        }
        const player = {identity: "Synthetic player", trackArtUrl: "image://icon/media"};
        const trayItem = {id: "synthetic", title: "Synthetic tray"};
        const accounts = Array.from({length: 32}, (_, i) => ({
            provider: "synthetic", accountLabel: "synthetic-" + i,
            limits: [{title: "5-hour", percent: (i % 10) / 10}, {title: "Weekly", percent: .5}]
        }));
        const body = "Synthetic **notification** with ![untrusted image](https://example.invalid/a.png) and plain text.";
        function operation(i) {
            if (plan.area === "audio")
                return service.getStreamVolume(nodes[i % nodes.length]);
            if (plan.area === "media")
                return service.getIdentity(player).length + service.getArtUrl(player).length;
            if (plan.area === "tray")
                return service.itemTitle(trayItem).length;
            if (plan.area === "notifications")
                return service.sanitizeBody(body).length;
            const windows = QuotaLogic.orderedWindows(QuotaLogic.primaryWindows(accounts[i % accounts.length]));
            return windows.reduce((sum, limit) => sum + QuotaLogic.remaining(limit), 0);
        }
        // Real calls warm the QV4 code and object projections before timing.
        // No sleep or timing offset stands in for this workload.
        for (let i = 0; i < plan.count; ++i)
            checksum += operation(i);
        const before = checksum;
        const count = plan.count + (plant === plan.area ? Math.round(plan.count * plantPercent / 100) : 0);
        clock.restart();
        for (let i = 0; i < count; ++i)
            checksum += operation(i);
        const elapsedMs = clock.elapsed() * 1000;
        if (!(elapsedMs > 0) || !(checksum > before))
            throw new Error("No confirmed adapter work");
        return {area: plan.area, metric: plan.area === "quota" ? "quota.windowProjectionNs" : plan.area + ".nanosecondsPerOperation",
                compileMs: compileMs, elapsedMs: elapsedMs,
                stackPadDepth: stackPadDepth, heapPadBytes: heapPad.length,
                plantPercent: plant === plan.area ? plantPercent : 0,
                operations: plan.count, warmupOperations: plan.count, actualOperations: count, checksum: checksum - before,
                nanosecondsPerOperation: elapsedMs * 1000000 / plan.count};
    }

    function runWithStackPad(depth, selected): var {
        // Keep random QV4 stack frames and heap allocation alive while probing.
        if (!depth)
            return selected.map(p => run(p));
        const result = runWithStackPad(depth - 1, selected);
        // A live use after recursion prevents tail-call frame elimination.
        checksum += depth;
        return result;
    }
    Component.onCompleted: Qt.callLater(function() {
        try {
            // Force the padding binding before any component load or timer.
            retained.push(heapPad);
            const selected = plans.filter(p => area === "providers" || p.area === area);
            const results = runWithStackPad(stackPadDepth, selected);
            if (!results.length)
                throw new Error("No provider selected");
            console.log("CAELESTIA_SERVICE_BENCH " + JSON.stringify(results));
            Qt.quit();
        } catch (error) {
            console.error("CAELESTIA_SERVICE_BENCH_FAILED " + error);
            Qt.quit();
        }
    })
}
