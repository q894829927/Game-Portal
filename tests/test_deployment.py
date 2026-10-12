import importlib.util
import tempfile
import unittest
from pathlib import Path

BASE = Path(__file__).resolve().parents[1]

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, BASE / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

prep = load("prepare_release", "scripts/prepare_release.py")
gate = load("ci_gate", "scripts/ci_gate.py")
SHA = "1" * 40


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in prep.REQUIRED:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("static", encoding="utf-8")
        (self.root / "index.html").write_text(
            '<link rel="icon" href="./assets/favicon.svg">'
            '<link rel="stylesheet" href="./styles.css">'
            '<script src="./config.js"></script><script src="./app.js"></script>'
            '<img src="./assets/rift-art.svg"><img src="./assets/tactics-art.svg">'
            '<a href="/games/rift/" id="rift-enter">Play</a>',
            encoding="utf-8",
        )

    def test_rewrite_and_commit_marker(self):
        prep.prepare(self.root, SHA)
        html = (self.root / "index.html").read_text(encoding="utf-8")
        for name in ("favicon", "rift-art", "tactics-art"):
            self.assertIn(f"/portal-assets/{name}.svg?v={SHA[:12]}", html)
            self.assertNotIn(f"./assets/{name}.svg", html)
        for name in ("styles.css", "config.js", "app.js"):
            self.assertIn(f"/{name}?v={SHA[:12]}", html)
        self.assertEqual((self.root / ".portal-commit").read_text(), SHA + "\n")

    def test_missing_asset_aborts(self):
        (self.root / "assets/tactics-art.svg").unlink()
        with self.assertRaises(ValueError):
            prep.prepare(self.root, SHA)

    def test_invalid_sha_aborts(self):
        with self.assertRaises(ValueError):
            prep.prepare(self.root, "bad")


class ApprovalTests(unittest.TestCase):
    def run(self, *, sha=SHA, branch="main", event="push",
            status="completed", conclusion="success", id=100, attempt=1,
            path="q894829927/Game-Portal/.github/workflows/validate-portal.yml@main"):
        return {
            "id": id, "run_attempt": attempt, "head_sha": sha,
            "event": event, "head_branch": branch,
            "status": status, "conclusion": conclusion, "path": path,
        }

    def test_matching_success_approved(self):
        self.assertEqual(gate.decision({"workflow_runs": [self.run()]}, SHA), "approved")

    def test_all_unapproved_variants(self):
        cases = [
            self.run(sha="2" * 40),
            self.run(branch="other"),
            self.run(event="pull_request"),
            self.run(status="in_progress", conclusion=None),
            self.run(status="completed", conclusion="failure"),
            self.run(status="completed", conclusion="cancelled"),
            self.run(path="q894829927/Game-Portal/.github/workflows/unrelated.yml"),
        ]
        for run in cases:
            with self.subTest(run=run):
                self.assertTrue(gate.decision({"workflow_runs": [run]}, SHA).startswith("waiting"))

    def test_latest_failed_attempt_blocks_older_success(self):
        runs = [
            self.run(id=3, attempt=1, status="completed", conclusion="success"),
            self.run(id=3, attempt=2, status="completed", conclusion="failure"),
        ]
        self.assertTrue(gate.decision({"workflow_runs": runs}, SHA).startswith("waiting"))

    def test_no_runs_blocks(self):
        self.assertEqual(gate.decision({"workflow_runs": []}, SHA), "waiting:no matching CI")


if __name__ == "__main__":
    unittest.main()
