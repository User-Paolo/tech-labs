resource "aws_db_subnet_group" "main" {
  name       = "lab16"
  subnet_ids = aws_subnet.private[*].id
}

# Nodes and pods use the cluster security group, so only they get in
resource "aws_security_group" "db" {
  name        = "lab16-db"
  description = "PostgreSQL from the EKS nodes and pods only"
  vpc_id      = aws_vpc.main.id
}

resource "aws_vpc_security_group_ingress_rule" "db_from_cluster" {
  security_group_id            = aws_security_group.db.id
  description                  = "PostgreSQL from the cluster"
  referenced_security_group_id = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

# TLS only, and log every connection for the detection part
resource "aws_db_parameter_group" "main" {
  name   = "lab16-postgres17"
  family = "postgres17"

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  parameter {
    name  = "log_connections"
    value = "1"
  }

  parameter {
    name  = "log_statement"
    value = "ddl"
  }

  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
  }
}

# Made before the database, or RDS makes it itself with no expiry
resource "aws_cloudwatch_log_group" "db" {
  #checkov:skip=CKV_AWS_158:Logs from a one week lab don't need my own KMS key
  #checkov:skip=CKV_AWS_338:Logs from a one week lab don't need a year of retention
  name              = "/aws/rds/instance/lab16/postgresql"
  retention_in_days = 7
}

resource "aws_db_instance" "main" {
  #checkov:skip=CKV_AWS_161:The app logs in with the password from Secrets Manager
  #checkov:skip=CKV_AWS_118:Enhanced monitoring isn't needed for a one week lab
  #checkov:skip=CKV_AWS_353:Performance Insights isn't needed for a one week lab
  #checkov:skip=CKV_AWS_354:Performance Insights isn't needed for a one week lab
  #checkov:skip=CKV_AWS_293:Teardown has to be able to delete it
  identifier                    = "lab16"
  engine                        = "postgres"
  engine_version                = "17"
  instance_class                = "db.t4g.micro"
  allocated_storage             = 20
  storage_type                  = "gp3"
  storage_encrypted             = true
  kms_key_id                    = aws_kms_key.main.arn
  multi_az                      = true
  db_name                       = "lab16"
  username                      = "labadmin"
  manage_master_user_password   = true
  master_user_secret_kms_key_id = aws_kms_key.main.key_id
  db_subnet_group_name          = aws_db_subnet_group.main.name
  vpc_security_group_ids        = [aws_security_group.db.id]
  parameter_group_name          = aws_db_parameter_group.main.name
  publicly_accessible           = false
  # The Free plan refused 7 days in lab 12 and accepted 1
  backup_retention_period         = 1
  copy_tags_to_snapshot           = true
  auto_minor_version_upgrade      = true
  enabled_cloudwatch_logs_exports = ["postgresql"]
  skip_final_snapshot             = true
  apply_immediately               = true

  depends_on = [aws_cloudwatch_log_group.db]
}

# The app's own role, it can read the database secret and nothing else
resource "aws_iam_role" "app" {
  name               = "lab16-app"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}

data "aws_iam_policy_document" "app" {
  statement {
    sid       = "ReadTheDatabaseSecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_db_instance.main.master_user_secret[0].secret_arn]
  }

  statement {
    sid       = "DecryptOnlyThroughSecretsManager"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.main.arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.us-east-1.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "app" {
  name   = "read-db-secret"
  role   = aws_iam_role.app.id
  policy = data.aws_iam_policy_document.app.json
}

resource "aws_eks_pod_identity_association" "app" {
  cluster_name    = aws_eks_cluster.main.name
  namespace       = "lab16"
  service_account = "web"
  role_arn        = aws_iam_role.app.arn
}
