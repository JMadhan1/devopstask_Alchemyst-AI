variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "Public subnet CIDR (engine-vm lives here)"
  type        = string
  default     = "10.0.0.0/24"
}

variable "private_subnet_cidr" {
  description = "Private subnet CIDR (inference-vm + caller-vm live here)"
  type        = string
  default     = "10.0.1.0/24"
}

variable "engine_instance_type" {
  description = "EC2 instance type for engine-vm"
  type        = string
  default     = "t3.small" # 2 vCPU, 2 GB RAM — enough for the engine only
}

variable "inference_instance_type" {
  description = "EC2 instance type for inference-vm (needs ~8 GB RAM for GGUF model)"
  type        = string
  default     = "t3.large" # 2 vCPU, 8 GB RAM
}

variable "caller_instance_type" {
  description = "EC2 instance type for caller-vm"
  type        = string
  default     = "t3.small" # 2 vCPU, 2 GB RAM
}
