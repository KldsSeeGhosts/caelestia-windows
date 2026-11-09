"""Prepared tooling cache identity, inventory and workflow trust boundaries."""

import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "windows/toolchain/prepared_python.py"
SPEC = importlib.util.spec_from_file_location("prepared_python", SCRIPT)
p = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(p)


class PreparedPythonTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(
            prefix="prepared-python-", dir=os.environ.get("CAELESTIA_TEST_OUTPUT_ROOT"))
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.environment = self.root / "tools"
        for name in ("pyvenv.cfg", "Scripts/python.exe", "Scripts/cmake.exe",
                     "Scripts/ninja.exe", "Lib/site-packages/setuptools/__init__.py"):
            path = self.environment / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"synthetic environment bytes, never executed")

    def test_full_inventory_round_trip_does_not_execute_cached_programs(self):
        p.record(self.environment)
        result = subprocess.run(
            [sys.executable, "-I", "-B", str(SCRIPT), "verify",
             "--environment", str(self.environment)],
            capture_output=True, text=True, timeout=30)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual("hit", result.stdout.strip())
        marker = json.loads((self.environment / p.MARKER).read_text())
        self.assertEqual(5, len(marker["files"]))
        self.assertEqual(p.python_identity(), marker["python"])

    def test_only_absent_environment_is_a_miss(self):
        self.assertEqual("miss", p.verify(self.root / "absent"))
        with self.assertRaises(OSError):
            p.verify(self.environment)
        (self.environment / p.MARKER).write_text("invalid JSON")
        with self.assertRaises(ValueError):
            p.verify(self.environment)

    def test_modified_added_and_missing_files_are_refused(self):
        target = self.environment / "Lib/site-packages/setuptools/__init__.py"
        original = target.read_bytes()
        p.record(self.environment)
        target.write_bytes(b"corrupt")
        with self.assertRaises(ValueError):
            p.verify(self.environment)
        target.write_bytes(original)
        extra = self.environment / "Lib/site-packages/extra.pth"
        extra.write_text("import sys; raise RuntimeError('must never execute')")
        with self.assertRaises(ValueError):
            p.verify(self.environment)
        extra.unlink()
        target.unlink()
        with self.assertRaises(ValueError):
            p.verify(self.environment)

    def test_contract_interpreter_and_location_changes_are_refused(self):
        p.record(self.environment)
        with patch.object(p, "contract_digest", return_value="changed"):
            with self.assertRaises(ValueError):
                p.verify(self.environment)
        with patch.object(p, "python_identity", return_value={"version": "different"}):
            with self.assertRaises(ValueError):
                p.verify(self.environment)
        relocated = self.root / "relocated"
        shutil.copytree(self.environment, relocated)
        with self.assertRaises(ValueError):
            p.verify(relocated)

    def test_same_version_interpreter_rebuild_changes_cache_key(self):
        original = p.python_identity()
        first = p.identity_digest()
        with patch.object(p, "python_identity",
                          return_value={**original, "executableSha256": "different"}):
            self.assertNotEqual(first, p.identity_digest())
        result = subprocess.run([sys.executable, "-I", "-B", str(SCRIPT), "identity"],
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(first, result.stdout.strip())

    @unittest.skipUnless(os.name == "nt", "Windows PowerShell boundary")
    def test_preparation_keeps_base_python_when_toolchain_changes_path(self):
        environment = self.root / "real-tools"
        subprocess.run([sys.executable, "-m", "venv", "--without-pip", str(environment)],
                       check=True, capture_output=True, timeout=30)
        for name in ("cmake.exe", "ninja.exe"):
            (environment / "Scripts" / name).write_bytes(b"synthetic tool, never executed")
        prepare = (ROOT / "windows/scripts/Prepare-Toolchain.ps1").read_text()
        resolution = [line for line in prepare.splitlines()
                      if line.startswith("$Python = (Get-Command $Python -CommandType Application")]
        self.assertEqual(1, len(resolution))
        harness = self.root / "shadow-python.ps1"
        harness.write_text(
            "param($BaseBin, $Environment, $Verifier)\n"
            "$ErrorActionPreference = 'Stop'\n"
            "$Python = 'python'\n"
            "$env:PATH = \"$BaseBin;$env:PATH\"\n"
            + resolution[0] + "\n"
            # This is the actual PATH change made by Enter-CaelestiaToolchain.
            "$env:PATH = \"$Environment\\Scripts;$env:PATH\"\n"
            "if ((Get-Command python -CommandType Application | Select-Object -First 1).Source -eq $Python) {\n"
            " throw 'Fixture did not shadow the base Python'\n}\n"
            "& $Python -I -B $Verifier record --environment $Environment\n"
            "if ($LASTEXITCODE -ne 0) { throw 'record failed' }\n"
            "$basePython = Join-Path $BaseBin 'python.exe'\n"
            "$state = & $basePython -I -B $Verifier verify --environment $Environment\n"
            "if ($LASTEXITCODE -ne 0 -or $state -ne 'hit') { throw 'base Python refused the recorded cache' }\n")
        command = ["powershell.exe", "-NoProfile", "-NonInteractive", "-File", str(harness),
                   "-BaseBin", str(Path(sys.executable).parent), "-Environment", str(environment),
                   "-Verifier", str(SCRIPT)]
        result = subprocess.run(command, capture_output=True, text=True, timeout=30)
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        # Reproduce the original bug with the same real venv and PATH change.
        harness.write_text(harness.read_text().replace(resolution[0], "# unpinned interpreter"))
        result = subprocess.run(command, capture_output=True, text=True, timeout=30)
        self.assertNotEqual(0, result.returncode)
        self.assertIn("base Python refused the recorded cache", result.stderr)

    def test_missing_required_tools_cannot_be_recorded(self):
        (self.environment / "Scripts/cmake.exe").unlink()
        with self.assertRaises(ValueError):
            p.record(self.environment)
        self.assertFalse((self.environment / p.MARKER).exists())

    def test_linked_files_are_refused(self):
        outside = self.root / "outside"
        outside.write_text("not an environment file")
        link = self.environment / "link"
        try:
            link.symlink_to(outside)
        except OSError:
            self.skipTest("this Windows account cannot create symlinks")
        with self.assertRaises(ValueError):
            p.record(self.environment)

    def test_workflow_uses_exact_keys_and_only_main_can_save(self):
        workflow = (ROOT / ".github/workflows/windows-build.yml").read_text()
        self.assertEqual((ROOT / "windows/ci/windows-build.yml.template").read_bytes(),
                         (ROOT / ".github/workflows/windows-build.yml").read_bytes())
        keys = [line.strip() for line in workflow.splitlines()
                if "key: windows-x64-prepared-python-v1-" in line]
        self.assertEqual(2, len(keys))
        self.assertEqual(1, len(set(keys)))
        for name in p.INPUTS:
            if name.endswith(".lock.txt"):
                self.assertIn("'windows/toolchain/*.lock.txt'", keys[0])
            else:
                self.assertIn(f"'{name}'", keys[0])
        self.assertIn("steps.python.outputs.python-version", keys[0])
        self.assertIn("steps.python-runtime.outputs.digest", keys[0])
        self.assertEqual(2, workflow.count("id: python-runtime"))
        self.assertEqual(2, workflow.count("-ReusePreparedPython"))
        for name, next_name in (("fixtures", "build"), ("build", "pair")):
            job = workflow.split(f"\n  {name}:\n", 1)[1].split(f"\n  {next_name}:\n", 1)[0]
            block = job.split("      - name: Restore verified prepared Python", 1)[1].split(
                "      - name:", 1)[0]
            self.assertIn(r"path: C:\t-public\tools", block)
            self.assertNotIn("restore-keys:", block)
        candidate = workflow.split("\n  candidate:\n", 1)[1].split("\n  publish:\n", 1)[0]
        self.assertNotIn("prepared-python-v1-", candidate)
        self.assertIn("Prepare-DeploymentToolchain.ps1", candidate)
        save = workflow.split("      - name: Save verified prepared Python from trusted main only", 1)[1].split(
            "      - name:", 1)[0]
        self.assertIn("github.ref == 'refs/heads/main' && github.event_name == 'push'", save)
        self.assertIn("steps.python-tools.outputs.cache-primary-key", save)
        self.assertNotIn("always()", save)
        prepare = (ROOT / "windows/scripts/Prepare-Toolchain.ps1").read_text()
        self.assertLess(prepare.index("$preparedVerifier verify"), prepare.index("& $venvPython"))
        self.assertLess(prepare.index("'final-assertions'"), prepare.index("$preparedVerifier record"))


if __name__ == "__main__":
    unittest.main()
