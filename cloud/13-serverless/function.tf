resource "aws_dynamodb_table" "visits" {
  #checkov:skip=CKV_AWS_119:My own KMS keys come in lab 14
  #checkov:skip=CKV_AWS_28:It's a visit counter in a lab, nothing to recover
  name         = "lab13-visits"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }

  server_side_encryption {
    enabled = true
  }
}

resource "aws_cloudwatch_log_group" "function" {
  #checkov:skip=CKV_AWS_158:Logs from a short lab don't need my own KMS key
  #checkov:skip=CKV_AWS_338:Logs from a short lab don't need a year of retention
  name              = "/aws/lambda/lab13-web"
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

resource "aws_iam_role" "function" {
  name               = "lab13-web"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

data "aws_iam_policy_document" "function" {
  statement {
    sid       = "CountVisits"
    actions   = ["dynamodb:UpdateItem"]
    resources = [aws_dynamodb_table.visits.arn]
  }

  statement {
    sid       = "WriteLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.function.arn}:*"]
  }
}

resource "aws_iam_role_policy" "function" {
  name   = "lab13-web"
  role   = aws_iam_role.function.id
  policy = data.aws_iam_policy_document.function.json
}

data "archive_file" "app" {
  type        = "zip"
  source_file = "${path.module}/app/app.py"
  output_path = "/tmp/lab13-app.zip"
}

resource "aws_lambda_function" "web" {
  #checkov:skip=CKV_AWS_50:CloudWatch logs are enough for one small function
  #checkov:skip=CKV_AWS_115:The account only allows 10 at once, I'm testing that limit here
  #checkov:skip=CKV_AWS_116:API Gateway calls it and waits, so a failure goes back to the caller
  #checkov:skip=CKV_AWS_117:It only talks to AWS APIs, a VPC would mean paying for a NAT gateway
  #checkov:skip=CKV_AWS_173:The variables only hold a table name and a version
  #checkov:skip=CKV_AWS_272:Nobody else deploys to this function
  function_name    = "lab13-web"
  role             = aws_iam_role.function.arn
  handler          = "app.handler"
  runtime          = "python3.13"
  architectures    = ["arm64"]
  memory_size      = 128
  timeout          = 5
  filename         = data.archive_file.app.output_path
  source_code_hash = data.archive_file.app.output_base64sha256

  environment {
    variables = {
      TABLE        = aws_dynamodb_table.visits.name
      PAGE_VERSION = var.page_version
    }
  }

  depends_on = [aws_cloudwatch_log_group.function, aws_iam_role_policy.function]
}
