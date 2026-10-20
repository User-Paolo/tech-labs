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

### 1. The VPC and the subnets
Everything gets a `Name` and a `Lab=05` tag, so I made a tiny helper for the tag part. That tag is also how [teardown.sh](teardown.sh) finds things later.
```
$ T() { echo "ResourceType=$1,Tags=[{Key=Name,Value=$2},{Key=Lab,Value=05}]"; }
$ VPC=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 --tag-specifications "$(T vpc lab05-vpc)" --query Vpc.VpcId --output text)
$ aws ec2 modify-vpc-attribute --vpc-id $VPC --enable-dns-hostnames
$ sub() { aws ec2 create-subnet --vpc-id $VPC --cidr-block $1 --availability-zone $2 --tag-specifications "$(T subnet $3)" --query Subnet.SubnetId --output text; }
$ PUB_A=$(sub 10.0.1.0/24 us-east-1a lab05-public-a); PUB_B=$(sub 10.0.2.0/24 us-east-1b lab05-public-b)
$ PRIV_A=$(sub 10.0.11.0/24 us-east-1a lab05-private-a); PRIV_B=$(sub 10.0.12.0/24 us-east-1b lab05-private-b)
$ for s in $PUB_A $PUB_B; do aws ec2 modify-subnet-attribute --subnet-id $s --map-public-ip-on-launch; done
$ aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC --query 'Subnets[].[Tags[?Key==`Name`]|[0].Value,CidrBlock,AvailabilityZone,MapPublicIpOnLaunch]' --output table
+------------------+----------------+-------------+--------+
|  lab05-public-a  |  10.0.1.0/24   |  us-east-1a |  True  |
|  lab05-private-a |  10.0.11.0/24  |  us-east-1a |  False |
|  lab05-private-b |  10.0.12.0/24  |  us-east-1b |  False |
|  lab05-public-b  |  10.0.2.0/24   |  us-east-1b |  True  |
+------------------+----------------+-------------+--------+
```
Only the public subnets hand out a public IP to new instances. I thought that setting was what made a subnet public. It isn't, as the next step shows.

### 2. Internet gateway and route tables
```
$ IGW=$(aws ec2 create-internet-gateway --tag-specifications "$(T internet-gateway lab05-igw)" --query InternetGateway.InternetGatewayId --output text)
$ aws ec2 attach-internet-gateway --internet-gateway-id $IGW --vpc-id $VPC
$ RT_PUB=$(aws ec2 create-route-table --vpc-id $VPC --tag-specifications "$(T route-table lab05-public-rt)" --query RouteTable.RouteTableId --output text)
$ RT_PRIV=$(aws ec2 create-route-table --vpc-id $VPC --tag-specifications "$(T route-table lab05-private-rt)" --query RouteTable.RouteTableId --output text)
$ aws ec2 create-route --route-table-id $RT_PUB --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW
$ for s in $PUB_A $PUB_B; do aws ec2 associate-route-table --route-table-id $RT_PUB --subnet-id $s; done
$ for s in $PRIV_A $PRIV_B; do aws ec2 associate-route-table --route-table-id $RT_PRIV --subnet-id $s; done
```

| Route table | Subnets | Routes |
|---|---|---|
| `lab05-public-rt` | public a and b | `10.0.0.0/16 -> local`, `0.0.0.0/0 -> igw-019ce979ce127fb48` |
| `lab05-private-rt` | private a and b | `10.0.0.0/16 -> local` |

The private table is just the public one minus the internet gateway line. There's no "private" setting anywhere in AWS. A subnet is public when its route table sends `0.0.0.0/0` to an internet gateway, and that's it.

### 3. Security groups
My home IP is replaced with `203.0.113.10` here. I got it from https://checkip.amazonaws.com in my own browser, because asking from CloudShell gives you an AWS address.
```
$ SG_WEB=$(aws ec2 create-security-group --group-name lab05-web --description "web, port 80 from my IP" --vpc-id $VPC --tag-specifications "$(T security-group lab05-web)" --query GroupId --output text)
$ SG_APP=$(aws ec2 create-security-group --group-name lab05-app --description "app, port 80 from the web SG only" --vpc-id $VPC --tag-specifications "$(T security-group lab05-app)" --query GroupId --output text)
$ aws ec2 authorize-security-group-ingress --group-id $SG_WEB --protocol tcp --port 80 --cidr $MYIP/32
$ aws ec2 authorize-security-group-ingress --group-id $SG_APP --protocol tcp --port 80 --source-group $SG_WEB
```

