#!/usr/bin/env bash
# Puts the canary user back the way Terraform made it after a test
set -euo pipefail
user=lab16-canary
for key in $(aws iam list-access-keys --user-name "$user" --query 'AccessKeyMetadata[].AccessKeyId' --output text); do
  aws iam delete-access-key --user-name "$user" --access-key-id "$key"
done
aws iam detach-user-policy --user-name "$user" --policy-arn arn:aws:iam::aws:policy/AWSCompromisedKeyQuarantineV3 2>/dev/null || true
aws iam delete-user-policy --user-name "$user" --policy-name revoke-sessions 2>/dev/null || true
echo "keys: $(aws iam list-access-keys --user-name "$user" --query 'length(AccessKeyMetadata)')"
echo "attached: $(aws iam list-attached-user-policies --user-name "$user" --query 'length(AttachedPolicies)')"
echo "inline: $(aws iam list-user-policies --user-name "$user" --query 'length(PolicyNames)')"
