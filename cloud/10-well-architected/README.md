# 10 Well-Architected Review

**Track:** Cloud
**Exam topics:** AWS Cloud Practitioner, Cloud Concepts (the Well-Architected Framework and its six pillars, the design principles behind them)

## Question
The exam wants the six pillars by name and I can recite them. But what do they look like when I score something I actually built? Lab 07 ended with checkov at 0 failed and it healed itself when I broke it, so I thought it was in decent shape. Does AWS's own review agree?

## Setup
The Well-Architected Tool in `us-east-1`. It's a free questionnaire in the console, with a set of questions per pillar. Each question has a list of best practices, I tick the ones I really do, and the tool gives the question a risk rating.

I'm reviewing [lab 07](../07-alb-autoscaling/) as I left it. Nothing gets rebuilt for this, I answered from its Terraform code and its test results, and from what the account has around it since labs 01, 02, 08 and 09.

| File | What's in it |
|---|---|
| [answers.json](answers.json) | My answers, with a note on each one saying why |
| [apply-answers.sh](apply-answers.sh) | Saves the answers into the review, safe to run again |

Clicking through 57 questions and retyping my reasons would take a while, so the answers are in a file. That also means anyone can see what I ticked and open an issue if they disagree.

Cost: free. The tool costs nothing and lab 07 stays destroyed.

## Steps and Evidence

### 1. Is it allowed on the Free plan?
I checked this first, since four security services were blocked in lab 09:
```
$ aws wellarchitected list-workloads --region us-east-1 2>&1 | tail -3
{
    "WorkloadSummaries": []
}
```
An empty list and no `SubscriptionRequiredException`, so it works.

### 2. Making the review
```
$ aws wellarchitected create-workload --workload-name lab07-review --description "Review of the lab 07 load balancer and Auto Scaling setup" --environment PREPRODUCTION --aws-regions us-east-1 --lenses wellarchitected --review-owner Paolo --tags Lab=10 --query WorkloadId --output text
```
A workload is just AWS's word for the thing being reviewed. A lens is the set of questions, and `wellarchitected` is the general one.

Then I pulled all the questions and their choices into a file so I could go through them next to the code:
```
$ jq -r '"\(.pillar): \(.questions | length)"' ~/lab10-questions-full.json
operationalExcellence: 11
security: 11
reliability: 13
performance: 5
costOptimization: 11
sustainability: 6
```
57 in total.

### 3. Answering the first three pillars
I only ticked what I could point to in the code or in a test. If something only half applies, the note says so. For least privilege, the instance role in lab 07 only has the Session Manager policy, but my own user has `AdministratorAccess`, so I left it unticked.

Five questions don't apply to one static page run by one person, so I marked them not applicable: organization culture, data classification, service architecture, preventing interaction failures and backups.
```
$ bash apply-answers.sh
saved: priorities
...
saved: planning-for-recovery
```
| Pillar | High | Medium | No risk | Not applicable |
|---|---|---|---|---|
| Operational Excellence | 8 | 2 | 0 | 1 |
| Security | 9 | 1 | 0 | 1 |
| Reliability | 8 | 2 | 0 | 3 |

25 high and 5 medium out of the 30 questions that apply. None of them came out clean. Even network protection was flagged, where I have public and private subnets and security groups that reference each other.

I didn't expect that after checkov said 0 failed. checkov looks at how each resource is set up in the code. The review also asks things like who gets told when it breaks, and the code has no answer for that. A lot of the questions assume a company with teams and customers, so I'm not reading all the high ratings as lab 07 being a disaster. A production system would need a lot more than a lab that ran for about an hour.

### 4. What the first three pillars actually found
A few things I hadn't noticed about my own lab until I went through the questions.

- **No scaling policy.** There's none in [asg.tf](../07-alb-autoscaling/asg.tf). The group keeps 2 instances alive and replaces broken ones, but `max_size = 4` only matters during a rolling update, so more traffic wouldn't get more instances. The group never actually scaled for load in lab 07.
- **No alarms.** There's no dashboard or logs either. I only saw the 502s in lab 07 because I was running curl in a loop.
- **One NAT gateway, in 1a.** Everything else is in two AZs. From reading the routes, if 1a goes down the site should still answer from 1b, since serving the page doesn't use the NAT gateway. That instance would lose its internet and Session Manager though. I haven't tested this.
- **Plain HTTP.** I knew this one already. No domain means no certificate.
- **No plan after an alert.** Lab 02 sends me emails, but I have nothing written down for what I'd do next.

### 5. The last three pillars
Same routine. Performance has 5 questions, cost has 11 and sustainability has 6. Three more don't apply here because there's no data store and the software is one static page, so that makes 8 not applicable in total.