| Group | Port 80 from |
|---|---|
| `lab05-web` | `203.0.113.10/32` |
| `lab05-app` | `sg-093c7e6d68dc03ebc`, which is `lab05-web` |

The app rule has no IP in it at all. Anything in the web group gets in, so if the web server got a new IP or I added a second one it would still work.

### 4. A role for Session Manager
```
$ aws iam create-role --role-name lab05-ssm --assume-role-policy-document file:///tmp/ec2-trust.json --tags Key=Lab,Value=05
$ aws iam attach-role-policy --role-name lab05-ssm --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
$ aws iam create-instance-profile --instance-profile-name lab05-ssm
$ aws iam add-role-to-instance-profile --instance-profile-name lab05-ssm --role-name lab05-ssm
```
The trust policy only lets `ec2.amazonaws.com` take the role. Within two seconds lab 02 emailed me four IAM changes, `CreateRole`, `AttachRolePolicy`, `CreateInstanceProfile` and `AddRoleToInstanceProfile`. Expected this time, and nice to see it still works.

### 5. The instances
```
$ AMI=$(aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 --query Parameter.Value --output text); echo $AMI
ami-0567589d25e06853e
$ run() { aws ec2 run-instances --image-id $AMI --instance-type t3.micro --subnet-id $1 --security-group-ids $2 --iam-instance-profile Name=lab05-ssm --metadata-options HttpTokens=required --user-data file://$HOME/tech-labs/cloud/05-vpc-from-scratch/web.sh --tag-specifications "$(T instance $3)" --query 'Instances[0].InstanceId' --output text; }
$ WEB=$(run $PUB_A $SG_WEB lab05-web); APP=$(run $PRIV_A $SG_APP lab05-app)
$ aws ec2 describe-instances --instance-ids $WEB $APP --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,SubnetId,PrivateIpAddress,PublicIpAddress,State.Name]' --output table
+-----------+---------------------------+-------------+-----------------+----------+
| lab05-web | subnet-04b147d1ee66d5842  | 10.0.1.95   | 44.204.111.115  | running  |
| lab05-app | subnet-0dcf6dbb8ddadb80f  | 10.0.11.22  | None            | running  |
+-----------+---------------------------+-------------+-----------------+----------+
```
The SSM parameter always points at the newest Amazon Linux 2023 image, so I don't have to look up an AMI ID. `HttpTokens=required` turns on IMDSv2 only, the safer version of the instance metadata service.

### 6. Who can reach what
My browser on `http://44.204.111.115` got `lab05 ip-10-0-1-95`. The same request from CloudShell:
```
$ curl -s -m 5 http://$WEB_IP || echo "timed out"
timed out
```
It times out instead of getting refused. A security group doesn't answer when it blocks something, it just drops it.

Which instances Session Manager knows about:
```
$ aws ssm describe-instance-information --query 'InstanceInformationList[].[InstanceId,PingStatus]' --output text
i-0bbfbde8eecd9b5fde    Online
$ echo "web=$WEB app=$APP"
web=i-0bbfbde8eecd9b5fde app=i-08bc538a6d51ba0c2
```
Only the web server. The agent on the app server has to call the SSM service on the internet and it has no way out, so it never shows up. I can't log in to it at all right now, which is kind of the point of a private subnet but also a bit annoying.

So I went through the web server instead:
```
$ aws ssm start-session --target $WEB
sh-5.2$ curl -s http://10.0.11.22
<h1>lab05 ip-10-0-11-22</h1>
sh-5.2$ curl -s -m 5 https://checkip.amazonaws.com
44.204.111.115
sh-5.2$ exit
```
Web to app works over the private IP because of the security group rule from step 3. And the web server goes out to the internet as its own public IP through the internet gateway.

### 7. The resource map
![VPC resource map](images/resource-map.png)

