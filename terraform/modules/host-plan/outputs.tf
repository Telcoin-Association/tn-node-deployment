output "validator_env" {
  description = "The validator's /etc/telcoin-first-boot/first-boot.env: KEY='value' lines."
  value       = local.validator_env

  precondition {
    condition     = alltrue([for kv in local.validator_env_pairs : can(regex(local.re.env, kv[1]))])
    error_message = "A validator env value holds a character outside letters, digits and . _ : / , @ -."
  }
}

output "gateway_env" {
  description = "The worker gateway's /etc/telcoin-first-boot/first-boot.env, or empty while the deployment has no gateway host (no gateway, or no rpc_domain yet)."
  value       = local.gateway_vm ? local.gateway_env : ""

  precondition {
    condition     = !local.gateway_vm || alltrue([for kv in local.gateway_env_pairs : can(regex(local.re.env, kv[1]))])
    error_message = "A worker gateway env value holds a character outside letters, digits and . _ : / , @ -."
  }
}

output "validator_user_data" {
  description = "The validator's #cloud-config: the first-boot scripts, its env file and, when given, the hubs file. Independent of rpc_domain."
  value       = local.validator_user_data
}

output "gateway_user_data" {
  description = "The worker gateway's #cloud-config, or empty while the deployment has no gateway host."
  value       = local.gateway_vm ? local.gateway_user_data : ""
}

# What a root that sends base64gzip(user data) counts against its cloud's
# limit (AWS: 16384 bytes): the decoded size, rounded up by the padding.
output "validator_user_data_gzip_bytes" {
  description = "The size of the validator's user data once gzipped, in bytes."
  value       = floor(length(base64gzip(local.validator_user_data)) * 3 / 4)
}

output "gateway_user_data_gzip_bytes" {
  description = "The size of the worker gateway's user data once gzipped, in bytes; 0 while it has none."
  value       = local.gateway_vm ? floor(length(base64gzip(local.gateway_user_data)) * 3 / 4) : 0
}

output "next_steps" {
  description = "The commands the operator runs on the validator host, in order, with this deployment's addresses."
  value       = local.next_steps
}

output "tao_handoff" {
  description = "The DNS record the RPC name needs: an A record for name (null until rpc_domain is set) at the gateway's static IP."
  value = {
    record = "A"
    name   = var.rpc_domain != "" ? var.rpc_domain : null
    ipv4   = var.role_set.gateway && var.gateway_public_ip != "" ? var.gateway_public_ip : null
    note   = local.tao_handoff_note
  }
}
