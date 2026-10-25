# 09 Security Services Tour

**Track:** Cloud
**Exam topics:** AWS Cloud Practitioner, Security and Compliance (Trusted Advisor, IAM Access Analyzer, AWS Artifact, GuardDuty, Inspector, Macie, AWS Config, Security Hub, shared responsibility)

## Question
The exam has a long list of security services with names that blur together. What does each one actually look at, and what does it find when I point it at my own account?

## Setup
One service at a time, all in `us-east-1`, mostly in the console.

| Service | What it looks at | Cost here |
|---|---|---|
| Trusted Advisor | The account's setup against AWS best practices | Free, the core checks come with Basic Support |
| IAM Access Analyzer | Policies that let someone outside the account in | Free for external access |
| AWS Artifact | AWS's own audit reports and certifications | Free |
| GuardDuty | CloudTrail, VPC flow logs and DNS logs, looking for threats | 30 day free trial |
| Inspector | Software vulnerabilities on instances | 15 day free trial |
| Macie | Sensitive data sitting in S3 | 30 day free trial, first GB of scanning free |
| AWS Config | How each resource is configured and whether it follows rules | A few cents |
| Security Hub | Findings from all of the above in one place, plus a score | 30 day free trial |

[fake-customers.csv](fake-customers.csv) is for Macie. Five people who don't exist, with `example.com` email addresses, `555-01xx` phone numbers that are reserved for fiction, made up addresses and the public test card numbers that payment companies publish, like 4111 1111 1111 1111. They pass the card number checksum, so they should look real to a scanner, but there's no card behind any of them.

[teardown.sh](teardown.sh) turns all the paid services off again and deletes what the lab made. After the trials GuardDuty, Inspector, Security Hub and Config would cost a few dollars a month between them, so they don't stay on.

Cost: under $1 if everything is turned off the same day.

## Steps and Evidence

### 1. Trusted Advisor
Under Recommendations I refreshed all checks and opened the Security category. With Basic Support only the core checks run, and the rest sit behind an upgrade banner.

![Trusted Advisor before](images/trusted-advisor-before.png)

Root MFA, no public EBS or RDS snapshots and no public S3 buckets were all green. One red. A security group called `launch-wizard-2` in `us-east-1` let anyone on the internet in on port 22. Nothing from my labs is called that. `launch-wizard-N` is the name the EC2 console gives a security group when you launch an instance through its wizard, so it's from training, before these labs. The lab 01 audit looked for leftovers that cost money, and a security group costs nothing, so it never came up there.

Before deleting anything I wanted to know what it was and whether anything still used it. Listing every non default security group in every region found a second one:
```
$ for r in $(aws ec2 describe-regions --query 'Regions[].RegionName' --output text); do aws ec2 describe-security-groups --region $r --query "SecurityGroups[?GroupName!='default'].[GroupId,GroupName]" --output text | sed "s/^/$r  /"; done
us-east-1  sg-0393a1ba7de56f731 launch-wizard-2
us-east-1  sg-09b58ad1c3fb67098 launch-wizard-1
$ for g in sg-0393a1ba7de56f731 sg-09b58ad1c3fb67098; do
  aws ec2 describe-security-groups --group-ids $g --query 'SecurityGroups[0].[GroupId,GroupName,VpcId]' --output text
  aws ec2 describe-security-groups --group-ids $g --query 'SecurityGroups[0].IpPermissions[].[IpProtocol,FromPort,ToPort,join(`,`,IpRanges[].CidrIp)]' --output text
  echo "in use by: $(aws ec2 describe-network-interfaces --filters Name=group-id,Values=$g --query 'NetworkInterfaces[].NetworkInterfaceId' --output text)"
done
sg-0393a1ba7de56f731    launch-wizard-2 vpc-04b0f2cebed78d8ff
tcp     22      22      0.0.0.0/0
in use by:
sg-09b58ad1c3fb67098    launch-wizard-1 vpc-04b0f2cebed78d8ff
tcp     22      22      203.0.113.10/32
in use by:
```
Both in the default VPC, both SSH only, and neither attached to any network interface. The first one was open to everyone, the second only to my home IP (replaced with `203.0.113.10` here), which explains the "1 of 2 security group rules" Trusted Advisor counted. The instances from training are long gone and their security groups just stayed behind.