Three route tables, though I only made two. The unnamed one is the main route table every VPC comes with. All four subnets are attached to mine on purpose, so it's not used for anything. If I'd forgotten to attach a subnet it would have landed on the main table without me noticing.

### 8. NAT gateway
Part 2. The NAT gateway goes in a public subnet, because it needs the internet gateway route itself, and it gets an Elastic IP.
```
$ EIP=$(aws ec2 allocate-address --domain vpc --tag-specifications "$(T elastic-ip lab05-nat-eip)" --query AllocationId --output text)
$ NAT=$(aws ec2 create-nat-gateway --subnet-id $PUB_A --allocation-id $EIP --tag-specifications "$(T natgateway lab05-nat)" --query NatGateway.NatGatewayId --output text)
$ aws ec2 wait nat-gateway-available --nat-gateway-ids $NAT && echo nat ready
nat ready
$ aws ec2 create-route --route-table-id $RT_PRIV --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $NAT
$ aws ec2 describe-route-tables --route-table-ids $RT_PRIV --query 'RouteTables[0].Routes[].[DestinationCidrBlock,GatewayId,NatGatewayId]' --output text
10.0.0.0/16     local   None
0.0.0.0/0       None    nat-08f8943eb72d8ce47
$ aws ec2 describe-addresses --allocation-ids $EIP --query 'Addresses[0].PublicIp' --output text
184.197.144.27
```
One new line in the private route table and that's the whole change.

### 9. The app server comes online
After a reboot (see What Broke) the app server finally showed up in Session Manager:
```
$ aws ssm describe-instance-information --query 'InstanceInformationList[].[InstanceId,PingStatus]' --output text
i-0bbfbde8eecd9b5fde    Online
i-08bc538a6d51ba0c2     Online
$ aws ssm start-session --target $APP
sh-5.2$ curl -s -m 5 https://checkip.amazonaws.com
184.197.144.27
sh-5.2$ curl -s -m 5 http://10.0.1.95 || echo "timed out"
timed out
sh-5.2$ exit
```
It goes out to the internet as the NAT's Elastic IP. It still has no public IP of its own, so nothing on the internet can start a connection to it. Outbound only.

The second curl is the app server calling the web server, and it got dropped. The web security group only lets in my IP, and that applies inside the VPC too. Being in the same VPC doesn't get you anything for free.

### 10. Security group vs network ACL
I made a new NACL for public a, where the web server lives. A new NACL denies everything until you add rules. I added port 80 in from my IP and port 80 out to my IP, which looks right at first glance. Then I changed one thing at a time and tested from a PowerShell window on my PC, since only my IP gets in:
```
PS> curl.exe -s -m 5 http://44.204.111.115; "exit $LASTEXITCODE"
```
`exit 0` with the page means it worked. `exit 28` is curl giving up after 5 seconds.

| # | NACL on public a | Result |
|---|---|---|
| 1 | In: allow 80. Out: allow 80 | `exit 28` |
| 2 | Out: add allow 1024 to 65535 | `exit 0` |
| 3 | In: add deny 80 from my IP as rule 200 | `exit 0` |
| 4 | In: move the deny to rule 90 | `exit 28` |
| 5 | Back to the default NACL | `exit 0` |

```
$ aws ec2 describe-network-acls --network-acl-ids $NACL --query 'NetworkAcls[0].Entries[?!Egress].[RuleNumber,RuleAction,PortRange.From]' --output table
|  90   |  deny   |  80    |
|  100  |  allow  |  80    |
|  32767|  deny   |  None  |
```

Test 1 was the one I was looking for. The request reaches the server on port 80, but the reply goes back to whatever random high port my PC picked, something between 49152 and 65535. A security group is stateful, it remembers the connection and lets the reply out on its own. A NACL is stateless and checks the reply like a brand new packet, and port 80 out doesn't match it. Allowing 1024 to 65535 out fixed it. That's the standard range for ephemeral ports, and it covers Windows, Linux and the NAT gateway.

Tests 3 and 4 are the rule order. NACL rules get checked from the lowest number up and the first match wins. At 200 the deny never got a look in because allow 100 matched first. At 90 it matched first and blocked me, even though the web security group still allowed my IP. The NACL sits at the edge of the subnet, so the request never even got to the security group.

