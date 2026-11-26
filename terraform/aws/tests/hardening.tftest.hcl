# Storage, metadata service and identity: the settings that keep the node's
# keys and the account safe whatever else the operator changes.

mock_provider "aws" {
  source          = "./tests/mocks"
  override_during = plan
}

variables {
  region     = "us-east-1"
  rpc_domain = "rpc.example.org"
}

run "testnet_storage" {
  command = plan

  assert {
    condition     = aws_ebs_volume.data.encrypted && aws_ebs_volume.data.type == "gp3"
    error_message = "The data volume must be encrypted gp3."
  }

  assert {
    condition     = aws_ebs_volume.data.size == 500 && aws_ebs_volume.data.iops == 15000 && aws_ebs_volume.data.throughput == 300
    error_message = "The testnet data volume defaults to 500 GiB, 15000 IOPS and 300 MiB/s."
  }

  assert {
    condition     = aws_ebs_volume.data.size >= 350 && aws_ebs_volume.data.iops >= 15000 && aws_ebs_volume.data.throughput >= 240
    error_message = "The testnet data volume must meet the floor: 350 GiB, 15000 IOPS, 240 MiB/s."
  }

  assert {
    condition     = aws_volume_attachment.data.volume_id == aws_ebs_volume.data.id && aws_volume_attachment.data.instance_id == aws_instance.validator.id && aws_volume_attachment.data.stop_instance_before_detaching
    error_message = "The data volume must attach to the validator, which is stopped before any detach."
  }

  assert {
    condition     = aws_instance.validator.root_block_device[0].encrypted && aws_instance.gateway[0].root_block_device[0].encrypted
    error_message = "Both root volumes must be encrypted."
  }
}

run "mainnet_storage" {
  command = plan

  variables {
    network = "mainnet"
  }

  assert {
    condition     = aws_ebs_volume.data.encrypted && aws_ebs_volume.data.size == 2000 && aws_ebs_volume.data.iops == 20000 && aws_ebs_volume.data.throughput == 300
    error_message = "The mainnet data volume defaults to an encrypted 2000 GiB, 20000 IOPS and 300 MiB/s, the floor."
  }
}

run "own_kms_key" {
  command = plan

  variables {
    kms_key_id = "arn:aws:kms:us-east-1:111122223333:key/1234abcd-12ab-34cd-56ef-1234567890ab"
  }

  assert {
    condition = alltrue([for k in [
      aws_ebs_volume.data.kms_key_id,
      aws_instance.validator.root_block_device[0].kms_key_id,
      aws_instance.gateway[0].root_block_device[0].kms_key_id,
    ] : k == var.kms_key_id])
    error_message = "kms_key_id must encrypt the data volume and both root volumes."
  }
}

run "metadata_and_identity" {
  command = plan

  assert {
    condition = alltrue([for m in [aws_instance.validator.metadata_options[0], aws_instance.gateway[0].metadata_options[0]] :
    m.http_tokens == "required" && m.http_endpoint == "enabled" && m.http_put_response_hop_limit == 1])
    error_message = "Both hosts must require IMDSv2 tokens, with a hop limit of 1 so no container reaches the metadata service."
  }

  assert {
    condition     = aws_iam_role_policy_attachment.ssm.policy_arn == "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" && aws_iam_role_policy_attachment.ssm.role == aws_iam_role.host.name
    error_message = "The host role must carry AmazonSSMManagedInstanceCore."
  }

  assert {
    condition     = jsonencode(jsondecode(aws_iam_role.host.assume_role_policy).Statement) == jsonencode([{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" } }])
    error_message = "The host role must trust ec2.amazonaws.com and nothing else."
  }

  assert {
    condition     = aws_instance.validator.iam_instance_profile == aws_iam_instance_profile.host.name && aws_instance.gateway[0].iam_instance_profile == aws_iam_instance_profile.host.name && aws_iam_instance_profile.host.role == aws_iam_role.host.name
    error_message = "Both hosts must run with the Session Manager role's profile."
  }

  assert {
    condition     = aws_instance.validator.user_data_replace_on_change != true
    error_message = "A change to the validator's user data must never replace it."
  }
}

run "pinned_image" {
  command = plan

  variables {
    ami_id = "ami-0fedcba9876543210"
  }

  assert {
    condition     = aws_instance.validator.ami == "ami-0fedcba9876543210" && aws_instance.gateway[0].ami == "ami-0fedcba9876543210" && length(data.aws_ssm_parameter.ubuntu) == 0
    error_message = "ami_id must replace Canonical's parameter on both hosts."
  }
}

run "canonical_image" {
  command = plan

  variables {
    ubuntu_version = "24.04"
  }

  assert {
    condition     = data.aws_ssm_parameter.ubuntu[0].name == "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id" && aws_instance.validator.ami == "ami-0123456789abcdef0"
    error_message = "Without ami_id both hosts boot Canonical's current image of ubuntu_version."
  }
}
