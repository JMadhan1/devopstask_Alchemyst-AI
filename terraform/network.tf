# ── VPC ──────────────────────────────────────────────────────────────────────

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = { Name = "iii-vpc" }
}

# ── Subnets ───────────────────────────────────────────────────────────────────

# Public subnet — engine-vm gets a public IP here (API gateway).
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = "${var.region}a"
  map_public_ip_on_launch = true

  tags = { Name = "iii-public-subnet" }
}

# Private subnet — inference-vm and caller-vm, no public IPs.
resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidr
  availability_zone = "${var.region}a"

  tags = { Name = "iii-private-subnet" }
}

# ── Internet Gateway (public subnet egress) ────────────────────────────────

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "iii-igw" }
}

# ── Elastic IP + NAT Gateway (private subnet egress for package installs) ──

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "iii-nat-eip" }
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id # NAT GW must be in the PUBLIC subnet
  tags          = { Name = "iii-nat-gw" }

  depends_on = [aws_internet_gateway.igw]
}

# ── Route Tables ───────────────────────────────────────────────────────────

# Public route table — default route via IGW
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = { Name = "iii-public-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Private route table — default route via NAT GW
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }

  tags = { Name = "iii-private-rt" }
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

# ── Security Groups ────────────────────────────────────────────────────────

# Engine VM security group — allows public HTTP API + internal traffic
resource "aws_security_group" "engine" {
  name        = "iii-engine-sg"
  description = "Engine VM: public API port + internal RPC + SSM"
  vpc_id      = aws_vpc.main.id

  # Public API access on port 3111 (iii-http)
  ingress {
    description = "Public inference API"
    from_port   = 3111
    to_port     = 3111
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow workers in the private subnet to connect via WebSocket
  ingress {
    description = "Worker WebSocket connections from private subnet"
    from_port   = 49134
    to_port     = 49134
    protocol    = "tcp"
    cidr_blocks = [var.private_subnet_cidr]
  }

  # Internal ICMP (ping) for debugging
  ingress {
    description = "Internal ICMP"
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = [var.vpc_cidr]
  }

  # All outbound allowed (needed for iii engine to reach workers + internet)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "iii-engine-sg" }
}

# Worker VMs security group — NO public inbound, only VPC-internal
resource "aws_security_group" "worker" {
  name        = "iii-worker-sg"
  description = "Worker VMs: inbound from VPC only, no public internet access"
  vpc_id      = aws_vpc.main.id

  # Accept connections only from within the VPC (engine → worker callbacks, SSM VPC endpoint)
  ingress {
    description = "VPC-internal traffic only"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  # Outbound allowed (NAT GW provides internet access for pip/npm installs)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "iii-worker-sg" }
}
