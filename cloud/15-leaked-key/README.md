# 15 Leaked Access Key Drill

**Track:** Cloud
**Exam topics:** AWS Cloud Practitioner, Security and Compliance (access keys, temporary credentials from STS, CloudTrail, responding to a security incident, the shared responsibility model)

## Question
After [lab 01](../01-aws-account-hardening/) my account has no access keys at all, and [lab 02](../02-security-alerts/) sends me an email for IAM changes and for AccessDenied errors. I've never tested any of that against an actual leak though. If a key got out, would I notice? Could I tell from CloudTrail what was done with it? And when I deactivate the key, is whoever has it really locked out?

## Setup
A decoy bucket and a user with one tiny policy, in Terraform from CloudShell in `us-east-1`.

I play both sides from CloudShell. The attacker uses the user's access key from shell variables, and I respond as my normal admin user.

| File | What's in it |
|---|---|
| [main.tf](main.tf) | The decoy bucket with a fake customer file, and the user `lab15-leaky`, which can only list buckets and read the decoy |
| [helpers.sh](helpers.sh) | `x` runs one command with the leaked key, `steal_session` gets a session with it, and `xs` runs one command with that session. None of them print a secret. `trail` searches CloudTrail in the regions the drill touched |
| [policies/](policies/) | The deny I use if the session keeps working after the key is gone |

Cost: under a cent. It's one small bucket and IAM, which is free, and nothing in this lab bills by the hour.

## Steps and Evidence

### 1. Is everything there?
```
$ aws iam list-users --query 'Users[].UserName' --output text
Paolo-Admin
$ aws iam list-access-keys --user-name Paolo-Admin --query 'length(AccessKeyMetadata)'
0
$ aws iam get-account-summary --query 'SummaryMap.AccessKeysPerUserQuota'
2
$ aws iam get-policy --policy-arn arn:aws:iam::aws:policy/AWSCompromisedKeyQuarantineV3 --query 'Policy.[PolicyName,DefaultVersionId]' --output text
AWSCompromisedKeyQuarantineV3   v3
$ aws events list-rules --name-prefix alert- --query 'Rules[].[Name,State]' --output text
alert-access-denied     ENABLED
alert-iam-change        ENABLED
alert-root-activity     ENABLED
alert-signin-failed     ENABLED
alert-signin-without-mfa        ENABLED
$ aws cloudtrail describe-trails --query 'trailList[].[Name,IsMultiRegionTrail]' --output text
management-events       True
```
Still one user with no keys, the alerts from lab 02 are on, and the trail is logging in every region. `AWSCompromisedKeyQuarantineV3` is the policy AWS attaches on its own when it finds one of your keys posted somewhere public. I want to see what it actually blocks, so I'll attach it myself during the response.

### 2. How I set it up
The access key is real, so I make it with the CLI during the drill instead of in Terraform. If Terraform made it, the secret would sit in the state file. The secret only lives in shell variables, nothing prints it, and the key gets deleted at the end.

Posting the key somewhere public would be more realistic, but I didn't do that. AWS and GitHub both scan for leaked keys, and a real report would turn a drill into an actual incident.

### 3. The leak
After the apply I made the key as my admin user and kept it in two shell variables:
```
$ read -r AK SK < <(aws iam create-access-key --user-name "$U" --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text)
$ echo "key made: ${AK:0:4}..."
key made: AKIA...
$ date -u +%FT%TZ
2026-11-09T18:53:26Z
```
From here I'm the attacker. The first thing to try with a key you found is asking AWS who it belongs to:
```
$ x sts get-caller-identity
{
    "UserId": "AIDA...",
    "Account": "123456789012",
    "Arn": "arn:aws:iam::123456789012:user/lab15-leaky"
}
```
That works with no permissions at all, so any key gives away the account ID and the user name. Then I tried to look around:
```
$ x iam list-users --query 'Users[].UserName' --output text
... is not authorized to perform: iam:ListUsers on resource: arn:aws:iam::123456789012:user/ because no identity-based policy allows the iam:ListUsers action
$ x iam list-attached-user-policies --user-name "$U"
... is not authorized to perform: iam:ListAttachedUserPolicies on resource: user lab15-leaky because no identity-based policy allows the iam:ListAttachedUserPolicies action
$ x s3 ls
2026-10-17 12:57:47 <trail bucket>
2026-10-18 15:37:33 <site bucket>
2026-11-09 18:53:07 <decoy bucket>
$ x s3 ls "s3://$B/" --recursive
2026-11-09 18:53:08         82 backups/customers.csv
$ x s3 cp "s3://$B/backups/customers.csv" -
id,name,email
1,Test Person,test@example.com
2,Another Person,another@example.com
$ x ec2 describe-instances --region eu-west-1 --query 'length(Reservations)'
An error occurred (UnauthorizedOperation) when calling the DescribeInstances operation: You are not authorized to perform this operation. ... because no identity-based policy allows the ec2:DescribeInstances action
$ x ec2 describe-instances --region ap-southeast-1 --query 'length(Reservations)'
An error occurred (UnauthorizedOperation) ... because no identity-based policy allows the ec2:DescribeInstances action
```
The user couldn't see its own policies, but `s3 ls` showed every bucket in the account, including the one that holds my CloudTrail logs. A policy that only meant to give access to one bucket still handed out a list of all of them. And the fake customer file was read in two commands.

