resource "aws_cloudwatch_log_group" "api" {
  #checkov:skip=CKV_AWS_158:Logs from a short lab don't need my own KMS key
  #checkov:skip=CKV_AWS_338:Logs from a short lab don't need a year of retention
  name              = "/aws/vendedlogs/lab13-api"
  retention_in_days = 7
}

resource "aws_apigatewayv2_api" "web" {
  name          = "lab13-web"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "function" {
  api_id                 = aws_apigatewayv2_api.web.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.web.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "all" {
  #checkov:skip=CKV_AWS_309:It's a public page, the rate limit on the stage is the protection
  api_id    = aws_apigatewayv2_api.web.id
  route_key = "$default"
  target    = "integrations/${aws_apigatewayv2_integration.function.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.web.id
  name        = "$default"
  auto_deploy = true

  # The URL is public, so this caps what a stray scanner can cost me
  default_route_settings {
    throttling_rate_limit  = 100
    throttling_burst_limit = 200
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api.arn
    format = jsonencode({
      id      = "$context.requestId"
      time    = "$context.requestTime"
      path    = "$context.path"
      status  = "$context.status"
      latency = "$context.responseLatency"
      lambda  = "$context.integrationLatency"
      error   = "$context.integrationErrorMessage"
    })
  }
}

resource "aws_lambda_permission" "api" {
  statement_id  = "AllowApiGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.web.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.web.execution_arn}/*"
}
