"""Contract, deterministic replay and planted-summary regression tests."""
import argparse
import copy
import importlib.util
import json
from pathlib import Path
import re
import tempfile
import unittest
import sys
import contextlib
import io
import math
import os
import time
from types import SimpleNamespace

sys.dont_write_bytecode = True

parser = argparse.ArgumentParser(__doc__)
parser.add_argument("--source", default=str(Path(__file__).resolve().parents[1] / "scripts"))
parser.add_argument("--output", help="New external directory for a test receipt")
args, rest = parser.parse_known_args()
root = Path(args.source)


class BoundedContract(unittest.TestCase):
    def test_default_workload_cannot_spend_seventy_minutes(self):
        script = (root.parent / "bench/tools/Measure-ShellRuntime.ps1").read_text(encoding="utf-8-sig")
        warmup = int(re.search(r"\$WarmupSeconds\s*=\s*(\d+)", script)[1])
        idle = int(re.search(r"\$IdleSeconds\s*=\s*(\d+)", script)[1])
        self.assertLessEqual(2 * 7 * (warmup + idle), 60,
                             "Default observation alone exceeds the targeted one-minute budget")
        runner = (root / "Measure-ShellBenchmark.ps1").read_text(encoding="utf-8-sig")
        self.assertNotIn("$CompareBaseline", runner)
        self.assertIn("580000", runner)

    def test_smoke_ci_completes_from_presented_frames_not_fixed_sleeps(self):
        shell = (root.parent / "shell/shell.qml").read_text(encoding="utf-8-sig")
        self.assertIn("Qt.callLater(root.finishSmokeCi)", shell)
        self.assertIn("scope.smokeFrames >= 2", shell)
        self.assertIn("repeat: !root.smokeCi", shell)
        self.assertNotIn("if (step < 3)", shell)


