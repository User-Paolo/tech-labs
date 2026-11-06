# 11 Monitoring and Scaling

**Track:** Cloud
**Exam topics:** AWS Cloud Practitioner, Cloud Technology (CloudWatch metrics, alarms and dashboards, SNS, EC2 Auto Scaling policies, VPC flow logs, Service Quotas) and Cloud Concepts (elasticity)

## Question
The review in [lab 10](../10-well-architected/) found that my Auto Scaling group never scaled for load and that nobody gets told when something breaks. Can I fix both on the same setup? If I send it more traffic, does it really add instances and remove them again later? And when an instance breaks, does an email reach me without me watching curl?

## Setup
[Lab 07](../07-alb-autoscaling/) again, in Terraform from CloudShell in `us-east-1`, with monitoring and logs added on top.

```
                 my IP only, port 80
                         |
              Application Load Balancer ---- access logs ---> S3
           public a  10.0.1.0/24 | public b  10.0.2.0/24
                         |
             Auto Scaling group, 2 to 4 instances
          private a  10.0.11.0/24 | private b  10.0.12.0/24
                         |
            NAT gateway in public a, for the SSM agent

VPC flow logs ---> S3
CloudWatch alarms ---> SNS ---> my email
```

| File | What's in it |
|---|---|
| [versions.tf](versions.tf), [network.tf](network.tf), [security.tf](security.tf), [web.sh.tftpl](web.sh.tftpl) | Same as lab 07 with new names |
| [variables.tf](variables.tf) | Lab 07's plus `alert_email` and `requests_per_target` |
| [alb.tf](alb.tf) | Lab 07's load balancer with access logs turned on |
| [asg.tf](asg.tf) | Lab 07's group plus a scaling policy and group metrics |
| [monitoring.tf](monitoring.tf) | The SNS topic and email, 3 alarms and the dashboard |
| [logs.tf](logs.tf) | The logs bucket, its policy and the VPC flow log |
| [outputs.tf](outputs.tf) | Lab 07's outputs plus the bucket name |

The scaling policy is target tracking on `ALBRequestCountPerTarget`, aiming for 100 requests per instance per minute. I went with requests over CPU because only my IP can reach the load balancer, so the traffic has to come from my PC, and a small loop from there can get past 100 a minute more easily than it can load up a CPU.

The 3 alarms are for an unhealthy instance, more than 5 load balancer errors in a minute, and an average response time over a second for 2 minutes.

My email goes in through `TF_VAR_alert_email` and my IP through `TF_VAR_my_ip`, so neither ends up in a file. The logs expire after 7 days, and `force_destroy` lets `terraform destroy` delete the bucket with logs still in it.

Cost: about $0.10 an hour while it's up, going by the lab 07 prices in [lab 08](../08-billing-and-costs/), plus a little for extra instances and logs. Under $1 if I destroy it the same day.

## Steps and Evidence

My home IP is replaced with `203.0.113.10`, the account ID with `123456789012` and my email with `you@example.com` everywhere below. The PowerShell times are my PC's clock, which is UTC+2 now, so 23:15 there is 21:15 UTC in CloudShell.

### 1. Building it
Same routine as lab 07:
```
$ export PATH=$HOME/bin:$PATH TF_DATA_DIR=/tmp/lab11-tf TF_VAR_my_ip=203.0.113.10 TF_VAR_alert_email=you@example.com
$ cd ~/tech-labs/cloud/11-monitoring-scaling && terraform init
$ terraform plan -no-color | grep -E 'Plan:|Error'
Plan: 43 to add, 0 to change, 0 to destroy.
$ terraform apply
Apply complete! Resources: 43 added, 0 changed, 0 destroyed.
```
Lab 07's 31 resources plus 12 new ones. It worked on the first try this time, the service linked role from lab 07 is still there.

