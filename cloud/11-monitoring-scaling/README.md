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
