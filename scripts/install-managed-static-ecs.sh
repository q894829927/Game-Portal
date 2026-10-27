#!/usr/bin/env bash
# One-time isolated PUBLIC static/Vite project install on the existing ECS.
set -Eeuo pipefail
umask 022
say() { printf '[Managed Install] %s\n' "$*"; }
fail() { say "ERROR: $*" >&2; exit 1; }
[[ "$EUID" == 0 ]] || fail "Run as root"
slug="" repo=""
while (($#)); do
  case "$1" in
    --slug) slug="$2"; shift 2;;
    --repo) repo="$2"; shift 2;;
    *) fail "Usage: $0 --slug new-game --repo owner/NewGame";;
  esac
done
[[ "$slug" =~ ^[a-z][a-z0-9-]{1,30}$ && "$slug" != *--* ]] || fail "Bad slug"
case "$slug" in rift|tactics) fail "Reserved slug";; esac
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "Use public owner/repo"
readonly ip=47.119.122.133
readonly remote="https://github.com/$repo.git"
readonly src="$(cd -- "$(dirname -- "$0")/.." && pwd -P)"
readonly conf="/etc/nginx/conf.d/rift.conf"
readonly snippet="/etc/nginx/snippets/game-portal-managed-$slug.conf"
readonly config="/etc/game-portal/managed-sites/$slug.env"
readonly unit="portal-site-$slug"
readonly svc="/etc/systemd/system/$unit.service"
readonly timer="/etc/systemd/system/$unit.timer"
readonly www="/var/www/game-portal/managed-sites/$slug"
readonly work="/opt/game-portal/managed-sites/$slug"
readonly shared="/opt/game-portal/bin/deploy-managed-static.sh"
readonly gate="/opt/game-portal/bin/managed-ci-gate.py"
readonly transport="/opt/game-portal/bin/managed-git-transport.sh"
for c in nginx python3 git curl systemctl flock install cp cmp timeout ssh ssh-keygen; do
  command -v "$c" >/dev/null || fail "Missing $c"
done
[[ "$(git -C "$src" branch --show-current)" == main &&
   -z "$(git -C "$src" status --porcelain)" ]] || fail "Game-Portal main must be clean"