Each pillar ended up asking about something different, which helps me more than the definitions did:

| Pillar | What it asked me about |
|---|---|
| Operational Excellence | How I run it, ship changes and notice problems |
| Security | Who can reach what, and how data is protected |
| Reliability | Surviving failures and handling changes in demand |
| Performance Efficiency | Picking the right resources and measuring them |
| Cost Optimization | Knowing what I spend and removing what I don't use |
| Sustainability | Using less hardware and energy |

### 6. The full score
```
$ bash apply-answers.sh
saved: priorities
...
saved: sus_dev
```
| Pillar | High | Medium | No risk | Not applicable |
|---|---|---|---|---|
| Operational Excellence | 8 | 2 | 0 | 1 |
| Security | 9 | 1 | 0 | 1 |
| Reliability | 8 | 2 | 0 | 3 |
| Performance Efficiency | 3 | 1 | 0 | 1 |
| Cost Optimization | 6 | 4 | 1 | 0 |
| Sustainability | 0 | 4 | 0 | 2 |
| **Total** | **34** | **14** | **1** | **8** |

The Medium and no risk questions, the rest are High:
```
$ aws wellarchitected list-answers --workload-id "$WL" --lens-alias wellarchitected --pillar-id "$p" --max-results 50 --query "AnswerSummaries[?Risk=='MEDIUM' || Risk=='NONE'].[QuestionId,Risk]" --output text
dev-integ       MEDIUM
operations-health       MEDIUM
network-protection      MEDIUM
adapt-to-changes        MEDIUM
withstand-component-failures    MEDIUM
performing-architecture MEDIUM
decomissioning-resources        MEDIUM
type-size-number-resources      MEDIUM
pricing-model   MEDIUM
evaluate-new-services   MEDIUM
evaluate-cost-effort    NONE
sus_region      MEDIUM
sus_user        MEDIUM
sus_hardware    MEDIUM
sus_dev MEDIUM
```
The one clean question is `evaluate-cost-effort`, which only has one choice to tick. Security did worst with 9 high out of 10.

The rating doesn't seem to be a simple count of ticks. I ticked 5 of 9 on `cloud-financial-management` and it's High, while `operations-health` is Medium with nothing ticked. `sus_region` is the same, and sustainability has no High at all. I don't know the exact rule, my guess is that some best practices count for more than others and some questions can't go above Medium.

Cost still got 6 high even after I spent all of lab 08 on my bill. Most of what's missing there is process, like policies and acting on real usage data.

### 7. What I'd fix
These are the gaps I think matter for lab 07, and where I plan to deal with them.

| Gap | Fix | When |
|---|---|---|
| No scaling policy, never load tested | A target tracking policy and a load test | Lab 11 |
| No alarms, dashboard or notifications | CloudWatch alarms and a dashboard, SNS for the emails | Lab 11 |
| No load balancer access logs or VPC flow logs | Turn both on, as I said in the checkov skips in lab 07 | Lab 11 |
| Never looked at a quota | Check the EC2 and load balancer ones in Service Quotas | Lab 11 |
| No secrets or backups to manage yet | Secrets Manager and snapshots with a real database | Lab 12 |
| My user has `AdministratorAccess`, default encryption keys only | Tighter policies and my own KMS key | Lab 14 |
| No plan after an alert | Write one and test it with a fake leaked key | Lab 15 |
| Plain HTTP | Needs a domain for an ACM certificate, no lab for this yet | Maybe the final project |
| One NAT gateway | A second one in 1b, about $0.05 more an hour with its Elastic IP | Leaving it, a real system should have it but a lab doesn't need it |

### 8. Saving the score
A milestone freezes the review as it is right now, so I can compare against it after I fix things.
```
$ aws wellarchitected create-milestone --workload-id "$WL" --milestone-name lab07-baseline --query MilestoneNumber --output text
1
```
The review stays in the account since the tool is free. After lab 11 I can update the answers and see whether the numbers actually move.

## What Broke and How I Fixed It

**My export only had 51 questions.** I only noticed when the risk table added up to more than I'd answered. `list-answers` gave me 10 questions per pillar and stopped, so four pillars got cut off with no error. Setting `--max-results 50` got all of them.

**The not applicable answers saved as empty.** The script threw `Cannot iterate over null` five times and kept going. I had `jq -r '.applicable // true'` to default a missing value to true, but in jq `//` also treats `false` as missing, so `false // true` gives `true`. Those five saved with no choices and stayed unanswered. Now it reads `.applicable` and compares it to `false`.
