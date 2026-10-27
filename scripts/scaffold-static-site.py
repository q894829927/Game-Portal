#!/usr/bin/env python3
"""Create a new public, independently deployed ECS static/Vite project."""
import argparse
import json
import re
from pathlib import Path

SLUG = re.compile(r"[a-z][a-z0-9-]{1,30}")
REPO = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")

WORKFLOW = r"""name: Publish managed static site
on:
  push:
    branches: [main]
  workflow_dispatch:
permissions:
  contents: write
concurrency:
  group: publish-managed-static
  cancel-in-progress: false
jobs:
  build-and-publish:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - uses: actions/setup-node@v4
        with:
          node-version: '22'
      - name: Build
        shell: bash
        run: |
          set -euo pipefail
__BUILD__
          test -s dist/index.html
          grep -Fq '__BASE__' dist/index.html
      - name: Publish current main build to site
        shell: bash
        run: |
          set -euo pipefail
          current="$(git ls-remote origin refs/heads/main | cut -f1)"
          [[ "$current" == "$GITHUB_SHA" ]] || { echo "Outdated commit; skip"; exit 0; }
          target="$RUNNER_TEMP/managed-site"
          if git ls-remote --exit-code origin refs/heads/site >/dev/null; then
            git fetch origin refs/heads/site
            git worktree add --detach "$target" FETCH_HEAD
            git -C "$target" switch -C site
          else
            git worktree add --detach "$target" HEAD
            git -C "$target" switch --orphan site
          fi
          find "$target" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf -- {} +
          cp -a dist/. "$target/"
          printf '%s\n' "$GITHUB_SHA" > "$target/.source-sha"
          printf 'portal-managed-static-v1\n' > "$target/.site-kind"
          printf '__SLUG__\n' > "$target/.site-slug"
          git -C "$target" config user.name 'github-actions[bot]'
          git -C "$target" config user.email '41898282+github-actions[bot]@users.noreply.github.com'
          git -C "$target" add -A
          if ! git -C "$target" diff --cached --quiet; then
            git -C "$target" commit -m "deploy: __SLUG__ from $GITHUB_SHA"
            git -C "$target" push origin HEAD:refs/heads/site
          fi
"""

def scaffold(repo: str, slug: str, title: str, kind: str, dest: Path) -> None:
    if not REPO.fullmatch(repo):
        raise ValueError("Expected GitHub owner/name")
    if not SLUG.fullmatch(slug) or "--" in slug or slug in ("rift", "tactics"):
        raise ValueError("Bad or reserved slug (2-31 lowercase letters/numbers/hyphens)")
    if not title.strip() or len(title) > 80 or any(c in title for c in "\r\n<>"):
        raise ValueError("Bad title")
    if dest.exists():
        raise FileExistsError(f"Refusing to overwrite: {dest}")
    base = f"/games/{slug}/"
    dest.mkdir(parents=True)

    def put(path, data):
        p = dest / path
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(data, encoding="utf-8")

    if kind == "static":
        build = "          mkdir -p dist\n          cp -a public/. dist/"
        put("public/index.html",
            f'<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">'
            f'<meta name="viewport" content="width=device-width,initial-scale=1">'
            f'<title>{title}</title><link href="{base}styles.css" rel="stylesheet">'
            f'</head><body><main><h1>{title}</h1><p>新项目已就绪。</p></main>'
            f'<script src="{base}app.js" defer></script></body></html>\n')
        put("public/styles.css", "body{font:16px system-ui;max-width:800px;margin:6rem auto;padding:1rem}\n")
        put("public/app.js", "console.log('Site ready');\n")
    elif kind == "vite":
        build = ("          if [[ -f package-lock.json ]]; then npm ci; "
                 "else npm install --no-audit --no-fund; fi\n"
                 "          npm run build")
        put("package.json", json.dumps({
            "name": slug, "private": True, "version": "0.1.0", "type": "module",
            "scripts": {"dev": "vite", "build": "vite build"},
            "devDependencies": {"vite": "^7.1.7"},
        }, indent=2) + "\n")
        put(".gitignore", "node_modules/\ndist/\n.env\n.env.*\n")
        put("vite.config.mjs", 'import {defineConfig} from "vite";\n'
            f'export default defineConfig({{base:"{base}"}});\n')
        put("index.html", '<!doctype html><html lang="zh-CN"><head><meta charset="UTF-8">'
            '<meta name="viewport" content="width=device-width,initial-scale=1">'
            f'<title>{title}</title></head><body><div id="app"></div>'
            '<script type="module" src="/src/main.js"></script></body></html>\n')
        put("src/main.js", 'import "./style.css";\n'
            f'document.querySelector("#app").textContent = {json.dumps(title + " — 新项目已就绪。", ensure_ascii=False)};\n')
        put("src/style.css", "body{font:16px system-ui;max-width:800px;margin:6rem auto;padding:1rem}\n")
    else:
        raise ValueError("kind must be static or vite")

    put(".github/workflows/publish-site.yml",
        WORKFLOW.replace("__BUILD__", build).replace("__BASE__", base).replace("__SLUG__", slug))
    put(".deployment.json", json.dumps({
        "schema":"portal-managed-static-v1", "repo":repo, "slug":slug, "path":base,
    }, indent=2) + "\n")
    put("README.md", f"""# {title}

访问地址： https://47.119.122.133{base}

部署：推送 main -> GitHub Actions 发布 site -> ECS 每约 3 分钟检查并原子更新。
发布设施归 [Game-Portal](https://github.com/q894829927/Game-Portal) 管理。

1. 将本目录作为 GitHub 公开仓库 {repo}，推送 main。
2. 等待 Actions / Publish managed static site 成功。
3. ECS Game-Portal 仓库执行：

    bash scripts/install-managed-static-ecs.sh --slug {slug} --repo {repo}

私有仓库、数据库、后端服务、WebSocket 不属于此静态模板，需单独配置。
""")

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--repo", required=True)
    p.add_argument("--slug", required=True)
    p.add_argument("--title", required=True)
    p.add_argument("--kind", choices=("static", "vite"), default="vite")
    p.add_argument("--output", type=Path, required=True)
    a = p.parse_args()
    scaffold(a.repo, a.slug, a.title, a.kind, a.output)
    print(f"[Scaffold] Generated: {a.output}")
    print(f"[Scaffold] Push to {a.repo} main; after CI, run on ECS:")
    print(f"  bash scripts/install-managed-static-ecs.sh --slug {a.slug} --repo {a.repo}")

if __name__ == "__main__":
    main()
