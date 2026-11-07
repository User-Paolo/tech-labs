resource "aws_db_subnet_group" "main" {
  name       = "lab12"
  subnet_ids = local.private_subnet_ids
}

resource "aws_db_instance" "main" {
  #checkov:skip=CKV_AWS_157:Starts in one AZ on purpose, the variable turns Multi AZ on for the test
  #checkov:skip=CKV_AWS_293:The lab ends with a destroy, deletion protection would only get in the way
  #checkov:skip=CKV_AWS_161:The password in Secrets Manager is what I'm testing here
  #checkov:skip=CKV_AWS_118:Nobody reads enhanced monitoring in a lab this short
  #checkov:skip=CKV_AWS_353:Nobody reads Performance Insights in a lab this short
  #checkov:skip=CKV_AWS_129:Nothing reads the database logs in this lab
  #checkov:skip=CKV2_AWS_30:Nothing reads the query logs in this lab
  identifier     = "lab12-db"
  engine         = "postgres"
  engine_version = "17"
  instance_class = "db.t4g.micro"

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = "lab12"
  username = "labadmin"

  # RDS makes the password and keeps it in Secrets Manager, so Terraform never sees it
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false
  multi_az               = var.multi_az

  # The Free plan refuses 7 days and accepts 1
  backup_retention_period = 1
  copy_tags_to_snapshot   = true
  skip_final_snapshot     = true
  apply_immediately       = true

  auto_minor_version_upgrade = true
}

resource "aws_dynamodb_table" "notes" {
  #checkov:skip=CKV_AWS_119:My own KMS keys come in lab 14
  name         = "lab12-notes"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }
}
