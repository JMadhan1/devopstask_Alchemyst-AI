#!/usr/bin/env bash
# setup-inference-worker.sh — runs as EC2 user_data on inference-vm
# Installs Python, iii-sdk, downloads the GGUF model, and starts the worker.
#
# Terraform injects ENGINE_IP at render time via templatefile().

set -uo pipefail
exec > >(tee /var/log/iii-inference-setup.log) 2>&1

export HOME=/root   # cloud-init user_data does not set HOME

ENGINE_IP="${engine_internal_ip}"   # injected by Terraform templatefile()
III_URL="ws://$ENGINE_IP:49134"

echo "[inference-setup] Starting at $(date), engine=$III_URL"

# ── Swap (2 GB) to survive pip/compile on t3.small ───────────────────────────
if [ ! -f /swapfile ]; then
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo "[inference-setup] Swap enabled"
fi

# ── System dependencies ───────────────────────────────────────────────────────
apt-get update -qq
apt-get install -y -qq python3 python3-pip python3-venv curl git jq cmake gcc g++ build-essential

# ── Project directory ─────────────────────────────────────────────────────────
WORKER_DIR=/opt/iii-inference-worker
mkdir -p "$WORKER_DIR"

# ── Clone worker source from GitHub ───────────────────────────────────────────
REPO=https://github.com/JMadhan1/devopstask_Alchemyst-AI.git
echo "[inference-setup] Cloning $REPO ..."
git clone --depth=1 "$REPO" /tmp/devops_repo
cp -r /tmp/devops_repo/workers/inference-worker/. "$WORKER_DIR/"

# ── Python virtualenv + dependencies ─────────────────────────────────────────
python3 -m venv "$WORKER_DIR/.venv"
"$WORKER_DIR/.venv/bin/pip" install --upgrade pip -q

echo "[inference-setup] Installing llama-cpp-python (pre-built binary)..."
"$WORKER_DIR/.venv/bin/pip" install llama-cpp-python --prefer-binary -q

echo "[inference-setup] Installing remaining Python dependencies..."
"$WORKER_DIR/.venv/bin/pip" install -r "$WORKER_DIR/requirements.txt" -q

echo "[inference-setup] Python dependencies installed."

# ── systemd environment file ──────────────────────────────────────────────────
cat > /etc/iii-inference.env << EOF
III_URL=$III_URL
MODEL_REPO=ggml-org/gemma-3-270m-GGUF
MODEL_FILE=gemma-3-270m-Q8_0.gguf
EOF

# ── systemd service ───────────────────────────────────────────────────────────
cat > /etc/systemd/system/iii-inference-worker.service << 'SERVICE'
[Unit]
Description=iii Inference Worker (Python / Gemma GGUF)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/iii-inference-worker
EnvironmentFile=/etc/iii-inference.env
ExecStart=/opt/iii-inference-worker/.venv/bin/python inference_worker.py
# Model takes ~2-5 min to load; don't kill it during startup
TimeoutStartSec=300
Restart=on-failure
RestartSec=10
MemoryMax=10G
StandardOutput=journal
StandardError=journal
SyslogIdentifier=iii-inference

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable iii-inference-worker
systemctl start iii-inference-worker

echo "[inference-setup] inference-worker service started."
