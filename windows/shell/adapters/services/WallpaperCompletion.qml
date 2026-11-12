import QtQuick
import Quickshell
import Quickshell.Windows as Native

// Desired shell images are independent of Windows completion. The backend
// reports operation/path/target, not a request id or worker generation.
// Serialize submissions and retain unanswered attempts so an identical late
// result can never be attributed to a newer request.
QtObject {
    id: root

    property var targets: ({})
    property int nextId: 0
    property var queue: []
    property var attempts: []
    property var active: null
    property var checks: []
    property int completionTimeout: 6500
    property var recoveryDelays: [300, 1500, 6500]
    signal outcomeChanged(int requestId, string outcome)

    function samePath(a, b): bool {
        return String(a).replace(/\\/g, "/").toLowerCase()
            === String(b).replace(/\\/g, "/").toLowerCase();
    }
    function publish(key, patch): void {
        targets = Object.assign({}, targets, {
            [key]: Object.assign({}, targets[key], patch)
        });
    }
    function currentKeys(job): var {
        return job.keys.filter(key => targets[key]?.requestId === job.id);
    }
    function status(screen): string {
        const id = screen ? Native.Wallpaper.screenTargetId(screen.name) : "";
        const states = screen ? [targets[id] || targets[""]].filter(Boolean) : Object.values(targets);
        if (!states.length)
            return "";
        for (const outcome of ["pending", "failed", "unknown"])
            if (states.some(state => state.outcome === outcome))
                return outcome;
        return "applied";
    }
    function announce(job): void {
        const states = Object.values(targets).filter(state => state.requestId === job.id);
        if (!states.length)
            return;
        const outcome = states.some(state => state.outcome === "pending") ? "pending"
            : states.some(state => state.outcome === "failed") ? "failed"
            : states.some(state => state.outcome === "unknown") ? "unknown" : "applied";
        outcomeChanged(job.id, outcome);
    }
    function request(path, target): bool {
        const names = {};
        if (target) {
            names[target.targetId] = target.name;
        } else {
            for (const screen of Quickshell.screens) {
                const key = Native.Wallpaper.screenTargetId(screen.name);
                if (key)
                    names[key] = screen.name;
            }
            if (!Object.keys(names).length)
                names[""] = "";
        }
        const job = {id: ++nextId, path: path, target: target, names: names,
            keys: Object.keys(names), repair: false, accepted: true};
        for (const key of job.keys) {
            publish(key, {requestId: job.id, desired: path, outcome: "pending",
                screenName: names[key], repairUsed: false, recovery: targets[key]?.recovery === true});
        }
        // Superseded queued work must not mutate Windows later.
        queue = queue.filter(item => currentKeys(item).length > 0).concat([job]);
        outcomeChanged(job.id, "pending");
        drain();
        return job.accepted;
    }
    function release(target): void {
        const next = Object.assign({}, targets);
        if (target)
            delete next[target.targetId];
        targets = target ? next : {};
        queue = queue.filter(item => currentKeys(item).length > 0);
    }
    function signatureMatches(a, b): bool {
        return a.operation === b.operation && a.nativeTarget === b.nativeTarget
            && samePath(a.path, b.path);
    }
    function drain(): void {
        if (active || !queue.length)
            return;
        const job = queue[0];
        queue = queue.slice(1);
        const keys = currentKeys(job);
        if (!keys.length) {
            drain();
            return;
        }
        // A queued global pick can have been superseded on only one display.
        // Submit the remaining displays separately, never overwrite the newer
        // display pick with the old global operation.
        if (!job.target && keys.length !== job.keys.length) {
            queue = keys.map(key => Object.assign({}, job, {keys: [key],
                target: {name: job.names[key], targetId: key}})).concat(queue);
            drain();
            return;
        }
        const attempt = {id: job.id, path: job.path, keys: keys, names: job.names,
            repair: job.repair, operation: job.target ? "setWallpaperForScreen" : "setWallpaper",
            nativeTarget: job.target ? job.target.targetId : "", deadline: Date.now() + completionTimeout};
        // A timed-out call still owes a result. Without backend ids, submitting
        // the same tuple again would make both completions ambiguous.
        if (attempts.some(item => signatureMatches(item, attempt))) {
            for (const key of keys)
                publish(key, {outcome: "unknown"});
            announce(job);
            Qt.callLater(drain);
            return;
        }
        active = attempt;
        attempts = attempts.concat([attempt]);
        clock.start();
        const ok = job.target
            ? Native.Wallpaper.screenTargetId(job.target.name) === job.target.targetId
                && Native.Wallpaper.setWallpaperForScreen(job.path, job.target.name)
            : Native.Wallpaper.setWallpaper(job.path, false);
        job.accepted = ok;
        if (!ok && attempts.includes(attempt))
            finish(attempt, false, "refused");
    }
    function scheduleChecks(): void {
        // One finite recovery window, even if more retirement notifications
        // arrive. No timer-driven mutation loop.
        if (!checks.length) {
            const now = Date.now();
            checks = recoveryDelays.map(delay => now + delay);
            clock.start();
        }
    }
    function finish(attempt, ok, reason): void {
        attempts = attempts.filter(item => item !== attempt);
        if (active === attempt)
            active = null;
        const uncertain = ["provider-timeout", "provider-disconnected",
            "provider-unavailable", "explorer-restarted"].includes(reason);
        if (uncertain)
            for (const key of attempt.keys)
                if (targets[key])
                    publish(key, {recovery: true});
        for (const key of currentKeys(attempt)) {
            // Global provider success means at least one monitor succeeded,
            // not that every monitor did. Readback can be cached, so it
            // cannot establish per-target success for a global operation.
            const observed = readTarget(key);
            publish(key, {observed: observed, outcome: uncertain ? "unknown"
                : !ok ? (attempt.repair ? "unknown" : "failed")
                : attempt.nativeTarget ? "applied" : "unknown"});
        }
        announce(attempt);
        if (uncertain || !currentKeys(attempt).length
                || currentKeys(attempt).some(key => targets[key].outcome === "unknown"))
            scheduleChecks();
        // Native Channel refuses reentrant mutations from its result callback.
        Qt.callLater(drain);
    }
    function completed(operation, path, target, ok, reason): void {
        const result = {operation: operation, path: path, nativeTarget: target};
        const attempt = attempts.find(item => signatureMatches(item, result));
        if (!attempt)
            return; // Wallpaper Engine/background operations are not our picks.
        finish(attempt, ok, reason);
    }
    function readTarget(key): string {
        const state = targets[key];
        if (!state)
            return "";
        if (key === "")
            return Native.Wallpaper.currentWallpaper();
        if (Native.Wallpaper.screenTargetId(state.screenName) !== key)
            return "";
        return Native.Wallpaper.currentWallpaperForScreen(state.screenName);
    }
    function reconcile(): void {
        for (const key of Object.keys(targets)) {
            const state = targets[key];
            const observed = readTarget(key);
            publish(key, {observed: observed});
            // Reads may be cached while COM is blocked. A matching read alone
            // must never promote an unknown result to applied.
            if (!observed || samePath(observed, state.desired))
                continue;
            if (state.outcome === "pending" || (state.outcome === "failed" && !state.recovery))
                continue;
            publish(key, {outcome: "unknown"});
            if (!state.recovery || state.repairUsed)
                continue;
            publish(key, {repairUsed: true, outcome: "pending"});
            const names = {[key]: state.screenName};
            queue = queue.concat([{id: state.requestId, path: state.desired,
                keys: [key], names: names, repair: true, accepted: true,
                target: key ? {name: state.screenName, targetId: key} : null}]);
        }
        drain();
    }
    function tick(): void {
        const now = Date.now();
        if (active && now >= active.deadline) {
            const expired = active;
            active = null;
            // Keep this unanswered tuple for late-result correlation.
            for (const key of currentKeys(expired))
                publish(key, {outcome: "unknown"});
            for (const key of expired.keys)
                if (targets[key])
                    publish(key, {recovery: true});
            announce(expired);
            scheduleChecks();
            Qt.callLater(drain);
        }
        if (checks.length && now >= checks[0]) {
            checks = checks.slice(1);
            reconcile();
        }
        if (!active && !checks.length)
            clock.stop();
    }
    property Timer clock: Timer {
        interval: 100
        repeat: true
        onTriggered: root.tick()
    }
    property Connections results: Connections {
        target: Native.Wallpaper
        ignoreUnknownSignals: true
        function onWallpaperOperationFinished(operation, path, target, ok, reason): void {
            root.completed(operation, path, target, ok, reason);
        }
    }
    property Connections notifications: Connections {
        target: Native.DesktopLayer
        function onWallpaperChanged(): void {
            // A retired provider may still land its COM call after the newer
            // generation. Observe it without adopting it as a shell choice.
            root.reconcile();
        }
    }
}
