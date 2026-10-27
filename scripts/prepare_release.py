#!/usr/bin/env python3
"""Prepare one immutable Portal release for existing ECS Nginx routes."""
from pathlib import Path
import re
import sys

REQUIRED = (
    "index.html", "styles.css", "app.js", "config.js",
    "assets/favicon.svg", "assets/rift-art.svg", "assets/tactics-art.svg", "assets/pinball-art.svg",
)

def prepare(root: Path, sha: str) -> None:
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise ValueError("expected full 40-character commit SHA")
    if not root.is_dir() or root.is_symlink():
        raise ValueError("release stage is missing or unsafe")
    for name in REQUIRED:
        item = root / name
        if not item.is_file() or item.is_symlink() or item.stat().st_size == 0:
            raise ValueError(f"missing/unsafe release resource: {name}")
    html = (root / "index.html").read_text(encoding="utf-8")
    for name in ("favicon", "rift-art", "tactics-art"):
        before = f"./assets/{name}.svg"
        if before not in html:
            raise ValueError(f"missing asset URL {before}")
        html = html.replace(before, f"/portal-assets/{name}.svg?v={sha[:12]}")
    for name in ("styles.css", "config.js", "app.js"):
        before = f"./{name}"
        if before not in html:
            raise ValueError(f"missing resource URL {before}")
        html = html.replace(before, f"/{name}?v={sha[:12]}")
    if 'id="rift-enter"' not in html or "/games/rift/" not in html:
        raise ValueError("Rift game card or expected URL is absent")
    if 'id="pinball-enter" href="/games/pinball/"' not in html or '/portal-assets/pinball-art.svg' not in html:
        raise ValueError("Pinball card or artwork URL is absent")
    (root / "index.html").write_text(html, encoding="utf-8")
    (root / ".portal-commit").write_text(sha + "\n", encoding="ascii")

if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("Usage: prepare_release.py STAGE_DIR COMMIT_SHA")
    try:
        prepare(Path(sys.argv[1]), sys.argv[2])
    except (OSError, ValueError) as exc:
        sys.exit(str(exc))
