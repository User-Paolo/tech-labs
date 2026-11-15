output "canary_user" {
  value = aws_iam_user.canary.name
}

output "decoy_bucket" {
  value = aws_s3_bucket.decoy.id
}
