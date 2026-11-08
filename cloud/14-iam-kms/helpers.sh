#!/bin/bash
# Source this from the lab folder after the apply: source helpers.sh
B=$(terraform output -raw bucket)
KEY=$(terraform output -raw key_arn)
ROLE=$(terraform output -raw role_arn)
BOUNDARY=$(terraform output -raw boundary_arn)
ADMIN=$(aws sts get-caller-identity --query Arn --output text)
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

# Fills in the placeholders in a policy file
render() {
  sed -e "s|BUCKET|$B|g" -e "s|KEY_ARN|$KEY|g" -e "s|ROLE_ARN|$ROLE|g" -e "s|ADMIN_ARN|$ADMIN|g" -e "s|ACCOUNT|$ACCOUNT|g" "$1"
}

# Runs one aws command as the tester role, the temporary keys are never printed
t() {
  local c
  c=$(aws sts assume-role --role-arn "$ROLE" --role-session-name tester --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text) || return 1
  AWS_ACCESS_KEY_ID=$(cut -f1 <<<"$c") AWS_SECRET_ACCESS_KEY=$(cut -f2 <<<"$c") AWS_SESSION_TOKEN=$(cut -f3 <<<"$c") aws "$@" 2>&1 | sed -E 's/[0-9]{12}/123456789012/g'
}

# Reads one file as the tester, prints its encryption and content
g() {
  rm -f /tmp/g.out
  t s3api get-object --bucket "$B" --key "$1" /tmp/g.out --query ServerSideEncryption --output text
  [ -s /tmp/g.out ] && echo "content: $(cat /tmp/g.out)"
}

# The same read as me
a() {
  rm -f /tmp/a.out
  aws s3api get-object --bucket "$B" --key "$1" /tmp/a.out --query ServerSideEncryption --output text 2>&1 | sed -E 's/[0-9]{12}/123456789012/g'
  [ -s /tmp/a.out ] && echo "content: $(cat /tmp/a.out)"
}
