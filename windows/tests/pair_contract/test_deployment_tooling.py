"""Deployment cache scope, archive verification and fail-closed fallback."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[3]


class DeploymentWorkflowTests(unittest.TestCase):
    def test_candidate_only_restores_verified_deployment_subset(self):
        workflow = (ROOT / ".github/workflows/windows-build.yml").read_text()
        self.assertEqual((ROOT / ".github/workflows/windows-build.yml").read_bytes(),
                         (ROOT / "windows/ci/windows-build.yml.template").read_bytes())
        build = workflow.split("\n  build:\n", 1)[1].split("\n  pair:\n", 1)[0]
        candidate = workflow.split("\n  candidate:\n", 1)[1].split("\n  publish:\n", 1)[0]
        lookup = build.split("name: Look up verified deployment tools", 1)[1].split("- name:", 1)[0]
        restore = candidate.split("name: Restore verified deployment tooling", 1)[1].split("- name:", 1)[0]
        self.assertIn("lookup-only: true", lookup)
        for block in (lookup, restore):
            self.assertIn("path: |\n            C:\\t-public\\Qt\n            C:\\t-public\\downloads\\qt", block)
            self.assertNotIn("restore-keys:", block)
            self.assertNotIn("LLVM", block)
            self.assertNotIn(r"C:\t-public\tools", block)
        keys = re.findall(r"key: (windows-x64-deployment-v1-[^\n]+)", workflow)
        self.assertEqual(2, len(keys))
        self.assertEqual(keys[0], keys[1])
        for name in ("windows/toolchain.json", "windows/toolchain/*.lock.txt",
                     "windows/scripts/Prepare-Toolchain.ps1", "windows/scripts/Prepare-DeploymentToolchain.ps1"):
            self.assertIn(f"'{name}'", keys[0])
        save = build.split("name: Save verified deployment tools", 1)[1].split("- name:", 1)[0]
        self.assertIn("steps.deployment-tools.outputs.cache-hit != 'true'", save)
        self.assertIn("github.ref == 'refs/heads/main' && github.event_name == 'push'", save)
        self.assertIn("steps.deployment-tools.outputs.cache-primary-key", save)
        self.assertLess(build.index("run --stage prepare --echo"), build.index("name: Save verified deployment tools"))
        self.assertNotIn("actions/cache/save@", candidate)
        self.assertNotIn("prepared-python-v1-", candidate)
        self.assertNotIn("tools-contract-v1-", candidate)
        self.assertIn("if ($env:DEPLOYMENT_CACHE_HIT -ne 'true') { $fallback += '-AllowFullPreparation' }", candidate)
        self.assertIn("Prepare-DeploymentToolchain.ps1", candidate)
        self.assertIn("C:/t-public/logs/deployment-prepare-timing.json", candidate)
        self.assertIn("C:/t-public/logs/prepare-timing.json", candidate)
        # Existing independent compiler receipt and exact CRT checks remain.
        release = (ROOT / "windows/scripts/New-CaelestiaRelease.ps1").read_text()
        self.assertIn("Assert-CaelestiaBuildToolchain $build", release)
        self.assertIn("Assert-CaelestiaReleaseVCRedist -Toolchain $build.toolchain", release)
        evidence = (ROOT / "windows/ci/nexus_candidate.py").read_text()
        self.assertIn('receipt["toolchain"]["actual"].items()', evidence)


@unittest.skipUnless(os.name == "nt", "Windows PowerShell boundary")
class DeploymentPreparationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(
            prefix="deployment-tools-", dir=os.environ.get("CAELESTIA_TEST_OUTPUT_ROOT"))
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.scripts = self.root / "source/windows/scripts"
        self.scripts.mkdir(parents=True)
        for name in ("Prepare-DeploymentToolchain.ps1", "Caelestia-Toolchain.ps1"):
            shutil.copyfile(ROOT / "windows/scripts" / name, self.scripts / name)
        # No synthetic executable is ever run by these refusal controls.
        self.tools = self.root / "tools"
        self.archive = self.tools / "downloads/qt/qtbase-Windows-Windows_11_24H2-MSVC2022-Windows-Windows_11_24H2-X86_64.7z"
        self.archive.parent.mkdir(parents=True)
        self.archive.write_bytes(b"synthetic archive, never extracted")
        self.qt = self.tools / "Qt/6.11.3/msvc2022_64"
        self.required = ("bin/qtpaths.exe", "bin/windeployqt.exe", "bin/Qt6Quick.dll", "bin/Qt6Svg.dll",
                         "bin/Qt6ShaderTools.dll", "plugins/imageformats/qjpeg.dll")
        for name in self.required:
            path = self.qt / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"synthetic file, never executed")
        spec = json.loads((ROOT / "windows/toolchain.json").read_text())
        spec["qtDownloads"] = [{"module": "qtbase", "sha256": hashlib.sha256(self.archive.read_bytes()).hexdigest()}]
        (self.scripts.parent / "toolchain.json").write_text(json.dumps(spec))
        self.fallback = self.tools / "fallback.called"
        (self.scripts / "Prepare-Toolchain.ps1").write_text(
            "param($ToolRoot, $Python, [switch]$InstallRust)\n"
            "if (-not $InstallRust) { throw 'Missing canonical Rust preparation.' }\n"
            "[IO.File]::WriteAllText((Join-Path $ToolRoot 'fallback.called'), $Python)\nexit 7\n")

    def prepare(self, *args):
        return subprocess.run(
            ["powershell.exe", "-NoProfile", "-NonInteractive", "-File",
             str(self.scripts / "Prepare-DeploymentToolchain.ps1"), "-ToolRoot", str(self.tools), *args],
            capture_output=True, text=True, timeout=30)

    def check_failed_without_fallback(self, expected):
        result = self.prepare()
        self.assertNotEqual(0, result.returncode)
        self.assertIn(expected, result.stderr)
        self.assertFalse(self.fallback.exists())
        timing = json.loads((self.tools / "logs/deployment-prepare-timing.json").read_text(encoding="utf-8-sig"))
        self.assertEqual("deployment", timing["profile"])
        self.assertNotIn(str(self.root), json.dumps(timing))

    def test_archive_mismatch_is_fatal_before_executing_cached_tools(self):
        self.archive.write_bytes(b"modified bytes")
        self.check_failed_without_fallback("checksum mismatch")

    def test_missing_archive_does_not_implicitly_download_or_prepare(self):
        self.archive.unlink()
        self.check_failed_without_fallback("checksum mismatch or missing archive")

    def test_missing_required_file_is_fatal_before_executing_any_tool(self):
        (self.qt / "bin/windeployqt.exe").unlink()
        self.check_failed_without_fallback("Incomplete deployment Qt prerequisite")

    def test_missing_or_incompatible_supplier_metadata_is_fatal(self):
        self.check_failed_without_fallback("Missing Qt supplier build metadata")
        path = self.qt / "sbom/qtbase-6.11.3.cdx.json"
        path.parent.mkdir()
        path.write_text(json.dumps({"components": [{"name": "Compiler MSVC", "version": "wrong"}]}))
        self.check_failed_without_fallback("Unsupported Qt qtbase supplier Compiler MSVC")

    def test_explicit_cold_fallback_preserves_canonical_failure(self):
        result = self.prepare("-AllowFullPreparation", "-Python", "synthetic-base-python")
        self.assertNotEqual(0, result.returncode)
        self.assertIn("Full deployment-cache miss preparation failed", result.stderr)
        self.assertEqual("synthetic-base-python", self.fallback.read_text())


if __name__ == "__main__":
    unittest.main()
