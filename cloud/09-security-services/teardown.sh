#!/usr/bin/env bash
# Turns off AWS Config and deletes what lab 09 made in us-east-1, the access analyzer stays
set -uo pipefail
export AWS_DEFAULT_REGION=us-east-1

for r in $(aws configservice describe-config-rules --query "ConfigRules[?starts_with(ConfigRuleName,'lab09-')].ConfigRuleName" --output text); do
  aws configservice delete-config-rule --config-rule-name "$r" && echo "deleted rule: $r"
done

# The bucket name has to be read before the delivery channel goes
CONFIG_BUCKET=$(aws configservice describe-delivery-channels --query 'DeliveryChannels[0].s3BucketName' --output text)
for rec in $(aws configservice describe-configuration-recorders --query 'ConfigurationRecorders[].name' --output text); do
  aws configservice stop-configuration-recorder --configuration-recorder-name "$rec"
done
for ch in $(aws configservice describe-delivery-channels --query 'DeliveryChannels[].name' --output text); do
  aws configservice delete-delivery-channel --delivery-channel-name "$ch" && echo "deleted delivery channel: $ch"
done
for rec in $(aws configservice describe-configuration-recorders --query 'ConfigurationRecorders[].name' --output text); do
  aws configservice delete-configuration-recorder --configuration-recorder-name "$rec" && echo "deleted recorder: $rec"
done

for g in $(aws ec2 describe-security-groups --filters Name=tag:Lab,Values=09 --query 'SecurityGroups[].GroupId' --output text); do
  aws ec2 delete-security-group --group-id "$g" >/dev/null && echo "deleted: $g"
done

buckets=$(aws resourcegroupstaggingapi get-resources --resource-type-filters s3 --tag-filters Key=Lab,Values=09 --query 'ResourceTagMappingList[].ResourceARN' --output text | sed 's#arn:aws:s3:::##g')
for b in $(echo $buckets $CONFIG_BUCKET | tr ' ' '\n' | grep -v '^None$' | sort -u); do
  aws s3 rm "s3://$b" --recursive --quiet && aws s3 rb "s3://$b" && echo "deleted bucket: $b"
done
