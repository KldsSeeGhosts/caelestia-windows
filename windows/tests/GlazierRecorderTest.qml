pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Caelestia
import Caelestia.Models
import qs.components
import qs.services
import qs.modules.utilities.cards
import qs.utils

ShellRoot {
    id: root
    property int step: 0
    property int assertions: 0
    property int ticks: 0
    property string audit: ""
    property bool missing: Quickshell.env("GLAZIER_TEST_MISSING") === "1"
    property bool disabled: Quickshell.env("GLAZIER_TEST_DISABLED") === "1"
    property int pendingCaptures: 0
    property var props: ({ recordingMode: "", recordingListExpanded: false, recordingConfirmDelete: "" })

    WindowsFonts {}
    FontLoader {
        id: bodyFont
        source: Quickshell.shellPath("assets/google-sans-flex/GoogleSansFlex-VariableFont_GRAD,ROND,opsz,slnt,wdth,wght.ttf")
    }
    FontLoader {
        id: iconFont
        source: Quickshell.shellPath("assets/material-symbols-rounded/MaterialSymbolsRounded.ttf")
    }
    ScreenState { id: screenState; modelData: Quickshell.screens[0] ?? null }

    FloatingWindow {
        visible: Quickshell.env("QT_QPA_PLATFORM") === "offscreen"
        implicitWidth: 660
        implicitHeight: 520
        color: Colours.palette.m3background
        Record {
            id: card
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: 20
            props: root.props
            screenState: screenState
        }
    }

    FileSystemModel {
        id: files
        path: Paths.recsdir
        nameFilters: Recorder.nameFilters
    }

    function check(value, message): void {
        if (!value) {
            console.error("GLAZIER_RECORDER_FAIL", step, message);
            Qt.exit(1);
            throw new Error(message);
        }
        assertions++;
    }

    function findText(item, text): var {
        if (item.text !== undefined && String(item.text).indexOf(text) >= 0)
            return item;
        for (const child of item.children ?? []) {
            const found = findText(child, text);
            if (found) return found;
        }
        return null;
    }

    function containsText(item, text): bool { return findText(item, text) !== null; }

    function fixture(command): void {
        helper.command = [Recorder.executable, command];
        helper.running = true;
    }

    function snapshot(name, after): void {
        pendingCaptures++;
        captureTimer.name = name;
        captureTimer.after = after;
        captureTimer.restart();
    }

    Timer {
        id: captureTimer
        interval: 500
        property string name
        property var after
        onTriggered: {
            const path = Quickshell.env("GLAZIER_STUB_ROOT").replace(/\\/g, "/") + "/" + name + ".png";
            CUtils.saveItem(card, Qt.resolvedUrl("file:///" + path), () => {
                root.pendingCaptures--;
                if (after) after();
            }, () => root.check(false, "offscreen screenshot"));
        }
    }

    Process {
        id: helper
        stdout: StdioCollector { onStreamFinished: root.audit = text }
    }

    Timer {
        interval: 100
        running: true
        repeat: true
        onTriggered: {
            if (++root.ticks > 250) {
                root.check(false, "timeout: state=" + Recorder.state + " status=" + Recorder.status
                    + " available=" + Recorder.available + " host=" + Recorder.hostId);
                return;
            }
            if (helper.running)
                return;
            if (root.pendingCaptures)
                return;
            if (bodyFont.status !== FontLoader.Ready || iconFont.status !== FontLoader.Ready)
                return;
            if (root.disabled) {
                if (root.ticks < 8) return;
                root.check(!Recorder.permitted && !Recorder.probed && !Recorder.available && !Recorder.canStart,
                    "live-off/smoke neither probes nor launches");
                root.check(!Recorder.start() && !Recorder.running, "live-off/smoke start refused");
                root.check(root.containsText(card, Recorder.status), "disabled reason in original card");
                console.log("GLAZIER_RECORDER_DISABLED_PASS", root.assertions);
                Qt.quit();
                return;
            }
            if (root.missing) {
                if (!Recorder.probed)
                    return;
                if (!root.containsText(card, "not found")) return;
                if (root.step === 0) {
                    root.check(!Recorder.available && !Recorder.canStart && !Recorder.running, "missing disables capture");
                    root.check(Recorder.lastError.indexOf("not found") >= 0, "missing error");
                    root.check(root.containsText(card, "not found"), "missing error displayed in original card");
                    root.snapshot("missing", () => {
                        console.log("GLAZIER_RECORDER_MISSING_PASS", root.assertions);
                        Qt.quit();
                    });
                    root.step++;
                }
                return;
            }
            switch (root.step) {
            case 0:
                if (!Recorder.canStart || !Recorder.hostId) return;
                root.check(!Recorder.running && Recorder.state === "idle", "initial idle");
                root.check(Paths.recsdir === Recorder.outputDir, "Glazier output folder");
                root.check(Recorder.start(), "fullscreen start accepted");
                root.step++;
                break;
            case 1:
                if (Recorder.state !== "recording" || !root.containsText(card, "Running...")) return;
                root.check(Recorder.running && !Recorder.paused, "started");
                root.check(Recorder.elapsed === 1.25, "elapsed comes from Glazier");
                root.check(root.containsText(card, "Running..."), "original card reflects recording");
                root.snapshot("recording", () => Recorder.togglePause());
                root.check(!Recorder.start(), "duplicate start refused");
                root.step++;
                break;
            case 2:
                if (!Recorder.paused || !root.containsText(card, "Paused")) return;
                root.check(root.containsText(card, "Paused"), "original card reflects pause");
                root.snapshot("paused", () => Recorder.togglePause());
                root.check(Recorder.elapsed === 1.25, "paused clock not locally advanced");
                root.step++;
                break;
            case 3:
                if (Recorder.paused) return;
                Recorder.stop();
                root.step++;
                break;
            case 4:
                if (Recorder.state !== "finalizing" || !root.containsText(card, "Saving recording")) return;
                root.check(Recorder.lastFile === "" && !Recorder.canStart, "no output path before finalize");
                root.check(root.containsText(card, "Saving recording"), "finalizing in card");
                root.fixture("--fixture-finish");
                root.step++;
                break;
            case 5:
                if (Recorder.running || !Recorder.lastFile || files.entries.length !== 1) return;
                if (!root.containsText(card, "recording-stub")) return;
                root.check(Recorder.lastFile.indexOf("recording-stub.mp4") >= 0, "finished output path");
                root.check(files.entries.length === 1, "list includes finalized file, not unpublished MP4");
                root.check(Paths.absolutePath(Recorder.lastFile).startsWith("file:///"), "Windows file URL for actions");
                root.fixture("--status");
                root.step++;
                break;
            case 6: {
                root.check(Paths.deleteRecording(Recorder.lastFile), "delete synthetic recording through Windows path adapter");
                const data = JSON.parse(root.audit);
                root.check(data.last_record_args.indexOf("--fullscreen") >= 0 && !data.system_sound && !data.mic,
                    "fullscreen without audio flags");
                root.check(Recorder.start(["-sr"]), "region with sound accepted");
                root.step++;
                break;
            }
            case 7:
                if (Recorder.state !== "recording" || files.entries.length !== 0) return;
                root.check(files.entries.length === 0, "recordings list updates after deletion");
                root.fixture("--status");
                root.step++;
                break;
            case 8: {
                const data = JSON.parse(root.audit);
                root.check(data.last_record_args.indexOf("--fullscreen") < 0 && data.system_sound && !data.mic,
                    "region with system sound and no mic flags");
                root.fixture("--fixture-error");
                root.step++;
                break;
            }
            case 9:
                if (Recorder.lastError !== "Simulated encoder error" || !root.containsText(card, "Simulated encoder error")) return;
                root.check(!Recorder.running && Recorder.lastFile === "", "error does not publish a file");
                root.check(root.containsText(card, "Simulated encoder error"), "error shown in original card");
                root.snapshot("error", () => root.fixture("--fixture-tray"));
                root.step++;
                break;
            case 10:
                if (!Recorder.running || Recorder.elapsed !== 42 || !root.containsText(card, "Running...")) return;
                root.check(root.containsText(card, "Running..."), "tray-started recording shown in card");
                root.fixture("--fixture-cancel");
                root.step++;
                break;
            case 11:
                if (Recorder.running) return;
                root.check(Recorder.lastFile === "", "cancel does not publish a file");
                root.check(Recorder.start(["-s"]), "fullscreen with sound accepted");
                root.step++;
                break;
            case 12:
                if (Recorder.state !== "recording") return;
                root.fixture("--status");
                root.step++;
                break;
            case 13: {
                const data = JSON.parse(root.audit);
                root.check(data.last_record_args.indexOf("--fullscreen") >= 0 && data.system_sound && !data.mic,
                    "fullscreen with sound flags");
                root.fixture("--fixture-cancel");
                root.step++;
                break;
            }
            case 14:
                if (Recorder.running) return;
                root.check(Recorder.start(["-r"]), "region without sound accepted");
                root.step++;
                break;
            case 15:
                if (Recorder.state !== "recording") return;
                root.fixture("--status");
                root.step++;
                break;
            case 16: {
                const data = JSON.parse(root.audit);
                root.check(data.last_record_args.indexOf("--fullscreen") < 0 && !data.system_sound && !data.mic,
                    "region without sound flags");
                root.fixture("--fixture-cancel");
                root.step++;
                break;
            }
            case 17:
                if (Recorder.running) return;
                root.fixture("--fixture-offline");
                root.step++;
                break;
            case 18:
                if (Recorder.lastError.indexOf("not running") < 0) return;
                if (root.pendingCaptures) return;
                root.check(!Recorder.running && Recorder.elapsed === 0, "host loss clears stale recording");
                const reply = (host, events) => JSON.stringify({ version: 1, ok: true, state: "idle", elapsed_ms: 0,
                    host_id: host, output_directory: "C:/x", events: events });
                const err = sequence => ({ sequence: sequence, type: "error", message: "boom" });
                root.check(Recorder.applyResponse(reply("replay-host", [err(1),
                    { sequence: 2, type: "finished", output_path: "C:\\x\\Old.mp4" }])) && Recorder.lastError === "",
                    "first response from a new host is a baseline: old error not replayed");
                root.check(Recorder.owns("c:/x/old.mp4") && !Recorder.owns("C:/x/other.mp4"), "baseline finished file is owned");
                root.check(!Paths.deleteRecording("C:/x/other.mp4") && Recorder.lastError.indexOf("Only recordings") === 0,
                    "delete of a file Glazier did not report is refused");
                root.check(Recorder.applyResponse(reply("replay-host", [err(3)])) && Recorder.lastError === "boom",
                    "events after the baseline apply");
                root.check(!Recorder.applyResponse('{"version":2,"ok":true}'), "reject unknown version");
                root.check(!Recorder.canStart, "incompatible host cannot record");
                console.log("GLAZIER_RECORDER_PASS", root.assertions);
                Qt.quit();
                break;
            }
        }
    }
}
