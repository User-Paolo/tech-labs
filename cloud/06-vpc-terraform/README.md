# 06 VPC in Terraform

**Track:** Cloud
**Exam topics:** AWS Cloud Practitioner, Cloud Technology (infrastructure as code, VPC, EC2, NAT gateways) and Security and Compliance (security groups, network ACLs, catching misconfigurations before they get deployed)

## Question
Lab 05 took me a whole evening of commands and copied IDs. If I write the same network as code, can I build it with one command and delete it with another? And can a scanner running in CI point out the security problems before anything gets built?

## Setup
The same network as [lab 05](../05-vpc-from-scratch/), this time in Terraform, run from CloudShell in `us-east-1`.

```
VPC 10.0.0.0/16
             us-east-1a                   us-east-1b
public       10.0.1.0/24   web server     10.0.2.0/24
private      10.0.11.0/24  app server     10.0.12.0/24

public route table   0.0.0.0/0 -> internet gateway
private route table  0.0.0.0/0 -> NAT gateway in public a
```

| File | What's in it |
|---|---|
| [versions.tf](versions.tf) | Terraform and AWS provider versions, the region and a `Lab=06` tag on everything |
| [variables.tf](variables.tf) | `my_ip`, `enable_nat` and `block_my_ip` |
| [network.tf](network.tf) | VPC, the four subnets, internet gateway, NAT gateway, route tables and a NACL for the public subnets |
| [security.tf](security.tf) | Both security groups and the Session Manager role |
| [instances.tf](instances.tf) | The web and app servers, running [web.sh](web.sh) like in lab 05 |
| [outputs.tf](outputs.tf) | The web URL, the app server's IP, the instance IDs and the NAT's IP |

My IP never goes in a file. I pass it in CloudShell with `export TF_VAR_my_ip=...` and Terraform picks it up from there. `block_my_ip` is a switch for the NACL deny test from lab 05, so turning it on and off is one apply each time. The state file stays in CloudShell and is gitignored.

The four subnets are one block that loops over a map, where lab 05 needed four commands. One thing Terraform does differently from the console and the CLI is that it deletes the default "everything out" rule from any security group it creates, so I had to write that rule myself.

Once it works, checkov, a scanner for infrastructure code, gets added to GitHub Actions so it checks this folder on every push.

Cost: under $1 if I destroy it the same day. The NAT gateway is about $0.045 an hour, its Elastic IP and the web server's public IP are $0.005 an hour each and the instances are free tier. `terraform destroy` deletes all of it.

## Steps and Evidence

## What Broke and How I Fixed It
