import importlib.util
import tempfile
import unittest
import subprocess
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
            '<img src="/portal-assets/pinball-art.svg">'
            '<a href="/games/rift/" id="rift-enter">Play</a>'
            '<a id="pinball-enter" href="/games/pinball/">Play</a>',
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
        self.assertIn('/portal-assets/pinball-art.svg', html)
        self.assertEqual((self.root / ".portal-commit").read_text(), SHA + "\n")

    def test_missing_asset_aborts(self):
        (self.root / "assets/tactics-art.svg").unlink()
        with self.assertRaises(ValueError):
            prep.prepare(self.root, SHA)

    def test_missing_pinball_art_aborts(self):
        (self.root / "assets/pinball-art.svg").unlink()
        with self.assertRaises(ValueError):
            prep.prepare(self.root, SHA)

    def test_invalid_sha_aborts(self):
        with self.assertRaises(ValueError):
            prep.prepare(self.root, "bad")


class ApprovalTests(unittest.TestCase):
    def make_run(self, *, sha=SHA, branch="main", event="push",
            status="completed", conclusion="success", id=100, attempt=1,
            path="q894829927/Game-Portal/.github/workflows/validate-portal.yml@main"):
        return {
            "id": id, "run_attempt": attempt, "head_sha": sha,
            "event": event, "head_branch": branch,
            "status": status, "conclusion": conclusion, "path": path,
        }

    def test_matching_success_approved(self):
        self.assertEqual(gate.decision({"workflow_runs": [self.make_run()]}, SHA), "approved")

    def test_all_unapproved_variants(self):
        cases = [
            self.make_run(sha="2" * 40),
            self.make_run(branch="other"),
            self.make_run(event="pull_request"),
            self.make_run(status="in_progress", conclusion=None),
            self.make_run(status="completed", conclusion="failure"),
            self.make_run(status="completed", conclusion="cancelled"),
            self.make_run(path="q894829927/Game-Portal/.github/workflows/unrelated.yml"),
        ]
        for run in cases:
            with self.subTest(run=run):
                self.assertTrue(gate.decision({"workflow_runs": [run]}, SHA).startswith("waiting"))

    def test_latest_failed_attempt_blocks_older_success(self):
        runs = [
            self.make_run(id=3, attempt=1, status="completed", conclusion="success"),
            self.make_run(id=3, attempt=2, status="completed", conclusion="failure"),
        ]
        self.assertTrue(gate.decision({"workflow_runs": runs}, SHA).startswith("waiting"))

    def test_no_runs_blocks(self):
        self.assertEqual(gate.decision({"workflow_runs": []}, SHA), "waiting:no matching CI")



class SSHTransportTests(unittest.TestCase):
    """Regression checks for an unchanged CI gate with SSH-first Git reads."""

    @classmethod
    def setUpClass(cls):
        cls.source = (BASE / "scripts/deploy-portal-ecs.sh").read_text(encoding="utf-8")

    def test_shell_script_syntax(self):
        subprocess.run(
            ["bash", "-n", str(BASE / "scripts/deploy-portal-ecs.sh")],
            check=True,
        )

    def test_ssh_primary_and_https_fallback(self):
        s = self.source
        self.assertIn('readonly SSH_REMOTE="ssh://git@ssh.github.com:443/q894829927/Game-Portal.git"', s)
        self.assertIn('readonly REMOTE="https://github.com/q894829927/Game-Portal.git"', s)
        self.assertIn('git_remote_main() {', s)
        self.assertIn('git_fetch_main() {', s)
        self.assertIn('env GIT_SSH_COMMAND="$SSH_COMMAND"', s)
        self.assertIn('ls-remote "$SSH_REMOTE" refs/heads/main', s)
        self.assertIn('ls-remote "$REMOTE" refs/heads/main', s)
        self.assertIn('fetch --no-tags --depth 1 "$SSH_REMOTE" refs/heads/main', s)
        self.assertIn('fetch --no-tags --depth 1 "$REMOTE" refs/heads/main', s)
        self.assertIn('remote="$(git_remote_main)"', s)
        self.assertIn('git_fetch_main ||', s)
        self.assertNotIn('ls-remote origin refs/heads/main', s)
        self.assertNotIn('fetch --no-tags --depth 1 origin refs/heads/main', s)

    def test_systemd_hardened_credentials(self):
        s = self.source
        service = (BASE / "ops/systemd/game-portal-deploy.service").read_text(encoding="utf-8")
        self.assertIn('ProtectHome=true', service)
        self.assertIn('/etc/game-portal/ssh/game_portal_deploy', s)
        self.assertIn('/etc/game-portal/ssh/github_known_hosts', s)
        self.assertIn('BatchMode=yes', s)
        self.assertIn('StrictHostKeyChecking=yes', s)
        self.assertIn('IdentitiesOnly=yes', s)
        self.assertIn('ConnectTimeout=8', s)
        self.assertIn('! -L "$SSH_IDENTITY"', s)

    def test_approval_and_rollback_not_removed(self):
        s = self.source
        self.assertIn('"$BIN/ci_gate.py"', s)
        self.assertIn('if [[ "$decision" != approved ]]', s)
        self.assertIn('"$fetched" == "$sha"', s)
        self.assertIn('http_matches / "$release/index.html"', s)
        self.assertIn('Verification failed; rolling back Portal to previous release', s)
        self.assertIn('git -C "$REPO" remote get-url origin', s)

if __name__ == "__main__":
    unittest.main()
