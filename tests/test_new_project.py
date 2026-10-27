"""Regression tests for managed public static-site onboarding."""
import importlib.util
import json
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


generator = load("static_scaffold", "scripts/scaffold-static-site.py")
ci = load("managed_gate", "scripts/managed-ci-gate.py")
SHA = "a" * 40
REPO = "q894829927/Demo-Game"


class ScaffoldTests(unittest.TestCase):
    def test_static_site_and_workflow_are_isolated(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "mydemo"
            generator.scaffold(REPO, "mydemo", "测试项目", "static", path)
            body = (path / "public/index.html").read_text()
            wf = (path / ".github/workflows/publish-site.yml").read_text()
            self.assertIn("/games/mydemo/styles.css", body)
            self.assertIn("on:\n  push:\n    branches: [main]", wf)
            self.assertIn("printf '%s\\n'", wf)
            self.assertIn("portal-managed-static-v1", wf)
            self.assertIn("grep -Fq '/games/mydemo/'", wf)
            self.assertIn("refs/heads/site", wf)
            self.assertIn(".source-sha", wf)
            self.assertEqual(json.loads((path / ".deployment.json").read_text())["slug"], "mydemo")
            self.assertFalse((path / ".git").exists())
            with self.assertRaises(FileExistsError):
                generator.scaffold(REPO, "mydemo", "test", "static", path)

    def test_vite_site_builds_to_correct_base(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "another"
            generator.scaffold(REPO, "another", "Demo", "vite", path)
            self.assertIn('base:"/games/another/"', (path / "vite.config.mjs").read_text())
            self.assertIn("npm run build", (path / ".github/workflows/publish-site.yml").read_text())
            self.assertIn("vite", (path / "package.json").read_text())
            self.assertTrue((path / "src/main.js").exists())

    def test_bad_slug_repo_and_title_fail_without_writes(self):
        with tempfile.TemporaryDirectory() as temp:
            for bad in ("rift", "tactics", "../etc", "love/aaa", "AB", "demo--two", "a"):
                p = Path(temp) / ("target-" + re.sub("[^a-zA-Z0-9]", "_", bad))
                with self.assertRaises(ValueError):
                    generator.scaffold(REPO, bad, "Demo", "static", p)
                self.assertFalse(p.exists())
            with self.assertRaises(ValueError):
                generator.scaffold("evil/../repo", "valid", "Demo", "static", Path(temp) / "bad")
            with self.assertRaises(ValueError):
                generator.scaffold(REPO, "valid", "<script>", "vite", Path(temp) / "bad")


class ManagedApprovalTests(unittest.TestCase):
    def run_info(self, **kw):
        base = {
            "head_sha": SHA, "head_branch": "main", "event": "push",
            "path": REPO + "/.github/workflows/publish-site.yml@main",
            "status": "completed", "conclusion": "success", "created_at": "2026-10-27T00:00:00Z",
            "id": 1, "run_attempt": 1,
        }
        base.update(kw)
        return base

    def test_exact_matching_success_only(self):
        self.assertEqual(ci.decision({"workflow_runs":[self.run_info()]}, REPO, SHA), "approved")
        for run in [
            self.run_info(head_sha="b" * 40),
            self.run_info(path="other.yml"),
            self.run_info(event="workflow_dispatch"),
            self.run_info(head_branch="evil"),
            self.run_info(status="in_progress",conclusion=None),
            self.run_info(conclusion="failure"),
        ]:
            self.assertNotEqual(ci.decision({"workflow_runs":[run]}, REPO, SHA), "approved")

    def test_latest_attempt_blocks_old_success(self):
        runs = [self.run_info(), self.run_info(id=2, run_attempt=2, conclusion="failure",
                created_at="2026-10-27T00:01:00Z")]
        self.assertNotEqual(ci.decision({"workflow_runs":runs}, REPO, SHA), "approved")


class ManagedDeploySafetyTests(unittest.TestCase):
    def test_shell_syntax_and_isolation(self):
        scripts = ("scripts/install-managed-static-ecs.sh",
                   "scripts/deploy-managed-static-ecs.sh")
        for path in scripts:
            subprocess.run(["bash", "-n", str(ROOT / path)], check=True)
        installer = (ROOT / scripts[0]).read_text()
        deploy = (ROOT / scripts[1]).read_text()
        for text in ("nginx -t", "systemctl reload nginx", "cp -p \"$conf\"",
                     "Rolling back only the new site", "game-portal-routes.conf",
                     'systemctl enable --now "$unit.timer"'):
            self.assertIn(text, installer)
        self.assertIn('[[ -e "$shared" ]] || install', installer)
        self.assertNotIn("systemctl restart nginx", installer)
        self.assertNotIn("systemctl restart rift", installer)
        for text in ("managed-ci-gate.py", ".source-sha", ".site-slug",
                     "cmp -s", "switched=1", "switched=0", "flock -n 9",
                     "restorecon", "/games/$slug/"):
            self.assertIn(text, deploy)
        self.assertIn("find \"$stage\" -mindepth 1 -type d -name", deploy)
        self.assertNotIn("npm install", deploy)
        self.assertNotIn("systemctl restart nginx", deploy)


    def test_managed_project_readonly_ssh_fallback(self):
        transport = (ROOT / "scripts/managed-git-transport.sh").read_text()
        provision = (ROOT / "scripts/provision-managed-ssh-ecs.sh").read_text()
        installer = (ROOT / "scripts/install-managed-static-ecs.sh").read_text()
        deployer = (ROOT / "scripts/deploy-managed-static-ecs.sh").read_text()
        for expected in (
            "ssh://git@ssh.github.com:443/$repo.git",
            "/etc/game-portal/managed-ssh/$slug/deploy_key",
            "IdentitiesOnly=yes",
            "StrictHostKeyChecking=yes",
            "UserKnownHostsFile=$MANAGED_GIT_HOSTS",
            "managed_git_ls_remote()", "managed_git_fetch_site()",
            "refs/heads/site",
        ):
            self.assertIn(expected, transport)
        self.assertIn("managed_git_setup", installer)
        self.assertIn("managed_git_ls_remote main", installer)
        self.assertIn("managed_git_ls_remote site", installer)
        self.assertIn("managed_git_fetch_site", deployer)
        self.assertIn('source "$transport"', deployer)
        self.assertIn("ssh-keygen -q -t ed25519", provision)
        self.assertIn("ssh-keygen -F '[ssh.github.com]:443'", provision)
        self.assertNotIn("StrictHostKeyChecking=no", transport)
        self.assertIn("no 'Allow write access'", provision)



if __name__ == "__main__":
    unittest.main()
