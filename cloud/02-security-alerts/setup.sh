#!/usr/bin/env bash
# Usage: bash setup.sh you@example.com
set -euo pipefail

EMAIL="${1:?usage: bash setup.sh <email>}"
HOME_REGION=us-east-1
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
HOME_BUS="arn:aws:events:$HOME_REGION:$ACCOUNT:event-bus/default"
ROLE_NAME=eventbridge-forward-to-us-east-1
DENIED='[{"prefix":"AccessDenied"},{"prefix":"UnauthorizedOperation"},{"prefix":"Client.UnauthorizedOperation"}]'

# SNS topic, policy and email subscription
TOPIC_ARN=$(aws sns create-topic --region "$HOME_REGION" --name security-alerts --query TopicArn --output text)
aws sns set-topic-attributes --region "$HOME_REGION" --topic-arn "$TOPIC_ARN" --attribute-name Policy --attribute-value "$(jq -nc --arg t "$TOPIC_ARN" --arg a "$ACCOUNT" '{
  Version: "2012-10-17",
  Statement: [
    {Sid: "Owner", Effect: "Allow", Principal: {AWS: "arn:aws:iam::\($a):root"}, Resource: $t,
     Action: ["SNS:GetTopicAttributes", "SNS:SetTopicAttributes", "SNS:AddPermission", "SNS:RemovePermission",
              "SNS:DeleteTopic", "SNS:Subscribe", "SNS:ListSubscriptionsByTopic", "SNS:Publish"]},
    {Sid: "EventBridge", Effect: "Allow", Principal: {Service: "events.amazonaws.com"}, Action: "sns:Publish", Resource: $t,
     Condition: {StringEquals: {"aws:SourceAccount": $a}}}
  ]}')"
if ! aws sns list-subscriptions-by-topic --region "$HOME_REGION" --topic-arn "$TOPIC_ARN" \
     --query 'Subscriptions[].Endpoint' --output text | grep -qx "$EMAIL"; then
  aws sns subscribe --region "$HOME_REGION" --topic-arn "$TOPIC_ARN" --protocol email --notification-endpoint "$EMAIL" >/dev/null
  echo "subscription: check $EMAIL and click Confirm subscription"
fi

# Alert rules in us-east-1, one quoted line per email line
alert_rule() {
  local name=$1 pattern=$2; shift 2
  aws events put-rule --region "$HOME_REGION" --name "$name" --event-pattern "$pattern" >/dev/null
  aws events put-targets --region "$HOME_REGION" --rule "$name" --targets "$(jq -nc --arg arn "$TOPIC_ARN" '[{
    Id: "email",
    Arn: $arn,
    InputTransformer: {
      InputPathsMap: {
        time: "$.detail.eventTime", type: "$.detail.userIdentity.type", arn: "$.detail.userIdentity.arn",
        user: "$.detail.userIdentity.userName", event: "$.detail.eventName", service: "$.detail.eventSource",
        region: "$.detail.awsRegion", error: "$.detail.errorCode", result: "$.detail.responseElements.ConsoleLogin",
        mfa: "$.detail.additionalEventData.MFAUsed", ip: "$.detail.sourceIPAddress"
      },
      InputTemplate: ($ARGS.positional | map("\"" + . + "\"") | join("\n"))
    }}]' --args "$@")" >/dev/null
  echo "rule: $HOME_REGION $name"
}

alert_rule alert-root-activity \
  '{"detail":{"userIdentity":{"type":["Root"]}}}' \
  "Root user activity" "Who: <arn>" "What: <event> on <service>" "Where: <region>" "When: <time>" "MFA used: <mfa>" "Source IP: <ip>"
alert_rule alert-iam-change \
  '{"source":["aws.iam"],"detail-type":["AWS API Call via CloudTrail"]}' \
  "IAM change" "Who: <arn>" "What: <event>" "When: <time>" "Source IP: <ip>"
alert_rule alert-access-denied \
  "$(jq -nc --argjson denied "$DENIED" '{"detail-type": ["AWS API Call via CloudTrail"], detail: {errorCode: $denied}}')" \
  "Access denied" "Who: <arn>" "What: <event> on <service>" "Where: <region>" "When: <time>" "Error: <error>" "Source IP: <ip>"
alert_rule alert-signin-failed \
  '{"source":["aws.signin"],"detail":{"eventName":["ConsoleLogin"],"responseElements":{"ConsoleLogin":["Failure"]}}}' \
  "Failed console sign in" "Who: <type> <user> <arn>" "Where: <region>" "When: <time>" "Result: <result>" "Source IP: <ip>"
alert_rule alert-signin-without-mfa \
  '{"source":["aws.signin"],"detail":{"eventName":["ConsoleLogin"],"additionalEventData":{"MFAUsed":["No"]}}}' \
  "Console sign in without MFA" "Who: <arn>" "Where: <region>" "When: <time>" "Source IP: <ip>"

# Role that lets other regions forward events to the us-east-1 bus
if ! aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document \
    '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"events.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
  sleep 10
fi
aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name put-events-us-east-1 --policy-document \
  "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"events:PutEvents\",\"Resource\":\"$HOME_BUS\"}]}"
ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query Role.Arn --output text)

# Forward rules in every other region
FORWARD=$(jq -nc --argjson denied "$DENIED" '{"$or": [
  {source: ["aws.signin"]},
  {detail: {userIdentity: {type: ["Root"]}}},
  {"detail-type": ["AWS API Call via CloudTrail"], detail: {errorCode: $denied}}]}')
for r in $(aws ec2 describe-regions --query 'Regions[].RegionName' --output text); do
  [ "$r" = "$HOME_REGION" ] && continue
  aws events put-rule --region "$r" --name forward-to-us-east-1 --event-pattern "$FORWARD" >/dev/null
  aws events put-targets --region "$r" --rule forward-to-us-east-1 \
    --targets "Id=home-bus,Arn=$HOME_BUS,RoleArn=$ROLE_ARN" >/dev/null
  echo "rule: $r forward-to-us-east-1"
done
