pragma Singleton
import QtQuick

// Synthetic external I/O state. No native plugin, filesystem API or process is
// reachable from these providers. Tests choose when every completion occurs.
QtObject {
    property string profile: ""
    property var environment: ({CAELESTIA_WINDOWS_NOTIFICATIONS: "1"})
    property var files: ({})
    property var writes: []
    property var readPaths: []
    property int forbiddenCalls: 0
    property int observationGeneration: 0
    property bool observing: false
    property int refusedObservationWrites: 0
    property int access: 2
    property string ownership: "owner"
    property int accessRequests: 0
    property int accessProbes: 0
    property int clipboardGeneration: 0
    property var clipboardInstances: ({})
    property var cancelled: ({})
    property var jobs: []
    property int shutdowns: 0
    property int completions: 0
    property int suppressed: 0

    function claimObservation(): int { return ++observationGeneration; }
    function observe(enabled, token): void {
        if (token === 0 || token !== observationGeneration) {
            refusedObservationWrites++;
            return;
        }
        observing = enabled;
    }
    function attach(instance): int {
        const token = ++clipboardGeneration;
        clipboardInstances[token] = instance;
        return token;
    }
    function shutdown(token): void {
        cancelled[token] = true;
        shutdowns++;
    }
    function detach(token): void { delete clipboardInstances[token]; }
    function enqueue(token, kind, value): int {
        jobs.push({token: token, kind: kind, value: value});
        return jobs.length - 1;
    }
    function complete(index): void {
        const job = jobs[index];
        if (!job)
            throw new Error("Unknown synthetic completion");
        jobs[index] = null;
        if (cancelled[job.token]) {
            suppressed++;
            return;
        }
        completions++;
        const target = clipboardInstances[job.token];
        if (!target)
            return;
        if (job.kind === "items")
            target.items = job.value;
        else if (job.kind === "paste")
            target.pasteReady(job.value);
        else if (job.kind === "image")
            target.imageReady(job.value, "image://synthetic/" + job.value);
        else
            throw new Error("Unknown synthetic job kind");
    }
}
