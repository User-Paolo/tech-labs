data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "key" {
  #checkov:skip=CKV_AWS_109:This is the default key policy, the account root has to keep control of the key
  #checkov:skip=CKV_AWS_111:This is the default key policy, the account root has to keep control of the key
  #checkov:skip=CKV_AWS_356:In a key policy the resource is always the key itself
  statement {
    sid       = "AccountCanManageTheKey"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }
}

resource "aws_kms_key" "data" {
  description             = "lab14 bucket key"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  policy                  = data.aws_iam_policy_document.key.json
}

resource "aws_kms_alias" "data" {
  name          = "alias/lab14-data"
  target_key_id = aws_kms_key.data.key_id
}

resource "aws_s3_bucket" "data" {
  #checkov:skip=CKV_AWS_18:A test bucket for one lab, CloudTrail already records the calls I care about
  #checkov:skip=CKV_AWS_144:A test bucket for one lab doesn't need a copy in another region
  #checkov:skip=CKV2_AWS_62:Nothing reacts to new objects
  #checkov:skip=CKV_AWS_21:Three small test files, versions would add nothing
  #checkov:skip=CKV2_AWS_61:Destroyed at the end of the lab
  bucket_prefix = "lab14-data-"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "data" {
  bucket                  = aws_s3_bucket.data.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "data" {
  bucket = aws_s3_bucket.data.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.data.arn
    }

    # Off so every read goes to KMS and shows up in CloudTrail
    bucket_key_enabled = false
  }
}

data "aws_iam_policy_document" "trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = [data.aws_caller_identity.current.arn]
    }
  }
}

# Starts with no permissions, the lab adds them one at a time
resource "aws_iam_role" "tester" {
  name                  = "lab14-tester"
  assume_role_policy    = data.aws_iam_policy_document.trust.json
  max_session_duration  = 3600
  force_detach_policies = true
}

data "aws_iam_policy_document" "boundary" {
  statement {
    sid       = "ListOnly"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.data.arn]
  }
}

resource "aws_iam_policy" "boundary" {
  name   = "lab14-boundary"
  policy = data.aws_iam_policy_document.boundary.json
}
