"""Data-only ZIP/path guard regressions. No installers or Qt processes run."""

import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[3]


@unittest.skipUnless(os.name == "nt", "Windows PowerShell boundary")
class UpdatePathTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(
            prefix="update-path-", dir=os.environ.get("CAELESTIA_TEST_OUTPUT_ROOT"))
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.module = ROOT / "windows/scripts/Caelestia-Update.ps1"

    def ps(self, script, *args):
        harness = self.root / "harness.ps1"
        harness.write_text(
            "param($Module, $Root, $Zip, $Destination, [long]$Entries, [long]$Size)\n"
            "$ErrorActionPreference = 'Stop'\n"
            ". $Module\n" + script)
        return subprocess.run(
            ["powershell.exe", "-NoProfile", "-NonInteractive", "-File", str(harness),
             "-Module", str(self.module), "-Root", str(self.root), *map(str, args)],
            capture_output=True, text=True, timeout=30)

    def test_ancestors_are_checked_again_and_existing_or_missing_paths_work(self):
        result = self.ps(
            "$plain = Join-Path $Root 'plain'\n"
            "$target = Join-Path $Root 'target'\n"
            "[IO.Directory]::CreateDirectory($plain) | Out-Null\n"
            "[IO.Directory]::CreateDirectory($target) | Out-Null\n"
            "Assert-CaelestiaUpdatePath $plain\n"
            "Assert-CaelestiaUpdatePath ($plain + '\\')\n"
            "$leaf = Join-Path $plain 'not-created\\leaf'\n"
            "Assert-CaelestiaUpdatePath $leaf\n"
            "[IO.File]::WriteAllText((Join-Path $plain 'file'), 'fixture')\n"
            "Assert-CaelestiaUpdatePath (Join-Path $plain 'file')\n"
            "[IO.File]::Delete((Join-Path $plain 'file'))\n"
            "[IO.Directory]::Delete($plain)\n"
            "New-Item -ItemType Junction -Path $plain -Target $target | Out-Null\n"
            "$refused = $false\n"
            "try { Assert-CaelestiaUpdatePath $leaf }\n"
            "catch { if ($_.Exception.Message -ne 'Linked update path refused.') { throw }; $refused = $true }\n"
            "if (-not $refused) { throw 'A changed ancestor bypassed verification' }\n"
            "[IO.Directory]::Delete($target)\n"
            "$refused = $false\n"
            "try { Assert-CaelestiaUpdatePath $leaf }\n"
            "catch { if ($_.Exception.Message -ne 'Linked update path refused.') { throw }; $refused = $true }\n"
            "if (-not $refused) { throw 'A broken junction bypassed verification' }\n")
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)

    def test_noncanonical_paths_and_reserved_components_still_fail(self):
        result = self.ps(
            "foreach ($path in @('C:\\', 'relative', '\\\\server\\share\\file',\n"
            " ($Root + '\\plain\\..\\file'), ($Root + '/file'), ($Root + '\\CON'),\n"
            " ($Root + '\\trailing.'), ($Root + '\\file:stream'))) {\n"
            " $refused = $false\n"
            " try { Assert-CaelestiaUpdatePath $path } catch { $refused = $true }\n"
            " if (-not $refused) { throw 'Unsafe path was accepted' }\n}\n")
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)

    def test_zip_bounds_links_collisions_and_traversal_still_fail(self):
        cases = [
            ("valid", [("bundle/nested/file.txt", b"fixture", None)], False),
            ("traversal", [("bundle/../outside", b"x", None)], True),
            ("backslash", [("bundle\\outside", b"x", None)], True),
            ("reserved", [("bundle/CON", b"x", None)], True),
            ("duplicate", [("bundle/a", b"x", None), ("bundle/A", b"x", None)], True),
            ("collision", [("bundle/a", b"x", None), ("bundle/a/b", b"x", None)], True),
            ("symlink", [("bundle/link", b"target", 0o120777 << 16)], True),
            ("size", [("bundle/a", b"x", None)], True),
        ]
        for name, rows, refused in cases:
            with self.subTest(name=name):
                archive = self.root / (name + ".zip")
                destination = self.root / name
                with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as output:
                    for path, body, attributes in rows:
                        entry = zipfile.ZipInfo(path)
                        # ZipInfo normalizes Windows separators on this host.
                        # Preserve the hostile bytes for the backslash case.
                        entry.filename = path
                        entry.orig_filename = path
                        if attributes is not None:
                            entry.create_system = 3
                            entry.external_attr = attributes
                        output.writestr(entry, body)
                size = sum(len(row[1]) for row in rows) + (1 if name == "size" else 0)
                result = self.ps(
                    "$null = Expand-CaelestiaUpdate $Zip $Destination 'bundle' $Entries $Size\n",
                    "-Zip", archive, "-Destination", destination, "-Entries", len(rows), "-Size", size)
                self.assertEqual(refused, result.returncode != 0, result.stdout + result.stderr)
                if refused:
                    self.assertFalse(destination.exists())
                else:
                    self.assertEqual(hashlib.sha256(b"fixture").digest(), hashlib.sha256(
                        (destination / "bundle/nested/file.txt").read_bytes()).digest())

    def test_payload_timing_artifacts_are_path_free_and_separate_from_assets(self):
        workflow = (ROOT / ".github/workflows/windows-build.yml").read_text()
        self.assertEqual((ROOT / ".github/workflows/windows-build.yml").read_bytes(),
                         (ROOT / "windows/ci/windows-build.yml.template").read_bytes())
        self.assertIn("C:/nexus-candidate/independent-payload/verification-timing.json", workflow)
        publication = workflow.split("      - name: Sanitized publication verification timings\n", 1)[1]
        self.assertIn("if: always()", publication)
        self.assertIn("path: C:/nexus-publish/payload-check/verification-timing.json", publication)
        self.assertNotIn(".log", publication)
        source = (ROOT / "windows/ci/Test-NexusCandidatePayload.ps1").read_text()
        timing = source.split("function Save-PayloadTiming", 1)[1].split(
            ". (Join-Path", 1)[0]
        self.assertIn("phase = $Phase; seconds =", timing)
        self.assertNotIn("Exception", timing)
        exporter = (ROOT / "windows/ci/New-NexusCandidate.ps1").read_text()
        self.assertNotIn("verification-timing", exporter)

    def test_timing_never_writes_into_an_existing_output_before_extraction(self):
        result = self.ps(
            "$source = Join-Path (Split-Path -Parent (Split-Path -Parent $Module)) 'ci\\Test-NexusCandidatePayload.ps1'\n"
            "$tokens = $null; $errors = $null\n"
            "$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)\n"
            "if ($errors.Count) { throw 'Verifier does not parse' }\n"
            "$function = $ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and\n"
            " $node.Name -eq 'Save-PayloadTiming'}, $true)\n"
            ". ([scriptblock]::Create($function.Extent.Text))\n"
            "$OutputDirectory = $Root\n"
            "$payloadClock = [Diagnostics.Stopwatch]::StartNew()\n"
            "$payloadTimings = [Collections.Generic.List[object]]::new()\n"
            "$payloadTimingReady = $false\n"
            "Save-PayloadTiming 'metadata-and-zip-hash'\n"
            "$file = Join-Path $Root 'verification-timing.json'\n"
            "if (Test-Path $file) { throw 'Timing modified an unqualified existing output' }\n"
            "$payloadTimingReady = $true\n"
            "Save-PayloadTiming 'zip-extraction'\n"
            "$text = Get-Content $file -Raw\n"
            "$doc = $text | ConvertFrom-Json\n"
            "if ($doc.phases.Count -ne 2 -or $text.Contains($Root)) { throw 'Timing content or count mismatch' }\n")
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
