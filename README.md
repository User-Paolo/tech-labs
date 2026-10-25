# Tech Labs

My notes from the labs I run while studying for the AWS Cloud Practitioner and Security+ exams, and later CCNA. I build each setup myself and write down what I did and what went wrong, mostly so I don't have to figure it all out again next time.

If you're working through the same material, feel free to look around and compare notes. And if you spot a mistake or know a better way to do something, open an issue and let me know.

## Labs
| Lab | Track | Topics | Status |
|---|---|---|---|
| [01 AWS account hardening and audit](cloud/01-aws-account-hardening/) | Cloud | IAM, MFA, least privilege, Budgets, CloudTrail, S3 Block Public Access | Done |
| [02 Security alerts](cloud/02-security-alerts/) | Cloud | CloudTrail, EventBridge, SNS, cross region forwarding | Done |
| [03 Static site with S3 and CloudFront](cloud/03-s3-cloudfront-site/) | Cloud | S3, CloudFront, OAC, edge locations, caching | Done |
| [04 S3 in depth](cloud/04-s3-in-depth/) | Cloud | Versioning, delete markers, presigned URLs, lifecycle, storage classes, Object Lock | Done |
| [05 VPC from scratch](cloud/05-vpc-from-scratch/) | Cloud | VPC, subnets, route tables, IGW, NAT, security groups, NACLs, Session Manager | Done |
| [06 VPC in Terraform](cloud/06-vpc-terraform/) | Cloud | Terraform, infrastructure as code, checkov, GitHub Actions | Done |
| [07 Load balancer and Auto Scaling](cloud/07-alb-autoscaling/) | Cloud | EC2, launch templates, Auto Scaling, Application Load Balancer, health checks, rolling updates | Done |
| [08 My own AWS bill](cloud/08-billing-and-costs/) | Cloud | Free plan credits, Cost Explorer, cost allocation tags, Budgets, Cost Anomaly Detection, pricing models | Done |
| [09 Security services tour](cloud/09-security-services/) | Cloud | Trusted Advisor, IAM Access Analyzer, Artifact, GuardDuty, Inspector, Macie, Config, Security Hub | Done |

## How Each Lab Is Laid Out
Every lab follows the same [template](LAB_TEMPLATE.md). It starts with the question I had and the setup I used, then goes through the steps with the commands, configs and screenshots, and ends with what broke and how I fixed it.

## License
This project is licensed under the MIT License. See [LICENSE](LICENSE).
