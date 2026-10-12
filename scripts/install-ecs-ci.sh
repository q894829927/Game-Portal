#!/usr/bin/env bash
# Install separate Portal CI-gated ECS deploy. Will not rewrite nginx or Rift.
set -Eeuo pipefail
umask 022
log() { printf '[Portal Install] %s\n' "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "Must run as root on ECS"
for cmd in git install systemctl nginx curl; do
  command -v "$cmd" >/dev/null || die "Missing command $cmd"
done
source_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
[[ -f "$source_dir/scripts/deploy-portal-ecs.sh" ]] || die "Missing Portal deploy script"
[[ "$(git -C "$source_dir" branch --show-current)" == main ]] ||
  die "Use the Game-Portal main branch"
[[ -z "$(git -C "$source_dir" status --porcelain)" ]] ||
  die "Local Git worktree is dirty; commit or stash changes"
origin="$(git -C "$source_dir" remote get-url origin)"
[[ "$origin" == https://github.com/q894829927/Game-Portal.git ||
   "$origin" == git@github.com:q894829927/Game-Portal.git ]] ||
  die "Unexpected git origin"
[[ -f /etc/nginx/conf.d/rift.conf &&
   -f /etc/nginx/snippets/game-portal-routes.conf &&
   -L /var/www/rift/current &&
   -L /var/www/game-portal/current ]] ||
  die "First complete the already-tested portal path migration"
nginx -t
response="$(mktemp)"
trap 'rm -f "$response"' EXIT
curl -fSs --max-time 12 -H 'Host: 47.119.122.133' \
  http://127.0.0.1/ -o "$response" || die "Portal homepage unavailable"
grep -q 'id="rift-enter"' "$response" || die "Wrong root page: abort"
curl -fSs --max-time 12 -H 'Host: 47.119.122.133' \
  http://127.0.0.1/health -o "$response" || die "Rift health unavailable"
grep -q '"status":"ok"' "$response" || die "Rift health not OK"

install -d -m 0755 /opt/game-portal/bin
if [[ -e /opt/game-portal/repo && ! -d /opt/game-portal/repo/.git ]]; then
  die "The /opt/game-portal/repo path exists but is not a git repo"
fi
if [[ ! -d /opt/game-portal/repo/.git ]]; then
  # Clone LOCAL checked-out code. No need for a new GitHub connection.
  git clone --no-hardlinks --branch main "$source_dir" /opt/game-portal/repo
fi
git -C /opt/game-portal/repo remote set-url origin \
  https://github.com/q894829927/Game-Portal.git
install -m 0755 "$source_dir/scripts/deploy-portal-ecs.sh" /opt/game-portal/bin/deploy.sh
install -m 0644 "$source_dir/scripts/prepare_release.py" /opt/game-portal/bin/prepare_release.py
install -m 0644 "$source_dir/ops/systemd/game-portal-deploy.service" /etc/systemd/system/game-portal-deploy.service
install -m 0644 "$source_dir/ops/systemd/game-portal-deploy.timer" /etc/systemd/system/game-portal-deploy.timer

if [[ ! -e /etc/default/game-portal-deploy ]]; then
  printf 'PORTAL_HOST=47.119.122.133\n' >/etc/default/game-portal-deploy
  chmod 0644 /etc/default/game-portal-deploy
fi
systemctl daemon-reload
systemctl enable --now game-portal-deploy.timer
log "SUCCESS: independent Portal deployment timer enabled"
log "No changes to Nginx, Rift server, or rift-deploy.timer"
log "Run once: systemctl start game-portal-deploy.service"
log "Logs: journalctl -u game-portal-deploy.service -n 80 --no-pager"
