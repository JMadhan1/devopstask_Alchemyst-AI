#!/usr/bin/env bash
# setup-engine.sh — runs as EC2 user_data on engine-vm
# Installs the iii engine, writes config, and starts it as a systemd service.

set -euo pipefail
exec > >(tee /var/log/iii-engine-setup.log) 2>&1

echo "[engine-setup] Starting at $(date)"

# ── System dependencies ───────────────────────────────────────────────────────
apt-get update -qq
apt-get install -y -qq curl git unzip jq

# ── Install iii engine ───────────────────────────────────────────────────────
export HOME=/root   # cloud-init user_data does not set HOME; installer needs it
if ! command -v iii &>/dev/null; then
  echo "[engine-setup] Installing iii engine…"
  curl -fsSL https://install.iii.dev/iii/main/install.sh | sh
  # Installer puts binary in ~/.local/bin; make it system-wide for systemd
  install -m 0755 /root/.local/bin/iii /usr/local/bin/iii
fi
export PATH="/usr/local/bin:$PATH"
echo "[engine-setup] iii version: $(iii --version)"

# Repo: https://github.com/JMadhan1/devopstask_Alchemyst-AI

# ── Project directory + config ───────────────────────────────────────────────
PROJECT_DIR=/opt/iii-engine
mkdir -p "$PROJECT_DIR/data"

cat > "$PROJECT_DIR/config.yaml" << 'YAML'
workers:
  - name: iii-observability
    config:
      enabled: true
      service_name: iii
      exporter: memory
      memory_max_spans: 10000
      metrics_enabled: true
      metrics_exporter: memory
      logs_enabled: true
      logs_exporter: memory
      logs_console_output: true
      sampling_ratio: 1.0

  - name: iii-queue
    config:
      adapter:
        name: builtin

  - name: iii-state
    config:
      adapter:
        name: kv
        config:
          store_method: file_based
          file_path: /opt/iii-engine/data/state_store.db

  - name: iii-http
    config:
      host: 0.0.0.0
      port: 3111
      default_timeout: 30000
      concurrency_request_limit: 1024
      cors:
        allowed_origins:
          - "*"
        allowed_methods:
          - GET
          - POST
          - PUT
          - DELETE
          - OPTIONS
YAML

# ── systemd service ───────────────────────────────────────────────────────────
cat > /etc/systemd/system/iii-engine.service << 'SERVICE'
[Unit]
Description=iii Engine (WebSocket hub + HTTP API gateway)
Documentation=https://iii.dev/docs
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/iii-engine
ExecStart=/usr/local/bin/iii --config config.yaml
Restart=on-failure
RestartSec=5
MemoryMax=1G
StandardOutput=journal
StandardError=journal
SyslogIdentifier=iii-engine

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable iii-engine
systemctl start iii-engine

echo "[engine-setup] Done at $(date) — iii engine started, API on :3111"
