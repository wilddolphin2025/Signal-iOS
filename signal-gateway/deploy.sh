#!/usr/bin/env bash
set -euo pipefail

# Copy this tree to rtc.wilddolphin.us and run install.sh.
# Uses ~/.ssh/id_ed25519 as requested.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST="${DEPLOY_HOST:-217.77.3.65}"
USER="${DEPLOY_USER:-root}"
PORT="${DEPLOY_PORT:-22}"
KEY="${SSH_KEY_PATH:-${HOME}/.ssh/id_ed25519}"
REMOTE_DIR="${REMOTE_DIR:-/opt/signal-gateway-src}"

if [[ ! -f "${KEY}" ]]; then
  echo "SSH private key not found: ${KEY}"
  echo "Public key to authorize on ${USER}@${HOST}:"
  if [[ -f "${KEY}.pub" ]]; then
    cat "${KEY}.pub"
  else
    echo "  generate with: ssh-keygen -t ed25519 -f ${KEY}"
  fi
  exit 1
fi

SSH_OPTS=(-i "${KEY}" -p "${PORT}" -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new)
REMOTE="${USER}@${HOST}"

echo "[deploy] sync to ${REMOTE}:${REMOTE_DIR}"
ssh "${SSH_OPTS[@]}" "${REMOTE}" "mkdir -p '${REMOTE_DIR}'"
rsync -az --delete \
  -e "ssh ${SSH_OPTS[*]}" \
  --exclude '.venv' \
  --exclude '__pycache__' \
  --exclude 'media/recordings' \
  "${ROOT}/" "${REMOTE}:${REMOTE_DIR}/"

echo "[deploy] install"
ssh "${SSH_OPTS[@]}" "${REMOTE}" "bash '${REMOTE_DIR}/install.sh'"

echo "[deploy] health"
ssh "${SSH_OPTS[@]}" "${REMOTE}" "curl -sk https://127.0.0.1/health || curl -s http://127.0.0.1:8787/health"
