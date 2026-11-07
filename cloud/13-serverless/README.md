# 13 Serverless

**Track:** Cloud
**Exam topics:** AWS Cloud Practitioner, Cloud Technology (Lambda, API Gateway, DynamoDB) and Billing and Pricing (paying per request against paying per hour)

## Question
[Lab 07](../07-alb-autoscaling/) serves one small page with a load balancer, a NAT gateway and at least 2 instances, and all of that bills by the hour even when nobody is visiting. Could the same page run with no servers at all? What would it cost at the same traffic, and what do I give up? The part I keep reading about is cold starts, so I want to measure those instead of just repeating the term.

## Setup
A Lambda function behind API Gateway, with a DynamoDB table holding a visit counter, in Terraform from CloudShell in `us-east-1`.

```
        anyone with the URL
                |
       API Gateway (HTTP API), limited to 100 requests a second
                |
        Lambda function, 128 MB
           |            |
    DynamoDB table   CloudWatch logs
```

There's no VPC this time, so there are no subnets, security groups or NAT gateway.

| File | What's in it |
|---|---|
| [app/app.py](app/app.py) | The function. It adds 1 to the counter and returns the visit count, the page version and whether this was a cold start |
| [function.tf](function.tf) | The function, its table, its log group and a role that can only update that table and write to that log group |
| [api.tf](api.tf) | The API, the rate limit and the access logs |
| [variables.tf](variables.tf) | `page_version`, so I can deploy a change |

The function also has two routes that are only for testing. `/slow` waits a second before answering and `/boom` throws an error.

Cost: nothing bills by the hour here, so it should cost nothing while idle apart from a little storage. The prices for one request:
```
0.0000002000    Requests            AWS Lambda - Total Requests for ARM
0.0000133334    Lambda-GB-Second    AWS Lambda - Total Compute for ARM, Tier-1
0.0000010000    Requests            $1/million requests - API Gateway HTTP API
0.0000006250    WriteRequestUnits   $0.625 per million write request units
```
That's about $1.86 per million requests if each one takes about 20 milliseconds. I don't know the real duration yet. The load test should use a few hundred thousand requests at most, so I expect well under $1 in total.

## Steps and Evidence

### 1. Is it allowed on the Free plan?
Same check as the last few labs:
```
$ aws lambda list-functions --query 'length(Functions)'
0
$ aws apigatewayv2 get-apis --query 'length(Items)'
0
$ aws dynamodb list-tables --query 'length(TableNames)'
0
$ aws lambda get-account-settings --query 'AccountLimit.{Total:ConcurrentExecutions,Unreserved:UnreservedConcurrentExecutions}' --output table
| Total | Unreserved |
|  10   |  10        |
$ aws service-quotas get-aws-default-service-quota --service-code lambda --quota-code L-B99A9384 --query 'Quota.{Name:QuotaName,Default:Value}' --output table
| Default |        Name          |
| 1000.0  | Concurrent executions |
```
All the services open, but this account can only run 10 copies of a function at the same time, and the normal default is 1000. A fast function might never reach that. The `/slow` route should reach it easily under load, so I can see what happens to the requests that don't fit.

### 2. How I set it up
The URL is public this time. In lab 07 I could limit the load balancer to my IP with a security group, but this type of API has no security group and restricting it would need other services. So I capped it at 100 requests a second on the stage instead, which limits what a stray scanner could cost me.

The function runs on ARM because it's cheaper per second than x86. Its role only has `dynamodb:UpdateItem` on this table, plus writing to its own log group, so I didn't use the usual managed policy for Lambda.

The function reports a cold start by keeping a variable that starts as true and flips after the first request. Anything at the top of [app.py](app/app.py) only runs when a new copy starts up, so the first request that copy handles is the cold one.
