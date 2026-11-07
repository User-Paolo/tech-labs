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
| [load.sh](load.sh), [even.sh](even.sh), [sum.sh](sum.sh) | The load tests and the script that sums up their results |

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

### 3. Deploying it
The first apply stopped at the stage:
```
BadRequestException: The following errors are found in Access Log Format: Access Log format must include
either $context.requestId or $context.extendedRequestId
```
I added `$context.requestId` to the log format and the second apply finished, with only the missing resource left to create. Nothing else had gone wrong.

### 4. Cold starts
Changing a function's settings makes Lambda start new copies, so I can force a cold start whenever I want. I did that 5 times, with 5 requests after each change:
```
{"page": "cold1", "visits": 1, "cold": true} 1.013993s
{"page": "cold1", "visits": 2, "cold": false} 0.082350s
{"page": "cold1", "visits": 3, "cold": false} 0.087105s
{"page": "cold1", "visits": 4, "cold": false} 0.054246s
{"page": "cold1", "visits": 5, "cold": false} 0.121311s
```
All 5 rounds looked like this. Cold requests took 0.79 to 1.06 seconds and warm ones 0.045 to 0.12 seconds, so about 10 times longer for the first request. That time includes the network from CloudShell, so I also pulled Lambda's own numbers out of the logs:

| | Handler | Startup (`Init Duration`) | Billed |
|---|---|---|---|
| Cold, 5 requests | 287 to 329 ms | 373 to 518 ms | 668 to 848 ms |
| Warm, 20 requests | 8 to 44 ms | None | 8 to 44 ms |

Two things I didn't know before this. The startup is billed, since the first request billed 791 ms from 310 ms in the handler and 480 ms of startup. The handler is also about 10 times slower on a cold start, even though it's running the same code. My guess is the first connection to DynamoDB, but I didn't measure that part on its own.

It used 92 MB of memory out of the 128 MB I gave it.

### 5. The same traffic as lab 11
In [lab 11](../11-monitoring-scaling/) I sent about 2000 requests a minute to make the group scale. I sent the same here with a small script that starts 33 `curl`s at once, once a second, for 5 minutes. I expected this to be easy for it:
```
$ bash ~/load.sh 33 300 "" > /tmp/fast.log
$ bash ~/sum.sh /tmp/fast.log
   9010 200
    890 503
requests 9900 p50 0.430229 p95 0.596837 p99 0.676310 max 1.316210
```
9% of the requests failed. The rest were much slower than the 0.05 seconds I got in step 4. The access logs explain the failures:
```
   9010 200
    890 503     The Lambda function is being throttled. Try again later.
```
And CloudWatch agrees, with 888 throttles and the same peak in every minute of the test:
```
--- Throttles (Sum)
20:40 93 20:41 195 20:42 202 20:43 167 20:44 124 20:45 86 20:46 21
--- ConcurrentExecutions (Maximum)
20:40 10 20:41 10 20:42 10 20:43 10 20:44 10 20:45 10 20:46 10
```
That's the limit of 10 from step 1. It confused me at first, because the average should be nowhere near it. About 29 requests a second at about 29 ms each only needs about 1 copy on average. But my script starts them all in the same instant, so for a moment each second it needs far more than 10 copies, and the ones that don't fit are refused straight away. They don't wait in a queue.

The slow timings turned out to be mostly CloudShell. API Gateway measured a median of 28 ms for the successful requests, and a p95 of 46 ms. So most of the 0.43 seconds seems to come from CloudShell starting 33 `curl`s at the same time.

### 6. The same rate, spread out
If the bursts are the problem, the same traffic spread evenly should be fine. So I sent one request about every 0.03 seconds instead:
```
$ bash ~/even.sh 33 180 "" > /tmp/even.log
$ bash ~/sum.sh /tmp/even.log
   5940 200
requests 5940 p50 0.043572 p95 0.062882 p99 0.083295 max 0.355754
```
5940 out of 5940. It came to about 30 requests a second against about 29 in the burst test, so the rate was close and the difference is how the requests arrive. The median was also back to 0.044 seconds.

So this account can take that average rate, and a sudden burst is what hurts it. I don't know how bursty my traffic was in lab 11, so I can't say lab 07 would have handled this exact pattern better. The normal default of 1000 wouldn't have had this problem at all, so this comes from my account's limit of 10.