An unused security group can't let anything in by itself. But anyone launching an instance later could pick `launch-wizard-2` from the list and have SSH open to the whole internet without noticing. Neither had any use, so both went:
```
$ aws ec2 delete-security-group --group-id sg-0393a1ba7de56f731 && echo "deleted launch-wizard-2"
deleted launch-wizard-2
$ aws ec2 delete-security-group --group-id sg-09b58ad1c3fb67098 && echo "deleted launch-wizard-1"
deleted launch-wizard-1
```

![Trusted Advisor after](images/trusted-advisor-after.png)

"0 of 0 security group rules" and everything green.

### 2. IAM Access Analyzer
In IAM under Access reports I made an analyzer called `account-external`, type external access, with the current account as the zone of trust. It reads the resource policies in the account, bucket policies, role trust policies, KMS key policies, SNS topic policies and so on, and reports anything that lets in a principal from outside that zone.

Active findings: 0.

My account does have resource policies that let other parties in, the lab 03 bucket policy for CloudFront, the CloudTrail bucket policy, the SNS topic policy for EventBridge and the EventBridge role's trust policy. All of those let in an AWS service and not another account, and the analyzer doesn't count AWS services as outside. Free and silent until something changes, so this one stays on.

### 3. AWS Artifact
Artifact is where AWS keeps its own audit reports, the ones done on AWS by outside auditors. Searching the reports for ISO 27001 gave 8, among them ISO 27001:2022, ISO 27017:2015 for cloud specific controls, ISO 27018:2019 for personal data in the cloud and CSA STAR Level 2. Each one has the period it covers, most of them November 2025 to November 2028.

This is the shared responsibility model in practice. AWS can't let every customer walk into its data centers to check, so it gets audited once and hands out the reports. Someone running their own audit downloads these as proof for AWS's half, the facilities, hardware and the services themselves. Everything in the first two steps of this lab, security groups, MFA and policies, is my half.

### 4. What the Free plan lets me use
Next was GuardDuty, and the console sent me to a page called "Complete your account setup" that said "your account is currently on free plan" and "Free account plans have limited access to certain services and features". So I asked each service directly from CloudShell:
```
$ aws guardduty list-detectors 2>&1 | tail -1
aws: [ERROR]: An error occurred (SubscriptionRequiredException) when calling the ListDetectors operation: The AWS Access Key Id needs a subscription for the service
$ aws inspector2 batch-get-account-status --query 'accounts[0].state.status' --output text 2>&1 | tail -1
aws: [ERROR]: An error occurred (SubscriptionRequiredException) when calling the BatchGetAccountStatus operation: The AWS Access Key Id needs a subscription for the service
$ aws macie2 get-macie-session 2>&1 | tail -1
aws: [ERROR]: An error occurred (SubscriptionRequiredException) when calling the GetMacieSession operation: The AWS Access Key Id needs a subscription for the service
$ aws securityhub describe-hub 2>&1 | tail -1
aws: [ERROR]: An error occurred (SubscriptionRequiredException) when calling the DescribeHub operation: The AWS Access Key Id needs a subscription for the service
$ aws configservice describe-configuration-recorders 2>&1 | tail -3
{
    "ConfigurationRecorders": []
}
```

| Service | On the Free plan |
|---|---|
| Trusted Advisor, core checks | Works |
| IAM Access Analyzer | Works |
| AWS Artifact | Works |
| AWS Config | Works |
| GuardDuty | Blocked |
| Inspector | Blocked |
| Macie | Blocked |
| Security Hub | Blocked |

The four blocked ones are exactly the ones with a free trial. Upgrading to a paid plan would open them, and the remaining credits would still count, but it can't be undone and it ends the Free plan's promise that the account never gets charged. I stayed on the Free plan, so [fake-customers.csv](fake-customers.csv) never got to meet Macie. What's left for these four is the theory:

- **GuardDuty** watches CloudTrail, VPC flow logs and DNS queries for signs of an attack, like calls from a known bad IP or an instance talking to a command and control server. It doesn't need anything installed.
- **Inspector** scans instances, container images and Lambda functions for software with known CVEs and for network paths open to the internet.
- **Macie** looks inside S3 objects for personal data, card numbers and credentials.
- **Security Hub** collects the findings of all of these and runs best practice checks of its own, which it builds on AWS Config rules.

### 5. AWS Config
Config works, and it's the one that covers what Trusted Advisor did in step 1, only on its own and with history. I set it up from CloudShell so every piece is visible. The console's one click setup records every resource type in the account, and each recorded change is $0.003, so mine records security groups and S3 buckets only.

