#!/usr/bin/env bash
# Shared, CI-gated public static-site release poller. Invoked by isolated systemd
# portal-site-<slug>.service. Never builds untrusted app code on the ECS.
set -Eeuo pipefail
umask 022
export GIT_TERMINAL_PROMPT=0
log() { printf '[Managed Site] %s\n' "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }
[[ "$EUID" -eq 0 ]] || die "Requires root"
[[ "$#" == 1 && "$1" =~ ^[a-z][a-z0-9-]{1,30}$ && "$1" != *--* ]] ||
  die "Usage: managed-site-deploy.sh valid-slug"
slug="$1"
case "$slug" in rift|tactics) die "Reserved slug";; esac
config="/etc/game-portal/managed-sites/$slug.env"
[[ -f "$config" && ! -L "$config" && "$(stat -c %u "$config")" == 0 ]] ||
  die "Missing root-owned managed project config"
# Installer writes validated key=value pairs. No content from GitHub is sourced.
source "$config"
[[ "$SITE_SLUG" == "$slug" && "$SITE_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ &&
   "$SITE_HOST" == 47.119.122.133 ]] ||
  die "Invalid managed project configuration"
readonly root="/var/www/game-portal/managed-sites/$slug"
readonly live="$root/current"
readonly releases="$root/releases"
readonly gitdir="/opt/game-portal/managed-sites/$slug/repo"
readonly remote="https://github.com/$SITE_REPO.git"
readonly api="https://api.github.com/repos/$SITE_REPO/actions/workflows/publish-site.yml/runs"
readonly prefix="/games/$slug/"
readonly gate="/opt/game-portal/bin/managed-ci-gate.py"
[[ -d "$gitdir/.git" && -d "$releases" && -f "$gate" ]] ||
  die "Managed-site installation incomplete"
[[ "$(git -C "$gitdir" remote get-url origin)" == "$remote" ]] ||
  die "Repository origin does not match approved configuration"
for cmd in git curl tar python3 flock timeout cmp; do
  command -v "$cmd" >/dev/null || die "Missing $cmd"
done
exec 9>"/run/lock/portal-managed-$slug.lock"
flock -n 9 || { log "$slug already checking; skip"; exit 0; }

old=""
stage=""
tmp=""
switched=0
cleanup() {
  local rc=$?
  trap - EXIT
  if ((rc != 0 && switched)); then
    log "Health check failed; restoring prior $slug release"
    if [[ -n "$old" && -d "$old" ]]; then
      ln -s "$old" "$root/.rollback-$$"
      mv -Tf "$root/.rollback-$$" "$live" ||
        log "CRITICAL: manually restore symlink to $old"
    else
      rm -f -- "$live"
    fi
  fi
  [[ -z "$stage" || ! -d "$stage" ]] || rm -rf -- "$stage"
  [[ -z "$tmp" || ! -d "$tmp" ]] || rm -rf -- "$tmp"
  exit "$rc"
}
trap cleanup EXIT

main_line="$(timeout 40 git -C "$gitdir" ls-remote "$remote" refs/heads/main)" ||
  die "Public GitHub main unreachable; existing release kept"
main="$(printf '%s\n' "$main_line" | awk '{print $1}')"
[[ "$main" =~ ^[0-9a-f]{40}$ ]] || die "Unexpected main ref"
if [[ -L "$live" ]]; then
  old="$(readlink -f "$live")"
  [[ -d "$old" && "$old" == "$releases/"* ]] ||
    die "Unexpected current symlink target"
  if [[ -f "$old/.source-sha" && "$(cat "$old/.source-sha")" == "$main" ]]; then
    log "$slug already serving main $main"
    exit 0
  fi
elif [[ -e "$live" ]]; then
  die "Live path is not a release symlink"
fi

site_line="$(timeout 40 git -C "$gitdir" ls-remote "$remote" refs/heads/site)" ||
  die "Public site branch unreachable"
site="$(printf '%s\n' "$site_line" | awk '{print $1}')"
[[ "$site" =~ ^[0-9a-f]{40}$ ]] || die "site branch not published"
tmp="$(mktemp -d)"
curl --fail --silent --show-error --location --connect-timeout 8 --max-time 35 \
  -H 'Accept: application/vnd.github+json' \
  "$api?event=push&branch=main&head_sha=$main&per_page=50" \
  -o "$tmp/runs.json" || die "GitHub Actions approval unavailable"
