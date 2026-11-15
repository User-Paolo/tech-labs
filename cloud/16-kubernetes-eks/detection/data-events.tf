# A bucket nobody has a reason to open, every read of it gets logged and emailed
resource "aws_s3_bucket" "decoy" {
  #checkov:skip=CKV_AWS_18:The data events trail already records every call I care about
  #checkov:skip=CKV_AWS_144:A decoy for one lab doesn't need a copy in another region
  #checkov:skip=CKV_AWS_145:The decoy file is fake, the default S3 encryption is enough
  #checkov:skip=CKV2_AWS_62:Nothing reacts to new objects
  #checkov:skip=CKV_AWS_21:One fake file, versions would add nothing
  #checkov:skip=CKV2_AWS_61:Destroyed at the end of the lab
  bucket_prefix = "lab16-backups-"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "decoy" {
  bucket                  = aws_s3_bucket.decoy.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_object" "decoy" {
  bucket  = aws_s3_bucket.decoy.id
  key     = "exports/customers.csv"
  content = "id,name,email\n1,Test Person,test@example.com\n2,Another Person,another@example.com\n"
}

resource "aws_s3_bucket" "trail" {
  #checkov:skip=CKV_AWS_18:These are the access logs themselves
  #checkov:skip=CKV_AWS_144:Logs from one lab don't need a copy in another region
  #checkov:skip=CKV_AWS_145:Logs from one lab don't need my own KMS key
  #checkov:skip=CKV2_AWS_62:Nothing reacts to new log files
  #checkov:skip=CKV_AWS_21:CloudTrail validation files already show if a log was changed
  #checkov:skip=CKV2_AWS_61:Destroyed at the end of the lab
  bucket_prefix = "lab16-data-trail-"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "trail" {
  bucket                  = aws_s3_bucket.trail.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

locals {
  data_trail_arn = "arn:aws:cloudtrail:us-east-1:${data.aws_caller_identity.current.account_id}:trail/lab16-data-events"
}

data "aws_iam_policy_document" "trail_bucket" {
  statement {
    sid       = "CheckBucket"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.trail.arn]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.data_trail_arn]
    }
  }

  statement {
    sid       = "WriteLogs"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.trail.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.data_trail_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }
}

resource "aws_s3_bucket_policy" "trail" {
  bucket = aws_s3_bucket.trail.id
  policy = data.aws_iam_policy_document.trail_bucket.json
}

# Only object calls in the decoy bucket, no management events, so it costs next to nothing
resource "aws_cloudtrail" "data" {
  #checkov:skip=CKV_AWS_35:Logs from one lab don't need my own KMS key
  #checkov:skip=CKV_AWS_67:The decoy bucket is in one region
  #checkov:skip=CKV_AWS_252:EventBridge already emails me, a second notice per log file adds nothing
  #checkov:skip=CKV2_AWS_10:EventBridge gets the events, CloudWatch Logs would only copy them
  name                          = "lab16-data-events"
  s3_bucket_name                = aws_s3_bucket.trail.id
  is_multi_region_trail         = false
  include_global_service_events = false
  enable_log_file_validation    = true

  advanced_event_selector {
    name = "Every object call in the decoy bucket"

    field_selector {
      field  = "eventCategory"
      equals = ["Data"]
    }

    field_selector {
      field  = "resources.type"
      equals = ["AWS::S3::Object"]
    }

    field_selector {
      field       = "resources.ARN"
      starts_with = ["${aws_s3_bucket.decoy.arn}/"]
    }
  }

  depends_on = [aws_s3_bucket_policy.trail]
}

resource "aws_cloudwatch_event_rule" "decoy_read" {
  name        = "lab16-decoy-read"
  description = "Someone downloaded a file from the decoy bucket"

  # Only downloads, Terraform's own checks of the file would email me on every plan
  event_pattern = jsonencode({
    source        = ["aws.s3"]
    "detail-type" = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource = ["s3.amazonaws.com"]
      eventName   = ["GetObject"]
      requestParameters = {
        bucketName = [aws_s3_bucket.decoy.id]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "decoy_email" {
  rule = aws_cloudwatch_event_rule.decoy_read.name
  arn  = data.aws_sns_topic.alerts.arn

  input_transformer {
    input_paths = {
      arn   = "$.detail.userIdentity.arn"
      event = "$.detail.eventName"
      key   = "$.detail.requestParameters.key"
      time  = "$.detail.eventTime"
      ip    = "$.detail.sourceIPAddress"
    }
    input_template = <<-EOT
      "Someone downloaded a file from the decoy bucket"
      "Who: <arn>"
      "What: <event> on <key>"
      "When: <time>"
      "Source IP: <ip>"
    EOT
  }
}
