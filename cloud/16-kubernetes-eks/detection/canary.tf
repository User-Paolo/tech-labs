# Nobody should ever use this user, so any call with its key means the key leaked
resource "aws_iam_user" "canary" {
  #checkov:skip=CKV_AWS_273:The whole point is a normal IAM user key that looks worth stealing
  name          = "lab16-canary"
  path          = "/canary/"
  force_destroy = true
}
