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

    def run_extract(self, extra=(), omit=(), expected_hash=None, timeout=900, profile="full"):
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
                                 expected_hash or digest, "20", timeout, profile)

    def native_members(self):
        existing = {name for name, _ in self.members}
        self.members += [("llvm/bin/" + name, name.encode()) for name in extractor.NATIVE_BINARIES
                         if "llvm/bin/" + name not in existing]
        self.members += [
            ("llvm/bin/clang.exe", b"unused-driver"),
            ("llvm/bin/clangd.exe", b"unused-language-server"),
            ("llvm/bin/libclang.dll", b"unused-library"),
            ("llvm/lib/clang/20/lib/windows/clang_rt.builtins.lib", b"compiler-runtime")]

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

    def test_native_profile_is_exact_and_preserves_all_compiler_resources(self):
        self.native_members()
        result = self.run_extract(profile=extractor.NATIVE_PROFILE)
        root = self.destination / "llvm"
        self.assertEqual(set(extractor.NATIVE_BINARIES), {path.name for path in (root / "bin").iterdir()})
        self.assertEqual(b"compiler-runtime", (root / "lib/clang/20/lib/windows/clang_rt.builtins.lib").read_bytes())
        self.assertEqual(2, result["schemaVersion"])
        self.assertEqual(extractor.NATIVE_PROFILE, result["profile"])
        self.assertTrue(extractor.verify_tree(self.destination, "llvm", result["archiveSha256"], "20",
                                              extractor.NATIVE_PROFILE))
        self.assertFalse(extractor.verify_tree(self.destination, "llvm", result["archiveSha256"], "20", "full"))

    def test_every_native_tool_is_required_from_archive_not_stale_disk(self):
        self.native_members()
        self.run_extract(profile=extractor.NATIVE_PROFILE)
        for name in extractor.NATIVE_BINARIES:
            with self.subTest(name=name):
                self.assert_refused(omit=["llvm/bin/" + name], profile=extractor.NATIVE_PROFILE)

    def test_cache_readiness_checks_every_native_tool(self):
        self.native_members()
        result = self.run_extract(profile=extractor.NATIVE_PROFILE)
        for name in extractor.NATIVE_BINARIES:
            path = self.destination / "llvm/bin" / name
            original = path.read_bytes()
            path.unlink()
            self.assertFalse(extractor.verify_tree(self.destination, "llvm", result["archiveSha256"], "20",
                                                   extractor.NATIVE_PROFILE), name)
            path.write_bytes(original)

    def test_native_request_never_prunes_or_relabels_existing_full_tree(self):
        self.native_members()
        result = self.run_extract()
        marker = self.destination / "llvm/.caelestia-extraction.json"
        original = marker.read_bytes()
        with self.assertRaisesRegex(ValueError, "profile-mismatch"):
            self.run_extract(profile=extractor.NATIVE_PROFILE)
        self.assertEqual(original, marker.read_bytes())
        self.assertEqual(b"unused-driver", (self.destination / "llvm/bin/clang.exe").read_bytes())
        # An older full marker has the same refusal and remains readable by
        # the default developer profile.
        result.pop("profile")
        result["schemaVersion"] = 1
        marker.write_text(json.dumps(result))
        self.assertTrue(extractor.verify_tree(self.destination, "llvm", result["archiveSha256"], "20"))
        with self.assertRaisesRegex(ValueError, "profile-mismatch"):
            extractor.verify_tree(self.destination, "llvm", result["archiveSha256"], "20",
                                  extractor.NATIVE_PROFILE)

    def test_unmarked_non_profile_files_refuse_without_deletion(self):
        self.native_members()
        unknown = self.destination / "llvm/bin/owner-tool.exe"
        unknown.parent.mkdir(parents=True)
        unknown.write_bytes(b"preserve")
        self.assert_refused(profile=extractor.NATIVE_PROFILE)
        self.assertEqual(b"preserve", unknown.read_bytes())

    def test_interrupted_native_retry_and_full_expansion_are_safe(self):
        self.native_members()
        self.assert_refused(profile=extractor.NATIVE_PROFILE, timeout=-1)
        native = self.run_extract(profile=extractor.NATIVE_PROFILE)
        self.assertEqual(extractor.NATIVE_PROFILE, native["profile"])
        full = self.run_extract()
        self.assertEqual("full", full["profile"])
        self.assertEqual(b"unused-library", (self.destination / "llvm/bin/libclang.dll").read_bytes())

    def test_native_link_cannot_expand_to_an_unselected_binary(self):
        self.native_members()
        self.members = [(name, (tarfile.SYMTYPE, "clang.exe") if name == "llvm/bin/clang-cl.exe" else payload)
                        for name, payload in self.members]
        self.assert_refused(profile=extractor.NATIVE_PROFILE)

    def test_native_profile_rejects_case_colliding_allowed_tools(self):
        self.native_members()
        self.assert_refused(extra=[("llvm/bin/CLANG-CL.exe", b"collision")], profile=extractor.NATIVE_PROFILE)

    def test_shared_hosted_cache_has_one_profile_and_two_preparation_consumers(self):
        root = Path(__file__).resolve().parents[2]
        workflow = (root / ".github/workflows/windows-build.yml").read_bytes()
        self.assertEqual(workflow, (root / "windows/ci/windows-build.yml.template").read_bytes())
        keys = [line.strip() for line in workflow.decode().splitlines()
                if "key: windows-x64-tools-contract-v1-py" in line]
        self.assertEqual(3, len(keys))
        self.assertEqual(1, len(set(keys)))
        self.assertIn("-llvm-native-v1-", keys[0])
        self.assertEqual(2, workflow.decode().count("-ReusePreparedPython -NativeRuntimeOnly"))
        self.assertNotIn("NativeRuntimeOnly", (root / "windows/scripts/Prepare-DeploymentToolchain.ps1").read_text())


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
