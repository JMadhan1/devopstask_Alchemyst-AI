#!/usr/bin/env bash
# setup-caller-worker.sh — runs as EC2 user_data on caller-vm
# Installs Node.js 20, iii-sdk, and starts the TypeScript caller worker.
#
# Terraform injects ENGINE_IP at render time via templatefile().

set -euo pipefail
exec > >(tee /var/log/iii-caller-setup.log) 2>&1

ENGINE_IP="${engine_internal_ip}"   # injected by Terraform templatefile()
III_URL="ws://$ENGINE_IP:49134"

echo "[caller-setup] Starting at $(date), engine=$III_URL"

# ── System dependencies ───────────────────────────────────────────────────────
export HOME=/root   # cloud-init user_data does not set HOME
apt-get update -qq
apt-get install -y -qq curl git jq

# ── Node.js 20 LTS ───────────────────────────────────────────────────────────
if ! command -v node &>/dev/null; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y -qq nodejs
fi

# ── Project directory ─────────────────────────────────────────────────────────
WORKER_DIR=/opt/iii-caller-worker
mkdir -p "$WORKER_DIR/src"

# ── Clone worker source from GitHub ────────────────────────────────────────────
REPO=https://github.com/JMadhan1/devopstask_Alchemyst-AI.git
echo "[caller-setup] Cloning $REPO ..."
git clone --depth=1 "$REPO" /tmp/devops_repo
cp -r /tmp/devops_repo/workers/caller-worker/. "$WORKER_DIR/"

# ── npm install ───────────────────────────────────────────────────────────────
cd "$WORKER_DIR"
npm install --silent

echo "[caller-setup] Node dependencies installed."

# ── systemd environment file ──────────────────────────────────────────────────
cat > /etc/iii-caller.env << EOF
III_URL=$III_URL
EOF

# ── systemd service ───────────────────────────────────────────────────────────
cat > /etc/systemd/system/iii-caller-worker.service << 'SERVICE'
[Unit]
Description=iii Caller Worker (TypeScript / HTTP gateway)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/iii-caller-worker
EnvironmentFile=/etc/iii-caller.env
ExecStart=/usr/bin/npx tsx src/worker.ts
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=iii-caller

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable iii-caller-worker
systemctl start iii-caller-worker

echo "[caller-setup] caller-worker service started."
