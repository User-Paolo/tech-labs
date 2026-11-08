# 14 IAM Policy Logic and KMS

**Track:** Cloud
**Exam topics:** AWS Cloud Practitioner, Security and Compliance (IAM policies, explicit and implicit deny, permissions boundaries, resource based policies, KMS keys and key policies, encryption at rest)

## Question
I can recite the rule for the exam: everything starts denied, an allow opens it up, and an explicit deny beats any allow. But I've never watched it happen with more than one policy in play. What happens when policies disagree? And the review in [lab 10](../10-well-architected/) flagged that my user has `AdministratorAccess` and that I only use the default encryption keys. If I make my own KMS key, is there anything an admin like me still can't do with it?

## Setup
A test role, an S3 bucket encrypted with my own KMS key and a permissions boundary, in Terraform from CloudShell in `us-east-1`.

The role starts with no permissions at all. It has no access keys either, I switch into it from CloudShell for one command at a time with `sts assume-role`. Then I add and remove policies on it one step at a time and run the same commands after each change.

| File | What's in it |
|---|---|
| [main.tf](main.tf) | The key, the bucket, the empty test role and the boundary policy |
| [policies/](policies/) | The policies I add during the lab, with placeholders for the bucket, key and account |
| [helpers.sh](helpers.sh) | `render` fills in the placeholders and `t` runs one command as the test role without printing its keys |

The bucket uses my key by default, with S3 Bucket Keys turned off. That's more expensive at scale, but every read goes to KMS, so each one shows up in CloudTrail.

Cost: a few cents. The key is $1 a month prorated and requests are $0.03 per 10,000:
```
1.0000000000    Keys        $1 per customer managed KMS key version in US East (N. Virginia)
0.0000030000    Requests    $0.03 per 10000 KMS requests in US East (N. Virginia)
```
A key can't be deleted straight away, the shortest wait is 7 days. So the destroy schedules the deletion and it finishes on its own a week later.

## Steps and Evidence

### 1. Is it allowed on the Free plan?
```
$ aws kms list-aliases --query "length(Aliases[?starts_with(AliasName,'alias/aws/')])"
13
$ aws kms list-aliases --query 'length(Aliases[?!starts_with(AliasName, `alias/aws/`)])'
0
$ aws iam simulate-principal-policy --policy-source-arn "$(aws sts get-caller-identity --query Arn --output text)" --action-names s3:ListAllMyBuckets --query 'EvaluationResults[0].EvalDecision' --output text
allowed
```
13 keys that AWS made for its own services, none of mine yet, and the policy simulator works. The only other roles in the account are AWS service roles and the one from [lab 02](../02-security-alerts/).

### 2. How I set it up
I didn't want to make access keys for a test user, since a leaked key is exactly what lab 15 is about. A role I switch into gets keys that expire on their own after an hour, and `t` keeps them in variables for one command and never prints them.

The policies in [policies/](policies/) have `BUCKET`, `KEY_ARN` and similar placeholders in them, so the account ID and the random bucket name stay out of the repo. `render` fills them in just before I use them.