Config needs its service linked role and an S3 bucket to deliver to:
```
$ export AWS_DEFAULT_REGION=us-east-1
$ ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
$ aws iam create-service-linked-role --aws-service-name config.amazonaws.com --query Role.RoleName --output text 2>&1 | tail -1
AWSServiceRoleForConfig
$ BUCKET=lab09-config-$(openssl rand -hex 3); echo "BUCKET=$BUCKET" > ~/lab09.env; echo $BUCKET
lab09-config-c9df29
$ aws s3api create-bucket --bucket $BUCKET --query Location --output text
/lab09-config-c9df29
$ aws s3api put-bucket-tagging --bucket $BUCKET --tagging 'TagSet=[{Key=Lab,Value=09}]'
$ aws s3api put-bucket-policy --bucket $BUCKET --policy "$(jq -nc --arg b $BUCKET --arg a $ACCOUNT '{Version:"2012-10-17",Statement:[{Sid:"ConfigCheck",Effect:"Allow",Principal:{Service:"config.amazonaws.com"},Action:["s3:GetBucketAcl","s3:ListBucket"],Resource:"arn:aws:s3:::\($b)",Condition:{StringEquals:{"AWS:SourceAccount":$a}}},{Sid:"ConfigWrite",Effect:"Allow",Principal:{Service:"config.amazonaws.com"},Action:"s3:PutObject",Resource:"arn:aws:s3:::\($b)/AWSLogs/\($a)/Config/*",Condition:{StringEquals:{"s3:x-amz-acl":"bucket-owner-full-control","AWS:SourceAccount":$a}}}]}')" && echo policy ok
policy ok
```
The policy only lets the Config service in, and only when it's working for my account. Then the recorder, the delivery channel and three AWS managed rules:
```
$ aws configservice put-configuration-recorder --configuration-recorder name=default,roleARN=arn:aws:iam::$ACCOUNT:role/aws-service-role/config.amazonaws.com/AWSServiceRoleForConfig --recording-group '{"allSupported":false,"includeGlobalResourceTypes":false,"recordingStrategy":{"useOnly":"INCLUSION_BY_RESOURCE_TYPES"},"resourceTypes":["AWS::EC2::SecurityGroup","AWS::S3::Bucket"]}'
$ aws configservice put-delivery-channel --delivery-channel name=default,s3BucketName=$BUCKET
$ aws configservice start-configuration-recorder --configuration-recorder-name default
$ aws configservice describe-configuration-recorder-status --query 'ConfigurationRecordersStatus[].[name,recording,lastStatus]' --output text
default True    SUCCESS
$ rule() { aws configservice put-config-rule --config-rule "$(jq -nc --arg n $1 --arg id $2 --arg t "$3" '{ConfigRuleName:$n,Source:{Owner:"AWS",SourceIdentifier:$id}} + (if $t=="" then {MaximumExecutionFrequency:"TwentyFour_Hours"} else {Scope:{ComplianceResourceTypes:[$t]}} end)')"; }
$ rule lab09-restricted-ssh INCOMING_SSH_DISABLED AWS::EC2::SecurityGroup
$ rule lab09-s3-public-read S3_BUCKET_PUBLIC_READ_PROHIBITED AWS::S3::Bucket
$ rule lab09-root-mfa ROOT_ACCOUNT_MFA_ENABLED ""
$ aws configservice describe-compliance-by-config-rule --query 'ComplianceByConfigRules[].[ConfigRuleName,Compliance.ComplianceType]' --output text
lab09-restricted-ssh    COMPLIANT
lab09-root-mfa  COMPLIANT
lab09-s3-public-read    COMPLIANT
```
The SSH rule checks every security group when it changes, the bucket rule every bucket, and the root MFA rule isn't about any one resource, so it runs every 24 hours instead. All compliant, since step 1 already got rid of the open security groups.

