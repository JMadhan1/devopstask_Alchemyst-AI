# Distributed Inferencing Stack — DevOps Assignment

Deploys the [iii quickstart](https://github.com/Alchemyst-ai/hiring/tree/main/may-2026/devops/quickstart) across three AWS EC2 instances in a private subnet, wired together over WebSocket RPC, with a public JSON HTTP API endpoint.

---

## Architecture

```
                        ┌──────────────────────────────────────────────────────┐
  Internet              │              AWS VPC  10.0.0.0/16                    │
      │                 │                                                      │
      │ HTTP :3111       │  ┌─────────────────────────────────────────────┐    │
      ▼                 │  │  Public Subnet  10.0.0.0/24                  │    │
 ┌────────────────┐     │  │                                              │    │
 │   engine-vm    │◄────┼──│  engine-vm  (10.0.0.X)  [PUBLIC IP]         │    │
 │  [PUBLIC IP]   │     │  │  • iii engine   ws://0.0.0.0:49134          │    │
 │  :3111 open    │     │  │  • iii-http     0.0.0.0:3111   ◄────────────┼────┤ API
 └────────────────┘     │  │  • iii-state    (file KV store)             │    │
                        │  └───────────────────┬─────────────────────────┘    │
                        │                      │ WebSocket :49134              │
                        │                      │ (private subnet only)         │
                        │  ┌───────────────────┴─────────────────────────┐    │
                        │  │  Private Subnet  10.0.1.0/24                │    │
                        │  │                                              │    │
                        │  │  ┌─────────────────┐  ┌─────────────────┐  │    │
                        │  │  │  inference-vm   │  │   caller-vm     │  │    │
                        │  │  │  NO PUBLIC IP   │  │  NO PUBLIC IP   │  │    │
                        │  │  │                 │  │                 │  │    │
                        │  │  │ Python worker   │  │  TS worker      │  │    │
                        │  │  │ inference::     │  │  inference::    │  │    │
                        │  │  │ run_inference   │  │  get_response   │  │    │
                        │  │  └─────────────────┘  │  http::         │  │    │
                        │  │                        │  run_inference  │  │    │
                        │  │       NAT GW ──────────│  _over_http     │  │    │
                        │  │    (outbound only)      └─────────────────┘  │    │
                        │  └─────────────────────────────────────────────┘    │
                        └──────────────────────────────────────────────────────┘
```

### RPC call flow

```
Client → POST /v1/chat/completions  (engine-vm public IP :3111)
              │
              ▼  iii-http routes to registered trigger
         caller-vm: http::run_inference_over_http
              │
              ▼  iii.trigger() over WebSocket (cross-VM RPC)
         caller-vm: inference::get_response
              │
              ▼  iii.trigger() over WebSocket (cross-VM RPC)
         inference-vm: inference::run_inference
              │  (Gemma GGUF forward pass)
              │
              └──► JSON response bubbles back through the chain → client
```

---

## API Reference

### `POST /v1/chat/completions`

**Request**
```json
{
  "messages": [
    {"role": "user", "content": "Explain transformers in one sentence."}
  ],
  "max_tokens": 256
}
```

**Response**
```json
{
  "object": "chat.completion",
  "model": "gemma-3-1b-it-Q8_0.gguf",
  "choices": [
    {
      "index": 0,
      "message": {
        "role": "assistant",
        "content": "A transformer is a neural network architecture that processes sequences in parallel using self-attention, enabling efficient learning of long-range dependencies."
      },
      "finish_reason": "stop"
    }
  ]
}
```

**Curl example** — replace `ENGINE_PUBLIC_IP` with the value from `terraform output engine_public_ip`:
```bash
curl -X POST http://ENGINE_PUBLIC_IP:3111/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "messages": [{"role": "user", "content": "What is 2 + 2?"}],
    "max_tokens": 128
  }'
```

---

## Prerequisites

| Tool | Install |
|------|---------|
| Terraform ≥ 1.5 | [developer.hashicorp.com/terraform](https://developer.hashicorp.com/terraform/install) |
| AWS CLI v2 | [docs.aws.amazon.com/cli](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) |
| AWS account | [aws.amazon.com](https://aws.amazon.com/free/) |

---

## Deploy from scratch

### 1. Configure AWS credentials

```bash
aws configure
# Enter your Access Key ID, Secret Access Key, region (us-east-1), output (json)
```

### 2. Clone this repo

```bash
git clone https://github.com/YOUR_USER/YOUR_REPO.git
cd YOUR_REPO
```

### 3. Provision infrastructure

```bash
cd terraform

terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

Terraform will print:
- `engine_public_ip` — put this into your curl command
- `curl_example` — ready-to-run test command
- `ssm_session_commands` — how to shell into each VM

> **Cost note:** The stack uses t3.small (engine, caller) + t3.large (inference) + 1 NAT Gateway.
> Estimated cost with AWS free-tier credits: ~$3–5/day. Remember to `terraform destroy` when done.

### 4. Wait for startup scripts to finish (~5–10 min)

The VMs run their setup scripts on first boot. The inference VM takes longest because it downloads the GGUF model (~1 GB from HuggingFace).

Check progress with SSM Session Manager (no SSH key or bastion needed):
```bash
# Open a shell on the inference VM and tail logs
aws ssm start-session --target $(cd terraform && terraform output -raw inference_private_ip | xargs -I{} aws ec2 describe-instances --filters "Name=private-ip-address,Values={}" --query "Reservations[0].Instances[0].InstanceId" --output text) --region us-east-1

# Or just watch the startup log:
# Inside the SSM session:
sudo tail -f /var/log/iii-inference-setup.log
```

Simpler — after `terraform output ssm_session_commands`:
```bash
aws ssm start-session --target <INSTANCE_ID> --region us-east-1
# Then inside:
sudo journalctl -u iii-inference-worker -f
```

### 5. Test the API

```bash
ENGINE_IP=$(cd terraform && terraform output -raw engine_public_ip)

curl -X POST "http://$ENGINE_IP:3111/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"Hello, what can you do?"}],"max_tokens":128}'
```

### 6. Tear down

```bash
cd terraform
terraform destroy
```

---

## File structure

```
.
├── terraform/
│   ├── main.tf          # AWS provider + Ubuntu AMI data source
│   ├── variables.tf     # Region, CIDR ranges, instance types
│   ├── network.tf       # VPC, public/private subnets, IGW, NAT GW, security groups
│   ├── compute.tf       # Three EC2 instances + IAM role for SSM access
│   └── outputs.tf       # Public IP, curl example, SSM shell commands
│
├── scripts/
│   ├── setup-engine.sh             # user_data for engine-vm
│   ├── setup-inference-worker.sh   # user_data for inference-vm (engine IP injected)
│   └── setup-caller-worker.sh      # user_data for caller-vm (engine IP injected)
│
├── systemd/
│   ├── iii-engine.service
│   ├── iii-inference-worker.service
│   └── iii-caller-worker.service
│
├── workers/
│   ├── inference-worker/
│   │   ├── inference_worker.py   # Python — loads Gemma GGUF, exposes inference::run_inference
│   │   ├── requirements.txt
│   │   └── iii.worker.yaml
│   └── caller-worker/
│       ├── src/worker.ts         # TypeScript — HTTP bridge + cross-VM RPC
│       ├── package.json
│       ├── tsconfig.json
│       └── iii.worker.yaml
│
├── config.yaml    # iii engine config (built-in workers: iii-http, iii-state)
├── iii.lock       # Worker lockfile for reproducible installs
└── README.md
```

---

## What I would harden before production

### Network
- **TLS termination** — put an AWS Application Load Balancer (ALB) with ACM certificate in front of the engine-vm. The engine-vm would then only accept traffic from the ALB's security group, not from the internet directly, and port 3111 would be closed to the public.
- **Remove the wildcard CORS rule** in `config.yaml`. Restrict `origins` to the exact frontend domain.
- **VPC Flow Logs** — enable on the VPC to detect unexpected lateral movement or data exfiltration.
- **Security group tightening** — the worker SG currently allows all VPC traffic inbound. In production, restrict it to only the engine's security group as the source, not the entire VPC CIDR.

### Authentication & authorization
- **API key / JWT on the HTTP endpoint** — anyone who knows the IP can currently call the inference API. Add an authorization function in iii-http or an ALB rule that validates a bearer token.
- **iii worker RBAC** — the engine currently accepts WebSocket connections from any process that can reach port 49134 inside the VPC. Enable the `iii-worker-manager` RBAC config to require authenticated workers only.
- **Least-privilege IAM** — all three VMs currently share one IAM role. In production, inference-vm needs no AWS permissions at all; give it an empty role. Caller-vm and engine-vm should have only what they actually use (SSM + CloudWatch Logs).

### Secrets & config
- **AWS Secrets Manager** for the HuggingFace token and any API keys — never embed them in startup scripts.
- **Pin all dependency versions** with hashes in `requirements.txt` and `package-lock.json` to prevent supply-chain attacks.

### Operations
- **Health checks** — add a `GET /health` endpoint that returns 200 only when all three workers are connected to the engine. Wire it to an ALB health check and auto-restart unhealthy instances.
- **CloudWatch alarms** — alert on high CPU, memory pressure on inference-vm, and HTTP 5xx rates.
- **Structured JSON logging** → CloudWatch Logs via the CloudWatch agent, so logs are searchable and retained after VM replacement.

---

## What I'd do differently at 100× model scale

A 100× larger model (~100B parameters) changes the problem in three fundamental ways:

### Hardware changes
- **GPU instances are mandatory.** A 70B model in FP16 needs ~140 GB VRAM — two A100 80 GB GPUs minimum. In AWS, that's `p4d.24xlarge` (8× A100) or `p3.16xlarge` (8× V100). For cost efficiency, use `g5.12xlarge` (4× A10G, 96 GB total) with INT4/INT8 quantization.
- **Model storage** — 70 GB of weights cannot live on instance storage. Store on EFS (shared NFS) or S3 with an `s5cmd`-based downloader baked into the AMI to cut cold-start time from 10+ minutes to under 60 seconds.

### Inference server
- Swap the `transformers.generate()` call for a purpose-built inference server: **vLLM** (best throughput via PagedAttention), **TGI** (HuggingFace, easy deployment), or **TensorRT-LLM** (best raw GPU utilization on NVIDIA hardware). The iii inference-worker becomes a thin shim that forwards requests to the vLLM HTTP server on the same host.
- Enable **continuous batching** — at this scale, serving one request at a time wastes 90%+ of GPU capacity.

### Infrastructure changes
- **Auto Scaling Group** for the inference tier, scaling on GPU utilization or SQS queue depth (the iii-queue worker already provides the queue primitive — wire it up).
- **Spot instances** for batch workloads (up to 70% cost savings); on-demand reserved for latency-sensitive traffic.
- **Multi-AZ** for the engine and caller VMs — a single AZ failure should not take down the API.

---

*Submitted by Madhan — Alchemyst AI DevOps Internship, May 2026*
