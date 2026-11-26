# The user data must fit AWS's 16384 bytes once a root gzips it. These bounds
# hold the first-boot scripts in terraform/first-boot/ to a margin under it.

variables {
  role_set             = { validator = true, gateway = true }
  network              = "mainnet"
  cloud                = "aws"
  login_user           = "ubuntu"
  validator_public_ip  = "203.0.113.10"
  validator_private_ip = "10.42.1.10"
  gateway_public_ip    = "203.0.113.20"
  gateway_private_ip   = "10.42.1.20"
  vpc_cidr             = "10.42.0.0/16"
  admin_ssh_cidrs      = ["198.51.100.7/32", "198.51.100.8/32"]
  rpc_domain           = "rpc.example.org"
  data_device          = "/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_vol0123456789abcdef0"
  session_commands = {
    validator = "aws ssm start-session --target i-0validator"
    gateway   = "aws ssm start-session --target i-0gateway"
  }
}

run "gateway" {
  command = plan

  assert {
    condition     = output.gateway_user_data_gzip_bytes > 0 && output.gateway_user_data_gzip_bytes < 14000
    error_message = "The gateway's gzipped user data is ${output.gateway_user_data_gzip_bytes} bytes; it must stay under 14000."
  }

  assert {
    condition     = output.gateway_user_data_gzip_bytes == floor(length(base64gzip(output.gateway_user_data)) * 3 / 4)
    error_message = "gateway_user_data_gzip_bytes must be the gzipped size of gateway_user_data."
  }
}

run "validator_no_hubs" {
  command = plan

  variables {
    trusted_nodes_content = ""
  }

  assert {
    condition     = output.validator_user_data_gzip_bytes > 0 && output.validator_user_data_gzip_bytes < 12000
    error_message = "The validator's gzipped user data with no hubs file is ${output.validator_user_data_gzip_bytes} bytes; it must stay under 12000."
  }
}

# 4096 characters of letters and digits from hashes, which gzip cannot shrink
# much: harder on the limit than a real hubs map of the same size.
run "validator_4k_hubs" {
  command = plan

  variables {
    trusted_nodes_content = substr(join("", [for i in range(100) : replace(replace(replace(base64sha256("hub-${i}"), "+", "x"), "/", "y"), "=", "")]), 0, 4096)
  }

  assert {
    condition     = length(var.trusted_nodes_content) == 4096
    error_message = "The hubs text must be 4096 characters."
  }

  assert {
    condition     = output.validator_user_data_gzip_bytes < 16384
    error_message = "The validator's gzipped user data with a 4 KiB hubs file is ${output.validator_user_data_gzip_bytes} bytes, over AWS's 16384."
  }
}
