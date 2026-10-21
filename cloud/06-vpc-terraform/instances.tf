data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

locals {
  instances = {
    web = { subnet = "public-a", sg = aws_security_group.web.id }
    app = { subnet = "private-a", sg = aws_security_group.app.id }
  }
}

resource "aws_instance" "this" {
  for_each = local.instances

  ami                    = data.aws_ssm_parameter.al2023.insecure_value
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.this[each.value.subnet].id
  vpc_security_group_ids = [each.value.sg]
  iam_instance_profile   = aws_iam_instance_profile.ssm.name
  user_data              = file("${path.module}/web.sh")

  metadata_options {
    http_tokens = "required"
  }

  tags = {
    Name = "lab06-${each.key}"
  }

  # A new AMI release shouldn't replace running instances
  lifecycle {
    ignore_changes = [ami]
  }

  # The SSM agent backs off if it boots before the NAT route exists
  depends_on = [aws_route.private_nat]
}
