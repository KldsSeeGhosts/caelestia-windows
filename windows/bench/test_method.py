"""No benchmarks run here. Pure analysis, privacy, and provenance regressions."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import idle_work

spec = importlib.util.spec_from_file_location("perf_method", Path(__file__).with_name("method.py"))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def receipt():
    identity = {"sourceSha": "a" * 40, "nativeSourceSha": "b" * 40,
                "backendPin": "c" * 40, "sourceDirty": False,
                "binaries": {"private-user-name.exe": "d" * 64},
                "toolchain": {"qtVersion": "6.11.3", "clangVersion": "C:/Users/private/tool"}}
    metrics = {name: 100. for name in m.METRICS}
    return {"protocol": m.PROTOCOL, "complete": True, "purpose": "aa",
            "acquisitionId": "first", "scenario": "idle", "cache": "cold",
            "spinMs": 0, "instrumentation": "none",
            "identities": {"A": identity, "B": copy.deepcopy(identity)},
            "pairs": [{"order": ["A", "B"], "A": {"metrics": dict(metrics)},
                       "B": {"metrics": dict(metrics)}} for _ in range(12)]}


class Analysis(unittest.TestCase):
    def test_idle_count_controls_fail_closed(self):
        row = {"minutes": 60.25 / 60, "processStarts": 4,
               "clockWakeups": 60, "plantedWakeups": 0}
        session = {name: dict(row) for name in ("a", "aa", "added", "b")}
        session["added"].update(processStarts=8, plantedWakeups=60)
        session["b"].update(processStarts=0, clockWakeups=1)
        self.assertEqual({"recorderStartsSaved": 4, "clockWakeupsSaved": 59},
                         idle_work.qualify(session))
        for name, metric, value in (
                ("aa", "processStarts", 3), ("aa", "clockWakeups", 63),
                ("added", "processStarts", 7), ("added", "plantedWakeups", 0),
                ("added", "clockWakeups", 65), ("b", "processStarts", 1),
                ("b", "clockWakeups", 60), ("a", "minutes", 0)):
            bad = copy.deepcopy(session)
            bad[name][metric] = value
            with self.subTest(name=name, metric=metric), self.assertRaises(ValueError):
                idle_work.qualify(bad)

    def test_all_four_verdicts(self):
        a = [100.] * 12
        self.assertEqual("improved", m.analyze(a, [80.] * 12, 5)["verdict"])
        self.assertEqual("regressed", m.analyze(a, [120.] * 12, 5)["verdict"])
        self.assertEqual("not-detected", m.analyze(a, a, 5)["verdict"])
        self.assertEqual("inconclusive", m.analyze(a, [50., 150.] * 6, 5)["verdict"])

    def test_insufficient_samples_do_not_prove_anything(self):
        row = m.analyze([10.], [1000.], 1)
        self.assertEqual("inconclusive", row["verdict"])
        self.assertIsNone(row["ci95"])

    def test_tail_claims_are_not_enabled_by_pair_count(self):
        self.assertTrue(all("insufficient" in v for v in
                            m.analyze([1.] * 1000, [1.] * 1000, 1)["tails"].values()))

    def test_floor_is_absolute_and_interval_must_clear_it(self):
        row = m.analyze([100.] * 12, [104.] * 12, 5)
        self.assertEqual("not-detected", row["verdict"])
        self.assertEqual([4., 4.], row["ci95"])

    def test_bad_values_and_mismatched_pairs_refused(self):
        for a, b in (([], []), ([1], [1, 2]), ([float("nan")], [1]), ([-1], [1])):
            with self.assertRaises(ValueError):
                m.analyze(a, b, 1)

    def test_exit_success_and_edited_analysis_are_not_verdicts(self):
        r = receipt()
        r["analysis"] = {"workMs": {"verdict": "improved"}}
        self.assertEqual("not-detected", m.summarize(r)["workMs"]["verdict"])
        r["complete"] = False
        with self.assertRaises(ValueError):
            m.summarize(r)

    def test_qualification_is_metric_specific(self):
        aa, added = receipt(), receipt()
        added.update(purpose="added", spinMs=75, acquisitionId="second")
        for pair in added["pairs"]:
            pair["B"]["metrics"]["cpuMs"] += 600
            pair["B"]["metrics"]["workMs"] += 75
        q = m.qualify(aa, added)
        self.assertTrue(q["workMs"]["qualified"])
        self.assertTrue(q["cpuMs"]["qualified"])
        self.assertFalse(q["privateMiB"]["qualified"])
        self.assertFalse(q["readyMs"]["qualified"])

    def test_qualification_refuses_reuse_and_different_conditions(self):
        aa, added = receipt(), receipt()
        added.update(purpose="added", spinMs=75)
        with self.assertRaises(ValueError):
            m.qualify(aa, added)
        added["acquisitionId"] = "second"
        added["cache"] = "warm"
        with self.assertRaises(ValueError):
            m.qualify(aa, added)

    def gate_inputs(self):
        compare = receipt()
        compare.update(purpose="compare", acquisitionId="comparison")
        for pair in compare["pairs"]:
            pair["B"]["metrics"]["workMs"] -= 20
        controls = []
        for i in range(3):
            aa, added = receipt(), receipt()
            aa["acquisitionId"] = f"aa-{i}"
            added.update(purpose="added", spinMs=75, acquisitionId=f"added-{i}")
            for pair in added["pairs"]:
                pair["B"]["metrics"]["workMs"] += 75
            controls.append((aa, added))
        return compare, controls

    def test_gate_requires_improvement_and_independent_controls(self):
        compare, controls = self.gate_inputs()
        self.assertTrue(m.gate(compare, controls, ["workMs"])["accepted"])
        self.assertFalse(m.gate(compare, controls[:1], ["workMs"])["accepted"])
        self.assertFalse(m.gate(compare, controls[:1] * 3, ["workMs"])["accepted"])
        for pair in compare["pairs"]:
            pair["B"]["metrics"]["workMs"] = 100
        self.assertIn("required-metric-not-improved", m.gate(compare, controls, ["workMs"])["reasons"])

    def test_gate_rejects_dirty_environment_change_and_other_regressions(self):
        compare, controls = self.gate_inputs()
        compare["identities"]["B"]["sourceDirty"] = True
        self.assertIn("dirty-source", m.gate(compare, controls, ["workMs"])["reasons"])
        compare["identities"]["B"]["toolchain"] = {"qtVersion": "6.11.2"}
        self.assertIn("different-environment-or-method", m.gate(compare, controls, ["workMs"])["reasons"])
        for pair in compare["pairs"]:
            pair["B"]["metrics"]["privateMiB"] += 8
        self.assertIn("regression", m.gate(compare, controls, ["workMs"])["reasons"])

    def test_gate_rejects_unqualified_metric_and_planted_confirmation(self):
        compare, controls = self.gate_inputs()
        self.assertIn("unqualified-required-metric", m.gate(compare, controls, ["privateMiB"])["reasons"])
        compare["spinMs"] = 1
        self.assertIn("not-unplanted-confirmation", m.gate(compare, controls, ["workMs"])["reasons"])

    def test_offscreen_environment_clears_live_authority_and_isolates_profile(self):
        with patch.dict(m.os.environ, {"CAELESTIA_WINDOWS_AUDIO_CONTROLS": "1",
                                       "QT_QPA_PLATFORM": "windows", "QS_TRANSITION_TRACE": "secretmarker"},
                        clear=False):
            env = m.environment(Path("qt"), Path("build"), Path("stage"), "idle", 0)
        self.assertEqual("offscreen", env["QT_QPA_PLATFORM"])
        self.assertEqual("software", env["QT_QUICK_BACKEND"])
        self.assertNotIn("CAELESTIA_WINDOWS_AUDIO_CONTROLS", env)
        self.assertNotIn("QS_TRANSITION_TRACE", env)
        self.assertIn("stage", env["CAELESTIA_PROFILE_ROOT"])
        self.assertEqual("off", env["CAELESTIA_WINDOWS_TILING"])

    def test_public_state_hashes_do_not_copy_paths(self):
        r = receipt()
        r["pairs"][0]["A"].update(profileSha256="a" * 64, cacheBeforeSha256="secretmarker")
        out = m.export_public(r)
        self.assertEqual({"profileSha256": "a" * 64}, out["stateHashes"]["A"][0])
        self.assertNotIn("secretmarker", json.dumps(out))

    def test_public_export_drops_unknown_fields_and_private_strings(self):
        r = receipt()
        r["path"] = "C:/Users/secretmarker"
        r["error"] = "device serial 1234"
        r["identities"]["A"]["machine"] = "secretmarker"
        out = json.dumps(m.export_public(r))
        for text in ("secretmarker", "serial", "Users", "machine", "private-user-name"):
            self.assertNotIn(text, out)
        self.assertIn("6.11.3", out)

    def test_public_export_rejects_nonhash_identity(self):
        r = receipt()
        r["identities"]["A"]["backendPin"] = "C:/Users/private"
        with self.assertRaises(ValueError):
            m.export_public(r)

    def test_public_export_rejects_free_text_in_numeric_plant_field(self):
        for value in ("secretmarker", True, -1, 101):
            r = receipt()
            r["spinMs"] = value
            with self.assertRaises(ValueError):
                m.export_public(r)

    def test_private_bytes_add_but_shared_working_set_does_not(self):
        rows = [dict(cpuMs=1, privateBytes=12, handles=2, gdi=3, user=4, workingSet=900)] * 2
        self.assertEqual(24, m.totals(rows)["privateBytes"])
        self.assertNotIn("workingSet", m.totals(rows))

    def test_identity_records_binary_receipt_and_toolchain_hashes(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for name in ("logs", "quickshell", "install/qml", "bin", "plugins/platforms"):
                (root / name).mkdir(parents=True, exist_ok=True)
            m.write(root / "logs/build.json", {"backendRevision": "c" * 40,
                    "sourceRevision": "a" * 40, "toolchain": {"qtVersion": "6.11.3"}})
            for name in ("quickshell/qs.exe", "bin/Qt6Core.dll", "bin/Qt6Quick.dll",
                         "plugins/platforms/qoffscreen.dll"):
                (root / name).write_bytes(b"first")
            def cmd(args, **kwargs):
                if "HEAD:windows/deps/quickshell" in args:
                    return "c" * 40
                if "rev-parse" in args:
                    return "a" * 40
                return ""
            with patch.object(m, "command", cmd):
                first = m.identity(root, root, root)
                (root / "quickshell/qs.exe").write_bytes(b"changed")
                second = m.identity(root, root, root)
            self.assertEqual("6.11.3", first["toolchain"]["qtVersion"])
            self.assertNotEqual(first["binaries"], second["binaries"])
            self.assertEqual(m.sha(root / "logs/build.json"), first["buildReceiptSha256"])

    def test_profile_parser_counts_ranges_and_rejects_empty_or_entities(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "trace.qtd"
            path.write_text('<trace><event index="1"><filename>Private.qml</filename></event>'
                            '<range eventIndex="1" startTime="1" duration="100"/></trace>')
            self.assertEqual(100, m.profile_events(path)[0]["durationNs"])
            path.write_text("<trace/>")
            with self.assertRaises(ValueError):
                m.profile_events(path)
            path.write_text('<!DOCTYPE test><trace/>')
            with self.assertRaises(ValueError):
                m.profile_events(path)


if __name__ == "__main__":
    unittest.main()
