#!/usr/bin/env bash
# Deletes everything tagged Lab=05 in us-east-1, in the order AWS needs
set -uo pipefail
export AWS_DEFAULT_REGION=us-east-1
TAG="Name=tag:Lab,Values=05"
VPC=$(aws ec2 describe-vpcs --filters "$TAG" --query 'Vpcs[0].VpcId' --output text)

ids=$(aws ec2 describe-instances --filters "$TAG" Name=instance-state-name,Values=pending,running,stopping,stopped --query 'Reservations[].Instances[].InstanceId' --output text)
if [ -n "$ids" ]; then
  aws ec2 terminate-instances --instance-ids $ids >/dev/null
  aws ec2 wait instance-terminated --instance-ids $ids && echo "terminated: $ids"
fi

nats=$(aws ec2 describe-nat-gateways --filter "$TAG" Name=state,Values=pending,available --query 'NatGateways[].NatGatewayId' --output text)
for n in $nats; do aws ec2 delete-nat-gateway --nat-gateway-id "$n" >/dev/null; done
for n in $nats; do
  while [ "$(aws ec2 describe-nat-gateways --nat-gateway-ids "$n" --query 'NatGateways[0].State' --output text)" != "deleted" ]; do sleep 15; done
  echo "deleted: $n"
done

for a in $(aws ec2 describe-addresses --filters "$TAG" --query 'Addresses[].AllocationId' --output text); do
  aws ec2 release-address --allocation-id "$a" && echo "released: $a"
done

if [ "$VPC" != "None" ]; then
  for f in $(aws ec2 describe-flow-logs --filter Name=resource-id,Values="$VPC" --query 'FlowLogs[].FlowLogId' --output text); do
    aws ec2 delete-flow-logs --flow-log-ids "$f" >/dev/null && echo "deleted: $f"
  done
  for g in $(aws ec2 describe-internet-gateways --filters Name=attachment.vpc-id,Values="$VPC" --query 'InternetGateways[].InternetGatewayId' --output text); do
    aws ec2 detach-internet-gateway --internet-gateway-id "$g" --vpc-id "$VPC"
    aws ec2 delete-internet-gateway --internet-gateway-id "$g" && echo "deleted: $g"
  done
  for s in $(aws ec2 describe-subnets --filters Name=vpc-id,Values="$VPC" --query 'Subnets[].SubnetId' --output text); do
    aws ec2 delete-subnet --subnet-id "$s" && echo "deleted: $s"
  done
  for r in $(aws ec2 describe-route-tables --filters Name=vpc-id,Values="$VPC" --query 'RouteTables[?!Associations[?Main]].RouteTableId' --output text); do
    aws ec2 delete-route-table --route-table-id "$r" && echo "deleted: $r"
  done
  for n in $(aws ec2 describe-network-acls --filters Name=vpc-id,Values="$VPC" --query 'NetworkAcls[?!IsDefault].NetworkAclId' --output text); do
    aws ec2 delete-network-acl --network-acl-id "$n" && echo "deleted: $n"
  done
  sgs=$(aws ec2 describe-security-groups --filters Name=vpc-id,Values="$VPC" --query "SecurityGroups[?GroupName!='default'].GroupId" --output text)
  for g in $sgs; do
    rules=$(aws ec2 describe-security-groups --group-ids "$g" --query 'SecurityGroups[0].IpPermissions' --output json)
    [ "$rules" != "[]" ] && aws ec2 revoke-security-group-ingress --group-id "$g" --ip-permissions "$rules" >/dev/null
  done
  for g in $sgs; do aws ec2 delete-security-group --group-id "$g" && echo "deleted: $g"; done
  aws ec2 delete-vpc --vpc-id "$VPC" && echo "deleted: $VPC"
fi

aws logs delete-log-group --log-group-name /lab05/flow-logs 2>/dev/null && echo "deleted: log group /lab05/flow-logs"
if aws iam get-instance-profile --instance-profile-name lab05-ssm >/dev/null 2>&1; then
  aws iam remove-role-from-instance-profile --instance-profile-name lab05-ssm --role-name lab05-ssm
  aws iam delete-instance-profile --instance-profile-name lab05-ssm
  aws iam detach-role-policy --role-name lab05-ssm --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
  aws iam delete-role --role-name lab05-ssm && echo "deleted: role and instance profile lab05-ssm"
fi
