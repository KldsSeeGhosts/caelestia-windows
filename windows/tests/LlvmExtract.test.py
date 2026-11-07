"""Offline integrity, stream selection and link-boundary regressions."""
import argparse
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    "llvm_extract", Path(__file__).resolve().parents[1] / "toolchain/extract_llvm.py")
extractor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(extractor)
OUTPUT = None


class ExtractionTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="case-", dir=OUTPUT))
        self.archive = self.root / "input.tar.xz"
        self.destination = self.root / "tools"
        self.members = [
            ("llvm/bin/clang-cl.exe", b"compiler"),
            ("llvm/bin/lld-link.exe", b"linker"),
            ("llvm/bin/llvm-rc.exe", b"resource-compiler"),
            ("llvm/lib/clang/20/include/stddef.h", b"resource-header"),
            ("llvm/lib/unused-sdk.lib", b"unused"),
            ("llvm/include/unused.h", b"unused"),
        ]

    def run_extract(self, extra=(), omit=(), expected_hash=None, timeout=900):
        with tarfile.open(self.archive, "w:xz") as bundle:
            for name, payload in self.members + list(extra):
                if name in omit:
                    continue
                if isinstance(payload, tuple):
                    entry = tarfile.TarInfo(name)
                    entry.type, entry.linkname = payload
                    bundle.addfile(entry)
                else:
                    entry = tarfile.TarInfo(name)
                    entry.size = len(payload)
                    bundle.addfile(entry, io.BytesIO(payload))
        digest = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        return extractor.extract(self.archive, self.destination, "llvm",
                                 expected_hash or digest, "20", timeout)

    def assert_refused(self, *args, **kwargs):
        with self.assertRaises((ValueError, OSError, tarfile.TarError, TimeoutError)):
            self.run_extract(*args, **kwargs)
        self.assertFalse((self.destination / "llvm/.caelestia-extraction.json").exists())

    def test_exact_tools_resources_and_completion(self):
        result = self.run_extract()
        self.assertEqual(result["files"], 4)
        self.assertEqual((self.destination / "llvm/bin/clang-cl.exe").read_bytes(), b"compiler")
        self.assertFalse((self.destination / "llvm/lib/unused-sdk.lib").exists())
        self.assertFalse((self.destination / "llvm/include").exists())
        marker = json.loads((self.destination / "llvm/.caelestia-extraction.json").read_text())
        self.assertEqual(marker["archiveSha256"], result["archiveSha256"])

    def test_forward_hardlink(self):
        self.members.insert(0, ("llvm/bin/alias.exe", (tarfile.LNKTYPE, "llvm/bin/clang-cl.exe")))
        self.run_extract()
        self.assertEqual((self.destination / "llvm/bin/alias.exe").read_bytes(), b"compiler")

    def test_relative_symbolic_alias_without_symlink_privilege(self):
        self.run_extract(extra=[("llvm/bin/alias.exe", (tarfile.SYMTYPE, "clang-cl.exe"))])
        self.assertEqual((self.destination / "llvm/bin/alias.exe").read_bytes(), b"compiler")
        self.assertFalse((self.destination / "llvm/bin/alias.exe").is_symlink())

    def test_wrong_hash(self):
        self.assert_refused(expected_hash="0" * 64)

    def test_missing_compiler_resource(self):
        self.assert_refused(omit=["llvm/lib/clang/20/include/stddef.h"])

    def test_traversal(self):
        self.assert_refused(extra=[("llvm/bin/../../../escaped", b"refuse")])
        self.assertFalse((self.root / "escaped").exists())

    def test_absolute_path(self):
        self.assert_refused(extra=[("/llvm/bin/absolute", b"refuse")])

    def test_windows_device_path(self):
        self.assert_refused(extra=[("C:/llvm/bin/absolute", b"refuse")])

    def test_windows_reserved_component(self):
        self.assert_refused(extra=[("llvm/bin/NUL.txt", b"refuse")])

    def test_windows_trailing_dot_alias(self):
        self.assert_refused(extra=[("llvm/bin/clang-cl.exe.", b"refuse")])

    def test_link_outside_selected_tree(self):
        self.assert_refused(extra=[("llvm/bin/alias.exe", (tarfile.SYMTYPE, "../../outside"))])

    def test_stale_target_is_not_archive_evidence(self):
        stale = self.destination / "llvm/bin/stale.exe"
        stale.parent.mkdir(parents=True)
        stale.write_bytes(b"stale")
        self.assert_refused(extra=[("llvm/bin/alias.exe", (tarfile.LNKTYPE, "llvm/bin/stale.exe"))])

    def test_cyclic_links(self):
        self.assert_refused(extra=[
            ("llvm/bin/a.exe", (tarfile.LNKTYPE, "llvm/bin/b.exe")),
            ("llvm/bin/b.exe", (tarfile.LNKTYPE, "llvm/bin/a.exe"))])

    def test_case_colliding_members(self):
        self.assert_refused(extra=[("llvm/bin/CLANG-CL.exe", b"collision")])

    def test_deadline_never_writes_success_marker(self):
        self.assert_refused(timeout=-1)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-root", required=True, type=Path)
    args = parser.parse_args()
    OUTPUT = args.output_root.resolve()
    OUTPUT.mkdir(parents=True, exist_ok=True)
    result = unittest.TextTestRunner(verbosity=2).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(ExtractionTests))
    (OUTPUT / "summary.json").write_text(json.dumps({
        "tests": result.testsRun, "failures": len(result.failures),
        "errors": len(result.errors), "skipped": len(result.skipped),
        "passed": result.wasSuccessful(),
    }) + "\n", encoding="utf-8")
    raise SystemExit(0 if result.wasSuccessful() else 1)
