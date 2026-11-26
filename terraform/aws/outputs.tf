output "validator_public_ip" {
  description = "The validator's static public IPv4 (an Elastic IP), which peers dial for P2P."
  value       = aws_eip.validator.public_ip
}

output "validator_private_ip" {
  description = "The validator's fixed private IPv4, the worker gateway's upstream."
  value       = local.validator_private_ip
}

output "gateway_public_ip" {
  description = "The worker gateway's static public IPv4 (an Elastic IP), where the RPC name's A record points. Null with gateway_enabled = false."
  value       = var.gateway_enabled ? aws_eip.gateway[0].public_ip : null
}

output "gateway_private_ip" {
  description = "The worker gateway's fixed private IPv4, the only source the validator's RPC and health port admit. Null with gateway_enabled = false."
  value       = var.gateway_enabled ? local.gateway_private_ip : null
}

output "gateway_created" {
  description = "Whether the worker-gateway host exists: true once rpc_domain is set (with gateway_enabled)."
  value       = local.gateway_vm
}

output "session_command" {
  description = "The command that opens a shell on each host through Session Manager (it needs the AWS CLI and its Session Manager plugin). gateway is null until the gateway host exists."
  value = {
    validator = local.session_commands.validator
    gateway   = local.gateway_vm ? local.session_commands.gateway : null
  }
}

output "next_steps" {
  description = "The commands to run on the validator host, in order, with this deployment's addresses."
  value       = module.host_plan.next_steps
}

output "tao_handoff" {
  description = "The DNS record the RPC name needs: an A record for rpc_domain at gateway_public_ip. Its name is null until rpc_domain is set."
  value       = module.host_plan.tao_handoff
}

# The apply that sets rpc_domain must leave this unchanged: the validator's
# first-boot input never depends on it.
output "validator_user_data_sha256" {
  description = "The SHA-256 of the validator's first-boot cloud-config. Setting rpc_domain leaves it unchanged, so the second apply plans no change to the validator."
  value       = sha256(module.host_plan.validator_user_data)
}