So the difference in short. Security groups only allow, belong to an instance and remember connections. NACLs can deny, cover a whole subnet and remember nothing. A NACL deny is how you'd block one bad IP for everything in a subnet. Doing all your allowing in NACLs is a pain because of the ephemeral ports.

While my test NACL was on public a it also cut off the NAT gateway, which lives in the same subnet. Everything except port 80 to and from my IP got dropped, so for those few minutes the app server lost its internet too.

### 11. Teardown
```
$ bash ~/tech-labs/cloud/05-vpc-from-scratch/teardown.sh
terminated: i-0bbfbde8eecd9b5fde i-08bc538a6d51ba0c2
deleted: nat-08f8943eb72d8ce47
released: eipalloc-0a651a79c7bf72aaa
deleted: igw-019ce979ce127fb48
deleted: subnet-04b147d1ee66d5842
deleted: subnet-0dcf6dbb8ddadb80f
deleted: subnet-06be1a96f0ba0f625
deleted: subnet-0254e073d67c8de49
deleted: acl-02d26c0412ddcbdb3
deleted: sg-093c7e6d68dc03ebc
deleted: sg-0b0bd909468dc2ed3
deleted: rtb-063f1f414da8fed88
deleted: rtb-01e6e97fdddb7f362
deleted: vpc-04d2d698afc53324e
deleted: role and instance profile lab05-ssm
$ aws ec2 describe-vpcs --filters Name=tag:Lab,Values=05 --query 'Vpcs[].VpcId' --output text
$ aws ec2 describe-addresses --query 'Addresses[].PublicIp' --output text
$ aws ec2 describe-nat-gateways --filter Name=state,Values=pending,available --query 'NatGateways[].NatGatewayId' --output text
$ aws iam get-role --role-name lab05-ssm 2>&1 | tail -1
aws: [ERROR]: An error occurred (NoSuchEntity) when calling the GetRole operation: The role with name lab05-ssm cannot be found.
```
That's the output put together from two runs, see What Broke. The NAT gateway and the Elastic IP were the only things costing real money, and both are gone. The order matters. Instances before the subnets they're in, the NAT gateway before its Elastic IP, and everything inside the VPC before the VPC itself. Lab 02 sent another round of IAM change emails for the role.

## What Broke and How I Fixed It

**The app server didn't show up after I added the NAT gateway.** The route was there and the NAT was available, but `start-session` said `TargetNotConnected` and the app server still wasn't in the Session Manager list. My guess is the SSM agent had spent the whole of part 1 failing to reach the internet and was backing off longer and longer between retries. I rebooted the instance so the agent started fresh, and two minutes later it was Online.

**My first round of NACL tests proved nothing.** I ran all the rule changes and the restore one after the other, and only curled from PowerShell at the end, so every test said `exit 0`. When I tried again, putting the default NACL back failed with `InvalidAssociationID.NotFound`. Every time you swap a subnet's NACL the association gets a new ID and the old one stops existing. My saved ID was from before the first restore, so the NACL wasn't even attached anymore, which also explains why everything worked. I attached it again, looked up the current association ID right before restoring instead of trusting the saved one, and did one change then one curl at a time. That's the table in step 10.

**Teardown left the VPC behind.** The first run ended with `DependencyViolation` on `DeleteVpc`, and there were no `deleted: rtb-` lines in the output. The two route tables were still there. The filter that's supposed to skip the main route table was `RouteTables[?!Associations[?Main]]`, and the `!` grabs `Associations` before the filter runs, so it matched no tables at all. `RouteTables[?!(Associations[?Main])]` with the brackets matched both of mine. I fixed it in [teardown.sh](teardown.sh) and ran it again, which deleted the two route tables and the VPC.

**CloudShell kept forgetting my variables.** It restarts after about 20 minutes of doing nothing and every `$VPC` and `$NACL` goes with it. That's why I kept saving IDs to `~/lab05.env` as I went. After a restart, `source ~/lab05.env` brought them back. My IP I set again by hand each time so it never ended up in a file.
