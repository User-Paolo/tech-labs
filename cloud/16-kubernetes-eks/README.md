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
| [nodes.tf](terraform/nodes.tf) | Two groups of ARM nodes, 2 normal `t4g.small` and 2 Spot ones that can be `t4g.small` or `t9g.small`, which have the same size. Pods can't reach the nodes' own AWS credentials |
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

### 7. The database and the app's files for EKS
The database for the paid week is in [terraform/rds.tf](terraform/rds.tf):

| Part | What it does |
|---|---|
| The database | PostgreSQL 17 on `db.t4g.micro` with a standby in the second zone, in the private subnets, encrypted with the lab's KMS key and with 1 day of backups. In [lab 12](../12-databases/) the Free plan refused 7 days and accepted 1 |
| Password | AWS makes it and keeps it in Secrets Manager, so it isn't in Terraform, the state or the repo |
| Security group | Only the cluster security group can reach port 5432. EKS gives that group to the nodes, and the pods use their node's group |
| Settings | Connections without TLS get refused, every login gets logged for the detection part, and so does any query slower than a second |
| The app's role | It can read that one secret and use the KMS key only through Secrets Manager. Pod Identity gives it only to the `web` service account in `lab16` |

The standby in a second zone still counts as 1 instance on the Free plan, so I'm under the limit of 2. checkov passed 138 checks with 23 skips, and the plan grew from 38 to 47:

