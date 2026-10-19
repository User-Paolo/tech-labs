# 04 S3 in Depth

**Track:** Cloud
**Exam topics:** AWS Cloud Practitioner, Cloud Technology (S3 versioning, lifecycle, storage classes, Glacier retrieval) and Security and Compliance (presigned URLs, Object Lock, data protection)

## Question
If I delete or overwrite something in S3 by mistake, can I get it back? And a few things around that. Can I share one private file without opening up the bucket, how do I stop old copies from piling up forever, and can I make a file that nobody can delete, not even me?

## Setup
Mostly the bucket from lab 03, the one behind CloudFront. Using it on purpose, because when I break something in it I can see the site break too.

For Object Lock I make a second small bucket. Object Lock needs versioning and has to be switched on for the bucket, and I didn't want a lock anywhere near the site.

The lifecycle rule lives in [lifecycle.json](lifecycle.json). It deletes old versions a day after they get replaced, cleans up delete markers that have nothing left behind them and drops half finished uploads. One day is way too short for anything real, more like 30 or 90, but I want to see it happen without waiting a month.

Cost: cents. A few tiny files, a handful of versions and one small file in Glacier.

## Steps and Evidence

## What Broke and How I Fixed It