### 6. Making the same mistake again on purpose
A new security group in the default VPC with SSH open to everyone, the same thing `launch-wizard-2` had. No instance uses it, so nothing is actually exposed:
```
$ VPC=$(aws ec2 describe-vpcs --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)
$ SG=$(aws ec2 create-security-group --group-name lab09-open-ssh --description "SSH open on purpose so Config can catch it" --vpc-id $VPC --tag-specifications 'ResourceType=security-group,Tags=[{Key=Lab,Value=09}]' --query GroupId --output text); echo "SG=$SG" >> ~/lab09.env; echo $SG
sg-0c297784f6c06f4f8
$ aws ec2 authorize-security-group-ingress --group-id $SG --protocol tcp --port 22 --cidr 0.0.0.0/0 >/dev/null && date -u +%T
15:21:00
$ aws configservice get-compliance-details-by-config-rule --config-rule-name lab09-restricted-ssh --query 'EvaluationResults[].[EvaluationResultIdentifier.EvaluationResultQualifier.ResourceId,ComplianceType,ResultRecordedTime]' --output text
sg-0377141be811cc4d1    COMPLIANT       2026-10-25T15:18:36.025000+00:00
sg-0c297784f6c06f4f8    NON_COMPLIANT   2026-10-25T15:23:01.099000+00:00
$ aws ec2 revoke-security-group-ingress --group-id $SG --protocol tcp --port 22 --cidr 0.0.0.0/0 >/dev/null && date -u +%T
15:24:27
$ aws configservice get-compliance-details-by-config-rule --config-rule-name lab09-restricted-ssh --query 'EvaluationResults[].[EvaluationResultIdentifier.EvaluationResultQualifier.ResourceId,ComplianceType,ResultRecordedTime]' --output text
sg-0377141be811cc4d1    COMPLIANT       2026-10-25T15:18:36.025000+00:00
sg-0c297784f6c06f4f8    COMPLIANT       2026-10-25T15:25:07.235000+00:00
```
The other group in the list is the default VPC's own default security group. And the history Config kept of mine:
```
$ aws configservice get-resource-config-history --resource-type AWS::EC2::SecurityGroup --resource-id $SG --output json | jq -r '.configurationItems[] | [.configurationItemCaptureTime, .configurationItemStatus, "inbound rules: \((.configuration | fromjson).ipPermissions | length)"] | @tsv'
2026-10-25T15:24:37.928000+00:00        OK      inbound rules: 0
2026-10-25T15:22:28.720000+00:00        ResourceDiscovered      inbound rules: 1
```

| UTC | What happened |
|---|---|
| 15:21:00 | SSH opened to 0.0.0.0/0 |
| 15:22:28 | Config discovers the group, already with the rule in it |
| 15:23:01 | `NON_COMPLIANT`, two minutes after the mistake |
| 15:24:27 | I close the rule |
| 15:24:37 | Config records the change, 10 seconds later |
| 15:25:07 | `COMPLIANT` again |

I expected three entries in the history, empty, then one rule, then empty again. But I made the group and opened the rule a few seconds apart, and Config only noticed the group about 90 seconds later, so it never saw it empty.

That's the difference to Trusted Advisor in step 1. Trusted Advisor showed me a problem when I went and refreshed it. Config caught the same problem on its own within two minutes, and it can say what the group looked like at any point and when it changed. In a bigger account that's the part that answers "who opened SSH and when".

### 7. Teardown
[teardown.sh](teardown.sh) deletes the rules, stops and removes the recorder and the delivery channel, deletes the security group and empties and deletes the bucket:
```
$ bash ~/teardown.sh
deleted rule: lab09-restricted-ssh
deleted rule: lab09-root-mfa
deleted rule: lab09-s3-public-read
deleted delivery channel: default
deleted recorder: default
deleted: sg-0c297784f6c06f4f8
remove_bucket: lab09-config-c9df29
deleted bucket: lab09-config-c9df29
$ aws configservice describe-configuration-recorders --query 'ConfigurationRecorders[].name' --output text
$ aws configservice describe-config-rules --query 'ConfigRules[].[ConfigRuleName,ConfigRuleState]' --output text
$ aws ec2 describe-security-groups --filters Name=tag:Lab,Values=09 --query 'SecurityGroups[].GroupId' --output text
$ aws s3 ls | grep lab09 || echo "no lab09 buckets"
no lab09 buckets
```
The access analyzer from step 2 stays on, it's free and only speaks up if something gets shared outside the account.

## What Broke and How I Fixed It

**GuardDuty wouldn't open.** Instead of the GuardDuty console I got a page about completing my account setup, which looked like something was wrong with the account. It's the Free plan. Asking the services one by one from CloudShell gave a clear `SubscriptionRequiredException` for four of them, see step 4. Nothing to fix there short of upgrading, so the lab went on with Config.

**The Config rules were still there after the teardown.** Right after `teardown.sh` printed "deleted rule" three times, listing the rules still showed all three. Deleting a Config rule is asynchronous, the call only starts it and the rule sits in a `DELETING` state for a bit. A minute later the list was empty.
