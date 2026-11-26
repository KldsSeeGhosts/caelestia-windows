import hashlib
import json
from pathlib import Path
import tarfile
import tomllib
import unittest


WINDOWS = Path(__file__).resolve().parents[2]
SCHEME_LOCK = json.loads((WINDOWS / "sources.lock.json").read_text(encoding="utf-8"))["schemeCli"]
ARCHIVE = Path(__file__).with_name(f"caelestia-cli-{SCHEME_LOCK['revision']}.tar.gz")


class SchemeArchiveTests(unittest.TestCase):
    def test_archive_matches_the_runtime_pin(self):
        self.assertEqual(hashlib.sha256(ARCHIVE.read_bytes()).hexdigest(), SCHEME_LOCK["archiveSha256"])

    def test_upstream_build_requirements_are_hash_locked(self):
        with tarfile.open(ARCHIVE, "r:gz") as archive:
            project_path = f"cli-{SCHEME_LOCK['revision']}/pyproject.toml"
            with archive.extractfile(project_path) as project:
                build = tomllib.loads(project.read().decode("utf-8"))["build-system"]
        self.assertEqual(build["build-backend"], "hatchling.build")
        requirements = (WINDOWS / "scripts/scheme/requirements.lock.txt").read_text(encoding="utf-8")
        for dependency in build["requires"]:
            with self.subTest(dependency=dependency):
                self.assertRegex(requirements, rf"(?m)^{dependency}==\S+\s+--hash=sha256:[0-9a-f]{{64}}$")


if __name__ == "__main__":
    unittest.main()
