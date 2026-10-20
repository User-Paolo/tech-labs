# 05 VPC from Scratch

**Track:** Cloud
**Exam topics:** AWS Cloud Practitioner, Cloud Technology (VPC, subnets, route tables, internet and NAT gateways, EC2, Availability Zones) and Security and Compliance (security groups, network ACLs, Session Manager instead of SSH)

## Question
If I build a network myself, which pieces actually decide what can reach the internet and what can reach what? And when something gets blocked, can I tell if it was a security group or a network ACL?

## Setup
Everything in `us-east-1`, built from CloudShell one piece at a time so every piece is its own command. Lab 06 builds the same thing again in Terraform, so this is the long way on purpose.

```
VPC 10.0.0.0/16
             us-east-1a                   us-east-1b
public       10.0.1.0/24   web server     10.0.2.0/24
private      10.0.11.0/24  app server     10.0.12.0/24

public route table   0.0.0.0/0 -> internet gateway
private route table  local only, then 0.0.0.0/0 -> NAT gateway in part 2
```

Two small instances, `t3.micro` with Amazon Linux. The web server sits in public a with a public IP, the app server in private a with no public IP at all. Both run [web.sh](web.sh) when they start, which just serves a page saying which instance answered.

No SSH anywhere, no port 22 and no key pairs. I get onto the instances with Session Manager through an IAM role. The web security group lets in port 80 from my IP only. The app security group lets in port 80 only from the web security group, not from any IP range.

I split it into two parts. Part 1 is the network, both instances and the basic reachability tests. Part 2 adds the NAT gateway and the security group vs network ACL tests, then everything gets deleted.

Cost: under $1 for the whole thing if I delete it at the end of each part. The instances are free tier types, the NAT gateway is about $0.045 an hour and only exists in part 2, and every public IPv4 address is $0.005 an hour. Everything is tagged `Lab=05` and [teardown.sh](teardown.sh) deletes it all in the order AWS wants.

## Steps and Evidence

## What Broke and How I Fixed It
