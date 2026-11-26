# Both hosts share one instance role. It trusts ec2.amazonaws.com alone and
# carries only the managed policy Session Manager needs: no inline policy, no
# other principal, nothing that reaches the account beyond the host itself.
data "aws_partition" "current" {}

resource "aws_iam_role" "host" {
  name_prefix = "${var.name_prefix}-host-"
  description = "Telcoin Network hosts of ${var.name_prefix}: Session Manager only"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.host.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "host" {
  name_prefix = "${var.name_prefix}-host-"
  role        = aws_iam_role.host.name
}
