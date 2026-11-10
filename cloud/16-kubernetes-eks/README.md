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

### 4. My own app, written as YAML
Typing commands one at a time is fine for learning, but nothing is saved anywhere. Real setups keep everything in files and apply them, so that's what I did next, with a small app of my own that I can also take to EKS:

| File | What's in it |
|---|---|
| [app/app.py](app/app.py) | A tiny web app with no libraries. It says hello with a greeting from its settings, its version and which pod answered, and whether it found its secret. It also has two paths for health checks and two that break it on purpose |
| [app/Dockerfile](app/Dockerfile) | Builds the app into an image that runs as a normal user, not root |
| [k8s/base/namespace.yaml](k8s/base/namespace.yaml) | Its own space in the cluster, `lab16` |
| [k8s/base/config.yaml](k8s/base/config.yaml) | The settings, as a ConfigMap |
| [k8s/base/deployment.yaml](k8s/base/deployment.yaml) | 3 copies, with health checks, memory and CPU limits, the secret mounted as a file and locked down security settings |
| [k8s/base/service.yaml](k8s/base/service.yaml) | The fixed address in front of the pods |
| [k8s/base/network-policy.yaml](k8s/base/network-policy.yaml) | Only pods inside `lab16` can reach the app |

checkov can check Kubernetes files and Dockerfiles as well as Terraform. It passed 95 checks with 3 skips, and two of those are only there because the image exists on my PC and not in a registry yet. It also preferred the secret mounted as a file over an environment variable, so I changed that. The [workflow](../../.github/workflows/lab16-checks.yml) runs the same checks on every push.

The secret itself isn't in the repo. I made it with a random value straight in the cluster, so it never gets printed:
```
kubectl -n lab16 create secret generic web-secret --from-literal=api-key="$(openssl rand -hex 16)"
```

![Building the image and applying the files](images/07-own-app-apply.png)

The app waits 10 seconds before its `/ready` path says yes, to act like an app that needs time to start:

![The pods running but not ready for about 15 seconds](images/08-readiness.png)

The pods were running after 5 seconds and only became ready at about 15. Until then they got no traffic. With nginx last time there was no wait at all, because nginx is ready as soon as it starts.

Then I called the service 6 times from a pod inside `lab16`, once from a pod outside it, and looked at how the secret is stored:

![Requests spread over the pods, the network policy and the secret](images/09-requests-policy-secret.png)

The 6 requests reached all 3 pods, just not evenly. The service picks a pod at random for each new connection, so 6 requests won't come out as 2 each. The request from the `default` namespace timed out with curl's exit code 28, so the network policy really blocks it here. The line I blacked out was the start of the stored secret, and decoding it gave back all 32 characters of the key. A Kubernetes Secret is only encoded, so anyone who's allowed to read Secrets can read the value. On EKS I want them encrypted with a KMS key like in [lab 14](../14-iam-kms/).

Next I made one pod fail its health check on purpose:

![The liveness check failing and the container being restarted](images/10-liveness.png)

The events show the liveness check getting a `500` and the container being restarted. The restart count still said 0 because I looked at the exact moment it happened. Kubernetes restarts the container inside the same pod, so the pod keeps its name, which is different from deleting a pod like in step 3.

Then I changed the greeting in the ConfigMap directly in the cluster, without touching the file:

![Changing the ConfigMap and restarting the pods](images/11-config-drift-1.png)

![Applying the files again](images/12-config-drift-2.png)

The running pods kept the old greeting, because they only read their settings when they start. After a restart they said `hello again`. Then I applied the files from the repo again. The ConfigMap went back to `hello from kind`, but the pods kept saying `hello again`, because the deployment file hadn't changed, so nothing restarted them. The settings in the cluster and what the pods were doing no longer matched, and nothing showed an error. The next restart, for any reason, would quietly change the greeting.

Last, the memory limit of 128Mi. `/eat` holds on to another 50 MB each time it's called:

![The container killed for using too much memory](images/13-out-of-memory.png)

50, then 100, and the third call ended with exit code 137, which means the process got killed. The pod shows `OOMKilled` as the reason and 1 restart. Without the limit, one leaking app could use up a whole node's memory and take the other pods with it.

My first try at the last three tests failed with `Connection refused` every time, even though the pods were healthy. Inside the pod, `localhost` points to both `127.0.0.1` and the IPv6 address `::1`. My guess is that `wget` tried `::1`, where my app doesn't listen. The health checks were fine because they use the pod's IPv4 address. Using `127.0.0.1` fixed it.

### 5. The Terraform for the paid week
Everything for EKS is in [terraform/](terraform/), written and checked before anything runs:

| File | What it builds |
|---|---|
| [network.tf](terraform/network.tf) | A VPC in 2 zones, with public subnets for load balancers and private subnets for the nodes and pods. One NAT gateway lets the nodes reach the internet. A real setup would have one per zone, but that doubles the cost |
| [eks.tf](terraform/eks.tf) | The cluster on 1.37, kept on standard support, with Secrets encrypted by my own KMS key and all the control plane logs in CloudWatch for 7 days. The network plugin has network policies switched on, since on EKS that's off by default |
| [nodes.tf](terraform/nodes.tf) | Two groups of ARM nodes, 2 normal `t4g.large` and 2 Spot ones that can be any of 3 types with the same size. Pods can't reach the nodes' own AWS credentials |
| [ecr.tf](terraform/ecr.tf) | A private registry for my image. Tags can't be overwritten and every push gets scanned |
| [lb-controller.tf](terraform/lb-controller.tf) | The role for the AWS Load Balancer Controller, which turns a Kubernetes ingress into a real load balancer. The policy is the official one from the controller's repo at v3.6.2, and only the controller's own service account can use the role |

The cluster API is reachable from the internet, so `admin_cidrs` has no default and refuses `0.0.0.0/0`. I set it to my CloudShell address when I load `~/lab16.env`. Logging in still needs my IAM user, so this is only an extra layer.

checkov passed 96 checks on the Terraform with 16 skips, and the [workflow](../../.github/workflows/lab16-checks.yml) now runs `terraform fmt`, `validate` and checkov on it too. One skip is because checkov's list of supported versions doesn't include 1.37 yet.

A plan creates nothing, so I ran one in CloudShell to see what AWS would make:
```
$ terraform plan -no-color -out=/tmp/lab16.plan | grep -E 'Plan:|Error'
Plan: 38 to add, 0 to change, 0 to destroy.
```
The registry is the only part I hadn't checked against the Free plan yet, so I made an empty one and deleted it straight away:
```
$ aws ecr create-repository --repository-name lab16-freeplan-test --query repository.repositoryName --output text
lab16-freeplan-test
$ aws ecr delete-repository --repository-name lab16-freeplan-test --query repository.repositoryName --output text
lab16-freeplan-test
```
ECR is allowed.

### 6. A database, first on my PC
On EKS the app will keep a visit counter in a PostgreSQL database on RDS. RDS costs money for every hour it runs, so I practised with PostgreSQL inside kind first.

The app now uses [pg8000](https://pypi.org/project/pg8000/) to talk to the database and boto3 to read the database password from Secrets Manager on EKS. On my PC it reads the password from a mounted file instead. So the line in step 4 about the app having no libraries isn't true anymore.

The same app needs different settings on my PC and on EKS, so I split the Kubernetes files with kustomize:

| Folder | What's in it |
|---|---|
| [k8s/base/](k8s/base/) | The 5 files from step 4, with no image tag |
| [k8s/kind/](k8s/kind/) | A practice PostgreSQL, a small change that points the app at it, and the image tag |

Later a `k8s/eks/` folder will point the app at RDS instead. `kubectl apply -k k8s/kind` puts the two together. checkov didn't like the small change file on its own, because it read it as a whole deployment with everything missing. So the workflow now builds each folder first and checks the result. That passed 176 checks with 5 skips.

PostgreSQL runs as a StatefulSet, which gives its pod a fixed name and its own disk that stays when the pod goes away. It also got its own network policy, so only pods labeled `app: web` can reach port 5432. I made its password the same way as the app's secret in step 4, so it never got printed:

![Building v3 and applying the kind folder](images/14-database-apply.png)

PostgreSQL started first and the 3 web pods were replaced one at a time. The disk `data-postgres-0` was created and is `Bound`.

Then I called the app 6 times, and tried to reach the database from a pod named `sneaky` that's in `lab16` but doesn't have the `app: web` label:

![The visit counter and the database policy](images/15-visit-counter-policy.png)

The count went from 1 to 6. All 6 requests landed on the same pod this time, which happens about 1 time in 243. I sent 12 more and they reached all 3 pods while the count kept going up, so the 3 pods really share one counter. `sneaky` got curl's timeout code 28, so being in the right namespace isn't enough to reach the database.

Then I deleted the database pod to see if the data would survive:

![Deleting the database pod](images/16-database-restart.png)

It did. The new pod had the same name, it was 11 seconds old while the disk was still 4m37s old, and the count went on from 19 instead of starting again at 1. The first request came while PostgreSQL was still starting, so the `InterfaceError` there was fair. The two other errors came after it was ready. Each web pod was still holding its connection to the old database. It found out on the next request that the connection was dead and threw it away, and only the request after that got a new one. So every pod turned one visitor away after the database came back. RDS with a standby in a second zone does the same kind of restart when it fails over, so I wanted this fixed before EKS.

Now when a request fails on an old connection, the app opens a new one and tries once more. If a new connection fails too, the database really is down and it gives up. One catch is that a retry could count a visit twice if the update went through just before the connection died, which is fine for a visit counter. I built that as v4 and did the same test:

![The same test with v4](images/17-retry-fix.png)

23 to 28 with no errors. kubectl said `configured` for the StatefulSet and both policies even though I hadn't changed them. `kubectl diff -k k8s/kind` showed no difference and the StatefulSet still had only 1 revision, so nothing really changed there. My guess is kubectl says `configured` whenever it sends an update, even an empty one.
