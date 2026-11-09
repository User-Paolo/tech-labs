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
| [helpers.sh](helpers.sh) | `x` runs one command with the leaked key, `steal_session` gets a session with it, and `xs` runs one command with that session. None of them print a secret |
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