Then I tried to keep access for later. A new user or a second key would survive the first key being deleted:
```
$ x iam create-user --user-name lab15-backdoor
... is not authorized to perform: iam:CreateUser on resource: arn:aws:iam::123456789012:user/lab15-backdoor because no identity-based policy allows the iam:CreateUser action
$ x iam create-access-key --user-name "$U" --query AccessKey.AccessKeyId --output text
... is not authorized to perform: iam:CreateAccessKey on resource: user lab15-leaky because no identity-based policy allows the iam:CreateAccessKey action
$ steal_session
session ready
$ xs sts get-caller-identity
{
    "UserId": "AIDA...",
    "Account": "123456789012",
    "Arn": "arn:aws:iam::123456789012:user/lab15-leaky"
}
```
Both IAM calls failed, but `sts get-session-token` worked. The [STS docs](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_temp_control-access_getsessiontoken.html) say a user needs no permissions to get a session token, so even a user with no policies at all could do this. The session has its own keys and lasts an hour here, up to 36 hours for a user.

### 4. What the alerts caught
Lab 02 sends an email for any IAM change and for any AccessDenied. The attacker got six errors in a row, so I expected a lot of email. Four arrived, shortened here:
```
"Access denied"   "Who: arn:aws:iam::123456789012:user/lab15-leaky"   "What: CreateUser on iam.amazonaws.com"   "Error: AccessDenied"
"IAM change"      "Who: arn:aws:iam::123456789012:user/lab15-leaky"   "What: CreateUser"
"IAM change"      "Who: arn:aws:iam::123456789012:user/lab15-leaky"   "What: CreateAccessKey"
"Access denied"   "Who: arn:aws:iam::123456789012:user/lab15-leaky"   "What: CreateAccessKey on iam.amazonaws.com"   "Error: AccessDenied"
```
Only the two calls that tried to change something. `ListUsers`, `ListAttachedUserPolicies` and both `DescribeInstances` failed too and sent nothing. The EventBridge metrics agree, with 5 matches for `alert-iam-change` (3 of them from my own setup) and 2 for `alert-access-denied`, and no failed deliveries.

The [EventBridge docs](https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-service-event-cloudtrail.html) explain it. Rules in the normal `ENABLED` state only get write events from CloudTrail. Read only calls like `List` and `Describe` only reach rules set to `ENABLED_WITH_ALL_CLOUDTRAIL_MANAGEMENT_EVENTS`. So my alerts can see an attacker trying to change things, and they're blind while the attacker is only looking around. This attacker happened to try `CreateUser` within ten seconds of starting, so I'd still have known. A quieter one that only reads would never trigger an email.

### 5. What CloudTrail saw
Back as my admin user, I searched CloudTrail for the leaked key ID. The EC2 calls went to other regions, so `trail` searches those as well:
```
$ SINCE=2026-11-09T18:50:00Z
$ trail AccessKeyId "$AK"
2026-11-09T18:53:41Z  us-east-1       GetCallerIdentity          ok                            AKIA...  203.0.113.10
2026-11-09T18:53:42Z  us-east-1       ListUsers                  AccessDenied                  AKIA...  203.0.113.10
2026-11-09T18:53:43Z  us-east-1       ListAttachedUserPolicies   AccessDenied                  AKIA...  203.0.113.10
2026-11-09T18:53:44Z  us-east-1       ListBuckets                ok                            AKIA...  203.0.113.10
2026-11-09T18:53:47Z  eu-west-1       DescribeInstances          Client.UnauthorizedOperation  AKIA...  203.0.113.10
2026-11-09T18:53:49Z  ap-southeast-1  DescribeInstances          Client.UnauthorizedOperation  AKIA...  203.0.113.10
2026-11-09T18:53:50Z  us-east-1       CreateUser                 AccessDenied                  AKIA...  203.0.113.10
2026-11-09T18:53:51Z  us-east-1       CreateAccessKey            AccessDenied                  AKIA...  203.0.113.10
2026-11-09T18:53:52Z  us-east-1       GetSessionToken            ok                            AKIA...  203.0.113.10
```
(`203.0.113.10` stands in for the CloudShell address.) Every call is there with its time, region and result, apart from two. The `ListObjects` and `GetObject` on the decoy bucket aren't in the list. Reading a file is an S3 data event, and the [S3 docs](https://docs.aws.amazon.com/AmazonS3/latest/userguide/cloudtrail-logging-s3-info.html) say trails don't record data events unless you turn them on, and Event history never has them. My trail only has management events. So CloudTrail shows the attacker listing the bucket names, and there's no record that the customer file was opened.

The session doesn't show up in that search either. `GetSessionToken` returned a new key ID starting with `ASIA`, and the session's calls are logged under that key:
```
$ aws cloudtrail lookup-events --lookup-attributes AttributeKey=EventName,AttributeValue=GetSessionToken --start-time "$SINCE" --output json | jq -r '.Events[].CloudTrailEvent | fromjson | [.eventTime, .userIdentity.userName, (.responseElements.credentials.accessKeyId | .[0:4] + "..."), .responseElements.credentials.expiration] | @tsv'
2026-11-09T18:53:52Z    lab15-leaky     ASIA...     2026-11-09T19:53:52Z
$ trail AccessKeyId "$SAK"
2026-11-09T18:54:05Z  us-east-1  GetCallerIdentity  ok  ASIA...  203.0.113.10
```
The last four characters of that key matched the session in my shell. So the `GetSessionToken` event is the link between the two keys, and searching only for the leaked key would miss anything done with the session. Searching by user name with `trail Username lab15-leaky` found both, the 9 calls with the leaked key and the one with the session.
