#!/usr/bin/env bash
# One-time key provisioner for public ECS managed sites when github.com:443
# HTTPS is blocked. Register the printed public key in THIS repository only.
set -Eeuo pipefail
umask 077
say() { printf '[Managed SSH] %s\n' "$*"; }
die() { say "ERROR: $*" >&2; exit 1; }
[[ "$EUID" == 0 ]] || die "Requires ECS root"
slug="" repo=""
while (($#)); do
  case "$1" in
    --slug) [[ $# -ge 2 ]] || die "Missing --slug"; slug="$2"; shift 2;;
    --repo) [[ $# -ge 2 ]] || die "Missing --repo"; repo="$2"; shift 2;;
    *) die "Usage: bash scripts/provision-managed-ssh-ecs.sh --slug pinball --repo owner/Repository";;
  esac
done
[[ "$slug" =~ ^[a-z][a-z0-9-]{1,30}$ && "$slug" != *--* ]] ||
  die "Invalid slug"
case "$slug" in rift|tactics) die "Reserved existing game slug";; esac
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
  die "Invalid repository owner/name"
for c in ssh-keygen install cat; do command -v "$c" >/dev/null || die "Missing $c"; done
hosts="/etc/game-portal/ssh/github_known_hosts"
[[ -s "$hosts" && ! -L "$hosts" ]] ||
  die "Existing verified Game-Portal SSH 443 known_hosts missing"
ssh-keygen -F '[ssh.github.com]:443' -f "$hosts" >/dev/null ||
  die "SSH 443 host key not found in existing verified known_hosts"
dir="/etc/game-portal/managed-ssh/$slug"
key="$dir/deploy_key"
metadata="$dir/repository"
install -d -o root -g root -m 0700 "$dir"
[[ ! -L "$key" && ! -L "$key.pub" && ! -L "$metadata" ]] ||
  die "Unexpected symlink in key storage"
if [[ -e "$metadata" ]]; then
  [[ "$(cat "$metadata")" == "$repo" ]] ||
    die "Slug already provisioned for another repository"
fi
if [[ -e "$key" || -e "$key.pub" ]]; then
  [[ -s "$key" && -s "$key.pub" && -s "$metadata" ]] ||
    die "Existing key pair incomplete. Do not overwrite; inspect manually"
  say "Reusing existing dedicated key for $repo"
else
  [[ ! -e "$metadata" ]] || die "Metadata without keys; inspect manually"
  ssh-keygen -q -t ed25519 -f "$key" -N '' -C "managed-$slug-readonly"
  printf '%s\n' "$repo" > "$metadata"
  chmod 0600 "$key" "$metadata"
  chmod 0644 "$key.pub"
  say "Generated a new per-project read-only deployment identity"
fi
say "Copy the following PUBLIC key (do not copy or share the private key):"
cat "$key.pub"
say "In GitHub, open https://github.com/$repo/settings/keys"
say "Add deploy key (no 'Allow write access'). Then rerun:"
say "  bash scripts/install-managed-static-ecs.sh --slug $slug --repo $repo"
