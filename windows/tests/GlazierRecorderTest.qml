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
    property string scenario: Quickshell.env("GLAZIER_TEST_SCENARIO")
    property int pendingCaptures: 0
    property var props: ({ recordingMode: "", recordingListExpanded: false, recordingConfirmDelete: "" })
    property string layoutExpected: ""
    property int layoutIndex: -1
    property var layoutHeights: []
    // The real Recorder.status strings, rendered in the real card at 430 px.
    property var layoutStatuses: [
        { name: "unavailable", lastError: "", connectionError: "", available: false, state: "idle", lines: 2 },
        { name: "not-found", lastError: "Unavailable: Glazier is missing from this installation.", connectionError: "", available: false, state: "idle", lines: 2 },
        { name: "start-failure", lastError: "Glazier did not start recording.", connectionError: "", available: false, state: "idle", lines: 1 },
        { name: "stopped", lastError: "", connectionError: "Glazier stopped", available: true, state: "idle", lines: 1 },
        { name: "ready", lastError: "", connectionError: "", available: true, state: "idle", lines: 1 },
        { name: "running", lastError: "", connectionError: "", available: true, state: "recording", lines: 1 }
    ]

    Component.onCompleted: check(Quickshell.stateDir.replace(/\\/g, "/")
        === Quickshell.env("GLAZIER_STUB_ROOT").replace(/\\/g, "/") + "/profile/state",
        "staged StateDir stays inside the disposable profile")

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
        // The status layout scenario renders the card at the real 430 px width.
        implicitWidth: root.scenario === "layout" ? 470 : 660
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

    FileView {
        id: ownershipStore
        path: root.scenario.startsWith("store-") ? Quickshell.stateDir + "/caelestia/recordings.json" : ""
        printErrors: false
        blockAllReads: true
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

    function findExact(item, text): var {
        if (item.text !== undefined && String(item.text) === text)
            return item;
        for (const child of item.children ?? []) {
            const found = findExact(child, text);
            if (found) return found;
        }
        return null;
    }

    function findKey(item, key): var {
        if (item[key] !== undefined)
            return item;
        for (const child of item.children ?? []) {
            const found = findKey(child, key);
            if (found) return found;
        }
        return null;
    }

    function findLoader(item): var {
        if (item.sourceComponent !== undefined && item.item !== undefined)
            return item;
        for (const child of item.children ?? []) {
            const found = findLoader(child);
            if (found) return found;
        }
        return null;
    }

    function applyLayoutStatus(index): void {
        const status = root.layoutStatuses[index];
        Recorder.probed = true;
        Recorder.executable = "";
        Recorder.available = status.available;
        Recorder.lastError = status.lastError;
        Recorder.connectionError = status.connectionError;
        Recorder.pendingStart = false;
        Recorder.state = status.state;
        root.layoutExpected = Recorder.status;
    }

    function checkLayout(status): bool {
        const text = root.findExact(card, root.layoutExpected);
        const loader = root.findLoader(card);
        const split = root.findKey(card, "menuItems");
        if (!text || text.lineCount <= 0 || !loader || !loader.item || loader.height <= 0 || !split)
            return false;
        // Wait for the list/controls height animation to settle before geometry.
        if (Math.abs(loader.height - loader.implicitHeight) > 0.5)
            return false;
        root.check(text.maximumLineCount === 2, status.name + ": status allows two lines");
        root.check(text.lineCount === status.lines, status.name + ": status uses " + status.lines + " line(s)");
        root.check(!text.truncated, status.name + ": status is not truncated");
        const row = split.parent;
        const rowBottom = row.mapToItem(card, 0, row.height).y;
        const statusTop = text.mapToItem(card, 0, 0).y;
        const statusBottom = statusTop + text.height;
        const statusLeft = text.mapToItem(card, 0, 0).x;
        const statusRight = statusLeft + text.width;
        const loaderTop = loader.mapToItem(card, 0, 0).y;
        const loaderBottom = loaderTop + loader.height;
        const contentLeft = loader.mapToItem(card, 0, 0).x;
        const contentRight = contentLeft + loader.width;
        root.check(statusTop >= rowBottom - 0.5, status.name + ": status sits below the header row");
        root.check(statusLeft >= contentLeft - 0.5 && statusRight <= contentRight + 0.5,
            status.name + ": full-width status stays inside the card");
        root.check(statusBottom <= loaderTop + 0.5, status.name + ": status stays above the list/controls");
        root.check(loaderBottom <= card.height + 0.5, status.name + ": card bottom edge stays below the list/controls");
        root.check(split.mapToItem(card, split.width, 0).x <= card.width + 0.5,
            status.name + ": mode button stays inside the card");
        root.check(Math.abs(card.nonAnimHeight - card.height) < 0.5,
            status.name + ": card height matches drawer animation height");
        root.layoutHeights[root.layoutIndex] = card.height;
        return true;
    }

    function findDelete(item, baseName): var {
        if (item.modelData?.baseName === baseName) {
            for (const child of item.children ?? []) {
                if (child.icon === "delete_forever")
                    return child;
            }
        }
        for (const child of item.children ?? []) {
            const found = findDelete(child, baseName);
            if (found) return found;
        }
        return null;
    }

    function ownedFixture(index): string {
        return Recorder.outputDir + "/fixture-" + index + ".mp4";
    }

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
            if (root.scenario === "cold-start" || root.scenario === "start-timeout") {
                if (!Recorder.canStart) return;
                if (root.step === 0) {
                    if (root.scenario === "cold-start" && !Recorder.connectionFailed) return;
                    if (root.scenario === "start-timeout" && !Recorder.hostId) return;
                    root.check(Recorder.start(), "failed-start attempt accepted");
                    root.step++;
                } else if (root.step === 1) {
                    const expected = root.scenario === "cold-start" ? "Synthetic cold-start failure" : "Glazier did not start recording.";
                    if (!Recorder.lastError.startsWith(expected)) return;
                    root.check(!Recorder.pendingStart && !Recorder.running, "failure ends pending Start");
                    root.fixture("--status");
                    root.step++;
                } else {
                    root.check(Recorder.applyResponse(root.audit), "valid idle reply after failed Start");
                    root.check(Recorder.lastError !== "" && Recorder.status === Recorder.lastError,
                        "valid idle reply does not erase failed Start");
                    console.log("GLAZIER_RECORDER_START_FAILURE_PASS", root.assertions);
                    Qt.quit();
                }
                return;
            }
            if (root.scenario.startsWith("store-")) {
                if (!Recorder.canStart || !Recorder.hostId || root.ticks < 8) return;
                if (root.scenario === "store-missing" || root.scenario === "store-corrupt") {
                    if (root.step === 0) {
                        root.check(Recorder.finishedFiles.length === 0, "missing/corrupt store grants no ownership");
                        root.check(!Recorder.owns(root.ownedFixture(0)), "unreported older recording not owned");
                        Recorder.remember(root.ownedFixture(500));
                        root.check(Recorder.owns(root.ownedFixture(500)), "store recovers on a new finished file");
                        root.step++;
                        return;
                    }
                } else if (root.scenario === "store-write" && root.step === 0) {
                    for (let i = 0; i <= 500; i++)
                        Recorder.remember(root.ownedFixture(i));
                    Recorder.remember(root.ownedFixture(500)); // duplicates do not evict another file
                    root.check(Recorder.finishedFiles.length === 500 && !Recorder.owns(root.ownedFixture(0))
                        && Recorder.owns(root.ownedFixture(1)) && Recorder.owns(root.ownedFixture(500)),
                        "only newest 500 distinct reported files owned");
                    root.step++;
                    return;
                } else {
                    if (root.scenario === "store-restart" && Recorder.finishedFiles.length !== 500) return;
                    const oldButton = root.findDelete(card, "fixture-0");
                    const ownedButton = root.findDelete(card, "fixture-500");
                    const foreignButton = root.findDelete(card, "fixture-unreported");
                    if (!oldButton || !ownedButton || !foreignButton) return;
                    root.check(!ownedButton.disabled && foreignButton.disabled,
                        "original list enables owned Delete and disables unreported Delete");
                    if (root.scenario === "store-write" && root.step === 1) {
                        root.check(oldButton.disabled, "cap-evicted recording Delete disabled");
                        Recorder.remember(root.ownedFixture(0));
                        root.step++;
                        return;
                    }
                    root.check(!oldButton.disabled && !Recorder.owns(root.ownedFixture(1)),
                        "Delete binding updates when a finished file enters the capped set");
                    root.check(Recorder.owns(root.ownedFixture(500).toUpperCase().replace(/\//g, "\\")),
                        "normalized ownership survives persistence");
                    if (root.scenario === "store-write" && root.step === 2) {
                        root.fixture("--fixture-error");
                        root.step++;
                        return;
                    }
                    if (root.scenario === "store-restart")
                        root.check(Recorder.lastError === "", "shell restart suppresses old host journal error");
                }
                // Wait for the real FileView's asynchronous atomic write before
                // exiting; the next process must read committed bytes, not RAM.
                ownershipStore.reload();
                try {
                    if (JSON.stringify(JSON.parse(ownershipStore.text())) !== JSON.stringify(Recorder.finishedFiles)) return;
                } catch (_) { return; }
                root.check(true, "ownership committed under the disposable profile");
                console.log("GLAZIER_RECORDER_STORE_PASS", root.assertions);
                Qt.quit();
                return;
            }
            if (root.scenario === "layout") {
                if (!Recorder.probed || root.ticks < 8) return;
                if (Math.abs(card.width - 430) > 0.5) {
                    if (root.ticks > 100)
                        root.check(false, "layout fixture width is " + card.width);
                    return;
                }
                if (root.layoutIndex < 0) {
                    root.check(true, "layout fixture renders the card at 430");
                    root.applyLayoutStatus(0);
                    root.layoutIndex = 0;
                    return;
                }
                if (root.layoutIndex >= root.layoutStatuses.length) {
                    // Let the card settle after the last status swap before
                    // comparing the animated and non-animated heights.
                    if (Math.abs(card.nonAnimHeight - card.height) >= 0.5 && root.ticks < 240)
                        return;
                    root.check(Math.abs(card.nonAnimHeight - card.height) < 0.5,
                        "wrapped card height matches the drawer animation height");
                    root.check(root.layoutHeights[1] > root.layoutHeights[4] + 1,
                        "a two-line status grows the card above a one-line status");
                    console.log("GLAZIER_RECORDER_LAYOUT_PASS", root.assertions);
                    Qt.quit();
                    return;
                }
                if (!root.checkLayout(root.layoutStatuses[root.layoutIndex]))
                    return;
                if (++root.layoutIndex < root.layoutStatuses.length)
                    root.applyLayoutStatus(root.layoutIndex);
                return;
            }
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
            if (root.scenario === "bundled") {
                if (!Recorder.probed || !Recorder.canStart) return;
                const expected = Quickshell.env("GLAZIER_BUNDLED_EXE").replace(/\\/g, "/").toLowerCase();
                root.check(Recorder.available && Recorder.executable.replace(/\\/g, "/").toLowerCase() === expected,
                    "bundled Glazier is resolved first");
                root.check(Glazier.executable.replace(/\\/g, "/").toLowerCase() === expected,
                    "the screenshot and recorder adapters resolve the same bundled tool");
                console.log("GLAZIER_RECORDER_BUNDLED_PASS", root.assertions);
                Qt.quit();
                return;
            }
            if (root.missing) {
                if (!Recorder.probed)
                    return;
                if (!root.containsText(card, "missing")) return;
                if (root.step === 0) {
                    root.check(!Recorder.available && !Recorder.canStart && !Recorder.running, "missing disables capture");
                    root.check(Recorder.lastError.indexOf("missing") >= 0, "missing error");
                    root.check(root.containsText(card, "missing"), "missing error displayed in original card");
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
                if (Recorder.status !== "Glazier stopped") return;
                if (root.pendingCaptures) return;
                root.check(!Recorder.running && Recorder.elapsed === 0, "host loss clears stale recording");
                const reply = (host, events) => JSON.stringify({ version: 1, ok: true, state: "idle", elapsed_ms: 0,
                    host_id: host, output_directory: "C:/x", events: events });
                const err = sequence => ({ sequence: sequence, type: "error", message: "boom" });
                Recorder.hostId = "";
                Recorder.eventSequence = 0;
                Recorder.baselinePending = true;
                Glazier.launchedHost = false; // a shell restart adopting a host that predates it
                root.check(Recorder.applyResponse(reply("replay-host", [err(1),
                    { sequence: 2, type: "finished", output_path: "C:\\x\\Old.mp4" }])) && Recorder.lastError === "",
                    "shell initial response is a baseline: old error not replayed");
                root.check(Recorder.owns("c:/x/old.mp4") && !Recorder.owns("C:/x/other.mp4"), "baseline finished file is owned");
                root.check(!Paths.deleteRecording("C:/x/other.mp4") && Recorder.lastError.indexOf("Only recordings") === 0,
                    "delete of a file Glazier did not report is refused");
                root.check(Recorder.applyResponse(reply("replay-host", [err(3)])) && Recorder.lastError === "boom",
                    "events after the baseline apply");
                root.check(Recorder.applyResponse(reply("replay-host", [err(3)])) && Recorder.lastError === "boom",
                    "idle poll does not clear a recording failure");
                root.check(!Recorder.applyResponse("{\"version\":1,"), "partial status rejected");
                root.check(!Recorder.incompatible, "partial status is transient, not incompatible");
                root.check(!Recorder.applyResponse('{"version":1}'), "incomplete status rejected");
                root.check(!Recorder.incompatible, "incomplete status is transient, not incompatible");
                root.check(Recorder.applyResponse(reply("replay-host", [])), "valid status after a partial response recovers");
                root.check(Recorder.lastError === "boom" && Recorder.connectionError === "",
                    "transport recovery preserves recording failure");
                root.check(Recorder.available && !Recorder.incompatible && Recorder.canStart,
                    "recorder re-enabled after a partial response");
                root.check(!Recorder.applyResponse(""), "empty status is transient");
                root.check(!Recorder.incompatible, "empty status does not latch incompatibility");
                root.check(Recorder.applyResponse(reply("replay-host", [])), "valid status after empty output recovers");
                root.check(!Recorder.applyResponse('{"version":2,"ok":true}'), "reject unknown version");
                root.check(Recorder.incompatible && !Recorder.canStart, "incompatible host cannot record");
                root.check(!Recorder.applyResponse('{"version":1,"ok":false,"error":"Glazier is not running."}'),
                    "offline v1 status is not an active host");
                root.check(!Recorder.incompatible && Recorder.available && Recorder.canStart,
                    "compatible offline status clears incompatibility and re-enables Start");
                root.check(!Recorder.applyResponse('{"version":2,"ok":true}'), "reject unknown version again");
                root.check(Recorder.incompatible && !Recorder.canStart, "incompatible host disables Start again");
                root.check(Recorder.applyResponse(reply("replay-host", [])), "compatible status clears incompatibility");
                root.check(!Recorder.incompatible && Recorder.available && Recorder.canStart,
                    "recorder recovers from explicit incompatibility");
                root.check(Recorder.applyResponse(reply("replay-host", [{ sequence: 4, type: "started" }]))
                    && Recorder.lastError === "", "recording clears prior failure before host replacement");
                root.check(Recorder.applyResponse(reply("replacement-host", [err(1)])) && Recorder.lastError === "boom",
                    "replacement host first-response error is visible without Start pending");
                root.check(Recorder.applyResponse(reply("replacement-host", [{ sequence: 2, type: "started" }]))
                    && Recorder.lastError === "", "started event clears recording failure");
                // A host this shell cold-started has no pre-restart journal, so
                // an error in its very first response is genuine even though no
                // offline response preceded it and no Start is pending.
                Recorder.hostId = "";
                Recorder.eventSequence = 0;
                Recorder.baselinePending = true;
                Recorder.lastError = "";
                Glazier.launchedHost = true;
                root.check(Recorder.applyResponse(reply("launched-host", [err(1)])) && Recorder.lastError === "boom",
                    "first-response error from a shell-launched host is visible");
                root.check(!Recorder.baselinePending, "first response still ends the baseline");
                let q = [];
                q = SchemeGenerator.coalescePending(q, "list", ["list"]);
                q = SchemeGenerator.coalescePending(q, "set", ["set-mode", "--mode", "light"]);
                q = SchemeGenerator.coalescePending(q, "set", ["set-variant", "--variant", "vibrant"]);
                root.check(q.length === 3 && q[0].kind === "list"
                    && q[1].args[0] === "set-mode" && q[2].args[0] === "set-variant",
                    "independent mode and variant changes stay queued with list");
                q = SchemeGenerator.coalescePending(q, "set", ["set-mode", "--mode", "dark"]);
                root.check(q.length === 3 && q[1].args[0] === "set-variant"
                    && q[2].args[0] === "set-mode" && q[2].args[2] === "dark",
                    "newer mode change supersedes only earlier mode change");
                q = SchemeGenerator.coalescePending(q, "apply", ["apply-wallpaper", "--image", "C:/w.png", "--smart", "1"]);
                root.check(q.length === 2 && q[0].kind === "list" && q[1].args[0] === "apply-wallpaper",
                    "smart wallpaper apply supersedes queued scheme state changes but keeps list");
                console.log("GLAZIER_RECORDER_PASS", root.assertions);
                Qt.quit();
                break;
            }
        }
    }
}
