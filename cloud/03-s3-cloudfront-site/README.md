# 03 Static Site with S3 and CloudFront

**Track:** Cloud
**Exam topics:** AWS Cloud Practitioner, Cloud Technology (S3, CloudFront, edge locations, caching) and Security and Compliance (bucket policies, Block Public Access, HTTPS, shared responsibility)

## Question
Can I put a website on S3 without making the bucket public, so the only way in is through CloudFront over HTTPS? And what does CloudFront's caching actually do when I change the site?

## Setup
A private S3 bucket in `us-east-1` with Block Public Access on, holding the three files in [site](site). In front of it a CloudFront distribution that uses Origin Access Control (OAC), so CloudFront signs every request it sends to S3 and the bucket policy only lets my distribution in. Visitors only ever talk to CloudFront.

```
browser --https--> CloudFront edge location --OAC signed request--> private S3 bucket
```

The distribution redirects HTTP to HTTPS with the default `*.cloudfront.net` certificate, sends a custom 404 page for anything missing and uses price class 100, which only uses the cheaper edge locations in North America and Europe.

[deploy.sh](deploy.sh) uploads the site from CloudShell and can clear the CloudFront cache with an invalidation.

Cost: about $0. CloudFront has an always free allowance of 1 TB of traffic and 10 million requests a month, the first 1,000 invalidation paths a month are free and the bucket holds a few KB.

## Steps and Evidence

## What Broke and How I Fixed It
