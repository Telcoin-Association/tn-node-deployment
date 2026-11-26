output "validator_public_ip" {
  description = "The validator's static public IPv4, which peers dial for P2P."
  value       = azurerm_public_ip.validator.ip_address
}

output "validator_private_ip" {
  description = "The validator's fixed private IPv4, the worker gateway's upstream."
  value       = local.validator_ip
}

output "gateway_public_ip" {
  description = "The worker gateway's static public IPv4, for the RPC name's A record. Null without a gateway."
  value       = var.gateway_enabled ? azurerm_public_ip.gateway[0].ip_address : null
}

output "gateway_private_ip" {
  description = "The worker gateway's fixed private IPv4, the only source the validator's RPC and health port admit. Null without a gateway."
  value       = var.gateway_enabled ? local.gateway_ip : null
}

output "gateway_created" {
  description = "Whether the gateway VM exists: true once rpc_domain is set (with gateway_enabled)."
  value       = local.gateway_vm
}

output "session_command" {
  description = "How to open a shell on each host: az network bastion ssh when Bastion is on, plain ssh otherwise."
  value       = local.session_commands
}

output "next_steps" {
  description = "The commands the operator runs on the validator host, in order, with this deployment's addresses."
  value       = module.plan.next_steps
}

output "tao_handoff" {
  description = "The DNS record the RPC name needs: an A record for name (null until rpc_domain is set) at the gateway's static IP."
  value       = module.plan.tao_handoff
}

output "validator_user_data_sha256" {
  description = "The SHA-256 of the validator's user data. Setting rpc_domain leaves it unchanged, so the second apply plans nothing for the validator."
  value       = sha256(module.plan.validator_user_data)
}
