resource "aws_s3_bucket" "decoy" {
  #checkov:skip=CKV_AWS_18:A test bucket for one lab, CloudTrail already records the calls I care about
  #checkov:skip=CKV_AWS_144:A test bucket for one lab doesn't need a copy in another region
  #checkov:skip=CKV_AWS_145:The decoy file is fake, the default S3 encryption is enough
  #checkov:skip=CKV2_AWS_62:Nothing reacts to new objects
  #checkov:skip=CKV_AWS_21:One fake file, versions would add nothing
  #checkov:skip=CKV2_AWS_61:Destroyed at the end of the lab
  bucket_prefix = "lab15-decoy-"
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
  key     = "backups/customers.csv"
  content = "id,name,email\n1,Test Person,test@example.com\n2,Another Person,another@example.com\n"
}

# The access key is made with the CLI so the secret stays out of the state
resource "aws_iam_user" "leaky" {
  #checkov:skip=CKV_AWS_273:The drill is about a leaked access key, so it needs a real IAM user
  name          = "lab15-leaky"
  force_destroy = true
}

data "aws_iam_policy_document" "leaky" {
  statement {
    sid       = "SeeBuckets"
    actions   = ["s3:ListAllMyBuckets"]
    resources = ["*"]
  }

  statement {
    sid       = "ReadTheDecoy"
    actions   = ["s3:ListBucket", "s3:GetObject"]
    resources = [aws_s3_bucket.decoy.arn, "${aws_s3_bucket.decoy.arn}/*"]
  }
}

resource "aws_iam_user_policy" "leaky" {
  #checkov:skip=CKV_AWS_40:One user with one tiny policy, a group would add nothing here
  name   = "lab15-leaky"
  user   = aws_iam_user.leaky.name
  policy = data.aws_iam_policy_document.leaky.json
}
