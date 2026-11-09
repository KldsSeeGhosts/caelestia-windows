"""Pinned accelerator archive caching never changes the build acceptance path."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "windows/ci/Prepare-Sccache.ps1"
ARCHIVE = "sccache-v0.15.0-x86_64-pc-windows-msvc.tar.gz"


class SccacheArchiveTests(unittest.TestCase):
    def test_exact_cache_is_isolated_verified_and_only_written_by_main(self):
        workflow = (ROOT / ".github/workflows/windows-build.yml").read_text()
        template = (ROOT / "windows/ci/windows-build.yml.template").read_bytes()
        self.assertEqual((ROOT / ".github/workflows/windows-build.yml").read_bytes(), template)
        jobs = {}
        for name in ("fixtures", "build"):
            jobs[name] = re.split(r"(?m)^  \w+:\n", workflow.split(f"\n  {name}:\n")[1])[0]
            job = jobs[name]
            self.assertEqual(1, job.count("key: windows-x64-sccache-archive-v1-"))
            self.assertIn("hashFiles('windows/ci/Prepare-Sccache.ps1')", job)
            self.assertIn("-ArchiveRoot C:\\sccache-tool", job)
            self.assertLess(job.index("name: Restore pinned compiler-cache archive"),
                            job.index("name: Prepare optional pinned compiler cache"))
            restore = job.split("name: Restore pinned compiler-cache archive", 1)[1].split("- name:", 1)[0]
            self.assertNotIn("restore-keys:", restore)
            self.assertIn("path: C:\\sccache-tool", restore)
        build = jobs["build"]
        save = build.split("name: Save verified compiler-cache archive", 1)[1].split("- name:", 1)[0]
        self.assertIn("env.CI_COMPILER_LAUNCHER != ''", save)
        self.assertIn("steps.sccache-tool.outputs.cache-hit != 'true'", save)
        self.assertIn("github.ref == 'refs/heads/main' && github.event_name == 'push'", save)
        self.assertNotIn("||", save)
        self.assertLess(build.index("name: Prepare optional pinned compiler cache"),
                        build.index("name: Save verified compiler-cache archive"))
        self.assertNotIn("name: Save verified compiler-cache archive", jobs["fixtures"])
        script = SCRIPT.read_text()
        self.assertLess(script.index("Get-FileHash"), script.index("tar.exe"))
        self.assertLess(script.index("sccache version mismatch"), script.index("CI_COMPILER_LAUNCHER="))
        self.assertIn("--retry 2 --retry-delay 2 --retry-max-time 120", script)

    @unittest.skipUnless(os.name == "nt", "Windows PowerShell boundary")
    def test_failed_download_removes_partial_archive_and_does_not_set_launcher(self):
        with tempfile.TemporaryDirectory(dir=os.environ.get("CAELESTIA_TEST_OUTPUT_ROOT")) as temp:
            root = Path(temp)
            env_file = root / "github-env"
            wrapper = root / "check.ps1"
            wrapper.write_text("""
param($Prepare, $Root)
$ErrorActionPreference = 'Stop'
function curl.exe {
    [IO.File]::WriteAllText($args[-1], 'partial download')
    $global:LASTEXITCODE = 22
}
& $Prepare -ToolRoot "$Root/tools" -ArchiveRoot "$Root/archives" -ReleaseBaseUrl 'http://127.0.0.1:9'
""")
            environment = os.environ.copy()
            environment["GITHUB_ENV"] = str(env_file)
            environment.pop("CI_COMPILER_LAUNCHER", None)
            result = subprocess.run(["powershell.exe", "-NoProfile", "-NonInteractive", "-File",
                                     str(wrapper), str(SCRIPT), temp], env=environment,
                                    capture_output=True, text=True, timeout=30)
            self.assertEqual(0, result.returncode, result.stdout + result.stderr)
            self.assertIn("building without the compiler cache", result.stdout)
            self.assertFalse((root / "archives" / ARCHIVE).exists())
            self.assertFalse(env_file.exists())

    @unittest.skipUnless(os.name == "nt", "Windows PowerShell boundary")
    def test_corrupt_cached_archive_fails_before_extraction_or_execution(self):
        with tempfile.TemporaryDirectory(dir=os.environ.get("CAELESTIA_TEST_OUTPUT_ROOT")) as temp:
            root = Path(temp)
            archive_root = root / "archives"
            archive_root.mkdir()
            (archive_root / ARCHIVE).write_bytes(b"not the pinned archive")
            env_file = root / "github-env"
            environment = os.environ.copy()
            environment["GITHUB_ENV"] = str(env_file)
            result = subprocess.run(["powershell.exe", "-NoProfile", "-NonInteractive", "-File",
                                     str(SCRIPT), "-ToolRoot", str(root / "tools"),
                                     "-ArchiveRoot", str(archive_root)], env=environment,
                                    capture_output=True, text=True, timeout=30)
            self.assertNotEqual(0, result.returncode)
            self.assertIn("sccache checksum mismatch", result.stderr)
            self.assertFalse((root / "tools").exists())
            self.assertFalse(env_file.exists())


if __name__ == "__main__":
    unittest.main()
