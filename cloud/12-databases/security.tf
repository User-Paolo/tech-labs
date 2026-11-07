resource "aws_security_group" "client" {
  name        = "lab12-client"
  description = "test instance, only talks to the database and to AWS over 443"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "lab12-client"
  }
}

resource "aws_security_group" "db" {
  name        = "lab12-db"
  description = "database, port 5432 from the test instance only"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "lab12-db"
  }
}

resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "lab12-default-locked"
  }
}

resource "aws_vpc_security_group_egress_rule" "client_to_db" {
  security_group_id            = aws_security_group.client.id
  description                  = "postgres to the database"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.db.id
}

resource "aws_vpc_security_group_egress_rule" "client_https" {
  security_group_id = aws_security_group.client.id
  description       = "https out for Session Manager, packages and the AWS APIs"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "db_from_client" {
  security_group_id            = aws_security_group.db.id
  description                  = "postgres from the test instance"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.client.id
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

resource "aws_iam_role" "client" {
  name               = "lab12-client"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.client.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "client" {
  statement {
    sid       = "ReadDbSecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_db_instance.main.master_user_secret[0].secret_arn]
  }

  statement {
    sid = "UseNotesTable"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:Scan",
    ]
    resources = [aws_dynamodb_table.notes.arn]
  }
}

resource "aws_iam_role_policy" "client" {
  name   = "lab12-client"
  role   = aws_iam_role.client.id
  policy = data.aws_iam_policy_document.client.json
}

resource "aws_iam_instance_profile" "client" {
  name = "lab12-client"
  role = aws_iam_role.client.name
}
