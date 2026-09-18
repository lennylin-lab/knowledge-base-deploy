#!/usr/bin/env bash
# Sync this deploy repo to a remote server over SSH (uses ~/.ssh/config Host aliases).
#
# Usage:
#   ./scripts/push.sh                    # interactive: pick Host + remote path
#   ./scripts/push.sh ColoCrossing       # Host from ssh config
#   ./scripts/push.sh rabisu ~/kb-deploy # Host + remote directory
#
# Syncs the full tree (including local *.env files) but excludes .git/.
# Remote directory is created if missing.
#
# Transport:
#   - rsync when available on both sides (--delete mirrors exactly)
#   - tar over ssh otherwise (remote-only files are kept)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SSH_CONFIG="${HOME}/.ssh/config"
DEFAULT_REMOTE_DIR="~/knowledge-base-deploy"

TAR_EXCLUDES=(
  --exclude='.git'
  --exclude='.DS_Store'
)

readarray -t SSH_HOSTS < <(
  if [[ -f "${SSH_CONFIG}" ]]; then
    awk '
      /^[Hh]ost[ \t]+/ {
        for (i = 2; i <= NF; i++) {
          if ($i !~ /[*?!]/ && $i !~ /^github/) print $i
        }
      }
    ' "${SSH_CONFIG}" | awk '!seen[$0]++'
  fi
)

pick_ssh_host() {
  if ((${#SSH_HOSTS[@]} == 0)); then
    echo "error: no Host entries found in ${SSH_CONFIG}" >&2
    exit 1
  fi

  echo "Select SSH Host (~/.ssh/config):" >&2
  local i
  for i in "${!SSH_HOSTS[@]}"; do
    printf '  %2d) %s\n' "$((i + 1))" "${SSH_HOSTS[$i]}" >&2
  done

  local choice
  while true; do
    read -r -p "Enter number [1-${#SSH_HOSTS[@]}]: " choice
    if [[ "${choice}" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#SSH_HOSTS[@]})); then
      REPLY="${SSH_HOSTS[$((choice - 1))]}"
      return 0
    fi
    echo "Invalid choice, try again." >&2
  done
}

prompt_remote_dir() {
  local input
  read -r -p "Remote directory [${DEFAULT_REMOTE_DIR}]: " input
  if [[ -z "${input}" ]]; then
    REPLY="${DEFAULT_REMOTE_DIR}"
  else
    REPLY="${input}"
  fi
}

remote_has_rsync() {
  ssh "${SSH_HOST}" 'command -v rsync >/dev/null 2>&1'
}

push_via_rsync() {
  local remote="${SSH_HOST}:${REMOTE_DIR%/}/"
  echo "==> Transport: rsync (--delete)"
  rsync -avz --delete --progress \
    --exclude '.git/' \
    --exclude '.DS_Store' \
    -e ssh \
    "${ROOT}/" "${remote}"
}

push_via_tar() {
  echo "==> Transport: tar over ssh (remote lacks rsync; stale files are kept)"
  ssh "${SSH_HOST}" "mkdir -p ${REMOTE_DIR}"
  tar czf - \
    "${TAR_EXCLUDES[@]}" \
    -C "${ROOT}" . \
    | ssh "${SSH_HOST}" "tar xzf - -C ${REMOTE_DIR}"
}

SSH_HOST="${1:-}"
REMOTE_DIR="${2:-}"

if [[ -z "${SSH_HOST}" ]]; then
  pick_ssh_host
  SSH_HOST="${REPLY}"
fi

if [[ -z "${REMOTE_DIR}" ]]; then
  prompt_remote_dir
  REMOTE_DIR="${REPLY}"
fi

if ! ssh -G "${SSH_HOST}" >/dev/null 2>&1; then
  echo "error: ssh cannot resolve Host '${SSH_HOST}' — check ~/.ssh/config" >&2
  exit 1
fi

REMOTE="${SSH_HOST}:${REMOTE_DIR%/}/"

echo "==> Target: ${REMOTE}"
echo "==> Source: ${ROOT}/"
echo "    (includes local *.env; excludes .git/)"
if remote_has_rsync && command -v rsync >/dev/null 2>&1; then
  echo "    rsync available on both sides — remote-only files will be deleted"
else
  echo "    falling back to tar — remote-only files will be kept"
fi
read -r -p "Proceed? [y/N]: " confirm
if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

ssh "${SSH_HOST}" "mkdir -p ${REMOTE_DIR}"

if remote_has_rsync && command -v rsync >/dev/null 2>&1; then
  push_via_rsync
else
  push_via_tar
fi

echo "==> Done. Remote tree:"
ssh "${SSH_HOST}" "ls -la ${REMOTE_DIR}"
