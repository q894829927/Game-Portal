#!/usr/bin/env bash
# ECS migration: keep Rift auto-deploy untouched; expose Portal at /.
# Usage: sudo bash scripts/migrate-ecs.sh preflight|apply --site /etc/nginx/... [--host IP]
# Roll back: sudo bash scripts/migrate-ecs.sh rollback --backup /var/backups/game-portal-migration/TIMESTAMP
set -Eeuo pipefail
umask 022
ACTION="$1"; shift || true
SITE=""; HOST="47.119.122.133"; BACKUP=""; PORTAL_REF="main"
RIFT="/var/www/rift/current"
PORTAL="/var/www/game-portal"
SNIPPET="/etc/nginx/snippets/game-portal-routes.conf"
BACKUPS="/var/backups/game-portal-migration"
STAGED=0

usage() {
  echo "Usage: sudo bash $0 preflight|apply --site /etc/nginx/sites-enabled/YOUR_SITE [--host 47.119.122.133] [--ref main]"
  echo "       sudo bash $0 rollback --backup /var/backups/game-portal-migration/TIMESTAMP"
}
while (( $# )); do
  case "$1" in
    --site) SITE="$2"; shift 2;;
    --host) HOST="$2"; shift 2;;
    --backup) BACKUP="$2"; shift 2;;
    --ref) PORTAL_REF="$2"; shift 2;;
    *) usage; exit 2;;
  esac
done
[[ "$ACTION" == preflight || "$ACTION" == apply || "$ACTION" == rollback ]] || { usage; exit 2; }
[[ $EUID -eq 0 ]] || { echo "Run with sudo on ECS" >&2; exit 1; }
for cmd in nginx git curl python3 cmp readlink; do
  command -v "$cmd" >/dev/null || { echo "Missing $cmd" >&2; exit 1; }
done
log() { printf '[Portal] %s\n' "$*"; }
reload_nginx() {
  nginx -t
  if command -v systemctl >/dev/null && systemctl is-active --quiet nginx; then
    systemctl reload nginx
  else
    nginx -s reload
  fi
}
get() { curl --fail --silent --show-error --max-time 12 -H "Host: $HOST" "http://127.0.0.1$1"; }

