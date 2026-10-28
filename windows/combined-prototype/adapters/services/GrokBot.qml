pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// Windows: the attached helper bounds every snapshot read before passing a
// single line to QML. Snapshot contents are private and are never logged.
Singleton {
    id: root

    readonly property string configDir: (Quickshell.env("CAELESTIA_CONFIG_DIR") || "").replace(/\\/g, "/")
    readonly property string configPath: configDir ? configDir + "/grokbot.json" : ""
    readonly property string runtimeDir: (Quickshell.env("CAELESTIA_RUNTIME_DIR") || "").replace(/\\/g, "/")
    readonly property string python: Quickshell.env("CAELESTIA_SCHEME_PYTHON") || ""
    readonly property string helper: Quickshell.shellPath("scripts/grokbot_watch.py")
    property string snapshotPath: ""
    property string sourceMode: "producer"
    readonly property bool enabled: snapshotPath.length > 0
    readonly property bool polling: reader.item?.running ?? false
    readonly property var helperPid: reader.item?.processId ?? null
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
        let source = "producer";
        try {
            const config = JSON.parse(text.replace(/^\uFEFF/, ""));
            if (config.enabled === true && (config.source === undefined || config.source === "producer" || config.source === "snapshot")) {
                source = config.source || "producer";
                const configuredPath = config.snapshotPath === undefined && source === "producer"
                    ? root.runtimeDir + "/grokbot-snapshot.json" : config.snapshotPath;
                if (typeof configuredPath === "string" && /^[A-Za-z]:[\\/]/.test(configuredPath))
                    path = configuredPath.replace(/\\/g, "/");
            }
        } catch (_) {}
        if (snapshotPath !== path || sourceMode !== source) {
            // Destroy the old attached helper before changing its arguments.
            snapshotPath = "";
            rawData = null;
            sourceMode = source;
            snapshotPath = path;
        }
        status = path ? "offline" : "unconfigured";
    }

    function stringField(b, key, limit): string {
        if (b[key] === undefined) return "";
        if (typeof b[key] !== "string") throw new Error("invalid text");
        return b[key].slice(0, limit);
    }
    function boolField(b, key): bool {
        if (b[key] === undefined) return false;
        if (typeof b[key] !== "boolean") throw new Error("invalid boolean");
        return b[key];
    }
    function nonnegativeInt(value, max): int {
        if (typeof value !== "number" || !Number.isInteger(value) || value < 0 || value > max)
            throw new Error("invalid count");
        return value;
    }
    function accept(text): void {
        try {
            const data = JSON.parse(text.replace(/^\uFEFF/, ""));
            if (!data || !Array.isArray(data.bots) || !data.counts || typeof data.counts !== "object"
                    || Array.isArray(data.counts) || !data.app || typeof data.app.running !== "boolean"
                    || typeof data.generated_ts !== "number" || !Number.isFinite(data.generated_ts)
                    || data.generated_ts > Date.now() / 1000 + 10
                    || data.generated_ts < Date.now() / 1000 - 60)
                throw new Error("invalid snapshot");
            for (const key of ["bots", "awaiting", "working", "unread"])
                nonnegativeInt(data.counts[key], 1000000);
            const shapes = ["circle", "egg", "capsule", "cylinder", "tablet", "squircle", "hex", "gem",
                "crystal", "wedge", "shield", "dome", "arch", "bean", "pebble", "cloud", "teardrop",
                "leaf", "group", "blob"];
            const bots = [];
            for (const b of data.bots) {
                if (!b || typeof b !== "object" || Array.isArray(b)) throw new Error("invalid bot");
                const shape = stringField(b, "shape", 32);
                const hex = stringField(b, "hex", 16);
                if (hex && !/^#[0-9a-fA-F]{6}$/.test(hex)) throw new Error("invalid colour");
                const timestamp = b.last_activity_ts === undefined ? 0 : b.last_activity_ts;
                if (typeof timestamp !== "number" || !Number.isFinite(timestamp)
                        || timestamp < 0 || timestamp > Date.now() / 1000 + 60)
                    throw new Error("invalid timestamp");
                const bot = {
                    name: stringField(b, "name", 128), title: stringField(b, "title", 128),
                    description: stringField(b, "description", 256), last_text: stringField(b, "last_text", 160),
                    shape: shapes.includes(shape) ? shape : "squircle", hex: hex,
                    unread: b.unread === undefined ? 0 : nonnegativeInt(b.unread, 9999),
                    awaiting: boolField(b, "awaiting"), working: boolField(b, "working"),
                    last_activity_ts: timestamp
                };
                if (bots.length < 32) bots.push(bot);
            }
            rawData = {
                generated_ts: data.generated_ts, app: {running: data.app.running}, bots: bots,
                counts: {bots: bots.length, awaiting: bots.filter(b => b.awaiting).length,
                    working: bots.filter(b => b.working).length, unread: bots.filter(b => b.unread > 0).length}
            };
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
        active: root.enabled && root.python.length > 0
        sourceComponent: Process {
            command: [root.python, "-I", "-u", root.helper, "--snapshot", root.snapshotPath, "--source", root.sourceMode]
            running: true
            stdout: SplitParser {
                splitMarker: "\n"
                onRead: data => root.accept(data)
            }
            onExited: {
                root.rawData = null;
                root.status = root.enabled ? "offline" : "unconfigured";
                if (root.enabled) restartTimer.restart();
            }
        }
    }
    Timer {
        id: restartTimer
        interval: 3000
        onTriggered: if (root.enabled && reader.item && !reader.item.running) reader.item.running = true
    }
    Timer {
        id: pollTimer
        running: root.enabled
        repeat: true
        interval: 1500
        onTriggered: {
            root.nowMs = Date.now();
            if (root.rawData && root.rawData.generated_ts < root.nowMs / 1000 - 60) {
                root.rawData = null;
                root.status = "offline";
            }
        }
    }
}
