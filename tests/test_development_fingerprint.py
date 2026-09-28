from pathlib import Path
import runpy
import subprocess
import tempfile
import unittest


fingerprint = runpy.run_path(str(Path(__file__).resolve().parents[1] / "bin/development-fingerprint"))["fingerprint"]


class DevelopmentFingerprintTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.git("init", "-q")
        self.git("config", "user.email", "test@example.invalid")
        self.git("config", "user.name", "Test")
        (self.root / ".gitignore").write_text("build/\n")
        (self.root / "source.swift").write_text("original")
        self.git("add", ".")
        self.git("commit", "-qm", "initial")

    def git(self, *args):
        subprocess.run(["git", *args], cwd=self.root, check=True, capture_output=True)

    def test_metadata_and_ignored_builds_do_not_trigger_an_update(self):
        before = fingerprint(self.root)
        self.git("commit", "--allow-empty", "-qm", "empty")
        (self.root / "build").mkdir()
        (self.root / "build/output").write_text("new build timestamp")
        (self.root / "source.swift").touch()
        self.assertEqual(before, fingerprint(self.root))

    def test_edits_additions_deletions_and_modes_trigger_updates_but_committing_does_not(self):
        for change in [
            lambda: (self.root / "source.swift").write_text("changed"),
            lambda: (self.root / "new file.swift").write_text("new"),
            lambda: (self.root / "source.swift").chmod(0o755),
            lambda: (self.root / "source.swift").unlink(),
        ]:
            before = fingerprint(self.root)
            change()
            after = fingerprint(self.root)
            self.assertNotEqual(before, after)
            self.git("add", "-A")
            self.git("commit", "-qm", "change")
            self.assertEqual(after, fingerprint(self.root))

    def test_symlink_target_changes_trigger_update(self):
        link = self.root / "link"
        link.symlink_to("source.swift")
        before = fingerprint(self.root)
        link.unlink()
        link.symlink_to("missing.swift")
        self.assertNotEqual(before, fingerprint(self.root))
