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

### 7. My own key policy against me
Everything so far was about the test role. My user has `AdministratorAccess`, so no IAM policy in the account can stop me unless I put it there. A key policy is different, because it sits on the key itself. With the role back on `s3-read` and [kms-decrypt.json](policies/kms-decrypt.json), both of us could read the KMS file. Then I replaced the key policy with [key-deny-admin.json](policies/key-deny-admin.json), which keeps the normal statement for the account and adds a deny on `kms:Decrypt` for my user only:
```
$ aws kms put-key-policy --key-id "$KEY" --policy-name default --policy "$(render policies/key-deny-admin.json)"
$ a kms/notes.txt
... User: arn:aws:iam::123456789012:user/Paolo-Admin is not authorized to perform: kms:Decrypt on resource: arn:aws:kms:us-east-1:123456789012:key/<key-id> with an explicit deny in a resource-based policy
$ a plain/hello.txt
AES256
content: hello
```
The admin lost the KMS file and kept the plain one, since that one never touches my key. Writing was a surprise:
```
$ echo "written by admin" > /tmp/new.txt
$ aws s3 cp /tmp/new.txt "s3://$B/kms/admin.txt" --quiet && echo uploaded
uploaded
$ a kms/admin.txt
... is not authorized to perform: kms:Decrypt ... with an explicit deny in a resource-based policy
$ g kms/admin.txt
aws:kms
content: written by admin
```
An upload uses `kms:GenerateDataKey`, and only `kms:Decrypt` was denied. So I could write a file that I couldn't read back, while the test role could read it fine.

The deny only lasts as long as I leave it there, though. The first statement still gives the account `kms:*`, and that includes changing the key policy. So I took the deny out again:
```
$ aws kms put-key-policy --key-id "$KEY" --policy-name default --policy "$(render policies/key-deny-admin.json | jq 'del(.Statement[1])')"
$ aws kms get-key-policy --key-id "$KEY" --policy-name default --query Policy --output text | jq -r '.Statement[].Sid'
AccountCanManageTheKey
$ a kms/notes.txt
aws:kms
content: kms notes
```
That answers the question from the start. A key policy can block an admin, even one with `AdministratorAccess`. But an admin who can still edit the key policy can just remove the block. To really keep someone out, the key policy would also have to take away `kms:PutKeyPolicy`, and if I got that wrong I could lock the whole account out of its own key. I didn't try that part. `terraform plan` said `No changes` afterwards, so the policy I put back matched the code.

### 8. Turning the key off
Next I disabled the key. No permissions changed this time:
```
$ aws kms disable-key --key-id "$KEY"
$ g kms/notes.txt
An error occurred (KMS.DisabledException) when calling the GetObject operation: arn:aws:kms:us-east-1:123456789012:key/<key-id> is disabled.
$ a kms/notes.txt
An error occurred (KMS.DisabledException) when calling the GetObject operation: arn:aws:kms:us-east-1:123456789012:key/<key-id> is disabled.
$ a plain/hello.txt
AES256
content: hello
```
A different error from all the others, since nobody was denied. The key just stopped working for everyone, me included, and new uploads with it failed too. After `enable-key` the tester read the file again straight away. So disabling a key is a quick way to make all the data under it unreadable without touching a single policy, and it's easy to undo.