rollback_internal() {
  local original previous
  [[ -f "$BACKUP/original-site.conf" ]] || { log "Missing rollback snapshot"; return 1; }
  original="$(cat "$BACKUP/site-path")"
  [[ "$original" == /etc/nginx/* ]] || return 1
  cp -p "$BACKUP/original-site.conf" "$original"
  rm -f "$SNIPPET"
  previous="$(cat "$BACKUP/previous-portal")"
  if [[ "$previous" == NONE ]]; then
    rm -f "$PORTAL/current"
  else
    [[ -d "$previous" ]] || return 1
    ln -sfn "$previous" "$PORTAL/.current-rollback"
    mv -Tf "$PORTAL/.current-rollback" "$PORTAL/current"
  fi
  reload_nginx
  log "Rollback completed; check / and /health."
}
die() {
  log "ERROR: $*" >&2
  if [[ "$STAGED" == 1 ]]; then
    STAGED=0
    rollback_internal || log "AUTO ROLLBACK FAILED; use snapshot: $BACKUP" >&2
  fi
  exit 1
}
on_error() {
  local status=$?
  trap - ERR
  if [[ "$STAGED" == 1 ]]; then
    STAGED=0
    log "Command failed; reverting Nginx and portal symlink."
    rollback_internal || log "AUTO ROLLBACK FAILED; snapshot: $BACKUP" >&2
  fi
  exit "$status"
}
trap on_error ERR

if [[ "$ACTION" == rollback ]]; then
  [[ -n "$BACKUP" ]] || die "Pass --backup"
  rollback_internal
  exit 0
fi

[[ -n "$SITE" && -f "$SITE" ]] || die "Pass --site pointing to active Nginx site conf"
SITE="$(readlink -f "$SITE")"
[[ "$SITE" == /etc/nginx/* ]] || die "Site must be under /etc/nginx"
SITE="$SITE" python3 - <<'PY'
import os, pathlib, re, sys
s=pathlib.Path(os.environ["SITE"]).read_text()
if len(re.findall(r"(?m)^\s*server\s*\{",s)) != 1:
    sys.exit("Site file must contain exactly one server { block; inspect and select another site.")
if "game-portal-routes.conf" in s:
    sys.exit("Portal already installed. Do not apply twice; use rollback first.")
if re.search(r"(?m)^\s*location\s*=\s*/\s*\{",s):
    sys.exit("Conflicting exact '/' location; manual review needed.")
index_locations = re.findall(r"(?m)^[ \t]*location[ \t]+=[ \t]+/index\.html[ \t]*\{",s)
if len(index_locations) != 1:
    sys.exit("Expected exactly one original exact '/index.html' location as in the provided rift.conf; abort.")
# This is the known ECS kit's setup; its original index location is retained
# and its root gets overridden to the portal in the activation transaction.
PY
[[ -L "$RIFT" && -s "$RIFT/index.html" && -d "$RIFT/assets" ]] ||
  die "Expected deployed Rift at $RIFT, with index.html and assets"
[[ ! -e "$SNIPPET" && ! -L "$SNIPPET" ]] ||
  die "Snippet already exists: $SNIPPET"
nginx -t
get /health | grep -q '"status"' || die "Current /health route failed"
get / | grep -Eqi '异界共振|Rift Resonance|RIFT' || die "Current root not Rift; wrong --site/--host?"
log "Preflight OK. Site=$SITE; Rift=$(readlink -f "$RIFT")."
[[ "$ACTION" == apply ]] || exit 0

stamp="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="$BACKUPS/$stamp"
[[ ! -e "$BACKUP" ]] || die "Backup timestamp already exists"
mkdir -p "$BACKUP" "$PORTAL/releases" /etc/nginx/snippets
chmod 700 "$BACKUP"
cp -p "$SITE" "$BACKUP/original-site.conf"
printf '%s\n' "$SITE" > "$BACKUP/site-path"
if [[ -L "$PORTAL/current" ]]; then
  readlink -f "$PORTAL/current" > "$BACKUP/previous-portal"
elif [[ -e "$PORTAL/current" ]]; then
  die "$PORTAL/current is not a symlink; refusing overwrite"
else
  printf 'NONE\n' > "$BACKUP/previous-portal"
fi
log "Backup snapshot: $BACKUP"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
git clone --depth 1 --branch main https://github.com/q894829927/Game-Portal.git "$tmp/portal"
if [[ "$PORTAL_REF" != main ]]; then
  git -C "$tmp/portal" fetch --depth 1 origin "$PORTAL_REF"
  git -C "$tmp/portal" checkout --detach FETCH_HEAD
fi
sha="$(git -C "$tmp/portal" rev-parse --short=12 HEAD)"
release="$PORTAL/releases/$stamp-$sha"
mkdir -p "$release"
cp -a "$tmp/portal/." "$release/"
rm -rf "$release/.git"
for name in index.html styles.css app.js config.js assets/rift-art.svg assets/tactics-art.svg assets/favicon.svg; do
  [[ -s "$release/$name" ]] || die "Missing portal asset: $name"
done
# Retain Rift's original Vite absolute /assets/ URLs; move portal art only.
python3 - "$release/index.html" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
for name in ("favicon","rift-art","tactics-art"):
    original=f"./assets/{name}.svg"
    if original not in s: sys.exit("Missing portal art URL: "+original)
    s=s.replace(original,f"/portal-assets/{name}.svg")
p.write_text(s)
PY
chmod -R a+rX "$release"

cat > "$SNIPPET" <<'NGINX'
# Preserve existing Colyseus /health, matchmaking, WS, and Rift /assets/ routes.
location = / { root /var/www/game-portal/current; try_files /index.html =404; }
location = /styles.css { root /var/www/game-portal/current; try_files $uri =404; }
location = /app.js { root /var/www/game-portal/current; try_files $uri =404; }
location = /config.js { root /var/www/game-portal/current; try_files $uri =404; }
location ^~ /portal-assets/ {
    alias /var/www/game-portal/current/assets/;
    try_files $uri =404;
}
location = /games/rift { return 308 /games/rift/; }
location ^~ /games/rift/ {
    alias /var/www/rift/current/;
    index index.html;
    try_files $uri $uri/ /games/rift/index.html;
}
NGINX
STAGED=1
SITE="$SITE" SNIPPET="$SNIPPET" python3 - <<'PY'
from pathlib import Path
import os,re,tempfile
p=Path(os.environ["SITE"]); s=p.read_text()
matches=list(re.finditer(r"(?m)^[ \t]*server\s*\{",s))
if len(matches)!=1: raise SystemExit("Site changed during migration")
# The original ECS kit already declares "location = /index.html" for
# no-store caching. Retain its directives but override the document root,
# rather than defining a second identical Nginx location in the include.
index=list(re.finditer(r"(?m)^[ \t]*location[ \t]+=[ \t]+/index\.html[ \t]*\{",s))
if len(index)!=1: raise SystemExit("Original exact index location missing")
brace_end=s.find("}",index[0].end())
if brace_end<0: raise SystemExit("Index location not closed")
existing=s[index[0].end():brace_end]
if re.search(r"(?m)^\s*(root|alias)\b",existing):
    raise SystemExit("Index location already defines root/alias; manual review needed")
offset=index[0].end()
s=s[:offset]+"\n        root /var/www/game-portal/current;"+s[offset:]
matches=list(re.finditer(r"(?m)^[ \t]*server\s*\{",s))
i=matches[0].end(); s=s[:i]+"\n    include "+os.environ["SNIPPET"]+";\n"+s[i:]
fd,tmp=tempfile.mkstemp(prefix=".portal-",dir=p.parent)
with os.fdopen(fd,"w") as f: f.write(s)
Path(tmp).chmod(p.stat().st_mode & 0o777)
os.replace(tmp,p)
PY
ln -s "$release" "$PORTAL/.current-new"
mv -Tf "$PORTAL/.current-new" "$PORTAL/current"
reload_nginx

get / | grep -q 'id="rift-enter"' || die "Portal index failed"
get /index.html | grep -q 'id="rift-enter"' || die "Portal /index.html failed"
get /styles.css | grep -q 'game-grid' || die "Portal CSS failed"
get /portal-assets/rift-art.svg | grep -q '<svg' || die "Portal artwork failed"
get /games/rift/ | grep -Eqi '异界共振|Rift Resonance|RIFT' || die "Rift new path failed"
get /health | grep -q '"status"' || die "Game /health failed"
asset="$(python3 - "$RIFT/index.html" <<'PY'
import re,sys
s=open(sys.argv[1]).read()
m=re.search(r'(?:src|href)="(/assets/[^"]+\.(?:js|css))"',s)
print(m.group(1) if m else "")
PY
)"
[[ -n "$asset" && -f "$RIFT$asset" ]] || die "Cannot locate original Rift JS/CSS asset"
get "$asset" > "$tmp/downloaded-asset"
cmp -s "$RIFT$asset" "$tmp/downloaded-asset" || die "Original Rift /assets/ broken"

STAGED=0
trap - ERR
log "SUCCESS. Portal=/ ; Rift=/games/rift/ ; health and original Vite assets preserved."
log "No changes to rift-game.service or rift-deploy.timer."
log "Manual rollback: sudo bash $0 rollback --backup $BACKUP"
log "IMPORTANT: verify two real clients can create/join a room (WebSocket)!"
