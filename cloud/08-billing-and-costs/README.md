# 08 My Own AWS Bill

**Track:** Cloud
**Exam topics:** AWS Cloud Practitioner, Billing, Pricing and Support (Free plan credits, Cost Explorer, cost allocation tags, AWS Budgets, Cost Anomaly Detection, IAM access to billing data)

## Question
Seven labs in and I've never paid anything, because the Free plan credits soak it all up. So what did those labs actually cost? And if something started costing real money, would I notice in time, or would the credits hide it until they ran out?

## Setup
No new infrastructure this time. It's my own account's billing data from labs 01 to 07, looked at mostly in the Billing and Cost Management console, plus a few CloudShell commands for tags.

Cost: $0. The Cost Explorer console is free, the first two budgets are free and Cost Anomaly Detection is free. The Cost Explorer API is $0.01 per request, so I stuck to the console for it.

The account ID is replaced with `123456789012` everywhere below.

## Steps and Evidence

### 1. The Free plan and the credits
![Free plan status](images/free-plan-status.png)

$199.43 left out of $200 and 150 days to go, so the Free plan runs until 21 March 2027 or until the credits are gone, whichever comes first. The banner on the billing home page says a Free plan account doesn't get charged, and that matches what I wrote in lab 01. AWS can't bill me past the credits unless I upgrade the plan myself.

![Credits](images/credits.png)

The credits page has two numbers, "used" at $0.00 and "estimated used" at $0.57. The first one only moves when a month's bill is finalized, the second one updates about once a day. Five of the credits are $20 each for the "Explore AWS" activities I did in training, setting up a budget, launching an instance, making an RDS database, a Lambda web app and trying the Bedrock playground. The sixth one is on the second page.

### 2. What the labs actually cost
Cost Explorer, 1 to 23 October, daily, grouped by service, with the charge type filter set to exclude `Credit`. Without that filter every day nets out to about zero, because the credits cancel the costs.

![Cost by service, credits excluded](images/cost-by-service.png)

| Day | What ran | About |
|---|---|---|
| 14 Oct | Bedrock, the "Explore AWS" activity | $0.01 |
| 19 Oct | S3, lab 04 | $0.01 |
| 20 Oct | Lab 05, the VPC by hand with a NAT gateway | $0.21 |
| 21 Oct | Lab 06, the same VPC in Terraform | $0.12 |
| 22 Oct | Lab 07, load balancer and Auto Scaling | $0.20 |

That adds up to the $0.57 on the credits page. Three things I noticed:

- The biggest part every day is **EC2-Other**. That's not the instances, it's the NAT gateway plus the EBS volumes. The volumes were 8 GB each for a few hours, so my guess is nearly all of it is the NAT gateway. Part 2 splits it by usage type to check.
- **EC2-Instances isn't zero.** The new Free plan doesn't have the old 750 free hours of t3.micro a month, everything just comes out of the credits.
- **VPC** on lab days is the public IPv4 addresses, $0.005 an hour each. **Elastic Load Balancing** only shows up on the 22nd, for lab 07.

Labs 01 to 03 don't show up at all. IAM, CloudTrail's first trail, EventBridge rules, SNS emails and CloudFront traffic this small are all free.

### 3. Tags that show up on the bill
Labs 05 to 07 tagged everything with `Lab`. Under Cost allocation tags in the billing console I activated `Lab` as a user defined cost allocation tag, so Cost Explorer can group costs by it. It only counts costs from the moment it's activated and takes up to a day to show up, so the result is in part 2.