![The plan with the database and the app's role](images/18-rds-plan.png)

The data source for the app's policy can only be read during the apply, because the secret's ARN doesn't exist until the database does.

Then the third kustomize folder, [k8s/eks/](k8s/eks/). It uses the same base as my PC with these changes:

- the image comes from ECR with tag v4
- a `web` service account for Pod Identity
- the database address and secret ARN, plus `DB_CA_FILE` pointing at the RDS certificates, so the app checks it's really talking to RDS
- an ingress that the AWS Load Balancer Controller turns into an ALB, which sends traffic straight to the pod addresses
- one more rule in the network policy for the public subnets, where the ALB sits
- the greeting changes to `hello from EKS`

The ECR address, the database address and the secret ARN all have my account ID or a random ID in them, so they can't be in the repo. The folder has fake values, and [deploy.sh](k8s/eks/deploy.sh) copies it to `/tmp`, fills in the real ones from `terraform output` and applies the copy. The workflow finds the new folder on its own and checkov passed 97 checks on it.

The certificates were the one thing that didn't make it into my first commit. My `.gitignore` skips every `.pem` file so a private key can't get pushed by accident, and the RDS bundle was called `rds-ca.pem`. It only holds the 3 public root certificates for `us-east-1`, so I renamed it to `rds-ca.crt` instead of loosening the rule.

The nodes are ARM and my PC builds x86 images, so the image has to be built for `linux/arm64` before it goes to ECR. That's the first thing to sort out when the cluster is up.

### 8. A leaked key that locks itself
In [lab 15](../15-leaked-key/) I did the whole response by hand after reading the alert emails, and the lab 02 rules never even saw the read only calls the attacker made. So before the paid week I built the response into the account, in its own folder, [detection/](detection/), which can run on its own without the cluster:

| Part | What it does |
|---|---|
| [canary.tf](detection/canary.tf) | A user called `lab16-canary` with no permissions at all. Nobody should ever use its key, so any call with it means the key leaked |
| The rule in [quarantine.tf](detection/quarantine.tf) | Matches any call by that user. It's set to `ENABLED_WITH_ALL_CLOUDTRAIL_MANAGEMENT_EVENTS`, so it gets read only calls too. It emails me through the lab 02 topic and starts the Lambda |
| [lambda/quarantine.py](detection/lambda/quarantine.py) | Turns off the user's keys, attaches `AWSCompromisedKeyQuarantineV3`, adds the `TokenIssueTime` deny from lab 15 so older sessions stop working, and emails me how long it took |
| The Lambda's role | It can only touch users under the path `/canary/`, and the only policy it can attach is the quarantine one. It could never lock my own user |

Terraform doesn't make the key, so its secret never ends up in the state file. checkov passed 37 checks with 9 skips, and the plan was 9 resources.

For the test I made the key in CloudShell straight into two variables, so it never got printed. Then I used it the way an attacker would and kept trying every 5 seconds until it stopped working:

![Using the canary key until it stopped working](images/19-canary-test.png)

The first call was at 03:35:48, and these emails came in:

![The alert from the rule](images/20-canary-alert-email.png)

![The email from the Lambda](images/21-canary-locked-email.png)

![The lab 02 IAM alerts showing the Lambda's changes](images/22-quarantine-iam-emails.png)

The Lambda locked the key 3 seconds after the call. The key still worked once more at 03:35:54 and only got refused at 03:36:00, 12 seconds after the first use. IAM changes take a few seconds to reach every AWS server, so even an instant response leaves a short window. In lab 15 the key worked until I read the email and acted, so this is still a lot better.

The lab 02 rules saw the Lambda's role turning off the key and attaching the two policies, which is a nice record that the response happened. The alert also shows the tool the attacker used, here `exec-env/CloudShell` and the exact command. A real attacker can fake that, but it's a free clue.

Every call with the key set off the Lambda again, so it ran 3 times. Only the first one did anything, and the other two saw the user was already locked and stopped, so I only got one "locked" email. The first two runs were billed longer than they took, because each started a new copy of the function and AWS bills that start up time too. The third reused a warm copy and was billed exactly its 300 ms.

One gap I know of: the rule is only in `us-east-1`. A call made through another region's endpoint shows up in that region, and the lab 02 rules that forward events to `us-east-1` only get write calls. My guess is that a `get-caller-identity` from `eu-west-1` would go unseen. This setup stays on through the paid week.

### 9. Scaling pods on my PC
I replaced my SSD between sessions, so this started on a fresh WSL install with Docker installed again and a new kind cluster.

The app now has a HorizontalPodAutoscaler in [k8s/base/hpa.yaml](k8s/base/hpa.yaml). It keeps between 3 and 10 pods and adds more when the average CPU goes over half of what each pod asks for, which is 25m. I also took `replicas: 3` out of the deployment. If both the file and the autoscaler set the number, every `kubectl apply` puts it back to 3, even in the middle of a scale up. The autoscaler needs metrics-server to measure the pods, and on kind it needs `--kubelet-insecure-tls` because the nodes use certificates they signed themselves. That's fine for practice and nothing I'd do on a real cluster.

![The new cluster with the autoscaler and metrics-server](images/23-autoscaler-setup.png)

The deployment started with 1 pod and the autoscaler raised it to 3 straight away, with the reason `Current number of replicas below Spec.MinReplicas`. For the first minute it showed `<unknown>`, because metrics-server didn't have any numbers yet.

Then I started a pod with 8 curl loops calling the app nonstop:

![Scaling up under load](images/24-scale-up.png)

It went from 3 to 6 pods and then to 10 in about 30 seconds. At 10 it was still around 200%, so it would have wanted about 40 pods, but 10 is the maximum I set. On EKS that's where the cluster autoscaler comes in and adds nodes, since 40 pods won't fit on 2. The load pod itself used 5441m, about 5 and a half CPU cores, while all 10 web pods together used about 870m. Starting a new curl process for every request costs a lot more than answering it. It also had no limit at all, because nothing in `lab16` gives pods a default one, so on a real node it could starve everything else. A VM was running on my laptop at the same time, so the exact numbers are rough, but the pattern is what I wanted to see.

Then I stopped the load:

![Scaling down after the load stopped](images/25-scale-down.png)

The CPU was back to 2% within a minute, but the pods stayed at 10 for about 5 more minutes and then dropped straight to 3. By default the autoscaler waits 5 minutes before scaling down, so a short quiet moment doesn't throw away pods that would be needed again right after. Adding pods is fast and removing them is slow.

### 10. The last pieces before the paid week
The rest of the Terraform for the cluster:

| File | What it adds |
|---|---|
| [flow-logs.tf](terraform/flow-logs.tf) | VPC flow logs for every connection, accepted or rejected, kept in CloudWatch for 7 days |
| [cluster-autoscaler.tf](terraform/cluster-autoscaler.tf) | A role for the cluster autoscaler, which adds nodes when pods don't fit. It can look at everything, but it can only resize the Auto Scaling groups tagged for `lab16` |
| [monitoring.tf](terraform/monitoring.tf) | Container Insights as an EKS addon, with container logs off to keep the cost down, and a role for Grafana that can only read CloudWatch |

I had Managed Prometheus in the plan, but its scraper needs extra access setup that I couldn't check before the cluster exists. Container Insights is one addon with a normal Pod Identity role, so there's less that can go wrong during the week I'm paying for.

The Kubernetes side got Helm settings for the [cluster autoscaler](k8s/cluster-autoscaler-values.yaml) and [Grafana](k8s/grafana-values.yaml), a [LimitRange](k8s/base/limit-range.yaml) so a pod with no limits gets 500m CPU at most instead of 5 and a half cores like my load pod, and room for 40 pods on EKS instead of 10. Step 9 showed the app wanting about 40 under load, which won't fit on 2 nodes, so the cluster autoscaler will have to add more.

The last gap from [lab 15](../15-leaked-key/) was that downloading a file from S3 left no record, because object reads are data events and my trail only had management events. Logging data events for every bucket costs money, so I made a decoy bucket called `lab16-backups-...` with a fake `exports/customers.csv` and a trail in [data-events.tf](detection/data-events.tf) that only logs object calls in that bucket. Nobody has a reason to open it, so a download means someone is looking around. The alert only fires on `GetObject`, because `terraform plan` checks the file every time and I don't want an email for that.

![Downloading the decoy file and resetting the canary](images/26-decoy-test.png)

![The email about the download](images/27-decoy-email.png)

I downloaded it at 04:37:38 and the email had the event at 04:37:39. This rule is in the normal `ENABLED` state and still got the download, so the special state from step 8 only matters for management events like `get-caller-identity`. Data events reach EventBridge anyway once a trail logs them.

[reset-canary.sh](detection/reset-canary.sh) puts the canary user from step 8 back the way Terraform made it, with no keys and no quarantine policies, so it's ready for the paid week.

### 11. The paid week, day 1
The first apply on November 20 made the cluster and the database fine, and then both node groups failed after 34 minutes:

![Both node groups failing](images/28-node-group-errors.png)

The normal group was refused because `t4g.large` isn't a Free Tier type. Step 1 only checked that the Free plan allows EKS itself, and I never checked which machines it would start for the nodes. It turns out the Free plan only launches Free Tier types, and the biggest ARM ones are `t4g.small` and `t9g.small`, with 2 vCPUs and 2 GiB each:

![The Free Tier instance types](images/29-free-tier-types.png)

So both groups went down to `t4g.small`. The next day the Spot group failed again, this time because AWS had no spare `t4g.small` capacity in `us-east-1b`. `t9g.small` is offered in both of my zones and was a bit cheaper, so the Spot group can now use either one:

![The Spot error, the zones and the Spot prices](images/30-spot-capacity.png)

The plan wanted to create the Spot group, because the failed one was still in AWS and Terraform had never saved it. I deleted it with `aws eks delete-nodegroup` first, and the apply after that added it cleanly:

![The nodes running](images/31-nodes-running.png)

Two normal `t4g.small` nodes and two Spot ones, one of each type, spread over both zones.

CloudShell runs on x86 and the nodes are ARM. My libraries are plain Python, so the [Dockerfile](app/Dockerfile) installs them on the build machine and only copies them into the ARM image, which means no emulator is needed. A check stops the build if a library ever brings compiled code for the wrong CPU. The image went to ECR as `v4`, and then the load balancer controller went in with Helm:

![The load balancer controller installed](images/32-lb-controller.png)

Then I ran the deploy script and the pods never got ready:

![Pods restarting with exit code 137](images/33-app-signals-restarts.png)

The readiness check said 503, but the app's own log shows the checks getting 200. The pod also had a lot of `OTEL_` variables and init containers I never wrote. The Container Insights addon from step 10 turns on Application Signals by default in version 8.0.0, and that puts OpenTelemetry into every pod for Java, Node.js, Python and .NET. Every pod had restarted 5 times with exit code 137, which means it was killed, and it wasn't out of memory. I didn't dig into why the instrumented app failed its checks. I turned it off in [monitoring.tf](terraform/monitoring.tf) with `monitorAllServices = false` and restarted the pods:
```
$ kubectl -n lab16 get pods
NAME                   READY   STATUS    RESTARTS   AGE
web-545c66bdf4-gmclp   1/1     Running   0          2m34s
web-545c66bdf4-vz6n5   1/1     Running   0          2m19s
web-545c66bdf4-zndd6   1/1     Running   0          2m50s
$ for i in 1 2 3 4; do curl -s --max-time 10 http://$alb/; echo; done
{"greeting": "hello from EKS", "version": "v2", "pod": "web-545c66bdf4-zndd6", "secret_set": true, "visits": 2}
{"greeting": "hello from EKS", "version": "v2", "pod": "web-545c66bdf4-gmclp", "secret_set": true, "visits": 3}
{"greeting": "hello from EKS", "version": "v2", "pod": "web-545c66bdf4-vz6n5", "secret_set": true, "visits": 4}
{"greeting": "hello from EKS", "version": "v2", "pod": "web-545c66bdf4-zndd6", "secret_set": true, "visits": 5}
```
That's the whole chain working. The load balancer sends each request to one of the three pods, and each pod counts the visit in RDS over TLS, logged in with the password it reads from Secrets Manager through Pod Identity.

### 12. Pods that stop cleanly
Deleting a pod took 30 seconds every time. The app runs as process 1 in its container, and process 1 ignores `SIGTERM` unless the program handles it, so Kubernetes waited the whole grace period and then killed it. That's also where the exit code 137 above came from. Version 5 of [app.py](app/app.py) exits on `SIGTERM`, and the deployment got a `preStop` pause, so the pod keeps answering while the load balancer takes it out of its list. With a 5 second pause I still lost 2 requests out of 120, so I raised it to 15:

![Deleting a pod during 160 requests, and 160 requests with no delete](images/34-clean-stop.png)

The pod stopped in 17 seconds, which is the 15 second pause plus the app exiting. One request out of 160 failed at 14:55:36, and the run without a delete got all 160. The new pod that replaced the deleted one became ready at 14:55:30, so my guess is the miss had to do with it joining the load balancer. Step 15 has a cleaner result with 5 pods leaving at once.

### 13. Scaling across nodes
EKS doesn't come with metrics-server, so it's an addon in [eks.tf](terraform/eks.tf) now, and the HorizontalPodAutoscaler from step 9 can read pod CPU. The cluster autoscaler went in with Helm and found both node groups by their tags:

![The cluster autoscaler installed](images/35-cluster-autoscaler.png)

The load is a Deployment in [k8s/eks/load.yaml](k8s/eks/load.yaml) with 8 threads asking `/ready` nonstop, so the database isn't part of it. It starts at 0 and I scale it up by hand. I let 3 load pods run overnight, and web went to the maximum of 40 pods on 8 nodes, 10 for a short while.

The next day the cluster autoscaler had brought the Spot group down to 0, and Terraform wanted to put it back to 2 when I reconnected. Both of them were setting the same number, so the node groups now ignore `desired_size` after the first apply and the cluster autoscaler owns it.

Then a cleaner test with 12 load pods:

![New nodes for the waiting pods](images/36-new-nodes.png)

9 pods were waiting for room at 16:33:25, the cluster autoscaler asked for 2 more nodes right away, and at 16:34:39 everything was placed. That part worked. The odd part was the HPA staying at 17 pods with the CPU between 28 and 48%, under its target of 50%. The load pods were barely using any CPU, so they were waiting on something:

![The load pods barely working](images/37-load-pods.png)

DNS wasn't it, since calling by IP was no faster. The real limit was in the app. Python's simple server only queues 5 new connections, and every request from the load pods is a new connection, so the extra ones got dropped and retried after 1 or 3 seconds. Measured on my PC with 8 clients, version 5 had 18 slow requests out of 4231 and version 6, with a queue of 128, had none out of 5947. I also found that about 1 in 50 name lookups inside the load pods failed after a 5 second wait. My guess is a known race in how Alpine's C library sends its DNS queries. The load script now looks up the name once at the start.

With version 6 it scaled the way it should:

![Scaling up with version 6](images/38-scale-v6.png)

7, then 9, then 17, then 20 pods in under 3 minutes, and it stayed at 20 with the 6 nodes it already had. Then I stopped the load:

![Scaling down after the load stopped](images/39-scale-down.png)

The CPU was at 2% within a minute, but the pods stayed at 20 until 17:26:44, about 5 minutes later, the same wait as on my PC in step 9. After that the HPA kept stepping down and the cluster autoscaler took the extra nodes away over the next hour. The dashboard in step 19 shows the whole week.

### 14. What the week really cost
After 4 days I grouped Cost Explorer by service and by usage type, leaving out the credits so the real numbers show:

![The cost by service and by usage type](images/40-cost-by-usage.png)

About $33.50 for November 20 to 23, so $8.40 a day. My estimate in step 2 was about $12 a day, so the week came out cheaper, and for a reason I didn't expect. The two normal `t4g.small` nodes aren't on the bill at all. The Free plan covers them, and only the Spot ones show up, at less than a dollar together.

CloudWatch cost more than the cluster itself, $13.98 against $7.67. Half of it is `CW:ObservationUsage`, which is Container Insights charging for every metric it collects from every pod and node. The other half is `VendedLog-Bytes`, logs that AWS services write into CloudWatch for me, at $0.50 per GB. The biggest log group answered where those came from:

![The log groups by size](images/41-log-groups.png)

The flow logs were 5 times the size of the control plane logs. My guess is the load test made them that big. The app answers with HTTP/1.0, which closes the connection after every response, so every request from the load pods was a new connection, and flow logs write a record for each one. In step 2 I guessed about $10 for monitoring and the detection setup for the whole week, and CloudWatch alone went past that in 4 days.

I left everything on, because the credits covered it and the detection part needs those logs. By November 26 the month was at $52.94:

![The cost summary on November 26](images/42-cost-summary.png)

The 8,585% only compares it to October, when the account cost 61 cents.

### 15. Losing a Spot node
When AWS takes a Spot instance back, the node group gets a warning and drains the node, which moves its pods somewhere else. I did the same drain by hand on the Spot node with the most web pods, while a loop called the load balancer 5 times a second.

The first run was with 12 load pods still going:

![The first drain with the load still on](images/43-spot-drain-with-load.png)

16 requests out of 226 failed, but the first one failed at 12:02:13, before the drain started at about 12:02:33, and they kept coming for 2 minutes after it was done. A run with no drain at all still lost 4 out of 137:
```
== codes ==
      4 000
    133 200
== slowest 200s ==
3.044775
3.030521
1.028819
1.027128
1.025887
1.017048
0.042275
0.037453
```
The failures timed out after 5 seconds with 0 bytes, and the slow ones took 1 or 3 seconds. Those are the times Linux waits before sending a lost connection request again, so connections from the load balancer to the pods were still being dropped now and then. With the load off and the same pods and nodes, all 279 requests got through. So version 6 made it rarer and didn't remove it. Keeping connections open with HTTP/1.1 would be the real fix, and I didn't change the app again this week.

So I ran the drain again with the load off:
```
$ kubectl drain $NODE --ignore-daemonsets --delete-emptydir-data --timeout=120s
12:24:16
node/<spot node> cordoned
evicting pod lab16/web-64c6d49884-r66ss
evicting pod lab16/web-64c6d49884-5lxsh
evicting pod lab16/web-64c6d49884-gm5xx
evicting pod lab16/web-64c6d49884-pwh56
evicting pod lab16/web-64c6d49884-q7rhb
pod/web-64c6d49884-5lxsh evicted
pod/web-64c6d49884-q7rhb evicted
pod/web-64c6d49884-r66ss evicted
pod/web-64c6d49884-gm5xx evicted
pod/web-64c6d49884-pwh56 evicted
node/<spot node> drained
12:24:34
== results ==
    691 200
== slowest ==
0.073428
0.070689
0.062862
```
All 691 requests worked and the slowest took 73 ms. 5 pods left the node at once in 18 seconds, and the load balancer never sent a request to one that was on its way out. There's no PodDisruptionBudget, so nothing stopped all 5 from leaving together, and it still held. The cluster autoscaler removed the empty nodes about 10 minutes later.

### 16. Rotating the database password
RDS manages the database password in Secrets Manager and changes it every 7 days on its own. The app reads the password each time it opens a new connection and keeps that connection open. I forced a rotation with `aws secretsmanager rotate-secret` while a loop called `/` twice a second, which counts a visit in the database every time, and then restarted the web pods so every pod would log in again:
```
== results ==
ok: 444  db_error: 43  other: 0
12:29:20 {"greeting": "hello from EKS", "version": "v2", "pod": "web-77565b99ff-jfbll", "secret_set": true, "visits": null, "db_error": "DatabaseError"}
12:29:22 {"greeting": "hello from EKS", "version": "v2", "pod": "web-77565b99ff-p96nd", "secret_set": true, "visits": null, "db_error": "DatabaseError"}
12:29:24 {"greeting": "hello from EKS", "version": "v2", "pod": "web-77565b99ff-kljjf", "secret_set": true, "visits": null, "db_error": "DatabaseError"}
"visits": 39331
"visits": 39774
{
    "rotated": "2026-11-24T12:30:03.718000+00:00"
}
```
I asked for the rotation at 12:28:53 and restarted the pods at 12:29:00, thinking it was already done. It finished at 12:30:03. Splitting the results by pod showed what happened in between:

![The errors split by pod, and a restart after the rotation](images/44-rotation-after.png)

Every error came from the new pods, between 12:29:20 and 12:30:03. The old pods kept counting on the connections they already had, since PostgreSQL doesn't drop open sessions when the password changes. RDS changes the password in the database first and only then marks the new one as current in Secrets Manager, so a pod that logged in during that gap read the old password and got refused. Each one tried again on the next request and was fine once the rotation finished. A second restart after it was done gave 157 out of 157.

So the app never needs a restart for a new password, and a pod that starts in the middle of a rotation gets about 40 seconds of errors and then recovers on its own. That gap comes with having one database user. The usual fixes are retrying the login a few times, or AWS's alternating users setup with two database users, so one of them always works.

### 17. The canary key inside the cluster
Step 8 tested the canary key from CloudShell. This time I made a new key straight into two variables, put it in a Secret called `leaked-aws-key` in `lab16`, as if someone had left it in the cluster, and started a pod with the AWS CLI that loads that Secret. The pod called `get-caller-identity` every 5 seconds, 12 times through `eu-west-1` and then 12 times through `us-east-1`, to test the guess from the end of step 8:
```
14:55:25 eu-west-1 works
14:55:32 eu-west-1 works
...
14:56:34 eu-west-1 works
14:56:40 eu-west-1 works
14:56:47 us-east-1 works
14:56:54 us-east-1 works
14:57:00 us-east-1 An error occurred (InvalidClientTokenId) when calling the GetCallerIde
14:57:07 us-east-1 An error occurred (InvalidClientTokenId) when calling the GetCallerIde
...
14:58:00 us-east-1 An error occurred (InvalidClientTokenId) when calling the GetCallerIde
```
The guess was right. The key worked 12 times through `eu-west-1` for over a minute and no email came. The first call through `us-east-1` set everything off:

![The alert for the call from the pod](images/45-canary-alert.png)

![The key locked 3 seconds later](images/46-canary-locked.png)

The Lambda locked the key 3 seconds after the call. The call at 14:56:54 still worked and from 14:57:00 on it was refused, 13 seconds after the first use. Step 8 got 12, so my guess is that delay is just how long IAM takes. The lab 02 rules emailed the Lambda's three changes like in step 8. This time there were only 2 alerts for the canary, since a refused call can't be matched to the canary user. AWS turns the key down before it knows whose key it is.

The alert says a lot about where the key was used. The tool line shows `installer#docker` and a kernel ending in `amzn2023.aarch64`, which is a container on one of my Graviton nodes, and the source IP was my NAT gateway:

![CloudTrail in both regions and the NAT gateway check](images/47-cloudtrail-regions.png)

CloudTrail did record all 12 calls in `eu-west-1`. So the gap is in the detection, and the logs had it the whole time. Fixing it would mean the same rule in every region, or forwarding read calls to `us-east-1` too, and I didn't build either one this week.

One more thing from the emails. [reset-canary.sh](detection/reset-canary.sh) tries to detach the quarantine policies even when they aren't attached. Those calls fail, and the lab 02 rules still emailed me about them, so they catch failed IAM changes too.

### 18. Failing over the database
The database has a standby in the second zone, and step 6 was about making the app survive a database restart. RDS can switch to the standby on purpose with a forced failover, so I did that while a loop called `/` twice a second:
```
before: us-east-1b      us-east-1a      available
15:03:51
rebooting
available again: 15:05:08
== results ==
ok: 534  db_error: 3  other: 0
== error window ==
15:03:55
15:04:11
      2 "db_error": "InterfaceError"
      1 "db_error": "TimeoutError"
== slowest ==
15:03:55 10.276942
15:04:12 5.261326
15:04:06 5.183238
15:04:20 0.213935
15:04:18 0.178854
after: us-east-1a       us-east-1b      available
15:04:02        Multi-AZ instance failover started.
15:04:19        DB instance restarted
15:04:35        Multi-AZ instance failover completed
15:04:35        The user requested a failover of the DB instance.
```
The two zones swapped places. The app had errors or slow answers from 15:03:55 to about 15:04:17, so a bit over 20 seconds, and then every pod had a new connection to the new primary with no restart. The loop waits for each answer before sending the next one, so it sent very few requests during those 20 seconds, and 3 errors makes it look smaller than it was. The app was back before RDS said the failover had finished at 15:04:35. The "available again" at 15:05:08 is late only because `aws rds wait` checks every 30 seconds.

### 19. Grafana
The `grafana` chart has moved to the `grafana-community` Helm repo, and the old repo marks it as deprecated. The new one has the same version 10.5.15 that my [values file](k8s/grafana-values.yaml) was written for. The admin password is random and lives in a Secret, and the role from step 10 lets Grafana read CloudWatch through Pod Identity:

![Grafana installed and reading CloudWatch](images/48-grafana-install.png)

My plan was to reach it with a port forward. CloudShell can't open a port in my browser, and a port forward from my PC needs AWS credentials on my PC, which I don't keep there. So for the screenshots I added a Service of type `LoadBalancer` that only my home IP could reach, and deleted it afterwards. It was plain HTTP, so I wouldn't leave it up. The dashboard is in [k8s/grafana-dashboard.json](k8s/grafana-dashboard.json), so it's in the repo like everything else:

![The dashboard for the week](images/49-grafana-dashboard.png)

The whole week is there. The overnight load on November 22 pushed web to its maximum of 40 pods and the nodes to 8. The spike on the 24th is the Spot test. Database connections follow the pod count, since every web pod keeps one connection open. The load balancer barely saw the big load, because the load pods called the `web` Service inside the cluster. It never answered with a 5xx itself all week. The few 5xx from the pods come at random times, even with nothing running. My guess is bots trying `POST` on the public load balancer, since Python's simple server answers any method it doesn't handle with 501.

## What Broke and How I Fixed It

**The Free plan refused my node type.** It only launches Free Tier instance types, and `t4g.large` isn't one. Step 1 checked EKS and missed this. Both node groups use `t4g.small` now, the biggest Free Tier ARM type.

**Spot had no capacity.** AWS had no spare `t4g.small` in one of my zones. The Spot group can use `t9g.small` too now, which has the same size.

**A failed node group stayed behind.** The apply was cut off while the Spot group was failing, so AWS kept it and Terraform never saved it. I deleted it with the AWS CLI before applying again.

**CloudShell timed out in the middle of the first apply.** After that its credentials failed with a 500 error until I signed out of the console and back in. Every new CloudShell session also needs `terraform init` again and an apply for its new IP, since the cluster API only accepts the address in `admin_cidrs`.

**`rds.force_ssl` showed up as a change in every plan.** RDS saves that parameter to apply after a reboot, and Terraform kept trying to apply it right away. Setting `apply_method = "pending-reboot"` in [rds.tf](terraform/rds.tf) stopped it.

**Container Insights put tracing into every pod.** Application Signals is on by default in the addon, and the pods kept getting killed until I turned it off in [monitoring.tf](terraform/monitoring.tf).

**Pods took 30 seconds to stop.** The app ignored `SIGTERM` as process 1. Version 5 handles it, and the 15 second `preStop` pause lets the load balancer catch up.

**Terraform and the cluster autoscaler fought over the node count.** The node groups ignore `desired_size` after the first apply now.

**The app dropped new connections under load.** The queue of 5 was too small, and version 6 raised it to 128. About 3% of requests through the load balancer still timed out while the load ran, since every request opens a new connection. HTTP/1.1 with connections kept open should fix it, and I didn't change the app again.

**Some DNS lookups failed after 5 seconds.** This only happened inside the Alpine based load pods, so the load script looks up the name once.

**New pods couldn't log in during a password rotation.** For about 40 seconds the database already had the new password while Secrets Manager still gave out the old one. The app recovered on its own, and two database users would close the gap.

**The canary rule only watches one region.** Using the key through `eu-west-1` went unseen. CloudTrail has the calls, and the rule needs to be in every region to catch them.

**The flow logs cost more than I thought.** HTTP/1.0 made every request of the load test its own connection, and the flow logs had 3.8 GB after 4 days.