if (root / "ShellBench.py").exists():
    spec = importlib.util.spec_from_file_location("shellbench", root / "ShellBench.py")
    bench = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(bench)

    class PairedSummary(unittest.TestCase):
        def test_review_exact_interval_and_equivalence(self):
            # A wide interval overlapping zero is not evidence of equivalence.
            a = [100] * 9
            b = [80, 85, 90, 95, 100, 105, 110, 115, 120]
            self.assertEqual(bench.compare(a, b, "cost", {"cost": 2})["verdict"], "unresolved")
            result = bench.compare(a, [125] * 9, "cost", {"cost": 2})
            self.assertEqual(result["verdict"], "regressed")
            self.assertAlmostEqual(result["deltaPercent"], 25)
            self.assertEqual(result["intervalMethod"], "exact Wilcoxon signed-rank / Walsh averages")

        def test_review_unmapped_qml_is_not_silently_skipped(self):
            mapping = bench.read(root.parent / "bench/map.json")
            selected = bench.select_paths(["modules/bar/Bar.qml"], mapping)
            self.assertEqual(selected["areas"], ["idle", "lifecycle", "panels"])
            self.assertEqual(bench.select_paths(["new/AlwaysOn.qml"], mapping)["areas"], ["idle"])
            native = bench.select_paths(["windows/deps/quickshell/src/windows/services/audio.cpp"], mapping)
            self.assertIn("notCovered", native)
            self.assertTrue(native["notCovered"])
            self.assertNotIn("audio", native["areas"])

        def test_unresolved_reading_separates_possible_slowdown(self):
            a = [100] * 9
            wide = bench.compare(a, [80, 85, 90, 95, 100, 105, 110, 115, 120], "cost", {"cost": 2})
            self.assertEqual(bench.kind(wide), "slower")
            self.assertTrue(bench.reading(wide).startswith("possibly slower, up to +"))
            faster = bench.compare(a, [97, 97.5, 98, 98.2, 98.5, 98.8, 99, 99.2, 99.5], "cost", {"cost": 2})
            self.assertEqual(bench.kind(faster), "unresolved")
            self.assertIn("faster", bench.reading(faster))
            self.assertTrue(bench.reading(faster).startswith("not slower"))

        def test_native_probe_floors_are_at_least_five_percent(self):
            # Binary layout alone moved tiling ~4% with unchanged code.
            floors = bench.read(root.parent / "bench/map.json")["floorsPercent"]
            for name in ("tiling.cyclesPerOperation", "tracker.cyclesPerOperation", "audio.nanosecondsPerOperation",
                         "media.nanosecondsPerOperation", "tray.nanosecondsPerOperation",
                         "notifications.nanosecondsPerOperation", "quota.windowProjectionNs"):
                self.assertGreaterEqual(floors[name], 5, name)

        def test_review_native_layout_randomization_and_balanced_plant(self):
            native = (root.parent / "bench/native/main.cpp").read_text()
            self.assertNotIn("SetThreadAffinityMask", native)
            self.assertIn("_alloca", native)
            self.assertIn("heapPad", native)
            self.assertIn("--plant=", native)

        def test_native_reuse_guard_covers_embedded_shaders_not_only_cpp(self):
            changes = ["modules/bar/Foo.qml", "windows/docs/BENCHMARKS.md",
                       "plugin/shaders/blur.frag", "windows/bench/native/main.cpp", "CMakeLists.txt"]
            self.assertEqual(bench.native_inputs(changes), ["plugin/shaders/blur.frag", "CMakeLists.txt"])

        def test_declared_metric_removal_preserves_original_observations(self):
            data = self.fixture()
            for trial in data["trials"]:
                trial["values"]["payloadAssemblyMs"] = 100 if trial["side"] == "A" else 150
                trial["values"]["cost"] = 100
            data["protocol"]["requiredMetrics"].append("payloadAssemblyMs")
            self.assertEqual(bench.summarize(data)["overall"], "regressed")
            data["analysisPolicy"] = bench.POLICY
            self.assertEqual(bench.summarize(data)["overall"], "same")
            self.assertNotIn("payloadAssemblyMs", bench.summarize(data)["metrics"])
            self.assertEqual(data["trials"][1]["values"]["payloadAssemblyMs"], 150)

        def test_exact_interval_uses_signed_rank_distribution_not_min_max(self):
            estimate, interval, coverage = bench.wilcoxon_interval(list(range(1, 8)))
            self.assertEqual(estimate, 4)
            self.assertEqual(interval, [2, 6])
            self.assertEqual(coverage, 1 - 6/128)
            self.assertEqual(bench.wilcoxon_interval(list(range(9)))[2], .9609375)

        def test_equivalence_floor_is_relative_fixed_and_not_either_sides_range(self):
            a = [100 * i for i in range(1, 10)]
            m = bench.compare(a, [v * 1.01 for v in a], "cost", {"cost": 2})
            self.assertEqual(m["verdict"], "same")
            self.assertEqual(m["floorPercent"], 2)
            self.assertAlmostEqual(m["deltaPercent"], 1)

        def test_backend_windows_does_not_match_window_directory(self):
            mapping = bench.read(root.parent / "bench/map.json")
            self.assertEqual(bench.select_paths(["windows/deps/quickshell/src/windows/other.cpp"], mapping)["areas"], ["idle"])
            self.assertEqual(bench.select_paths(["windows/deps/quickshell/test/test.cpp"], mapping)["areas"], [])

        def test_same_improved_and_planted_regression(self):
            a = [100, 101, 99] * 3
            for b, expected in (([101, 100, 99] * 3, "same"),
                                ([151, 150, 149] * 3, "regressed"),
                                ([51, 50, 49] * 3, "improved")):
                m = bench.compare(a, b, "cost", {"cost": 2})
                self.assertEqual(m["verdict"], expected)
                self.assertEqual(m, bench.compare(a, b, "cost", {"cost": 2}))
                self.assertEqual(m["pairedDeltas"], [y - x for x, y in zip(a, b)])
                self.assertEqual(len(m["deltaInterval95"]), 2)

        def test_zero_cpu_and_invalid_measurements(self):
            for a, b in (([1]*9, [1]*8), ([1]*9, [float("nan")]*9), ([0]*9, [0]*9)):
                with self.assertRaises(ValueError):
                    bench.compare(a, b, "cost")

        def test_candidate_variability_cannot_widen_its_own_tolerance(self):
            result = bench.compare([100, 101, 99]*3, [125, 126, 180]*3, "cost", {"cost": 2})
            self.assertEqual(result["verdict"], "regressed")
            self.assertEqual(result["floorPercent"], 2)
            self.assertEqual(result["noiseFloor"], 2)

        def fixture(self):
            return {"schemaVersion": 1, "protocol": {"version": bench.PROTOCOL, "runs": 9,
                    "floorsPercent": {"cost": 2, "payloadAssemblyMs": 2, "tracker.nanosecondsPerOperation": 2},
                    "requiredMetrics": ["cost"]},
                    "trials": [{"index": i, "side": side, "values": {"cost": 100 if side == "A" else 150}}
                               for i in range(1, 10) for side in ("A", "B")]}

        def test_replay_rejects_missing_reordered_or_common_missing_metrics(self):
            data = self.fixture()
            self.assertEqual(bench.summarize(data)["overall"], "regressed")
            self.assertEqual(bench.summarize(data), bench.summarize(json.loads(json.dumps(data))))
            for mutation in ("missing", "order", "common-missing"):
                broken = copy.deepcopy(data)
                if mutation == "missing":
                    broken["trials"].pop()
                elif mutation == "order":
                    broken["trials"].reverse()
                else:
                    broken["protocol"]["requiredMetrics"].append("absent")
                with self.assertRaises(ValueError):
                    bench.summarize(broken)

        def test_chart_contains_each_raw_trial_without_network_dependencies(self):
            data = self.fixture()
            data.update({"summary": bench.summarize(data), "wallSeconds": 1,
                         "sides": {"A": {"revision": "a"*40}, "B": {"revision": "b"*40}}, "removed": {}})
            with tempfile.TemporaryDirectory(prefix="caelestia-summary-test-") as directory:
                target = Path(directory) / "report.html"
                bench.report(data, target)
                markup = target.read_text()
                self.assertEqual(markup.count("<circle "), 19)
                self.assertNotIn("https://", markup)
                self.assertIn("regressed", markup)
                self.assertIn('id="summary-chart"', markup)
                self.assertIn("resolution", markup)
                regression_color = re.search(r"\.regressed\{color:(#[a-f0-9]+)\}", markup)[1]
                circle_colors = re.findall(r'<circle[^>]+fill="([^"]+)"', markup)
                self.assertEqual(circle_colors[-9:], [regression_color] * 9)

        def test_raw_work_not_just_the_cached_verdict_drives_replay(self):
            data = self.fixture()
            data["protocol"].update({"rawRequired": True, "requiredMetrics": ["tracker.nanosecondsPerOperation"]})
            for trial in data["trials"]:
                value = trial["values"]["cost"]
                trial["values"] = {"tracker.nanosecondsPerOperation": value}
                trial["raw"] = {"tracker": {"elapsedNs": value * 10, "operations": 10,
                                             "actualOperations": 10, "checksum": 10}}
            self.assertEqual(bench.summarize(data)["overall"], "regressed")
            data["trials"][0]["raw"]["tracker"]["elapsedNs"] += 1
            with self.assertRaisesRegex(ValueError, "raw counters"):
                bench.summarize(data)


