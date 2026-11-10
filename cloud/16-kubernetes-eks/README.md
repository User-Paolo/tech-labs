# 16 Final Project, Kubernetes on EKS

**Track:** Cloud, final project
**Exam topics:** AWS Cloud Practitioner, Cloud Technology and Services (containers, Amazon EKS, EC2 pricing and Spot Instances) and Security and Compliance (CloudTrail, monitoring, responding to incidents). Kubernetes itself isn't on the exam.

## Question
Kubernetes is in a lot of the job ads I read and I've never touched it. What is it actually doing, and what does running it on AWS involve? This is the last AWS project in this repo, so I want one week with a real cluster on EKS, with the detection work from [lab 02](../02-security-alerts/) and [lab 15](../15-leaked-key/) improved and watching the account the whole time.

## Plan
EKS charges for every hour the cluster exists, so I'm keeping the paid part short and doing everything I can before it for free:

1. Check that the Free plan allows EKS and what a week would cost
2. Learn the basics on a practice cluster on my own PC
3. Write and check all the Terraform while nothing is running
4. One week live on EKS, with a database on RDS, a scaling test, Spot nodes, monitoring and the detection setup
5. Tear it all down and check nothing is left

## Steps and Evidence

### 1. Is EKS allowed on the Free plan?
The AWS docs only say the Free plan leaves out services that would use up the credits too fast, and they don't name EKS either way. So I checked what I could from CloudShell first:
```
$ for q in L-1216C47A L-34B43A08; do aws service-quotas get-service-quota --service-code ec2 --quota-code $q --query 'Quota.[QuotaName,Value]' --output text; done
Running On-Demand Standard (A, C, D, H, I, M, R, T, Z) instances        16.0
All Standard (A, C, D, H, I, M, R, T, Z) Spot Instance Requests 32.0
$ aws eks describe-cluster-versions --query 'clusterVersions[].[clusterVersion,status]' --output text | head -8
1.37    STANDARD_SUPPORT
1.36    STANDARD_SUPPORT
1.35    STANDARD_SUPPORT
1.34    STANDARD_SUPPORT
1.33    EXTENDED_SUPPORT
1.32    EXTENDED_SUPPORT
1.31    EXTENDED_SUPPORT
$ aws amp list-workspaces --query 'length(workspaces)'
0
$ aws grafana list-workspaces --query 'length(workspaces)'
An error occurred (SubscriptionRequiredException) when calling the ListWorkspaces operation: The AWS Access Key Id needs a subscription for the service
```
The quotas are counted in vCPUs. 16 for normal instances means 8 nodes with 2 vCPUs each, and Spot gets 32 on top of that, so my scaling test can't go much past 20 small nodes. Versions in extended support cost $0.60 an hour instead of $0.10, so I'll stay on 1.37. Managed Prometheus answered, and Managed Grafana gave the same error GuardDuty did in [lab 09](../09-security-services/). So Grafana will have to run inside the cluster.

Listing clusters works on any account, so that didn't tell me much about EKS. The only real test was making one. I made the smallest cluster possible, with no nodes, in the default VPC, and a role for it:
```
$ aws eks create-cluster --name freeplan-test --kubernetes-version 1.37 --role-arn "$ROLE_ARN" --resources-vpc-config subnetIds="$SUBNETS" --upgrade-policy supportType=STANDARD --tags Lab=16 --query 'cluster.[name,version,status]' --output text
freeplan-test   1.37    CREATING
$ aws eks wait cluster-active --name freeplan-test && echo "active at $(date -u +%T)"
active at 16:38:02
$ aws eks describe-cluster --name freeplan-test --query 'cluster.[status,version,platformVersion,upgradePolicy.supportType]' --output text
ACTIVE  1.37    eks.7   STANDARD
$ aws eks delete-cluster --name freeplan-test --query cluster.status --output text
DELETING
$ aws eks wait cluster-deleted --name freeplan-test && echo "deleted at $(date -u +%T)"
deleted at 16:39:05
```
It was accepted and became active about 10 minutes after I asked for it. Deleting it took about a minute. Then I removed the role. The whole test cost a couple of cents.

### 2. What a week would cost
Prices from the Pricing API for `us-east-1`, apart from the lines marked as estimates:

| Part | Price | For 7 days |
|---|---|---|
| EKS cluster | $0.10 an hour | $16.80 |
| 2 normal `t4g.large` nodes | $0.0672 an hour each | $22.58 |
| 2 Spot `t4g.large` nodes | $0.0235 to $0.0346 an hour each, it changes | about $8 to $12 |
| NAT gateway | $0.045 an hour, plus $0.045 per GB | about $8 |
| Load balancer | $0.0225 an hour, plus usage | about $4 |
| Public IPs, disks | estimate | about $4 |
| RDS, Multi AZ `db.t4g.micro` | estimate | about $6 |
| Scaling test, about 20 nodes for 3 hours | estimate | about $3 |
| Monitoring and the detection setup | estimate, Managed Prometheus is free for the first 40M samples | about $10 |
| **Total** | | **about $85** |

I have about $198 of credits left, so that leaves room for extra days or bigger nodes and still keeps a buffer. A Free plan account closes when the credits run out, so I don't want to get close to zero.

### 3. Learning the basics on my PC first
Before paying for anything I wanted to know the basic words and commands, so I installed `kubectl`, the Kubernetes command line tool, and `kind`, which runs a whole Kubernetes cluster inside one Docker container on my PC. Both were checked against their published checksums. The words that matter most so far:

| Word | What it means |
|---|---|
| Node | A machine that runs containers. Here it's one Docker container, on EKS it will be an EC2 instance |
| Pod | The smallest thing Kubernetes runs, one or more containers that always run together |
| Deployment | Keeps a set number of identical pods running and replaces them when they change |
| Service | One fixed address in front of a group of pods, since pods come and go and change IPs |

The first cluster:

![kind creating the practice cluster](images/01-kind-cluster.png)

The node shows `NotReady` because I asked 2 seconds after it was made. A node only turns `Ready` when its network plugin is running, and that was still starting. The pods listed are Kubernetes itself, like `etcd`, where the cluster keeps all its state, and the API server that `kubectl` talks to. A few minutes later the node was `Ready` and there were 11 pods in total.

Then my first app, 2 copies of nginx with a service in front of them:

![A deployment with 2 nginx pods and a service](images/02-first-deployment.png)

Each pod got its own IP, and the service got a fixed one that the rest of the cluster can use. Then I deleted one of the two pods on purpose:

![Deleting a pod and a new one taking its place](images/03-self-healing.png)

A new pod was already running a second later. The deployment wants 2, saw only 1, and made another one. Nothing I did told it to.

The service only has an address inside the cluster, so to reach it from my PC I opened a tunnel with `port-forward`:

![Reaching nginx through a port forward](images/04-port-forward.png)

Next I scaled up to 5 copies and shipped a broken version, with an image name that doesn't exist:

![Scaling to 5 and then a deploy with a broken image](images/05-broken-deploy.png)

The rollout gave up after the 40 seconds I allowed it, and 4 of the 5 old pods were still running. Kubernetes replaces pods a few at a time. By default it can add 25% extra pods and have 25% unavailable while it does that, which with 5 pods means 2 extra and 1 down. So it started 3 new pods, retired 1 old one, and then stopped, because none of the new ones came up. Most of the old version kept serving the whole time. Then I rolled back:

![Rolling back to the working version](images/06-rollback.png)

All 5 were healthy again a few seconds later. The history only shows revisions 2 and 3. Rolling back took revision 1 and gave it the newest number, so 1 became 3.
