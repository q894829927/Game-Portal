#!/usr/bin/env bash
# Poll main and install ONLY Game-Portal code after this SHA's push CI succeeds.
# Do not restart nginx or touch rift-deploy.timer, rift-game, or /var/www/rift.
set -Eeuo pipefail
umask 022
export GIT_TERMINAL_PROMPT=0

readonly REPO="/opt/game-portal/repo"
readonly BIN="/opt/game-portal/bin"
readonly WWW="/var/www/game-portal"
readonly LIVE="$WWW/current"
readonly RELEASES="$WWW/releases"
readonly REMOTE="https://github.com/q894829927/Game-Portal.git"
readonly ACTIONS="https://api.github.com/repos/q894829927/Game-Portal/actions/workflows/validate-portal.yml/runs"
readonly HOST="${PORTAL_HOST:-47.119.122.133}"

log() { printf '[Portal Deploy] %s\n' "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Must run as root"
[[ -L "$LIVE" && -d "$RELEASES" ]] || die "Portal migration not installed"
[[ -f /etc/nginx/snippets/game-portal-routes.conf ]] || die "Portal Nginx routes absent"
[[ "$HOST" =~ ^[a-zA-Z0-9.:-]+$ ]] || die "Invalid PORTAL_HOST"
for cmd in curl git python3 tar flock timeout cmp; do
  command -v "$cmd" >/dev/null || die "Missing $cmd"
done
[[ -d "$REPO/.git" && -f "$BIN/prepare_release.py" && -f "$BIN/ci_gate.py" ]] ||
  die "Missing deploy installation; run install-ecs-ci.sh"
[[ "$(git -C "$REPO" remote get-url origin)" == "$REMOTE" ]] ||
  die "Unexpected git remote; refusing deployment"

exec 9>/run/lock/game-portal-deploy.lock
flock -n 9 || { log "Already deploying; skip"; exit 0; }

stage=""; tmp=""; old=""; switched=0
finish() {
  local rc=$?
  trap - EXIT
  if (( rc != 0 && switched == 1 )); then
    log "Verification failed; rolling back Portal to previous release"
    if [[ -d "$old" ]]; then
      ln -s "$old" "$WWW/.rollback-$$" &&
        mv -Tf "$WWW/.rollback-$$" "$LIVE" ||
        log "CRITICAL: manual rollback required: ln -sfn $old $LIVE"
    else
      log "CRITICAL: previous release is missing"
    fi
  fi
  [[ -z "$stage" || ! -d "$stage" ]] || rm -rf -- "$stage"
  [[ -z "$tmp" || ! -d "$tmp" ]] || rm -rf -- "$tmp"
  exit "$rc"
}
trap finish EXIT

# Fail closed on GitHub outages: the previous Portal remains online.
remote="$(timeout 45 git -C "$REPO" ls-remote origin refs/heads/main)" ||
  die "Could not reach GitHub; old Portal remains live"
sha="$(printf '%s\n' "$remote" | awk '{print $1}')"
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || die "Invalid GitHub main SHA"

old="$(readlink -f "$LIVE")"
[[ -d "$old" ]] || die "Current portal release broken"
if [[ -f "$old/.portal-commit" ]] && [[ "$(cat "$old/.portal-commit")" == "$sha" ]]; then
  log "Already serving $sha"
  exit 0
fi

tmp="$(mktemp -d)"
curl -fSLsS --connect-timeout 8 --max-time 30 --retry 2 --retry-delay 2 \
  -H "Accept: application/vnd.github+json" \
  "$ACTIONS?event=push&branch=main&head_sha=$sha&per_page=50" \
  -o "$tmp/ci.json" || die "CI API unavailable; skip deployment"
decision="$(python3 "$BIN/ci_gate.py" "$sha" "$tmp/ci.json")" ||
  die "Could not parse CI API response"
if [[ "$decision" != approved ]]; then
  log "Not deploying $sha ($decision)"
  exit 0
fi
log "Approved by Game-Portal push CI: $sha"

timeout 90 git -C "$REPO" fetch --no-tags --depth 1 origin refs/heads/main ||
  die "Git fetch failed; previous release unchanged"
fetched="$(git -C "$REPO" rev-parse FETCH_HEAD)"
[[ "$fetched" == "$sha" ]] ||
  die "main changed during CI check ($sha to $fetched); retry next cycle"

stage="$(mktemp -d "$RELEASES/.stage.XXXXXXXX")"
git -C "$REPO" archive --format=tar "$sha" | tar -xf - -C "$stage"
python3 "$BIN/prepare_release.py" "$stage" "$sha"
chmod -R a+rX "$stage"
if command -v getenforce >/dev/null && [[ "$(getenforce)" == Enforcing ]]; then
  command -v restorecon >/dev/null || die "SELinux enforcing but restorecon missing"
  restorecon -RF "$stage"
fi
release="$RELEASES/$sha"
if [[ -e "$release" || -L "$release" ]]; then
  [[ -d "$release" && ! -L "$release" &&
     -f "$release/.portal-commit" &&
     "$(cat "$release/.portal-commit")" == "$sha" ]] ||
    die "Existing release path does not match this commit"
else
  mv -T "$stage" "$release"
  stage=""
fi
ln -s "$release" "$WWW/.current-deploy-$$"
mv -Tf "$WWW/.current-deploy-$$" "$LIVE"
switched=1

# Read back the exact served bytes; no nginx reload or client disconnect.
http_matches() {
  local route="$1" file="$2" attempt code
  for attempt in 1 2 3 4 5; do
    code="$(curl -sS --max-time 8 -H "Host: $HOST" -H 'Cache-Control: no-cache' \
      -o "$tmp/http-body" -w '%{http_code}' "http://127.0.0.1$route")" || code=000
    if [[ "$code" == 200 ]] && cmp -s "$file" "$tmp/http-body"; then
      return 0
    fi
    sleep 1
  done
  log "HTTP mismatch: $route; last status=$code" >&2
  return 1
}
http_contains() {
  local route="$1" marker="$2" code
  code="$(curl -sS --max-time 8 -H "Host: $HOST" \
    -o "$tmp/http-body" -w '%{http_code}' "http://127.0.0.1$route")" || return 1
  [[ "$code" == 200 ]] && grep -q -- "$marker" "$tmp/http-body"
}
http_matches / "$release/index.html" || die "Portal homepage mismatch"
http_matches /styles.css "$release/styles.css" || die "Portal stylesheet mismatch"
http_matches /app.js "$release/app.js" || die "Portal script mismatch"
http_matches /config.js "$release/config.js" || die "Portal config mismatch"
http_matches /portal-assets/rift-art.svg "$release/assets/rift-art.svg" ||
  die "Portal artwork mismatch"
http_contains /games/rift/ "RIFT" || die "Existing Rift route failed"
http_contains /health '"status":"ok"' || die "Existing Rift backend unhealthy"

switched=0
log "SUCCESS. Now serving $sha from $release"
log "Rift game, Nginx and Rift auto-deploy unchanged"