sys.path.insert(0, str(root.parent / "bench"))
import campaign


class CampaignControls(unittest.TestCase):
    def control(self, value=100, plant="None", serial=0):
        name = "tiling.cyclesPerOperation"
        data = {"schemaVersion": 1, "protocol": {
            "version": bench.PROTOCOL, "runs": 8, "order": "counterbalanced",
            "rawRequired": True, "requiredMetrics": [name], "mode": "Offscreen",
            "floorsPercent": {name: 5}}, "trials": [], "serial": serial,
            "wallSeconds": 1, "plantB": plant, "plantPercent": 25,
            "machine": {"id": "unit-test-only"}, "sides": {}}
        for side in ("A", "B"):
            data["sides"][side] = {n: "test-only" for n in
                ("revision", "backendRevision", "executableSha256", "nativeModules",
                 "buildRecordSha256", "runtimeFiles")}
        for index in range(1, 9):
            for side in bench.pair_order(index, "counterbalanced"):
                cost = value if side == "B" else 100
                data["trials"].append({"side": side, "index": index,
                    "values": {name: cost}, "raw": {"tiling": {"operations": 10,
                    "actualOperations": 13 if plant == "Tiling" and side == "B" else 10,
                    "checksum": 10, "cpuCycles": cost * 10}}})
        data["summary"] = bench.summarize(data)
        return data

    def controls(self, directory, unresolved=False):
        groups = {"aa": [], "added": []}
        for group in groups:
            for serial in range(3):
                data = self.control(100 if group == "aa" else 125,
                                    "None" if group == "aa" else "Tiling", serial)
                if unresolved and group == "aa":
                    for trial in data["trials"]:
                        if trial["side"] == "B":
                            value = 65 + 10 * trial["index"]
                            trial["raw"]["tiling"]["cpuCycles"] = value * 10
                            trial["values"]["tiling.cyclesPerOperation"] = value
                    data["summary"] = bench.summarize(data)
                path = Path(directory) / f"{group}-{serial}.json"
                bench.write(path, data)
                groups[group].append(str(path))
        return groups

    def test_counterbalanced_replay_and_wrong_order_refusal(self):
        data = self.control()
        self.assertEqual(bench.summarize(data)["overall"], "same")
        data["protocol"]["order"] = "AB"
        with self.assertRaises(ValueError):
            bench.summarize(data)

    def test_zero_work_missing_pairs_nan_and_negative_floor_fail(self):
        for mode in ("operations", "checksum", "pairs", "nan"):
            data = self.control()
            if mode == "pairs":
                data["trials"].clear()
            elif mode == "nan":
                data["trials"][0]["values"]["tiling.cyclesPerOperation"] = math.nan
            else:
                data["trials"][0]["raw"]["tiling"][mode] = 0
            with self.assertRaises((ValueError, IndexError)):
                bench.summarize(data)
        for floor in (0, -1, math.nan, math.inf):
            with self.assertRaises(ValueError):
                bench.compare([100]*8, [100]*8, "cost", {"cost": floor})

    def test_fixtures_and_exit_zero_do_not_qualify(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fixture.json"
            data = self.control(70)
            data["evidenceClass"] = "fixture"
            data["exitCode"] = 0
            bench.write(path, data)
            with self.assertRaisesRegex(ValueError, "fixtures"):
                campaign.replay(path, bench)

    def test_duplicate_controls_not_independent(self):
        with tempfile.TemporaryDirectory() as directory:
            groups = self.controls(directory)
            groups["aa"][1] = groups["aa"][0]
            with self.assertRaisesRegex(ValueError, "independent"):
                campaign.qualify(SimpleNamespace(**groups, output=Path(directory) / "q"), bench)

    def test_qualification_and_gate_recheck_controls(self):
        with tempfile.TemporaryDirectory() as directory, contextlib.redirect_stdout(io.StringIO()):
            groups = self.controls(directory)
            output = Path(directory) / "qualification"
            self.assertEqual(campaign.qualify(SimpleNamespace(**groups, output=output), bench), 0)
            candidate = self.control(70)
            candidate["sides"]["B"]["revision"] = "different-candidate"
            path = Path(directory) / "candidate.json"
            bench.write(path, candidate)
            args = SimpleNamespace(results=path, qualification=output / "qualification.json", expect="improved")
            self.assertEqual(campaign.gate(args, bench), 0)
            # Changing qualification evidence invalidates even a favorable cached verdict.
            changed = bench.read(groups["aa"][0])
            changed["serial"] = "changed"
            bench.write(groups["aa"][0], changed)
            with self.assertRaisesRegex(ValueError, "changed"):
                campaign.gate(args, bench)

    def test_unresolved_aa_publishes_partial_not_qualification(self):
        with tempfile.TemporaryDirectory() as directory, contextlib.redirect_stdout(io.StringIO()):
            groups = self.controls(directory, unresolved=True)
            output = Path(directory) / "q"
            self.assertEqual(campaign.qualify(SimpleNamespace(**groups, output=output), bench), 3)
            report = bench.read(output / "qualification.json")
            self.assertEqual(report["status"], "partial")
            self.assertFalse(report["metrics"]["tiling.cyclesPerOperation"]["qualified"])

    def test_gate_rejects_unresolved_and_planted_candidates(self):
        with tempfile.TemporaryDirectory() as directory, contextlib.redirect_stdout(io.StringIO()):
            groups = self.controls(directory)
            output = Path(directory) / "q"
            campaign.qualify(SimpleNamespace(**groups, output=output), bench)
            candidate = self.control()
            for trial in candidate["trials"]:
                if trial["side"] == "B":
                    value = 65 + 10 * trial["index"]
                    trial["raw"]["tiling"]["cpuCycles"] = value * 10
                    trial["values"]["tiling.cyclesPerOperation"] = value
            candidate["summary"] = bench.summarize(candidate)
            candidate["exitCode"] = 0
            self.assertEqual(candidate["summary"]["overall"], "unresolved")
            path = Path(directory) / "candidate.json"
            bench.write(path, candidate)
            args = SimpleNamespace(results=path, qualification=output / "qualification.json", expect="improved")
            self.assertEqual(campaign.gate(args, bench), 3)
            bench.write(path, self.control(125, "Tiling"))
            with self.assertRaisesRegex(ValueError, "planted"):
                campaign.gate(args, bench)

    def test_added_cost_requires_actual_added_work(self):
        with tempfile.TemporaryDirectory() as directory:
            candidate = self.control(125, "Tiling")
            for trial in candidate["trials"]:
                trial["raw"]["tiling"]["actualOperations"] = 10
            path = Path(directory) / "not-really-planted.json"
            bench.write(path, candidate)
            with self.assertRaisesRegex(ValueError, "operation count"):
                campaign.replay(path, bench)

    def test_failed_or_nonraw_acquisition_never_enters_campaign(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "invalid.json"
            for kind in ("error", "raw", "time"):
                candidate = self.control()
                if kind == "error":
                    candidate["error"] = "worker failed"
                elif kind == "raw":
                    candidate["protocol"]["rawRequired"] = False
                else:
                    candidate["wallSeconds"] = 581
                bench.write(path, candidate)
                with self.assertRaises(ValueError):
                    campaign.replay(path, bench)

    def test_huge_plant_does_not_invent_small_effect_resolution(self):
        with tempfile.TemporaryDirectory() as directory, contextlib.redirect_stdout(io.StringIO()):
            groups = self.controls(directory)
            output = Path(directory) / "q"
            campaign.qualify(SimpleNamespace(**groups, output=output), bench)
            metric = bench.read(output / "qualification.json")["metrics"]["tiling.cyclesPerOperation"]
            self.assertEqual(metric["smallestTestedDetectedNominalPercent"], 25)
            self.assertIn("No extrapolation", metric["limits"])

    def test_shared_working_set_not_double_counted(self):
        rows = [{"pid": i, "cpuSecondsDelta": .1, "privateBytes": 100,
                 "workingSet": 500, "handles": 5} for i in (10, 11)]
        totals = campaign.aggregate(rows, 2)
        self.assertEqual(totals["privateCommitBytes"], 200)
        self.assertEqual(totals["cpuCorePercent"], 10)
        self.assertIsNone(totals["workingSetTotal"])
        self.assertIsNone(totals["wakeups"])
        self.assertIsNone(totals["contextSwitches"])
        self.assertEqual(totals["workingSetBytesByProcess"], {"10": 500, "11": 500})

    def test_empty_duplicate_and_reset_process_counters_fail(self):
        row = {"pid": 1, "cpuSecondsDelta": 1, "privateBytes": 100, "workingSet": 500, "handles": 1}
        for rows in ([], [row, row], [dict(row, cpuSecondsDelta=-1)]):
            with self.assertRaises(ValueError):
                campaign.aggregate(rows, 1)

    def test_external_new_evidence_roots(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ValueError):
                bench.external_output(directory)
            with self.assertRaises(ValueError):
                bench.external_output(root / "new-results")
            build = Path(directory) / "payload"
            with self.assertRaises(ValueError):
                bench.external_output(build / "result", [build])

    def test_profile_does_not_capture_and_missing_tools_refuse(self):
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as directory, contextlib.redirect_stdout(io.StringIO()):
            args = SimpleNamespace(output=Path(directory) / "profile", qt=Path(directory) / "no-qt",
                                   build=Path(directory) / "no-build", source=Path(directory) / "no-source", seconds=30)
            with patch.object(campaign.shutil, "which", return_value=None):
                self.assertEqual(campaign.profile(args, bench), 3)
            record = bench.read(Path(args.output) / "profile.json")
            self.assertFalse(record["captureExecuted"])
            self.assertEqual(record["hotspots"], [])
            self.assertIsNone(record["instrumentationOverhead"])
            self.assertGreaterEqual(len(record["refusals"]), 3)

    def test_monitor_needs_explicit_authority_and_separate_long_bound(self):
        args = SimpleNamespace(allow_process_observation=False)
        with self.assertRaises(ValueError):
            campaign.monitor(args, bench)
        for seconds in (0, 600, 86401):
            args = SimpleNamespace(allow_process_observation=True, seconds=seconds, interval=5)
            with self.assertRaises(ValueError):
                campaign.monitor(args, bench)

    @unittest.skipUnless(os.name == "nt", "Windows API fixture")
    def test_windows_reader_observes_only_this_test_process(self):
        import ctypes as C
        from ctypes import wintypes as W
        kernel = C.WinDLL("kernel32", use_last_error=True)
        kernel.GetCurrentProcess.restype = W.HANDLE
        kernel.GetProcessTimes.argtypes = [W.HANDLE] + [C.POINTER(C.c_ulonglong)] * 4
        times = [C.c_ulonglong() for _ in range(4)]
        self.assertTrue(kernel.GetProcessTimes(kernel.GetCurrentProcess(), *(C.byref(v) for v in times)))
        manifest = {"ownershipEvidence": "this test process only", "candidateIdentity": "fixture-only",
                    "processes": [{"role": "shell", "pid": os.getpid(),
                                   "imageSha256": bench.sha(sys.executable),
                                   "creationTime100ns": times[0].value}]}
        reader = campaign.ProcessReader(manifest, bench)
        try:
            rows = reader.sample()
            self.assertEqual([r["pid"] for r in rows], [os.getpid()])
            self.assertGreater(rows[0]["privateBytes"], 0)
            self.assertGreater(rows[0]["handles"], 0)
        finally:
            reader.close()
        manifest["processes"][0]["creationTime100ns"] += 1
        with self.assertRaisesRegex(ValueError, "reused|stale"):
            campaign.ProcessReader(manifest, bench)

    def test_representative_gaps_are_explicit_not_zero_sample_passes(self):
        scenarios = bench.read(root.parent / "bench/scenarios.json")["scenarios"]
        self.assertGreaterEqual(len(scenarios), 12)
        missing = [s for s in scenarios if s.get("driver", "unknown") is None]
        self.assertTrue(all(s["status"].startswith("blocked:") for s in missing))
        panel = next(s for s in scenarios if s["id"] == "panels-offscreen")
        self.assertEqual(panel["observationsPerPanelPerTrial"], 2)

    def test_scored_deadline_and_no_capture_entrypoint(self):
        self.assertLessEqual(bench.LIMIT_SECONDS, 570)
        script = (root / "Measure-ShellBenchmark.ps1").read_text()
        self.assertIn("580000", script)
        self.assertNotIn("Capture-WindowsTrace", script)
        runtime = (root.parent / "bench/tools/Measure-ShellRuntime.ps1").read_text()
        self.assertIn("[ValidateSet('Offscreen')]", runtime)
        self.assertNotIn("EnvironmentVariables['QS_TRANSITION_TRACE']", runtime)


if __name__ == "__main__":
    started = time.perf_counter()
    program = unittest.main(argv=[__file__] + rest, exit=False)
    result = program.result
    if args.output:
        output = bench.external_output(args.output)
        output.mkdir(parents=True)
        bench.write(output / "selftests.json", {
            "schemaVersion": 1, "evidenceClass": "fixture",
            "sourceRevision": bench.git(root.parent.parent, "rev-parse", "HEAD"),
            "sourceDirty": bool(bench.git(root.parent.parent, "status", "--porcelain")),
            "testSha256": bench.sha(__file__), "harnessSha256": bench.sha(root / "ShellBench.py"),
            "campaignSha256": bench.sha(root.parent / "bench/campaign.py"),
            "tests": result.testsRun, "failures": len(result.failures),
            "errors": len(result.errors), "skips": len(result.skipped),
            "wallSeconds": time.perf_counter() - started,
            "successful": result.wasSuccessful()})
    sys.exit(0 if result.wasSuccessful() else 1)
