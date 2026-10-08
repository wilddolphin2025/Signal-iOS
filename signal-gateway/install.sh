#!/usr/bin/env bash
set -euo pipefail

# Installs the Signal gateway, test contacts, and signal-cli on Ubuntu 24.04.
# Intended for rtc.wilddolphin.us (217.77.3.65).

GATEWAY_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_PATH="${DEPLOY_PATH:-/opt/signal-gateway}"
SIGNAL_CLI_VERSION="${SIGNAL_CLI_VERSION:-0.14.9}"
TLS_DIR="${TLS_DIR:-/etc/signal-gateway/tls}"
DOMAIN="${DOMAIN:-rtc.wilddolphin.us}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root (sudo $0)"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq python3 python3-venv python3-pip python3-dev \
  build-essential ffmpeg nginx openssl curl unzip openjdk-21-jre-headless \
  libopus-dev libvpx-dev pkg-config libsrtp2-dev

id -u signal-gateway >/dev/null 2>&1 || useradd --system --home /var/lib/signal-cli --shell /usr/sbin/nologin signal-gateway
mkdir -p /var/lib/signal-cli "${DEPLOY_PATH}" "${TLS_DIR}" /etc/signal-gateway

rsync -a --delete \
  --exclude '.venv' \
  --exclude 'media/recordings' \
  --exclude '__pycache__' \
  "${GATEWAY_SRC}/" "${DEPLOY_PATH}/"

python3 "${DEPLOY_PATH}/scripts/generate-media.py"
python3 -m venv "${DEPLOY_PATH}/.venv"
"${DEPLOY_PATH}/.venv/bin/pip" install --upgrade pip wheel
"${DEPLOY_PATH}/.venv/bin/pip" install aiohttp aiortc av

if [[ ! -x /usr/local/bin/signal-cli ]]; then
  tmp="$(mktemp -d)"
  curl -fsSL -o "${tmp}/signal-cli.tar.gz" \
    "https://github.com/AsamK/signal-cli/releases/download/v${SIGNAL_CLI_VERSION}/signal-cli-${SIGNAL_CLI_VERSION}-Linux-native.tar.gz"
  tar -C "${tmp}" -xzf "${tmp}/signal-cli.tar.gz"
  install -m 0755 "${tmp}/signal-cli" /usr/local/bin/signal-cli || \
    install -m 0755 "${tmp}/bin/signal-cli" /usr/local/bin/signal-cli
  rm -rf "${tmp}"
fi

if [[ ! -f "${TLS_DIR}/fullchain.pem" || ! -f "${TLS_DIR}/privkey.pem" ]]; then
  openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
    -keyout "${TLS_DIR}/privkey.pem" \
    -out "${TLS_DIR}/fullchain.pem" \
    -subj "/CN=${DOMAIN}" \
    -addext "subjectAltName=DNS:${DOMAIN},IP:217.77.3.65"
fi

install -m 0644 "${DEPLOY_PATH}/systemd/signal-gateway.service" /etc/systemd/system/signal-gateway.service
install -m 0644 "${DEPLOY_PATH}/systemd/signal-cli.service" /etc/systemd/system/signal-cli.service
install -m 0644 "${DEPLOY_PATH}/systemd/signal-bridge.service" /etc/systemd/system/signal-bridge.service
install -m 0644 "${DEPLOY_PATH}/nginx/rtc.wilddolphin.us.conf" /etc/nginx/sites-available/rtc.wilddolphin.us.conf
ln -sfn /etc/nginx/sites-available/rtc.wilddolphin.us.conf /etc/nginx/sites-enabled/rtc.wilddolphin.us.conf
rm -f /etc/nginx/sites-enabled/default

if [[ ! -f /etc/signal-gateway.env ]]; then
  cat > /etc/signal-gateway.env <<'EOF'
# Optional: E.164 of a dedicated Signal account linked via:
#   sudo -u signal-gateway signal-cli --data-dir /var/lib/signal-cli link -n rtc-gateway
SIGNAL_CLI_ACCOUNT=
SIGNAL_CLI_RPC=http://127.0.0.1:7583/api/v1/rpc
EOF
fi

chown -R signal-gateway:signal-gateway "${DEPLOY_PATH}" /var/lib/signal-cli
chmod 0750 /var/lib/signal-cli
chmod 0640 /etc/signal-gateway.env || true

nginx -t
systemctl daemon-reload
systemctl enable --now signal-gateway.service signal-cli.service signal-bridge.service
systemctl reload nginx

echo
echo "Signal gateway is installed."
echo "Contacts:"
python3 - <<'PY'
import json
from pathlib import Path
data = json.loads(Path("/opt/signal-gateway/contacts.json").read_text())
for c in data["contacts"]:
    print(f"  {c['display_name']:22} {c['e164']}  ext {c['short_number']}  {c['id']}")
PY
echo
echo "Health: https://${DOMAIN}/health"
echo "To attach a Signal account: sudo -u signal-gateway signal-cli --data-dir /var/lib/signal-cli link -n rtc-gateway"
echo "Then set SIGNAL_CLI_ACCOUNT in /etc/signal-gateway.env and restart signal-bridge."
