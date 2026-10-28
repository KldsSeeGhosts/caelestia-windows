pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// Windows: consume a locally published watcher snapshot, never the Linux
// persistence database, a process, or an endpoint. Snapshot contents are private.
Singleton {
    id: root

    readonly property string configDir: (Quickshell.env("CAELESTIA_CONFIG_DIR") || "").replace(/\\/g, "/")
    readonly property string configPath: configDir ? configDir + "/grokbot.json" : ""
    property string snapshotPath: ""
    readonly property bool enabled: snapshotPath.length > 0
    readonly property bool polling: pollTimer.running
    property string status: "unconfigured"
    property var rawData: null
    property double nowMs: Date.now()
    readonly property var bots: Array.isArray(rawData?.bots) ? rawData.bots : []
    readonly property var counts: rawData?.counts ?? ({bots: 0, awaiting: 0, working: 0, unread: 0})
    readonly property bool appRunning: rawData?.app?.running === true
    readonly property var attentionBot: {
        const waiting = bots.filter(b => b.awaiting).sort((a, b) => (a.last_activity_ts || 0) - (b.last_activity_ts || 0));
        const working = bots.filter(b => b.working);
        const unread = bots.filter(b => b.unread > 0).sort((a, b) => (b.last_activity_ts || 0) - (a.last_activity_ts || 0));
        return waiting[0] ?? working[0] ?? unread[0] ?? null;
    }
    readonly property var sortedBots: {
        const wants = bots.filter(b => b.awaiting || b.unread > 0);
        const rest = bots.filter(b => !b.awaiting && !(b.unread > 0));
        wants.sort((a, b) => (a.last_activity_ts || 0) - (b.last_activity_ts || 0));
        rest.sort((a, b) => (b.last_activity_ts || 0) - (a.last_activity_ts || 0));
        return wants.concat(rest);
    }

    function configure(text): void {
        let path = "";
        try {
            const config = JSON.parse(text.replace(/^\uFEFF/, ""));
            if (config.enabled === true && typeof config.snapshotPath === "string"
                    && /^[A-Za-z]:[\\/]/.test(config.snapshotPath))
                path = config.snapshotPath.replace(/\\/g, "/");
        } catch (_) {}
        if (snapshotPath !== path) {
            rawData = null;
            snapshotPath = path;
        }
        status = path ? "offline" : "unconfigured";
    }

    function accept(text): void {
        try {
            const data = JSON.parse(text.replace(/^\uFEFF/, ""));
            if (!data || !Array.isArray(data.bots) || !data.counts || typeof data.counts !== "object"
                    || typeof data.generated_ts !== "number" || !Number.isFinite(data.generated_ts)
                    || data.generated_ts > Date.now() / 1000 + 10
                    || data.generated_ts < Date.now() / 1000 - 60
                    || data.bots.some(b => !b || typeof b !== "object" || Array.isArray(b)))
                throw new Error("invalid snapshot");
            rawData = data;
            status = "ok";
        } catch (_) {
            rawData = null;
            status = "offline";
        }
    }

    function faceFor(b): string {
        if (!b) return "neutral";
        if (b.awaiting) return "attentive";
        if (b.working) return "curious";
        if (b.unread > 1) return "excited";
        if (b.unread > 0) return "curious";
        if (b.last_activity_ts && nowMs / 1000 - b.last_activity_ts > 7 * 24 * 3600) return "drowsy";
        return "neutral";
    }
    function colorFor(b, fallback: color): color {
        return b && typeof b.hex === "string" && /^#[0-9a-fA-F]{6}$/.test(b.hex) ? b.hex : fallback;
    }
    function fmtAgo(ts: double): string {
        if (!ts) return "";
        const s = Math.max(0, nowMs / 1000 - ts);
        if (s < 90) return "now";
        const m = Math.floor(s / 60);
        if (m < 60) return m + "m";
        const h = Math.floor(m / 60);
        if (h < 24) return h + "h";
        const d = Math.floor(h / 24);
        return d < 7 ? d + "d" : Math.floor(d / 7) + "w";
    }

    Loader {
        active: root.configPath.length > 0
        sourceComponent: FileView {
            path: root.configPath
            printErrors: false
            watchChanges: true
            onLoaded: root.configure(text())
            onFileChanged: reload()
            onLoadFailed: root.configure("")
        }
    }
    Loader {
        id: reader
        active: root.enabled
        sourceComponent: FileView {
            path: root.snapshotPath
            printErrors: false
            watchChanges: true
            onLoaded: root.accept(text())
            onFileChanged: reload()
            onLoadFailed: {
                root.rawData = null;
                root.status = "offline";
            }
        }
    }
    Timer {
        id: pollTimer
        running: root.enabled
        repeat: true
        interval: 1500
        onTriggered: {
            root.nowMs = Date.now();
            if (reader.item) reader.item.reload();
        }
    }
}