### 7. A slow function, and a broken one
Bursts aren't the only way to reach the limit. `/slow` takes a second per request, so at about 30 requests a second it needs about 30 copies, even when they're spread out:
```
$ bash ~/even.sh 33 60 slow > /tmp/slow.log
$ bash ~/sum.sh /tmp/slow.log
    619 200
   1361 503
requests 1980 p50 0.024497 p95 1.054129 p99 1.063527 max 1.996273
```
Only 31% got through. It ran for 66 seconds, so that's about 9.4 a second, which fits 10 copies that each take a second. The median of 0.024 seconds looks great, but that's just how quickly the rejected ones came back. So duration matters as much as traffic here, and it's easy to miss in the average numbers.

For the code crashing, I called `/boom`. The caller gets a generic message, and the real error only goes to the logs:
```
$ curl -s -i "${URL}boom" | sed -n '1p;$p'
HTTP/2 500
{"message":"Internal Server Error"}
```
```
[ERROR] RuntimeError: broken on purpose
Traceback (most recent call last):
  File "/var/task/app.py", line 17, in handler
    raise RuntimeError("broken on purpose")
```

### 8. Deploying with traffic running
In lab 07 a new version took a rolling update that replaced the instances over several minutes. Here I changed `page_version` to `v2` while another tab sent about 3 requests a second:
```
$ awk '{print $3, $NF}' /tmp/deploy.log | uniq -c
    216 "cold5", 200
    178 "v2", 200
$ grep -c '"cold": true' /tmp/deploy.log
1
```
216 requests on the old version, then 178 on the new one, all `200`. They didn't mix back and forth, and it took 1 cold start. I wouldn't call that proof for a busy function, but at this traffic the deploy was invisible.

The counter was a nice check on all of this. Adding up every `200` before the deploy test finished gives 25 + 9010 + 5940 + 619 + 216 = 15810, and the first `v2` response said `"visits": 15811`. So every request that returned `200` was counted once.

### 9. What it would cost
I measured what one request uses instead of guessing. Over the whole lab there were 15964 invocations, 15963 DynamoDB write units and about 500 bytes of logs per request. The logs were the part I had left out of my estimate.

| Per million requests | |
|---|---|
| API Gateway | $1.00 |
| DynamoDB, 1 write unit per request | $0.625 |
| CloudWatch logs, about 0.5 GB at $0.50 per GB | $0.25 |
| Lambda requests | $0.20 |
| Lambda compute, 128 MB at 29 ms | $0.05 |
| **Total** | **About $2.12** |

In [lab 08](../08-billing-and-costs/) the Pricing Calculator put the lab 07 setup at $69.43 a month, whatever the traffic. So this is the comparison, if the traffic stayed steady for the whole month:

| Traffic | Serverless | Lab 07 setup |
|---|---|---|
| Nothing | About $0 | $69.43 |
| 1000 visits a day | About $0.06 | $69.43 |
| About 750 requests a minute | About $69 | $69.43 |
| 2000 requests a minute | About $186 | $69.43, plus the extra instances and load balancer usage, which I didn't price |

I expected serverless to be cheaper, and it's only cheaper up to about 750 requests a minute. Above that, the servers I pay for by the hour start to look better. This leaves out any free tier, and a plain static page wouldn't need the DynamoDB write. All the requests in this lab should come to about 4 cents.

So back to the question. Yes, the page runs fine with no servers, it costs nothing while idle and deploys cleanly. What I give up:

- The first request after a quiet period or a deploy takes about a second, about 10 times longer than normal.
- I can't limit the URL to my IP the way I did in lab 07 without adding other services.
- Requests over the concurrency limit are refused and don't wait, which matters a lot on an account limited to 10.
- It gets expensive under steady heavy traffic.

### 10. Cleaning up
```
Destroy complete! Resources: 11 destroyed.
```
```
functions: 0
apis: 0
tables: 0
log groups: 0
roles: 0
old url: 000
```
The limit of 10 is one I need to remember for the final project. Anything built on Lambda in this account has to stay under it, or I'd have to request an increase.

## What Broke and How I Fixed It

**The first apply stopped at the stage.** API Gateway requires a request ID in the access log format, and mine didn't have one. Adding `$context.requestId` fixed it, and Terraform only had to create what was missing.

**9% of the requests failed in a test I expected to pass.** The average rate was far below the limit, so at first the `503`s made no sense. The access logs, `Throttles` and `ConcurrentExecutions` all pointed at the limit of 10, and spreading out the same rate in step 6 confirmed that my bursts were the cause.

**The load test timings were misleading.** The median of 0.43 seconds in step 5 looked like the function being slow, but API Gateway measured 28 ms. Most of that time seems to be CloudShell starting 33 `curl`s at once, so I now compare the client side timings with the server side ones.
