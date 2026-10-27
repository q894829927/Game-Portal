#!/usr/bin/env bash
# Shared transport for PUBLIC managed projects. Use a dedicated read-only
# repository Deploy Key (SSH 443) if provisioned; fallback to public HTTPS.
# This file is sourced by the reviewed installer and the installed poller.
managed_git_setup() {
  local slug="$1" repo="$2"
  MANAGED_GIT_PUBLIC="https://github.com/$repo.git"
  MANAGED_GIT_SSH="ssh://git@ssh.github.com:443/$repo.git"
  MANAGED_GIT_KEY="/etc/game-portal/managed-ssh/$slug/deploy_key"
  MANAGED_GIT_HOSTS="/etc/game-portal/ssh/github_known_hosts"
  MANAGED_GIT_METADATA="/etc/game-portal/managed-ssh/$slug/repository"
  if [[ -e "$MANAGED_GIT_KEY" ]]; then
    [[ -f "$MANAGED_GIT_METADATA" && ! -L "$MANAGED_GIT_METADATA" &&
       "$(cat "$MANAGED_GIT_METADATA")" == "$repo" ]] || {
      printf '[Managed Git] Key binding does not match repository %s\n' "$repo" >&2
      return 1
    }
  fi
  MANAGED_GIT_SSH_ENABLED=0
  if [[ -s "$MANAGED_GIT_KEY" && ! -L "$MANAGED_GIT_KEY" &&
        -s "$MANAGED_GIT_HOSTS" && ! -L "$MANAGED_GIT_HOSTS" &&
        "$(stat -c %u "$MANAGED_GIT_KEY")" == 0 &&
        "$(stat -c %a "$MANAGED_GIT_KEY")" == 600 ]]; then
    MANAGED_GIT_SSH_ENABLED=1
    MANAGED_GIT_SSH_COMMAND="ssh -i $MANAGED_GIT_KEY -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$MANAGED_GIT_HOSTS -o ConnectTimeout=8 -o ConnectionAttempts=1"
  fi
}
managed_git_ls_remote() {
  local branch="$1" output="" rc
  case "$branch" in main|site) ;; *) return 2;; esac
  if (( MANAGED_GIT_SSH_ENABLED )); then
    if output="$(timeout 35 env GIT_SSH_COMMAND="$MANAGED_GIT_SSH_COMMAND" \
        git ls-remote "$MANAGED_GIT_SSH" "refs/heads/$branch")" && [[ -n "$output" ]]; then
      printf '%s\n' "$output"
      return 0
    fi
    printf '[Managed Git] SSH 443 lookup %s failed; falling back to HTTPS\n' "$branch" >&2
  fi
  output="$(timeout 45 git -c credential.interactive=never \
    ls-remote "$MANAGED_GIT_PUBLIC" "refs/heads/$branch")" || return 1
  [[ -n "$output" ]] || return 1
  printf '%s\n' "$output"
}
managed_git_fetch_site() {
  local gitdir="$1"
  if (( MANAGED_GIT_SSH_ENABLED )); then
    if timeout 120 env GIT_SSH_COMMAND="$MANAGED_GIT_SSH_COMMAND" \
      git -C "$gitdir" fetch --no-tags --depth 1 "$MANAGED_GIT_SSH" refs/heads/site; then
      printf '[Managed Git] Downloaded site via SSH 443\n' >&2
      return 0
    fi
    printf '[Managed Git] SSH 443 fetch failed; falling back to HTTPS\n' >&2
  fi
  timeout 120 git -c credential.interactive=never -C "$gitdir" \
    fetch --no-tags --depth 1 "$MANAGED_GIT_PUBLIC" refs/heads/site
}
managed_git_hint() {
  local slug="$1" repo="$2"
  printf '[Managed Git] For reliable ECS access, create a dedicated Deploy Key:\n' >&2
  printf '  bash scripts/provision-managed-ssh-ecs.sh --slug %s --repo %s\n' "$slug" "$repo" >&2
  printf '[Managed Git] Add the printed PUBLIC key (read-only) at:\n' >&2
  printf '  https://github.com/%s/settings/keys\n' "$repo" >&2
  printf '[Managed Git] Then rerun the installer. The old sites are unchanged.\n' >&2
}
