#!/usr/bin/env bash
# Read only audit, run in CloudShell

show() {
  [ -n "$2" ] && printf '  %-12s %s\n' "$1" "$2"
}

echo "== Account summary"
aws iam get-account-summary \
  --query 'SummaryMap.{RootMFA:AccountMFAEnabled,RootKeys:AccountAccessKeysPresent,Users:Users}' \
  --output table

echo "== IAM roles and customer managed policies"
aws iam list-roles --query 'Roles[?!starts_with(Path, `/aws-service-role/`)].RoleName' --output text
aws iam list-policies --scope Local --query 'Policies[].PolicyName' --output text

echo "== S3 buckets"
aws s3 ls

for r in $(aws ec2 describe-regions --query 'Regions[].RegionName' --output text); do
  echo "== $r"
  show instances  "$(aws ec2 describe-instances --region "$r" --filters Name=instance-state-name,Values=pending,running,stopping,stopped --query 'Reservations[].Instances[].InstanceId' --output text)"
  show eips       "$(aws ec2 describe-addresses --region "$r" --query 'Addresses[].PublicIp' --output text)"
  show nat        "$(aws ec2 describe-nat-gateways --region "$r" --filter Name=state,Values=pending,available --query 'NatGateways[].NatGatewayId' --output text)"
  show volumes    "$(aws ec2 describe-volumes --region "$r" --query 'Volumes[].VolumeId' --output text)"
  show snapshots  "$(aws ec2 describe-snapshots --region "$r" --owner-ids self --query 'Snapshots[].SnapshotId' --output text)"
  show endpoints  "$(aws ec2 describe-vpc-endpoints --region "$r" --query 'VpcEndpoints[].VpcEndpointId' --output text)"
  show extra_vpcs "$(aws ec2 describe-vpcs --region "$r" --filters Name=is-default,Values=false --query 'Vpcs[].VpcId' --output text)"
  show log_groups "$(aws logs describe-log-groups --region "$r" --query 'logGroups[].logGroupName' --output text)"
  show lambda     "$(aws lambda list-functions --region "$r" --query 'Functions[].FunctionName' --output text)"
  show rds        "$(aws rds describe-db-instances --region "$r" --query 'DBInstances[].DBInstanceIdentifier' --output text)"
  show rds_snaps  "$(aws rds describe-db-snapshots --region "$r" --snapshot-type manual --query 'DBSnapshots[].DBSnapshotIdentifier' --output text)"
  show dynamodb   "$(aws dynamodb list-tables --region "$r" --query 'TableNames[]' --output text)"
  show stacks     "$(aws cloudformation list-stacks --region "$r" --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE ROLLBACK_COMPLETE --query 'StackSummaries[].StackName' --output text)"
done
