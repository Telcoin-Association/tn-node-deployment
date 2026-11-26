output "validator_public_ip" {
  description = "The validator's static public IPv4, which peers dial for P2P."
  value       = google_compute_address.validator_public.address
}

output "validator_private_ip" {
  description = "The validator's fixed private IPv4, the worker gateway's upstream."
  value       = google_compute_address.validator_internal.address
}

output "gateway_public_ip" {
  description = "The worker gateway's static public IPv4, where the RPC name's A record points. Null without a gateway."
  value       = var.gateway_enabled ? google_compute_address.gateway_public[0].address : null
}

output "gateway_private_ip" {
  description = "The worker gateway's fixed private IPv4, the only source the validator's RPC and health port admit. Null without a gateway."
  value       = var.gateway_enabled ? google_compute_address.gateway_internal[0].address : null
}

output "gateway_created" {
  description = "Whether the worker-gateway host exists: it is created by the apply that sets rpc_domain."
  value       = local.gateway_vm
}

output "session_command" {
  description = "The command that opens a shell on each host (OS Login, through IAP when enable_iap is on). gateway is null until the gateway host exists."
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
  description = "The DNS record the RPC name needs: an A record for rpc_domain at gateway_public_ip."
  value       = module.host_plan.tao_handoff
}
