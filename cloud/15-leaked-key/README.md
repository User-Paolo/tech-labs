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

### 6. Turning the key off
Switching back to the defender, the usual first step is to deactivate the key. I did that at 18:59:08 and tried both sets of keys 20 seconds later:
```
$ aws iam update-access-key --user-name "$U" --access-key-id "$AK" --status Inactive
$ x sts get-caller-identity
An error occurred (InvalidClientTokenId) when calling the GetCallerIdentity operation: The security token included in the request is invalid.
$ xs sts get-caller-identity --query Arn --output text
arn:aws:iam::123456789012:user/lab15-leaky
$ xs s3 cp "s3://$B/backups/customers.csv" -
id,name,email
1,Test Person,test@example.com
2,Another Person,another@example.com
```
The leaked key stopped working at once, and the session didn't care. It still knew who it was and still read the customer file. The [IAM docs on temporary credentials](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_temp_control-access_disable-perms.html) say they're valid until they expire, and that you have to change the permissions to stop them. This session was made for an hour, so the attacker would have had until 19:53, and a session can be asked for 36 hours. Deactivating the key only stopped the attacker from making new sessions.

That second read is also the one I'd most want to know about, and it left nothing behind. It was a data event, so CloudTrail didn't record it, and it wasn't an error, so no alert could have fired.

### 7. The quarantine policy
Next I attached the policy AWS uses when it finds a leaked key:
```
$ aws iam attach-user-policy --user-name "$U" --policy-arn arn:aws:iam::aws:policy/AWSCompromisedKeyQuarantineV3
$ xs s3 ls
... is not authorized to perform: s3:ListAllMyBuckets with an explicit deny in an identity-based policy: arn:aws:iam::aws:policy/AWSCompromisedKeyQuarantineV3
$ xs s3 cp "s3://$B/backups/customers.csv" -
download failed: s3://<decoy bucket>/backups/customers.csv to - An error occurred (403) when calling the HeadObject operation: Forbidden
```
That error names the exact policy that denied it, which I hadn't seen before. I expected the read to keep working, because I thought the policy only stopped changes. The policy itself says otherwise:
```
$ aws iam get-policy-version --policy-arn arn:aws:iam::aws:policy/AWSCompromisedKeyQuarantineV3 --version-id v3 --query 'length(PolicyVersion.Document.Statement[0].Action)'
98
$ aws iam get-policy-version --policy-arn arn:aws:iam::aws:policy/AWSCompromisedKeyQuarantineV3 --version-id v3 --query 'PolicyVersion.Document.Statement[0].Action' --output text | tr '\t' '\n' | grep -iE '^(s3|sts|cloudtrail):' | sort | paste -sd' '
cloudtrail:LookupEvents s3:CreateBucket s3:DeleteBucket s3:DeleteBucketPolicy s3:DeleteObject s3:DeleteObjectVersion s3:GetObject s3:ListAllMyBuckets s3:ListBucket s3:ObjectOwnerOverrideToBucketOwner s3:PutAccountPublicAccessBlock s3:PutBucketAcl s3:PutBucketCors s3:PutBucketOwnershipControls s3:PutBucketPolicy s3:PutEncryptionConfiguration s3:PutLifecycleConfiguration sts:GetFederationToken sts:GetSessionToken
```
98 denied actions, and the S3 ones include reading objects and listing buckets. It also denies `sts:GetSessionToken`, so no new sessions, and `cloudtrail:LookupEvents`, so the attacker can't read the logs to see what I know. Because it's a deny, it applies to the session as well as the key. For this attacker it was already enough.

