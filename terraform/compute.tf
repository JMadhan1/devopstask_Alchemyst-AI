# ── IAM Role for SSM Session Manager ─────────────────────────────────────────
# Lets us SSH into private VMs without opening port 22 or a bastion host.

resource "aws_iam_role" "ssm_role" {
  name = "iii-ssm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_policy" {
  role       = aws_iam_role.ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ssm_profile" {
  name = "iii-ssm-profile"
  role = aws_iam_role.ssm_role.name
}

# ── engine-vm ─────────────────────────────────────────────────────────────────
# Public subnet, has a public IP.
# Runs: iii engine (WebSocket :49134) + iii-http (:3111) + iii-state

resource "aws_instance" "engine" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.engine_instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.engine.id]
  iam_instance_profile   = aws_iam_instance_profile.ssm_profile.name

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  user_data = file("${path.module}/../scripts/setup-engine.sh")

  tags = { Name = "engine-vm", Role = "engine" }
}

# ── inference-vm ──────────────────────────────────────────────────────────────
# Private subnet, NO public IP.
# Runs: Python inference worker (connects to engine via WebSocket)

resource "aws_instance" "inference" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.inference_instance_type
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.worker.id]
  iam_instance_profile   = aws_iam_instance_profile.ssm_profile.name

  root_block_device {
    volume_size = 30   # Extra space for GGUF model weights
    volume_type = "gp3"
  }

  user_data = templatefile("${path.module}/../scripts/setup-inference-worker.sh", {
    engine_internal_ip = aws_instance.engine.private_ip
  })

  tags = { Name = "inference-vm", Role = "worker" }

  depends_on = [aws_nat_gateway.nat]
}

# ── caller-vm ─────────────────────────────────────────────────────────────────
# Private subnet, NO public IP.
# Runs: TypeScript caller worker (HTTP bridge + cross-VM RPC)

resource "aws_instance" "caller" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.caller_instance_type
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.worker.id]
  iam_instance_profile   = aws_iam_instance_profile.ssm_profile.name

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  user_data = templatefile("${path.module}/../scripts/setup-caller-worker.sh", {
    engine_internal_ip = aws_instance.engine.private_ip
  })

  tags = { Name = "caller-vm", Role = "worker" }

  depends_on = [aws_nat_gateway.nat]
}
