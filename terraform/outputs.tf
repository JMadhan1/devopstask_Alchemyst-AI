output "api_endpoint" {
  description = "Public HTTP API endpoint for inference"
  value       = "http://${aws_instance.engine.public_ip}:3111"
}

output "engine_public_ip" {
  description = "Public IP of the engine VM (API gateway)"
  value       = aws_instance.engine.public_ip
}

output "engine_private_ip" {
  description = "Private IP of the engine VM (used by workers for WebSocket)"
  value       = aws_instance.engine.private_ip
}

output "inference_private_ip" {
  description = "Private IP of the inference worker VM"
  value       = aws_instance.inference.private_ip
}

output "caller_private_ip" {
  description = "Private IP of the caller worker VM"
  value       = aws_instance.caller.private_ip
}

output "curl_example" {
  description = "Example curl command to call the inference API"
  value = <<-EOT
    curl -X POST http://${aws_instance.engine.public_ip}:3111/v1/chat/completions \
      -H 'Content-Type: application/json' \
      -d '{
        "messages": [
          {"role": "user", "content": "What is 2 + 2?"}
        ],
        "max_tokens": 128
      }'
  EOT
}

output "ssm_session_commands" {
  description = "AWS SSM Session Manager commands to access each VM (no SSH key needed)"
  value = <<-EOT
    # Engine VM:
    aws ssm start-session --target ${aws_instance.engine.id} --region ${var.region}

    # Inference VM (private — SSM only):
    aws ssm start-session --target ${aws_instance.inference.id} --region ${var.region}

    # Caller VM (private — SSM only):
    aws ssm start-session --target ${aws_instance.caller.id} --region ${var.region}
  EOT
}

output "check_logs" {
  description = "Commands to tail service logs on each VM (run inside SSM session)"
  value = <<-EOT
    # On engine-vm:
    sudo journalctl -u iii-engine -f

    # On inference-vm:
    sudo journalctl -u iii-inference-worker -f

    # On caller-vm:
    sudo journalctl -u iii-caller-worker -f
  EOT
}
