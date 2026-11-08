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
| [helpers.sh](helpers.sh) | `render` fills in the placeholders, `t` runs one command as the test role without printing its keys, and `g` and `a` read one file as the test role or as me |

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

### 3. No permissions at all
The apply made 7 resources. I uploaded three small files: `plain/hello.txt` and `secret/plan.txt` with the normal S3 encryption (`AES256`), and `kms/notes.txt` with my key. Then I tried the role before giving it anything:
```
$ t s3 ls "s3://$B/"
... is not authorized to perform: s3:ListBucket on resource: "arn:aws:s3:::<bucket>" because no identity-based policy allows the s3:ListBucket action
$ t s3 cp "s3://$B/plain/hello.txt" -
An error occurred (403) when calling the HeadObject operation: Forbidden
```
The first error is the implicit deny, and it says so in plain words. Nothing allowed it, so it's denied. The second one only says `Forbidden`, because `s3 cp` asks for the file's details with `HeadObject` first, and that call returns no message. So from here on I read files with `s3api get-object` through the `g` function, which gives the full reason.

### 4. An allow, then an explicit deny
I gave the role [s3-read.json](policies/s3-read.json), which allows listing the bucket and reading any file in it:
```
$ g plain/hello.txt
AES256
content: hello
$ g secret/plan.txt
AES256
content: the plan
$ g kms/notes.txt
... is not authorized to perform: kms:Decrypt on resource: arn:aws:kms:us-east-1:123456789012:key/<key-id> because no identity-based policy allows the kms:Decrypt action
```
The S3 part worked for all three files, and the KMS file still failed. S3 has to ask KMS to decrypt the file, and it asks as the role. So reading a file encrypted with my own key needs two permissions in two services, and having all of S3 isn't enough.

Then I added [deny-secret.json](policies/deny-secret.json) next to it, which denies reading anything under `secret/`. Both policies are on the role at the same time, one allowing the file and one denying it:
```
$ g plain/hello.txt
AES256
content: hello
$ g secret/plan.txt
... is not authorized to perform: s3:GetObject on resource: "arn:aws:s3:::<bucket>/secret/plan.txt" with an explicit deny in an identity-based policy
```
The deny won, and the error names it as an explicit deny this time. The policy simulator gives the same answers without making any real request:
```
$ aws iam simulate-principal-policy --policy-source-arn "$ROLE" --action-names s3:GetObject --resource-arns "arn:aws:s3:::$B/plain/hello.txt" "arn:aws:s3:::$B/secret/plan.txt" --query 'EvaluationResults[0].ResourceSpecificResults[].[EvalResourceName,EvalResourceDecision]' --output text
arn:aws:s3:::<bucket>/plain/hello.txt    allowed
arn:aws:s3:::<bucket>/secret/plan.txt    explicitDeny
```

### 5. A permissions boundary
I swapped both policies for [s3-all.json](policies/s3-all.json), which allows every S3 action on the bucket, and set the boundary from [main.tf](main.tf) on the role. The boundary only allows `s3:ListBucket`:
```
$ t s3 ls "s3://$B/plain/"
2026-11-08 18:39:42          6 hello.txt
$ g plain/hello.txt
... is not authorized to perform: s3:GetObject on resource: "arn:aws:s3:::<bucket>/plain/hello.txt" because no permissions boundary allows the s3:GetObject action
$ t s3api delete-object --bucket "$B" --key plain/hello.txt
... is not authorized to perform: s3:DeleteObject on resource: "arn:aws:s3:::<bucket>/plain/hello.txt" because no permissions boundary allows the s3:DeleteObject action
```
The role's own policy allows `s3:*`, and it could still only list. So the boundary only limits what the role's own policies give, and the role gets the actions that both of them allow. Here that's only the list, so the delete failed and `hello.txt` was still there.

### 6. A bucket policy instead
For this one I took everything off the role, so it had no policies and no boundary. Then I put [bucket-allow-tester.json](policies/bucket-allow-tester.json) on the bucket. It lets the role read files under `plain/`:
```
$ g plain/hello.txt
AES256
content: hello
$ g secret/plan.txt
... because no identity-based policy allows the s3:GetObject action
$ t s3 ls "s3://$B/"
... because no identity-based policy allows the s3:ListBucket action
```
A role with zero policies read a file. Inside one account, an allow from either side is enough, the role's own policies or the policy on the resource.

Then I put the list only boundary back on the role, without changing anything else:
```
$ g plain/hello.txt
... because no permissions boundary allows the s3:GetObject action
```
I wasn't sure about this one before trying it. The [IAM docs on boundaries](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_boundaries.html) cover it, and the answer depends on how the bucket policy names the role. My bucket policy used the role ARN, and a resource policy that names the role ARN is limited by the boundary. A resource policy that names the role session (`arn:aws:sts::123456789012:assumed-role/lab14-tester/tester`) gives the permission straight to that session, and the boundary doesn't limit it. So I changed only the principal, with the boundary still on:
```
$ SESSION="arn:aws:sts::$ACCOUNT:assumed-role/lab14-tester/tester"
$ aws s3api put-bucket-policy --bucket "$B" --policy "$(render policies/bucket-allow-tester.json | sed "s|$ROLE|$SESSION|")"
$ g plain/hello.txt
AES256
content: hello
```
It worked, like the docs say. That's an odd gap. A boundary is meant to be the most a role can do, and a bucket policy in the same account can still go around it, depending on which ARN it names. If I relied on boundaries to limit someone, I'd also have to watch the bucket policies.