### 8. Cutting off the session
The quarantine policy only covers the actions on its list. To stop the session from doing anything at all, I added [revoke-sessions.json](policies/revoke-sessions.json) with the current time as the cutoff. It denies everything for credentials issued before that time:
```
$ CUTOFF=$(date -u +%FT%TZ); echo "cutoff $CUTOFF"
cutoff 2026-11-09T18:59:55Z
$ aws iam put-user-policy --user-name "$U" --policy-name revoke-sessions --policy-document "$(sed "s/CUTOFF/$CUTOFF/" policies/revoke-sessions.json)"
$ xs s3 ls
... is not authorized to perform: s3:ListAllMyBuckets with an explicit deny in an identity-based policy
$ xs s3 cp "s3://$B/backups/customers.csv" -
download failed: s3://<decoy bucket>/backups/customers.csv to - An error occurred (403) when calling the HeadObject operation: Forbidden
$ xs sts get-caller-identity --query Arn --output text
arn:aws:iam::123456789012:user/lab15-leaky
```
The error stopped naming a policy, I think because two policies deny it now. The [IAM docs on revoking sessions](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_use_revoke-sessions.html) explain `aws:TokenIssueTime`. The key only exists on temporary credentials, so this deny doesn't touch the user's normal access keys, only sessions older than the cutoff. A session made after the cutoff would get through, so this only works once the key that makes sessions is already off. `get-caller-identity` still answers, since it needs no permissions and can't be denied, but all it does is say who you are.

CloudTrail had the session's side of this:
```
$ trail Username lab15-leaky
...
2026-11-09T18:59:32Z  us-east-1  GetCallerIdentity  ok            ASIA...  203.0.113.10
2026-11-09T18:59:54Z  us-east-1  ListBuckets        AccessDenied  ASIA...  203.0.113.10
2026-11-09T19:00:17Z  us-east-1  ListBuckets        AccessDenied  ASIA...  203.0.113.10
```
The `GetCallerIdentity` at 18:59:32 is the session still working after the key was off. The `InvalidClientTokenId` call with the dead key isn't in this search. Neither of the denied `ListBuckets` sent an email, since they're read only.

### 9. Cleaning up
I deleted the key, cleared the variables and took off the two policies I had added by hand, so Terraform only had its own things to remove:
```
$ aws iam delete-access-key --user-name "$U" --access-key-id "$AK"
$ unset AK SK SAK SSK STOK
$ aws iam detach-user-policy --user-name "$U" --policy-arn arn:aws:iam::aws:policy/AWSCompromisedKeyQuarantineV3
$ aws iam delete-user-policy --user-name "$U" --policy-name revoke-sessions
```
```
Destroy complete! Resources: 5 destroyed.
```
```
users: Paolo-Admin
decoy bucket: 404 Not Found
lab 15 tagged resources: 0
```
Every step of my response sent its own `IAM change` email: `UpdateAccessKey`, `AttachUserPolicy`, `PutUserPolicy`, `DeleteAccessKey`, `DetachUserPolicy` and `DeleteUserPolicy`. The destroy sent `DeleteUserPolicy`, `DeleteUser` and a `DeleteLoginProfile`. That last one is odd, since the user never had a console password. My guess is that `force_destroy` tries to remove one just in case. So the alerts caught the defender a lot better than the attacker.

The cost stays under a cent by my estimate. IAM is free, and the decoy bucket held one 82 byte file for about 10 minutes.

## What Broke and How I Fixed It

**My alerts missed most of the attack.** I expected an email for each of the attacker's errors and got one for each write attempt only. The EventBridge metrics showed the rules were working and matching only what they get. Read only calls never reach a rule in the normal `ENABLED` state. Setting the rules to `ENABLED_WITH_ALL_CLOUDTRAIL_MANAGEMENT_EVENTS` should fix that, but then every failed `List` or `Describe` in the account sends an email. I haven't changed lab 02 yet. I'd want to narrow the access denied rule to IAM users first.

**The theft left no record.** The two reads of the customer file aren't anywhere in CloudTrail, because object reads are data events and my trail only records management events. Turning on data events for one sensitive bucket would cover it. Doing it for every bucket costs more, and I didn't turn it on for this lab.

**I got the quarantine policy wrong at first.** I assumed it only blocked changes. `s3 cp` only said `Forbidden` again, because it calls `HeadObject` first, which returns no reason. Reading the policy document settled it, with `s3:GetObject` on the list. The `s3 ls` error was the more useful one, since it named the policy.