Labs 02 and 03 are still running and had no tags, so I added them. S3 replaces a bucket's whole tag set when you set tags, so I checked first that there was nothing to lose:
```
$ ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
$ TRAIL_BUCKET=$(aws cloudtrail describe-trails --query 'trailList[0].S3BucketName' --output text)
$ TRAIL_ARN=$(aws cloudtrail describe-trails --query 'trailList[0].TrailARN' --output text)
$ aws s3api get-bucket-tagging --bucket lab03-site-9b14af 2>&1 | tail -3
aws: [ERROR]: An error occurred (NoSuchTagSet) when calling the GetBucketTagging operation: The TagSet does not exist
$ aws s3api get-bucket-tagging --bucket $TRAIL_BUCKET 2>&1 | tail -3
aws: [ERROR]: An error occurred (NoSuchTagSet) when calling the GetBucketTagging operation: The TagSet does not exist
$ aws s3api put-bucket-tagging --bucket lab03-site-9b14af --tagging 'TagSet=[{Key=Lab,Value=03}]'
$ aws cloudfront tag-resource --resource arn:aws:cloudfront::$ACCOUNT:distribution/EDFDVBD6EXAMPLE --tags 'Items=[{Key=Lab,Value=03}]'
$ aws s3api put-bucket-tagging --bucket $TRAIL_BUCKET --tagging 'TagSet=[{Key=Lab,Value=02}]'
$ aws sns tag-resource --resource-arn arn:aws:sns:us-east-1:$ACCOUNT:security-alerts --tags Key=Lab,Value=02
$ aws cloudtrail add-tags --resource-id $TRAIL_ARN --tags-list Key=Lab,Value=02
$ aws resourcegroupstaggingapi get-resources --tag-filters Key=Lab --query 'ResourceTagMappingList[].[ResourceARN,Tags[?Key==`Lab`]|[0].Value]' --output text
arn:aws:s3:::cloudtrail-logs-48213      02
arn:aws:sns:us-east-1:123456789012:security-alerts      02
arn:aws:cloudfront::123456789012:distribution/EDFDVBD6EXAMPLE    03
arn:aws:s3:::lab03-site-9b14af  03
arn:aws:cloudtrail:us-east-1:123456789012:trail/management-events       02
```
Four different services and every service tags things its own way, but the Resource Groups Tagging API lists them all in one go. CloudFront is global and still shows up from `us-east-1`.

### 4. A budget that doesn't count credits
In lab 01 I found that my $1 training budget counts credits, so it sits at $0 and can never fire. I left that one alone and made a second one next to it:

| Setting | What I picked |
|---|---|
| Name | `real-usage` |
| Type | Cost budget, monthly, recurring, fixed $5 |
| Scope | All AWS services |
| Aggregate costs by | Unblended costs |
| Charge types | Credits and refunds not included |
| Alert 1 | Actual costs over 50%, so $2.50 |
| Alert 2 | Forecasted costs over 100% |

Leaving credits out is the whole point. Now it tracks what my usage would cost without the Free plan, which is the number I actually care about once the credits run out. A forecast alert can fire before anything has been spent, if a lab leaves something running and the month's projection goes over $5.

### 5. Cost Anomaly Detection
I was going to make a monitor, but the billing home page already said "1 monitor(s) active". Either AWS made it for the new account or I clicked through it in training, I honestly don't remember. It watches spending per service and flags anything unusual, without me having to pick a number like a budget needs.

## What Broke and How I Fixed It

**My admin user couldn't see the bill.** Every number on the billing home page said Access denied, even though `Paolo-Admin` has `AdministratorAccess`. By default only the root user can see billing data, and IAM users and roles only get in after the root user turns on "IAM user and role access to Billing information" under Account. Their policies still decide what each one can do after that, but without the switch even a full admin gets nothing. So I signed in as root once, turned it on, and signed straight back out.

Lab 02 noticed. Two root alerts came in, a minute and a half apart:
```
"Root user activity"
"What: ConsoleLogin on signin.amazonaws.com"
"When: 2026-10-23T16:46:18Z"
"MFA used: Yes"

"Root user activity"
"What: SetIAMAccessPreference on billingconsole.amazonaws.com"
"When: 2026-10-23T16:48:52Z"
"MFA used: "
```
The second one has an empty MFA field. That's not a problem with the sign in, AWS only fills in that field for console logins and not for anything done afterwards.
