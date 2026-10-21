resource "aws_security_group" "web" {
  #checkov:skip=CKV2_AWS_5:Attached to the web instance through local.instances
  name        = "lab06-web"
  description = "web, port 80 from my IP"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "lab06-web"
  }
}

resource "aws_security_group" "app" {
  #checkov:skip=CKV2_AWS_5:Attached to the app instance through local.instances
  name        = "lab06-app"
  description = "app, port 80 from the web SG only"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "lab06-app"
  }
}

# No rules at all, so nothing can use the default group by accident
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "lab06-default-locked"
  }
}

resource "aws_vpc_security_group_ingress_rule" "web_http" {
  security_group_id = aws_security_group.web.id
  description       = "http from my IP"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "${var.my_ip}/32"
}

resource "aws_vpc_security_group_ingress_rule" "app_http" {
  #checkov:skip=CKV_AWS_260:The source is the web security group, not 0.0.0.0/0
  security_group_id            = aws_security_group.app.id
  description                  = "http from the web SG"
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
  referenced_security_group_id = aws_security_group.web.id
}

# Terraform removes the default allow all egress rule, so it has to be written out
resource "aws_vpc_security_group_egress_rule" "all_out" {
  for_each = {
    web = aws_security_group.web.id
    app = aws_security_group.app.id
  }

  security_group_id = each.value
  description       = "everything out, same as the AWS default"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

data "aws_iam_policy_document" "ec2_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ssm" {
  name               = "lab06-ssm"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ssm" {
  name = "lab06-ssm"
  role = aws_iam_role.ssm.name
}
