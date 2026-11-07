output "url" {
  value = aws_apigatewayv2_stage.default.invoke_url
}

output "function_name" {
  value = aws_lambda_function.web.function_name
}
