output "bucket" {
  value = aws_s3_bucket.data.id
}

output "key_arn" {
  value = aws_kms_key.data.arn
}

output "role_arn" {
  value = aws_iam_role.tester.arn
}

output "boundary_arn" {
  value = aws_iam_policy.boundary.arn
}