Two kinds of email showed up while it ran. One was the SNS confirmation, the alarm emails don't start until I click the link in it. The others were from [lab 02](../02-security-alerts/), which sent an `IAM change` email for each of `CreateRole`, `CreateInstanceProfile`, `AttachRolePolicy` and `AddRoleToInstanceProfile`, all from my own user. That's Terraform making the Session Manager role, and it's good to see those alerts still work.

### 2. Quotas
Lab 10 pointed out that I had never looked at one. The group can go up to 4 `t3.micro` instances, which is 8 vCPUs.
```
$ for q in "ec2 L-1216C47A" "ec2 L-0263D0A3" "elasticloadbalancing L-53DA6B97" "autoscaling L-CDE20ADC" "vpc L-F678F1CE" "vpc L-FE5A380F"; do set -- $q; aws service-quotas get-service-quota --service-code "$1" --quota-code "$2" --query 'Quota.[QuotaName,Value]' --output text; done
Running On-Demand Standard (A, C, D, H, I, M, R, T, Z) instances        16.0
EC2-VPC Elastic IPs     5.0
Application Load Balancers per Region   50.0
Auto Scaling groups per region  500.0
VPCs per Region 5.0
NAT gateways per Availability Zone      5.0
```
The vCPU one was the one I wanted to see, and 16 is plenty for this.

### 3. Does an email reach me when something breaks?
Same break as test A in lab 07, killing the web server on one instance. A curl loop ran from PowerShell at about one request a second, which is far below the scaling target, and this watcher ran in CloudShell:
```
$ aws ssm send-command --instance-ids i-032c313b6f2b83d91 --document-name AWS-RunShellScript --parameters 'commands=["pkill -f http.server"]' --query Command.CommandId --output text
$ watch_alarms
21:15:58 lab11-errors OK lab11-unhealthy OK  | healthy healthy
21:16:30 lab11-errors OK lab11-unhealthy OK  | healthy unhealthy
21:17:01 lab11-errors OK lab11-unhealthy OK  | healthy unhealthy
21:17:33 lab11-errors OK lab11-unhealthy OK  | healthy draining
21:18:04 lab11-errors OK lab11-unhealthy OK  | healthy healthy
21:18:36 lab11-errors OK lab11-unhealthy OK  | healthy healthy
21:19:07 lab11-errors OK lab11-unhealthy ALARM  | healthy healthy
21:19:39 lab11-errors OK lab11-unhealthy ALARM  | healthy healthy
21:20:10 lab11-errors OK lab11-unhealthy OK  | healthy healthy
```
The history from the group and the alarms:
```
$ aws autoscaling describe-scaling-activities --auto-scaling-group-name lab11-web --max-items 2 --query 'Activities[].[StartTime,Description]' --output text
2026-11-06T21:17:17.909000+00:00        Launching a new EC2 instance: i-03f6362b229ae3f4c
2026-11-06T21:17:15.882000+00:00        Terminating EC2 instance: i-032c313b6f2b83d91
$ aws cloudwatch describe-alarm-history --alarm-name lab11-unhealthy --history-item-type StateUpdate --query 'AlarmHistoryItems[].[Timestamp,HistorySummary]' --output text
2026-11-06T21:20:05.648000+00:00        Alarm updated from ALARM to OK
2026-11-06T21:19:05.642000+00:00        Alarm updated from OK to ALARM
2026-11-06T21:14:05.646000+00:00        Alarm updated from INSUFFICIENT_DATA to OK
```
The first email I got from each alarm was at 21:14, from `INSUFFICIENT_DATA` to `OK`, right after building it. That's only the alarm starting up and has nothing to do with the test.

| UTC | What happened |
|---|---|
| 21:15:56 | I kill the web server, the 502s start |
| 21:16:11 | The last 502, the load balancer has stopped using that instance |
| 21:17:15 | The group terminates the instance, because of the failed health check |
| 21:17:17 | The group launches a replacement |
| 21:17:36 | The replacement `ip-10-0-11-138` answers for the first time |
| 21:19:05 | `lab11-unhealthy` goes to `ALARM` and the email arrives |
| 21:20:05 | Back to `OK`, with another email |

