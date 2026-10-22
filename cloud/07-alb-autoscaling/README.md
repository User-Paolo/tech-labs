# 07 Load Balancer and Auto Scaling

**Track:** Cloud
**Exam topics:** AWS Cloud Practitioner, Cloud Technology (Elastic Load Balancing, EC2 Auto Scaling, launch templates, Availability Zones, high availability) and Security and Compliance (security groups that reference each other, private instances, Session Manager)

## Question
In labs 05 and 06 the web server was one instance with its own public IP. If it died, the site died with it. Can I put a load balancer in front of a group of instances that replaces broken ones by itself? And can I roll out a new version of the page without the site going down while it happens?

## Setup
The network from [lab 06](../06-vpc-terraform/), in Terraform again, run from CloudShell in `us-east-1`. This time nothing has a public IP except the load balancer and the NAT gateway.

```
                 my IP only, port 80
                         |
              Application Load Balancer
           public a  10.0.1.0/24 | public b  10.0.2.0/24
                         |
             Auto Scaling group, 2 instances
          private a  10.0.11.0/24 | private b  10.0.12.0/24
                         |
            NAT gateway in public a, for the SSM agent
```

| File | What's in it |
|---|---|
| [versions.tf](versions.tf) | Same as lab 06 with a `Lab=07` tag |
| [variables.tf](variables.tf) | `my_ip`, and `page_version` which is printed on the page |
| [network.tf](network.tf) | The lab 06 network without public IPs on any subnet and without the NACL switch |
| [security.tf](security.tf) | Security groups for the load balancer and the instances, the locked default group and the Session Manager role |
| [alb.tf](alb.tf) | The load balancer, its target group with the health check and a listener on port 80 |
| [asg.tf](asg.tf) | A launch template and the Auto Scaling group that uses it |
| [outputs.tf](outputs.tf) | The load balancer's URL, the group's name and the target group |
| [web.sh.tftpl](web.sh.tftpl) | The user data, now showing the version, the instance and its AZ |

The load balancer lets in port 80 from my IP only. The instances let in port 80 from the load balancer's security group only, so the load balancer is the only way to reach them. They sit in the two private subnets, one per AZ, and I still get onto them with Session Manager.

The launch template is the recipe for an instance. The Auto Scaling group keeps 2 of them running, spread over both AZs, and registers each one with the load balancer's target group. The load balancer checks `/` on every instance every 10 seconds, and the group uses those checks too, so an instance the load balancer gives up on gets replaced.

`page_version` is there for the last test. Changing it changes the launch template, and the group then swaps the instances for new ones a batch at a time.

Cost: under $1 if I destroy it the same day. The load balancer is about $0.0225 an hour, the NAT gateway about $0.045 and its Elastic IP $0.005. The instances are free tier.

## Steps and Evidence

## What Broke and How I Fixed It
