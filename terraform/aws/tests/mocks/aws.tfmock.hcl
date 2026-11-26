# Fixed values for what the AWS API would return, shared by every test file.
# Each file's mock_provider sets override_during = plan, so these are known
# while planning and the assertions can read them.

mock_data "aws_partition" {
  defaults = {
    partition = "aws"
  }
}

mock_data "aws_ssm_parameter" {
  defaults = {
    insecure_value = "ami-0123456789abcdef0"
  }
}

# An image registered for NitroTPM; the TPM refusals override it.
mock_data "aws_ami" {
  defaults = {
    tpm_support = "v2.0"
  }
}

mock_data "aws_ec2_instance_type" {
  defaults = {
    default_cores           = 8
    memory_size             = 65536
    supported_architectures = ["x86_64"]
    ebs_nvme_support        = "required"
    nitro_tpm_support       = "supported"
  }
}

# us-east-1a offers every type the tests use; us-east-1b only the gateway's.
mock_data "aws_ec2_instance_type_offerings" {
  defaults = {
    locations      = ["us-east-1b", "us-east-1a", "us-east-1a", "us-east-1a"]
    instance_types = ["m7i.large", "m7i.large", "m7i.2xlarge", "m7i.4xlarge"]
  }
}

mock_resource "aws_ebs_volume" {
  defaults = {
    id = "vol-0123456789abcdef0"
  }
}

override_resource {
  target = aws_eip.validator
  values = {
    public_ip     = "203.0.113.10"
    allocation_id = "eipalloc-0validator"
  }
}

override_resource {
  target = aws_eip.gateway
  values = {
    public_ip     = "203.0.113.20"
    allocation_id = "eipalloc-0gateway"
  }
}

override_resource {
  target = aws_instance.validator
  values = {
    id = "i-0a1b2c3d4e5f60001"
  }
}

override_resource {
  target = aws_instance.gateway
  values = {
    id = "i-0a1b2c3d4e5f60002"
  }
}

override_resource {
  target = aws_security_group.validator
  values = {
    id = "sg-0validator"
  }
}

override_resource {
  target = aws_security_group.gateway
  values = {
    id = "sg-0gateway"
  }
}

override_resource {
  target = aws_network_interface.validator
  values = {
    id = "eni-0validator"
  }
}

override_resource {
  target = aws_network_interface.gateway
  values = {
    id = "eni-0gateway"
  }
}

override_resource {
  target = aws_iam_role.host
  values = {
    name = "telcoin-host-20261126000000000000000001"
  }
}

override_resource {
  target = aws_iam_instance_profile.host
  values = {
    name = "telcoin-host-20261126000000000000000002"
  }
}
