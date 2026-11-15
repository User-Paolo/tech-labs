data "aws_caller_identity" "current" {}

# Made by lab 02's setup.sh, it emails me
data "aws_sns_topic" "alerts" {
  name = "security-alerts"
}

locals {
  quarantine_policy = "arn:aws:iam::aws:policy/AWSCompromisedKeyQuarantineV3"
  canary_users      = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/canary/*"
}

# Read only calls too, the lab 02 rules only ever get write calls
resource "aws_cloudwatch_event_rule" "canary_used" {
  name        = "lab16-canary-used"
  description = "Any call made with the canary user's key"
  state       = "ENABLED_WITH_ALL_CLOUDTRAIL_MANAGEMENT_EVENTS"

  event_pattern = jsonencode({
    "detail-type" = ["AWS API Call via CloudTrail"]
    detail = {
      userIdentity = {
        userName = [aws_iam_user.canary.name]
      }
    }
  })
}

# One quoted line per email line, like lab 02
resource "aws_cloudwatch_event_target" "email" {
  rule = aws_cloudwatch_event_rule.canary_used.name
  arn  = data.aws_sns_topic.alerts.arn

  input_transformer {
    input_paths = {
      user   = "$.detail.userIdentity.userName"
      event  = "$.detail.eventName"
      region = "$.detail.awsRegion"
      time   = "$.detail.eventTime"
      ip     = "$.detail.sourceIPAddress"
      agent  = "$.detail.userAgent"
    }
    input_template = <<-EOT
      "Canary key used, the quarantine function is locking it now"
      "Who: <user>"
      "What: <event> in <region>"
      "When: <time>"
      "Source IP: <ip>"
      "Tool: <agent>"
    EOT
  }
}

resource "aws_cloudwatch_event_target" "quarantine" {
  rule = aws_cloudwatch_event_rule.canary_used.name
  arn  = aws_lambda_function.quarantine.arn
}

resource "aws_lambda_permission" "events" {
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.quarantine.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.canary_used.arn
}

resource "aws_cloudwatch_log_group" "quarantine" {
  #checkov:skip=CKV_AWS_158:Logs from a short lab don't need my own KMS key
  #checkov:skip=CKV_AWS_338:Logs from a short lab don't need a year of retention
  name              = "/aws/lambda/lab16-quarantine"
  retention_in_days = 7
}

data "aws_iam_policy_document" "lambda_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "quarantine" {
  name               = "lab16-quarantine"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

# It can only touch users under /canary/, and only attach the quarantine policy
data "aws_iam_policy_document" "quarantine" {
  statement {
    sid       = "LockCanaryUsers"
    actions   = ["iam:ListAccessKeys", "iam:UpdateAccessKey", "iam:ListAttachedUserPolicies", "iam:PutUserPolicy"]
    resources = [local.canary_users]
  }

  statement {
    sid       = "AttachOnlyTheQuarantinePolicy"
    actions   = ["iam:AttachUserPolicy"]
    resources = [local.canary_users]

    condition {
      test     = "ArnEquals"
      variable = "iam:PolicyARN"
      values   = [local.quarantine_policy]
    }
  }

  statement {
    sid       = "EmailMe"
    actions   = ["sns:Publish"]
    resources = [data.aws_sns_topic.alerts.arn]
  }

  statement {
    sid       = "WriteLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.quarantine.arn}:*"]
  }
}

resource "aws_iam_role_policy" "quarantine" {
  name   = "lab16-quarantine"
  role   = aws_iam_role.quarantine.id
  policy = data.aws_iam_policy_document.quarantine.json
}

data "archive_file" "quarantine" {
  type        = "zip"
  source_file = "${path.module}/lambda/quarantine.py"
  output_path = "/tmp/lab16-quarantine.zip"
}

resource "aws_lambda_function" "quarantine" {
  #checkov:skip=CKV_AWS_50:CloudWatch logs are enough for one small function
  #checkov:skip=CKV_AWS_115:The Free plan only allows 10 at once, reserving some would lower that for everything else
  #checkov:skip=CKV_AWS_116:EventBridge retries it, and a failed run still leaves the email from the rule
  #checkov:skip=CKV_AWS_117:It only talks to AWS APIs, a VPC would mean paying for a NAT gateway
  #checkov:skip=CKV_AWS_173:The only variable is the topic ARN
  #checkov:skip=CKV_AWS_272:Nobody else deploys to this function
  function_name    = "lab16-quarantine"
  role             = aws_iam_role.quarantine.arn
  handler          = "quarantine.handler"
  runtime          = "python3.13"
  architectures    = ["arm64"]
  memory_size      = 128
  timeout          = 30
  filename         = data.archive_file.quarantine.output_path
  source_code_hash = data.archive_file.quarantine.output_base64sha256

  environment {
    variables = {
      TOPIC_ARN = data.aws_sns_topic.alerts.arn
    }
  }

  depends_on = [aws_cloudwatch_log_group.quarantine, aws_iam_role_policy.quarantine]
}
