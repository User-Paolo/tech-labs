#!/usr/bin/env bash
# Removes everything setup.sh made, the trail stays
set -uo pipefail

HOME_REGION=us-east-1
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
ROLE_NAME=eventbridge-forward-to-us-east-1

for r in $(aws ec2 describe-regions --query 'Regions[].RegionName' --output text); do
  [ "$r" = "$HOME_REGION" ] && continue
  aws events remove-targets --region "$r" --rule forward-to-us-east-1 --ids home-bus >/dev/null 2>&1
  aws events delete-rule --region "$r" --name forward-to-us-east-1 2>/dev/null && echo "deleted: $r forward-to-us-east-1"
done

for name in alert-root-activity alert-iam-change alert-access-denied alert-signin-failed alert-signin-without-mfa; do
  aws events remove-targets --region "$HOME_REGION" --rule "$name" --ids email >/dev/null 2>&1
  aws events delete-rule --region "$HOME_REGION" --name "$name" 2>/dev/null && echo "deleted: $HOME_REGION $name"
done

aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name put-events-us-east-1 2>/dev/null
aws iam delete-role --role-name "$ROLE_NAME" 2>/dev/null && echo "deleted: role $ROLE_NAME"

aws sns delete-topic --region "$HOME_REGION" --topic-arn "arn:aws:sns:$HOME_REGION:$ACCOUNT:security-alerts" && echo "deleted: topic security-alerts"