approval="$(python3 "$gate" "$SITE_REPO" "$main" "$tmp/runs.json")" ||
  die "Invalid workflow approval"
if [[ "$approval" != approved ]]; then
  log "$slug not deployed ($approval)"
  exit 0
fi

timeout 120 git -C "$gitdir" fetch --no-tags --depth 1 "$remote" refs/heads/site ||
  die "Could not fetch approved site"
[[ "$(git -C "$gitdir" rev-parse FETCH_HEAD)" == "$site" ]] ||
  die "site branch changed while fetching"
source_sha="$(git -C "$gitdir" show "$site:.source-sha" | tr -d '\r\n')"
kind="$(git -C "$gitdir" show "$site:.site-kind" | tr -d '\r\n')"
published_slug="$(git -C "$gitdir" show "$site:.site-slug" | tr -d '\r\n')"
[[ "$source_sha" == "$main" && "$kind" == portal-managed-static-v1 &&
   "$published_slug" == "$slug" ]] ||
  die "site artifact is not the approved project/build"
stage="$(mktemp -d "$releases/.stage.XXXXXXXX")"
git -C "$gitdir" archive --format=tar "$site" | tar -xf - -C "$stage" ||
  die "Invalid site archive"
[[ -s "$stage/index.html" && -s "$stage/.source-sha" ]] ||
  die "Missing static build"
[[ -z "$(find "$stage" -type l -print -quit)" ]] ||
  die "Site contains symlinks; refuse outside-root reads"
[[ -z "$(find "$stage" -type d -name '.*' -print -quit)" ]] ||
  die "Site contains hidden directories"
[[ -z "$(find "$stage" -type f -name '.*' ! -name '.source-sha' \
  ! -name '.site-kind' ! -name '.site-slug' -print -quit)" ]] ||
  die "Site contains unexpected dotfiles"
[[ "$(du -sm "$stage" | awk '{print $1}')" -le 250 ]] ||
  die "Static build exceeds 250 MiB"
grep -Fq "$prefix" "$stage/index.html" ||
  die "HTML is not compiled for expected URL prefix"
chmod -R a+rX "$stage"
if command -v getenforce >/dev/null && [[ "$(getenforce)" == Enforcing ]]; then
  command -v restorecon >/dev/null || die "SELinux restorecon required"
  restorecon -RF "$stage"
fi
release="$releases/$site"
if [[ -e "$release" || -L "$release" ]]; then
  [[ -d "$release" && ! -L "$release" &&
     "$(cat "$release/.source-sha")" == "$main" ]] ||
    die "Release path collision"
else
  mv -T "$stage" "$release"
  stage=""
fi
ln -s "$release" "$root/.new-current-$$"
mv -Tf "$root/.new-current-$$" "$live"
switched=1

check_url() {
  local scheme="$1" path="$2" expected="$3" code
  if [[ "$scheme" == http ]]; then
    code="$(curl --noproxy '*' --silent --show-error --max-time 8 \
      -H "Host: $SITE_HOST" -o "$tmp/response" -w '%{http_code}' \
      "http://127.0.0.1$path")" || return 1
  else
    code="$(curl --noproxy '*' --silent --show-error --max-time 8 \
      --resolve "$SITE_HOST:443:127.0.0.1" \
      -o "$tmp/response" -w '%{http_code}' \
      "https://$SITE_HOST$path")" || return 1
  fi
  [[ "$code" == 200 ]] && cmp -s "$expected" "$tmp/response"
}
passed=0
for try in 1 2 3 4 5 6 7 8 9 10; do
  if check_url http "$prefix" "$release/index.html" &&
     check_url https "$prefix" "$release/index.html"; then
    passed=1
    break
  fi
  sleep 1
done
((passed)) || die "HTTP/HTTPS page bytes did not match staged release"
for path in / /games/rift/ /games/tactics/ /health; do
  code="$(curl --noproxy '*' --silent --show-error --max-time 8 \
    -H "Host: $SITE_HOST" -o /dev/null -w '%{http_code}' \
    "http://127.0.0.1$path")" || die "Existing $path unavailable"
  [[ "$code" == 200 ]] || die "Existing $path degraded ($code)"
done
switched=0
log "SUCCESS: $slug at https://$SITE_HOST$prefix main=$main site=$site"
log "Only this project's atomic symlink was updated; other services untouched"
