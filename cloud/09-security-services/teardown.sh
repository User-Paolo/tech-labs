#!/usr/bin/env bash
# Turns off the security services lab 09 switched on and deletes what it made, us-east-1 only
set -uo pipefail
export AWS_DEFAULT_REGION=us-east-1
TAG="Name=tag:Lab,Values=09"

ids=$(aws ec2 describe-instances --filters "$TAG" Name=instance-state-name,Values=pending,running,stopping,stopped --query 'Reservations[].Instances[].InstanceId' --output text)
if [ -n "$ids" ]; then
  aws ec2 terminate-instances --instance-ids $ids >/dev/null
  aws ec2 wait instance-terminated --instance-ids $ids && echo "terminated: $ids"
fi
for g in $(aws ec2 describe-security-groups --filters "$TAG" --query 'SecurityGroups[].GroupId' --output text); do
  aws ec2 delete-security-group --group-id "$g" >/dev/null && echo "deleted: $g"
done

for d in $(aws guardduty list-detectors --query 'DetectorIds[]' --output text); do
  aws guardduty delete-detector --detector-id "$d" && echo "GuardDuty off: $d"
done
aws inspector2 disable --resource-types EC2 ECR LAMBDA LAMBDA_CODE >/dev/null && echo "Inspector off"
aws securityhub disable-security-hub && echo "Security Hub off"
aws macie2 disable-macie && echo "Macie off"

# Config, the bucket name has to be read before the delivery channel goes
for r in $(aws configservice describe-config-rules --query "ConfigRules[?starts_with(ConfigRuleName,'lab09-')].ConfigRuleName" --output text); do
  aws configservice delete-config-rule --config-rule-name "$r" && echo "deleted rule: $r"
done
CONFIG_BUCKET=$(aws configservice describe-delivery-channels --query 'DeliveryChannels[0].s3BucketName' --output text 2>/dev/null)
for rec in $(aws configservice describe-configuration-recorders --query 'ConfigurationRecorders[].name' --output text); do
  aws configservice stop-configuration-recorder --configuration-recorder-name "$rec"
done
for ch in $(aws configservice describe-delivery-channels --query 'DeliveryChannels[].name' --output text); do
  aws configservice delete-delivery-channel --delivery-channel-name "$ch" && echo "deleted delivery channel: $ch"
done
for rec in $(aws configservice describe-configuration-recorders --query 'ConfigurationRecorders[].name' --output text); do
  aws configservice delete-configuration-recorder --configuration-recorder-name "$rec" && echo "deleted recorder: $rec"
done

buckets=$(aws resourcegroupstaggingapi get-resources --resource-type-filters s3 --tag-filters Key=Lab,Values=09 --query 'ResourceTagMappingList[].ResourceARN' --output text | sed 's#arn:aws:s3:::##g')
for b in $buckets ${CONFIG_BUCKET:-}; do
  [ "$b" = "None" ] && continue
  aws s3 rm "s3://$b" --recursive --quiet && aws s3 rb "s3://$b" && echo "deleted bucket: $b"
done

if aws iam get-instance-profile --instance-profile-name lab09-ssm >/dev/null 2>&1; then
  aws iam remove-role-from-instance-profile --instance-profile-name lab09-ssm --role-name lab09-ssm
  aws iam delete-instance-profile --instance-profile-name lab09-ssm
  aws iam detach-role-policy --role-name lab09-ssm --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
  aws iam delete-role --role-name lab09-ssm && echo "deleted: role and instance profile lab09-ssm"
fi
