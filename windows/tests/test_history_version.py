"""Real disposable Git histories, with no publication or API dependency."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "windows/ci"))
import history_version as v


class HistoryVersionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.name", "Version fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        self.path = self.root / v.VERSION_FILE
        self.path.parent.mkdir(parents=True)
        self.anchor = self.set_base("0.3.0")

    def git(self, *args):
        return v.git(self.root, *args)

    def commit(self, message):
        self.git("add", "--all")
        self.git("commit", "--allow-empty", "-q", "-m", message)
        return self.git("rev-parse", "HEAD")

    def set_base(self, base, **extra):
        self.path.write_text(json.dumps({"schema": 1, "version": base, "profileSchema": 1, **extra}))
        return self.commit("reviewed base")

    def merge(self, title, body=""):
        self.git("checkout", "-q", "-b", "topic")
        self.commit("feat!: topic commits must not enter the fold")
        self.git("checkout", "-q", "main")
        self.git("merge", "--no-ff", "-q", "topic", "-m",
                 "Merge pull request #42 from owner/topic\n\n" + title + body)
        self.git("branch", "-D", "topic")
        return self.git("rev-parse", "HEAD")

    def test_anchor_races_gaps_and_reruns(self):
        self.assertEqual("0.3.0", v.resolve(self.root, self.anchor))
        c1 = self.merge("fix: first")
        c2 = self.merge("fix: second")
        self.assertEqual("0.3.1", v.resolve(self.root, c1))
        self.assertEqual("0.3.2", v.resolve(self.root, c2))
        # Nothing publishes C1. A docs-only merge still consumes a patch.
        docs = self.merge("docs: no publication")
        feature = self.merge("feat(ui): a feature after fixes")
        self.assertEqual("0.3.3", v.resolve(self.root, docs))
        self.assertEqual("0.4.0", v.resolve(self.root, feature))
        self.git("tag", "v99.0.0-development")  # Published state is irrelevant.
        self.assertNotIn("v99.0.0-development",
                         self.git("tag", "--merged", c2, "--list", "v*"))
        self.assertEqual("0.3.2", v.resolve(self.root, c2))
        self.assertEqual("0.3.1", v.resolve(self.root, c1))

    def test_breaking_and_no_rollover(self):
        self.merge("feat!: breaking before 1.0")
        self.assertEqual("0.4.0", v.resolve(self.root))
        self.merge("refactor(api): compatibility break", "\n\nBREAKING CHANGE: new schema")
        self.assertEqual("0.5.0", v.resolve(self.root))
        self.set_base("1.2.99")
        self.merge("fix: no decimal rollover")
        self.assertEqual("1.2.100", v.resolve(self.root))
        self.merge("refactor!: breaking after 1.0")
        self.assertEqual("2.0.0", v.resolve(self.root))
        with self.assertRaisesRegex(ValueError, "native-version-overflow"):
            v.bump("1.2.65535", "patch")

    def test_anchor_change_is_first_parent_merge_not_topic_commit(self):
        self.merge("fix: consumed")
        self.git("checkout", "-q", "-b", "topic")
        self.set_base("1.0.0")
        self.git("checkout", "-q", "main")
        self.git("merge", "--no-ff", "-q", "topic", "-m",
                 "Merge pull request #43 from owner/topic\n\nfeat!: reviewed 1.0")
        self.assertEqual("1.0.0", v.resolve(self.root))
        self.set_base("1.0.0", note="not a base change")
        self.assertEqual("1.0.1", v.resolve(self.root))
        self.commit("feat!: direct commits are patches")
        self.assertEqual("1.0.2", v.resolve(self.root))

    def test_shallow_history_fails_closed(self):
        shallow = self.root / "shallow"
        subprocess.run(["git", "clone", "-q", "--depth=1", self.root.as_uri(), str(shallow)],
                       check=True, capture_output=True)
        with self.assertRaisesRegex(ValueError, "version-history-shallow"):
            v.resolve(shallow)

    def test_merge_message_parsing(self):
        for title, expected in (
            ("feat: thing", "minor"), ("feat(ui): thing", "minor"),
            ("feat!: thing", "breaking"), ("fix(api)!: thing", "breaking"),
            ("fix: thing", "patch"), ("perf: thing", "patch"),
            ("refactor: thing", "patch"), ("unknown: thing", "patch"),
            ("unknown!: explicit break", "breaking"),
            ("missing prefix", "patch"), ("fix: feat!: not a feature", "patch"),
        ):
            message = "Merge pull request #2 from owner/feat!\n\n" + title
            with self.subTest(title=title):
                self.assertEqual(expected, v.merge_bump(message, 2))
                self.assertEqual("patch", v.merge_bump(message, 1))
        self.assertEqual("patch", v.merge_bump("feat: a direct commit", 1))
        self.assertEqual("patch", v.merge_bump("Merge branch 'topic'\n\nfeat!: not GitHub", 2))

    def test_invalid_base_fails_closed(self):
        for base in ("0.03.0", "0.3.0+metadata", "0.3.0-dev.1.2.3", "65536.0.0"):
            self.set_base(base)
            with self.subTest(base=base), self.assertRaises(ValueError):
                v.resolve(self.root)
        self.path.write_text('{"schema": 2, "version": "0.3.0", "profileSchema": 1}')
        self.commit("invalid schema")
        with self.assertRaisesRegex(ValueError, "invalid-authoritative-version-file"):
            v.resolve(self.root)

    def test_title_check_and_safe_cli(self):
        for kind in ("feat", "fix", "perf", "refactor", "docs", "test", "build",
                     "ci", "chore", "style", "revert"):
            for title in (kind + ": description", kind + "(ui)!: description"):
                self.assertTrue(v.check_title(title), title)
        for title in ("feature: x", "Feat: x", "feat:x", "fix: ", "fix(): x",
                      "fix: x\nfeat: y", "feat(scope!): x\n", "missing prefix"):
            self.assertFalse(v.check_title(title), title)
        for title, code in (("feat: $(not-a-command)", 0), ("missing prefix", 1)):
            result = subprocess.run([sys.executable, "-I", "-B",
                                     str(ROOT / "windows/ci/history_version.py"), "--check-title"],
                                    env={**os.environ, "PR_TITLE": title}, capture_output=True)
            self.assertEqual(code, result.returncode)
        workflow = (ROOT / ".github/workflows/windows-build.yml").read_bytes()
        self.assertEqual(workflow, (ROOT / "windows/ci/windows-build.yml.template").read_bytes())
        self.assertIn(b"types: [opened, synchronize, reopened, edited]", workflow)
        self.assertIn(b"PR_TITLE: ${{ github.event.pull_request.title }}", workflow)
        self.assertIn(b"history_version.py --check-title", workflow)

    def test_native_and_packaging_consumers_share_the_fold(self):
        build = (ROOT / "windows/scripts/Build-Prototype.ps1").read_text()
        self.assertIn("$sourceVersion = Get-CaelestiaSourceVersion $repoRoot", build)
        self.assertIn('[IO.File]::WriteAllText($nativeVersionPath, ($sourceVersion + "`n")', build)
        self.assertIn('"-DQS_VERSION_FILE:FILEPATH=$nativeVersionPath"', build)
        self.assertIn('"-DVERSION=$sourceVersion"', build)
        self.assertIn("history_version.py", (ROOT / "cmake/CaelestiaVersion.cmake").read_text())
        for script in ("New-CaelestiaRelease.ps1", "Install-Caelestia.ps1"):
            self.assertIn("$appVersion.version = Get-CaelestiaSourceVersion $repoRoot",
                          (ROOT / "windows/scripts" / script).read_text())


if __name__ == "__main__":
    unittest.main()
