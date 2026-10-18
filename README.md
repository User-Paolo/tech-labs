# Tech Labs

My notes from the labs I run while studying for the AWS Cloud Practitioner and Security+ exams, and later CCNA. I build each setup myself and write down what I did and what went wrong, mostly so I don't have to figure it all out again next time.

If you're working through the same material, feel free to look around and compare notes. And if you spot a mistake or know a better way to do something, open an issue and let me know.

## Labs
| Lab | Track | Topics | Status |
|---|---|---|---|
| [01 AWS account hardening and audit](cloud/01-aws-account-hardening/) | Cloud | IAM, MFA, least privilege, Budgets, CloudTrail, S3 Block Public Access | Done |
| [02 Security alerts](cloud/02-security-alerts/) | Cloud | CloudTrail, EventBridge, SNS, cross region forwarding | Done |
| [03 Static site with S3 and CloudFront](cloud/03-s3-cloudfront-site/) | Cloud | S3, CloudFront, OAC, edge locations, caching | Done |

## How Each Lab Is Laid Out
Every lab follows the same [template](LAB_TEMPLATE.md). It starts with the question I had and the setup I used, then goes through the steps with the commands, configs and screenshots, and ends with what broke and how I fixed it.

## License
This project is licensed under the MIT License. See [LICENSE](LICENSE).
