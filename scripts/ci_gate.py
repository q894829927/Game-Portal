#!/usr/bin/env python3
"""Fail-closed approval check for a public GitHub Actions workflow-run response."""
import json
import re
import sys

def decision(payload: dict, sha: str) -> str:
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise ValueError("invalid SHA")
    runs = [
        run for run in payload.get("workflow_runs", [])
        if run.get("head_sha") == sha
        and run.get("event") == "push"
        and run.get("head_branch") == "main"
        and run.get("path", "").endswith("/.github/workflows/validate-portal.yml")
    ]
    if not runs:
        return "waiting:no matching CI"
    latest = max(runs, key=lambda r: (int(r.get("id", 0)), int(r.get("run_attempt", 0))))
    if latest.get("status") == "completed" and latest.get("conclusion") == "success":
        return "approved"
    return f"waiting:{latest.get('status')}/{latest.get('conclusion')}"

if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("Usage: ci_gate.py SHA WORKFLOW_RUNS_JSON")
    try:
        with open(sys.argv[2], encoding="utf-8") as stream:
            print(decision(json.load(stream), sys.argv[1]))
    except (OSError, ValueError, KeyError, TypeError) as exc:
        sys.exit(str(exc))