So the email works, but it came 3 minutes and 9 seconds after the break, and about a minute and a half after the replacement was already answering. By the time I read "an instance is failing", nothing was failing anymore. The email itself says it's reacting to an old datapoint:
```
Threshold Crossed: 1 datapoint [1.0 (06/11/26 21:16:00)] was greater than the threshold (0.0).
```
The metric was for 21:16:00 and the alarm changed at 21:19:05. I don't know exactly where those 3 minutes go. My guess is that most of it is the load balancer's metrics reaching CloudWatch late. So this alarm is more of a record that something happened than a warning I can act on. For one failed instance that's fine since the group handles it by itself.

**`lab11-errors` never fired.** Its only history entry is the start up at 21:14. My curl loop saw 7 errors, but 2 of them fell in the 21:15 minute and 5 in the 21:16 minute. The alarm needs more than 5 in one minute, so it just missed. With about one request a second, half of them failing for 15 seconds can't really reach that. The threshold would have to be lower for traffic this small.

**The 3.5 minutes from lab 07.** There, an instance with a dead web server took 3.5 minutes to get replaced. My guess was that the group was busy with the other instance I had terminated. This time I only broke one, and the group terminated it 1 minute 19 seconds after the kill. That fits my guess, though it's only one run.

### 4. Load test, going up
From PowerShell, 5 requests at a time with the output thrown away:
```
PS> curl.exe -s -Z --parallel-immediate --parallel-max 5 -m 5 "http://lab11-alb-2020219417.us-east-1.elb.amazonaws.com/?n=[1-100000]" > $null
```
A watcher in CloudShell, showing the group's desired and running instances and the two alarms AWS made for the scaling policy:
```
$ watch_scale
21:25:53 desired/inservice 2/2 | high/low OK/INSUFFICIENT_DATA | slow OK
21:29:06 desired/inservice 2/2 | high/low OK/INSUFFICIENT_DATA | slow OK
21:29:38 desired/inservice 2/2 | high/low OK/OK | slow OK
21:31:15 desired/inservice 2/2 | high/low OK/OK | slow OK
21:31:48 desired/inservice 4/4 | high/low ALARM/OK | slow OK
21:37:45 desired/inservice 4/4 | high/low ALARM/OK | slow OK
```
I never made those two alarms, target tracking creates them by itself. Their limits:
```
$ aws cloudwatch describe-alarms --alarm-name-prefix TargetTracking-lab11-web --query 'MetricAlarms[].[AlarmName,Threshold,EvaluationPeriods]' --output text
TargetTracking-lab11-web-AlarmHigh-e9f9037b-7d03-4871-9884-7e865496c001 100.0   3
TargetTracking-lab11-web-AlarmLow-e34c156b-e086-4673-b1fa-cdc4939661ea  75.0    15
```
So above 100 for 3 minutes to scale out, and below 75 for 15 minutes to scale in. Why it fired:
```
$ aws autoscaling describe-scaling-activities --auto-scaling-group-name lab11-web --max-items 2 --query 'Activities[].[StartTime,Description,Cause]' --output text
2026-11-06T21:31:33.617000+00:00  Launching a new EC2 instance: i-0001522e7200d41c5  At 2026-11-06T21:31:28Z a monitor alarm TargetTracking-lab11-web-AlarmHigh-e9f9037b-7d03-4871-9884-7e865496c001 in state ALARM triggered policy lab11-requests-per-target changing the desired capacity from 2 to 4.
```
The traffic started at 21:26 and the alarm fired at 21:31:28, so a bit over 5 minutes. 3 of those are the alarm's own rule, and the rest looks like the same metric delay as step 3. It then launched both new instances straight away. It went from 2 to 4 in one step, I think because at about 1000 requests per instance it wanted far more than my maximum of 4. All four answered:
```
PS> 1..16 | % { curl.exe -s -m 5 http://lab11-alb-2020219417.us-east-1.elb.amazonaws.com }
<h1>lab11 v1 ip-10-0-12-123 us-east-1b</h1>
<h1>lab11 v1 ip-10-0-11-138 us-east-1a</h1>
<h1>lab11 v1 ip-10-0-11-108 us-east-1a</h1>
<h1>lab11 v1 ip-10-0-12-161 us-east-1b</h1>
```
That's the fix for the biggest finding from lab 10, the group now adds instances for load.