url="$(git -C "$src" remote get-url origin)"
[[ "$url" == https://github.com/q894829927/Game-Portal.git ||
   "$url" == git@github.com:q894829927/Game-Portal.git ||
   "$url" == ssh://git@ssh.github.com:443/q894829927/Game-Portal.git ]] ||
  fail "Unexpected Game-Portal origin"
exec 9>/run/lock/portal-managed-install.lock
flock -n 9 || fail "Concurrent install"
[[ -f "$src/scripts/managed-git-transport.sh" ]] || fail "Managed Git helper missing"
source "$src/scripts/managed-git-transport.sh"
[[ -f "$conf" && -f /etc/nginx/snippets/game-portal-routes.conf ]] ||
  fail "Original Portal Nginx configuration missing"
for p in "$snippet" "$config" "$svc" "$timer" "$www" "$work"; do
  [[ ! -e "$p" && ! -L "$p" ]] || fail "Existing project/install: $p"
done
if [[ -e "$shared" ]] &&
   ! cmp -s "$shared" "$src/scripts/deploy-managed-static-ecs.sh"; then
  fail "Installed shared deployer differs from source; manual upgrade required"
fi
if [[ -e "$gate" ]] &&
   ! cmp -s "$gate" "$src/scripts/managed-ci-gate.py"; then
  fail "Installed CI gate differs from source; manual upgrade required"
fi
if [[ -e "$transport" ]] &&
   ! cmp -s "$transport" "$src/scripts/managed-git-transport.sh"; then
  fail "Installed transport helper differs from source; manual upgrade required"
fi
nginx -t
check() {
  local proto="$1" path="$2" code
  if [[ "$proto" == http ]]; then
    code="$(curl --noproxy '*' -sS --max-time 8 -H "Host: $ip" \
      -o /dev/null -w '%{http_code}' "http://127.0.0.1$path")" || return 1
  else
    code="$(curl --noproxy '*' -sS --max-time 8 \
      --resolve "$ip:443:127.0.0.1" -o /dev/null -w '%{http_code}' \
      "https://$ip$path")" || return 1
  fi
  [[ "$code" == 200 ]]
}
for proto in http https; do
  for path in / /games/rift/ /games/tactics/; do
    check "$proto" "$path" || fail "Existing $proto$path unhealthy"
  done
done
check http /health || fail "Game health unavailable"
check https /love/ || fail "Private site unavailable"
if nginx -T 2>/dev/null | grep -Eq "location[[:space:]]+(\^~|=)?[[:space:]]*/games/$slug(/|[[:space:]])"; then
  fail "Nginx path already registered"
fi
managed_git_setup "$slug" "$repo" || fail "SSH key binding mismatch"
m="$(managed_git_ls_remote main)" || {
  managed_git_hint "$slug" "$repo"
  fail "GitHub main unreachable via SSH 443 or public HTTPS"
}
s="$(managed_git_ls_remote site)" || {
  managed_git_hint "$slug" "$repo"
  fail "GitHub site unreachable via SSH 443 or public HTTPS"
}
[[ "$m" =~ ^[0-9a-f]{40} && "$s" =~ ^[0-9a-f]{40} ]] ||
  fail "Push main and await successful publish-site GitHub Action"

backup="/var/backups/game-portal-managed-install/$(date -u +%Y%m%d-%H%M%S)-$slug-$$"
install -d -m 0700 "$backup"
cp -p "$conf" "$backup/rift.conf"
changed=1
rollback() {
  local rc=$?
  trap - EXIT
  if ((rc != 0 && changed)); then
    say "Rolling back only the new site and HTTP nginx include"
    systemctl stop "$unit.timer" >/dev/null 2>&1 || true
    systemctl disable "$unit.timer" >/dev/null 2>&1 || true
    cp -p "$backup/rift.conf" "$conf"
    rm -f -- "$snippet" "$config" "$svc" "$timer"
    systemctl daemon-reload || true
    nginx -t && systemctl reload nginx ||
      say "CRITICAL: restore Nginx from $backup/rift.conf manually"
    rm -rf -- "$www" "$work"
  fi
  exit "$rc"
}
trap rollback EXIT
install -d -m 0755 /etc/nginx/snippets /etc/game-portal/managed-sites \
  /opt/game-portal/bin "$www/releases" "$work"
[[ -e "$shared" ]] || install -m 0755 "$src/scripts/deploy-managed-static-ecs.sh" "$shared"
[[ -e "$gate" ]] || install -m 0644 "$src/scripts/managed-ci-gate.py" "$gate"
[[ -e "$transport" ]] || install -m 0644 "$src/scripts/managed-git-transport.sh" "$transport"
printf 'SITE_SLUG=%s\nSITE_REPO=%s\nSITE_HOST=%s\n' "$slug" "$repo" "$ip" > "$config"
chmod 0600 "$config"
git init -q "$work/repo"
git -C "$work/repo" remote add origin "$remote"
cat > "$snippet" <<EOF
location = /games/$slug { return 308 /games/$slug/; }
location ^~ /games/$slug/ {
    alias $www/current/;
    index index.html;
    try_files \$uri \$uri/ /games/$slug/index.html;
    add_header X-Content-Type-Options "nosniff" always;
}
EOF
python3 - "$conf" "$snippet" <<'PY'
import os,re,sys,tempfile
from pathlib import Path
p=Path(sys.argv[1]);s=p.read_text()
blocks=list(re.finditer(r"(?m)^[ \t]*server[ \t]*\{",s))
if len(blocks)!=1 or "game-portal-routes.conf" not in s:
    sys.exit("Unexpected HTTP site layout")
i=blocks[0].end()
s=s[:i]+"\n    include "+sys.argv[2]+";\n"+s[i:]
fd,name=tempfile.mkstemp(dir=p.parent,prefix=".portal-site-")
with os.fdopen(fd,"w") as f:f.write(s)
os.chmod(name,p.stat().st_mode & 0o777);os.replace(name,p)
PY
cat > "$svc" <<EOF
[Unit]
Description=Deploy public CI-approved project $slug
Wants=network-online.target
After=network-online.target
ConditionPathExists=$config
[Service]
Type=oneshot
User=root
EnvironmentFile=$config
ExecStart=$shared $slug
TimeoutStartSec=240
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
EOF
cat > "$timer" <<EOF
[Unit]
Description=Poll $slug releases every three minutes
[Timer]
OnBootSec=2min
OnUnitInactiveSec=3min
AccuracySec=30s
Unit=$unit.service
[Install]
WantedBy=timers.target
EOF
if command -v getenforce >/dev/null && [[ "$(getenforce)" == Enforcing ]]; then
  command -v restorecon >/dev/null || fail "SELinux restorecon missing"
  restorecon -RF "$www" "$work"
fi
nginx -t
systemctl reload nginx
systemctl daemon-reload
systemctl start "$unit.service" || fail "First verified deploy failed"
[[ -L "$www/current" && -s "$www/current/index.html" ]] ||
  fail "First release not deployed"
systemctl enable --now "$unit.timer"
systemctl is-active --quiet "$unit.timer" &&
systemctl is-enabled --quiet "$unit.timer" || fail "Timer installation failed"
changed=0
trap - EXIT
say "SUCCESS: https://$ip/games/$slug/ (GitHub $repo main; auto-check ~3min)"
say "Nginx backup: $backup/rift.conf"
say "Existing Portal/Rift/Tactics/love files and timers unchanged"
