#!/usr/bin/env python3
"""Fail-closed approval of a public managed-site build for one exact main SHA."""
import json
import re
import sys

SHA = re.compile(r"[0-9a-f]{40}")
REPO = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")

def decision(payload, repo, sha):
    if not REPO.fullmatch(repo) or not SHA.fullmatch(sha):
        return "rejected:invalid arguments"
    allowed = (f"{repo}/.github/workflows/publish-site.yml@main",
               ".github/workflows/publish-site.yml")
    matches = []
    for run in payload.get("workflow_runs", []):
        if (run.get("head_sha") == sha and run.get("head_branch") == "main" and
                run.get("event") == "push" and
                run.get("path") in allowed):
            matches.append(run)
    if not matches:
        return "waiting:no matching push workflow"
    matches.sort(key=lambda x: (x.get("created_at", ""), x.get("run_attempt", 0), x.get("id", 0)), reverse=True)
    newest = matches[0]
    if newest.get("status") == "completed" and newest.get("conclusion") == "success":
        return "approved"
    return "waiting:workflow incomplete or failed"

if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit("Usage: managed-ci-gate.py OWNER/REPO SHA runs.json")
    try:
        with open(sys.argv[3], encoding="utf-8") as f:
            print(decision(json.load(f), sys.argv[1], sys.argv[2]))
    except (OSError, ValueError, TypeError, KeyError) as exc:
        sys.exit(f"Invalid CI response: {exc}")