To be honest about the target though, the two instances were nowhere near struggling. Going by the logs in the next step, they did about 2000 requests a minute with the instance taking about 0.0015 seconds per request, and `lab11-slow` never fired. I set 100 so low so that a small test from my PC could trigger it. On a real system that number should come from load testing, and I'd be paying for two extra instances here that I didn't need.

### 5. What the logs show
Load balancer access logs land in S3 about every 5 minutes. To read them I copied them to CloudShell and counted, with `$9` being the status code, `$2` the time and `$7` the time the instance took:
```
$ zcat $A | awk '{print $9}' | sort | uniq -c
  13154 200
      1 460
      7 502
$ zcat $A | awk '$9==502 {print substr($2,1,16)}' | sort | uniq -c
      2 2026-11-06T21:15
      5 2026-11-06T21:16
$ zcat $A | awk '{m=substr($2,1,16); n[m]++; t[m]+=$7} END {for (k in n) printf "%s %d requests, target %.4f s\n", k, n[k], t[k]/n[k]}' | sort
2026-11-06T21:26 1837 requests, target 0.0013 s
2026-11-06T21:27 1952 requests, target 0.0015 s
2026-11-06T21:28 2040 requests, target 0.0015 s
2026-11-06T21:29 1979 requests, target 0.0013 s
2026-11-06T21:30 667 requests, target 0.0017 s
2026-11-06T21:31 975 requests, target 0.0016 s
2026-11-06T21:32 1316 requests, target 0.0014 s
2026-11-06T21:33 1114 requests, target 0.0017 s
2026-11-06T21:34 549 requests, target 0.0016 s
2026-11-06T21:36 31 requests, target -0.0303 s
```
The 7 errors match what curl showed me in step 3, 2 and 5, so `lab11-errors` really did miss by one.

The drop at 21:30 got me for a while. The traffic fell to a third before any new instance existed, but the instances didn't get any slower. A little later my gentle one a second loop started getting timeouts as well, while every instance stayed healthy. I'm on university WiFi with a lot of people on it, so I think the slowdown was on my side and the load balancer just received less. I can't prove that, but nothing in these logs points at AWS.

The one `460` is the negative number at 21:36. That code means the client gave up before getting an answer, which was curl hitting its time limit, and the log puts `-1` as the instance time for it.

The WiFi also makes "my IP only" weaker than it sounds. If everyone there shares one public address, the load balancer is open to all of them too.

The VPC flow logs were more of a surprise. The network was about 25 minutes old at this point:
```
$ zcat $F | awk '$13=="ACCEPT" || $13=="REJECT" {print $13}' | sort | uniq -c
  48434 ACCEPT
    661 REJECT
$ zcat $F | awk '$13=="REJECT" {print $4}' | sort -u | wc -l
496
$ zcat $F | awk '$13=="REJECT" {print $7}' | sort -u | wc -l
537
$ zcat $F | awk '$13=="REJECT" {print $7}' | sort | uniq -c | sort -rn | head -5
     26 443
      7 110
      6 98
      6 80
      6 0
```
661 rejected records from 496 different addresses on 537 different ports. Nobody knows about this network and I only gave the URL to myself. My guess is that these are scanners going through public IP addresses, and they found the ones on the load balancer and the NAT gateway. The security groups stopped them, which is why they show up as `REJECT`. I knew this happens but I didn't expect to see it within half an hour. Lab 07 probably got the same and I had no way of seeing it.
