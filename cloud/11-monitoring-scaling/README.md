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
