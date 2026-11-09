"""Differential privacy-policy tests. No binary or artifact code is executed."""

import base64
import json
import os
from pathlib import Path
import random
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[3]


@unittest.skipUnless(os.name == "nt", "Windows PowerShell boundary")
class ReleasePrivacyTests(unittest.TestCase):
    def test_scanner_preserves_policy_encodings_and_culture(self):
        with tempfile.TemporaryDirectory(
                prefix="privacy-policy-", dir=os.environ.get("CAELESTIA_TEST_OUTPUT_ROOT")) as directory:
            root = Path(directory)
            cases = []

            def raw(name, body, extension=".dll", roots=(), **expected):
                cases.append(dict(name=name, body=base64.b64encode(body).decode(),
                                  extension=extension, roots=list(roots), **expected))

            def text(name, body, extension=".dll", roots=(), **expected):
                for encoding, prefix in (("utf-8", b""), ("utf-16-le", b""),
                                         ("utf-16-le", b"\x01")):
                    raw(name + "-" + encoding + "-" + str(len(prefix)),
                        prefix + body.encode(encoding), extension, roots, **expected)

            text("ordinary", "ordinary public content", sensitive=False, generic=False)
            text("key-label", "-----BEGIN PRIVATE KEY-----", sensitive=False, generic=False)
            text("key-short", "-----BEGIN PRIVATE KEY-----\n" + "A" * 31, sensitive=False)
            for kind in ("", "RSA ", "EC ", "DSA ", "OPENSSH ", "ENCRYPTED "):
                text("key-material-" + kind, "-----BEGIN " + kind + "PRIVATE KEY-----\n" + "A" * 32,
                     sensitive=True)
            text("escaped-key", "-----BEGIN EC PRIVATE KEY-----\\n" + "Ab01/+=" * 6, sensitive=True)
            text("encrypted-preamble", "-----BEGIN RSA PRIVATE KEY-----\nProc-Type: 4,ENCRYPTED",
                 sensitive=True)
            text("short-token", "ghp_" + "a" * 19, sensitive=False)
            for prefix in ("ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_", "GITHUB_PAT_", "GİTHUB_PAT_"):
                expected = {} if prefix in ("GITHUB_PAT_", "GİTHUB_PAT_") else {"sensitive": True}
                text("token-" + prefix, prefix + "a" * 24, **expected)
            text("users-path", r"C:\Users\fixture\source.cpp", sensitive=False, generic=True)
            text("home-path", "/home/fixture/source.cpp", sensitive=False, generic=True)
            text("pdb-path", r"D:\build\module.pdb", sensitive=False, generic=True)
            for extension in (".dll", ".DLL", ".exe", ".txt"):
                text("binary-path-" + extension, r"C:\sdk\tools\file", extension=extension,
                     sensitive=False, generic=extension != ".txt")
            for body in ("i:\\sdk\\file", "\u0130:\\sdk\\file", "\x01C:\\x\x02\x03",
                         "C:\\folder\\file.dll\ufffd", "ordinary\x00C:/sdk\x01tail"):
                text("culture-or-control-path", body)
            private = r"C:\private.(root)"
            for body in (private, private.upper(), private.replace("\\", "/"),
                         private.replace("\\", "\\\\")):
                text("literal-private-root", body, roots=(private,), sensitive=True)
            text("empty-root", "ordinary", roots=("",), sensitive=True)
            for private in ("a", "ab", "abc", "ab\U00010400/private", "\U00010400a/private", "ßp/private"):
                text("short-or-unicode-root", private, roots=(private,), sensitive=True)
                text("root-case-mapping", private.lower(), roots=(private,))
            text("shared-prefix-roots", "C:/PRIVATE/two/file",
                 roots=("C:\\private\\one", "c:\\private\\two"), sensitive=True)
            raw("empty-bytes", b"", sensitive=False, generic=False)
            token = ("github_pat_" + "a" * 24).encode("utf-16-le")
            # GenericPath is already true in UTF-8, but the sensitive marker
            # is visible only in one of the subsequent UTF-16 views.
            for padding in (b"", b"\x00"):
                raw("later-sensitive-view", b"C:\\sdk\\file.pdb\x00" + padding + token,
                    sensitive=True, generic=True)
                raw("later-private-root-view",
                    b"C:\\sdk\\file.pdb\x00" + padding + "C:\\private\\file".encode("utf-16-le"),
                    roots=("c:\\private",), sensitive=True, generic=True)
            text("large-late-token", "public " * 10000 + "ghp_" + "a" * 24, sensitive=True)
            generator = random.Random(937)
            for index in range(20):
                raw("random-" + str(index), generator.randbytes(1024))
            source = root / "cases.json"
            source.write_text(json.dumps(cases), encoding="utf-8")
            harness = root / "compare.ps1"
            harness.write_text(r'''
param($Repository, $Cases, $Culture)
$ErrorActionPreference = 'Stop'
. (Join-Path $Repository 'windows\tests\fixtures\ReleasePrivacyReference.ps1')
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $Repository 'windows\scripts\New-CaelestiaRelease.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Production scanner does not parse' }
$function = $ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq 'Get-ReleaseFilePrivacy'}, $true)
. ([scriptblock]::Create($function.Extent.Text))
$cases = Get-Content -LiteralPath $Cases -Raw -Encoding UTF8 | ConvertFrom-Json
$saved = [Threading.Thread]::CurrentThread.CurrentCulture
$count = 0
try {
    $selected = if ($Culture -eq 'Invariant') { [Globalization.CultureInfo]::InvariantCulture }
        else { [Globalization.CultureInfo]::GetCultureInfo($Culture) }
    [Threading.Thread]::CurrentThread.CurrentCulture = $selected
    foreach ($case in $cases) {
            $bytes = [Convert]::FromBase64String($case.body)
            $roots = [string[]]@($case.roots)
            $before = Get-ReferenceReleaseFilePrivacy $bytes $case.extension $roots
            $after = Get-ReleaseFilePrivacy $bytes $case.extension $roots
            if ($before.Sensitive -ne $after.Sensitive -or $before.GenericPath -ne $after.GenericPath) {
                throw "Policy mismatch: case=$($case.name) culture=$Culture"
            }
            if ($null -ne $case.PSObject.Properties['sensitive'] -and $after.Sensitive -ne $case.sensitive) {
                throw "Sensitive-content expectation mismatch: case=$($case.name) culture=$Culture"
            }
            if ($null -ne $case.PSObject.Properties['generic'] -and $after.GenericPath -ne $case.generic) {
                throw "Path expectation mismatch: case=$($case.name) culture=$Culture"
            }
            $count++
    }
} finally { [Threading.Thread]::CurrentThread.CurrentCulture = $saved }
[ordered]@{ comparisons = $count } | ConvertTo-Json -Compress
''', encoding="utf-8")
            # PowerShell caches -match expressions in its runspace. Fresh
            # processes prevent one locale's cached policy masking another.
            for culture in ("Invariant", "en-US", "tr-TR"):
                result = subprocess.run(
                    ["powershell.exe", "-NoProfile", "-NonInteractive", "-File", str(harness),
                     "-Repository", str(ROOT), "-Cases", str(source), "-Culture", culture],
                    capture_output=True, text=True, timeout=60)
                self.assertEqual(0, result.returncode, result.stdout + result.stderr)
                output = json.loads(result.stdout)
                self.assertEqual(len(cases), output["comparisons"])


if __name__ == "__main__":
    unittest.main()
