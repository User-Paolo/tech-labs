output "bucket" {
  value = aws_s3_bucket.decoy.id
}

output "user" {
  value = aws_iam_user.leaky.name
}