### 9. What CloudTrail saw
With Bucket Keys off, every read and write of a KMS file should be its own KMS call. I pulled the `Decrypt` and `GenerateDataKey` events for the last 40 minutes:
```
2026-11-08T18:39:43Z  GenerateDataKey  arn:aws:iam::123456789012:user/Paolo-Admin                 ok                 arn:aws:s3:::<bucket>/kms/notes.txt
2026-11-08T18:41:06Z  Decrypt  arn:aws:sts::123456789012:assumed-role/lab14-tester/tester         AccessDenied       -
2026-11-08T18:51:29Z  Decrypt  arn:aws:sts::123456789012:assumed-role/lab14-tester/tester         ok                 arn:aws:s3:::<bucket>/kms/notes.txt
2026-11-08T18:51:30Z  Decrypt  arn:aws:iam::123456789012:user/Paolo-Admin                         ok                 arn:aws:s3:::<bucket>/kms/notes.txt
2026-11-08T18:57:23Z  Decrypt  arn:aws:iam::123456789012:user/Paolo-Admin                         AccessDenied       -
2026-11-08T18:57:25Z  GenerateDataKey  arn:aws:iam::123456789012:user/Paolo-Admin                 ok                 arn:aws:s3:::<bucket>/kms/admin.txt
2026-11-08T18:57:26Z  Decrypt  arn:aws:iam::123456789012:user/Paolo-Admin                         AccessDenied       -
2026-11-08T18:57:27Z  Decrypt  arn:aws:sts::123456789012:assumed-role/lab14-tester/tester         ok                 arn:aws:s3:::<bucket>/kms/notes.txt
2026-11-08T18:57:29Z  Decrypt  arn:aws:sts::123456789012:assumed-role/lab14-tester/tester         ok                 arn:aws:s3:::<bucket>/kms/admin.txt
2026-11-08T18:58:26Z  Decrypt  arn:aws:iam::123456789012:user/Paolo-Admin                         ok                 arn:aws:s3:::<bucket>/kms/notes.txt
2026-11-08T19:00:31Z  Decrypt  arn:aws:sts::123456789012:assumed-role/lab14-tester/tester         DisabledException  arn:aws:s3:::<bucket>/kms/notes.txt
2026-11-08T19:00:32Z  Decrypt  arn:aws:iam::123456789012:user/Paolo-Admin                         DisabledException  arn:aws:s3:::<bucket>/kms/notes.txt
2026-11-08T19:00:33Z  GenerateDataKey  arn:aws:iam::123456789012:user/Paolo-Admin                 DisabledException  arn:aws:s3:::<bucket>/kms/admin2.txt
2026-11-08T19:00:57Z  Decrypt  arn:aws:sts::123456789012:assumed-role/lab14-tester/tester         ok                 arn:aws:s3:::<bucket>/kms/notes.txt
```
Every KMS step of the lab is in there, from step 4 to step 8, with who asked and which file. The calls were made by S3, but they're logged under the person who asked S3. One of the denied events in full shows how:
```
"eventSource": "kms.amazonaws.com",
"errorCode": "AccessDenied",
"invokedBy": "fas.s3.amazonaws.com",
"requestParameters": null
```
`fas` stands for forward access sessions, which is how S3 calls KMS with my identity instead of its own. The denied events have no `requestParameters`, so they don't say which file was asked for. The file name only shows up when the call goes through.

### 10. Cleaning up
I removed the two policies I had added by hand, then destroyed the rest:
```
Destroy complete! Resources: 7 destroyed.
```
```
$ aws kms describe-key --key-id "$KEY" --query 'KeyMetadata.[KeyState,DeletionDate]' --output text
PendingDeletion 2026-11-15T19:07:18.540000+00:00
$ aws kms encrypt --key-id "$KEY" --plaintext aGk= --query KeyId --output text
An error occurred (KMSInvalidStateException) when calling the Encrypt operation: arn:aws:kms:us-east-1:123456789012:key/<key-id> is pending deletion.
```
```
my own aliases: 0
role: NoSuchEntity
boundary policies: 0
bucket: 404 Not Found
```
The key can't be used while it waits, and the [KMS pricing page](https://aws.amazon.com/kms/pricing/) says a key scheduled for deletion isn't billed. The key only existed for about half an hour of its $1 a month and the lab made well under 100 KMS requests, so my estimate is under a cent.

## What Broke and How I Fixed It

**Reads as the test role only said `Forbidden`.** `s3 cp` calls `HeadObject` first, and that call returns a bare `403` with no reason. Switching to `s3api get-object` gave the full message with the policy type that denied it, so the `g` and `a` functions use that.

**An upload printed nothing at all.** With the key disabled, my upload showed neither `uploaded` nor an error. `--quiet` in `s3 cp` hides errors as well. Listing the folder showed the file was never written, and CloudTrail had the `GenerateDataKey` call with `DisabledException`.

**I couldn't look up a KMS denial in more detail.** The KMS errors end with an authorization ID that's meant to be looked up with `get-request-authorization-details`. The CLI in CloudShell doesn't have that command yet and answered `Found invalid choice`. The error message and CloudTrail were enough for this lab, so I left it.
