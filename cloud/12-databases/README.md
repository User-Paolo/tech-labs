# 12 Databases

**Track:** Cloud
**Exam topics:** AWS Cloud Practitioner, Cloud Technology (RDS, Multi AZ, read replicas, snapshots, DynamoDB) and Security and Compliance (Secrets Manager)

## Question
For the exam I know that Multi AZ is for surviving failures and read replicas are for scaling reads, but I've never watched either of them work. If the database fails while something is writing to it, how long is it actually gone? What happens when I try to write to a read replica? Can I get deleted rows back from a snapshot?

This also picks up a gap from the review in [lab 10](../10-well-architected/). I had no secrets or backups to manage, because nothing I've built so far holds any data.

## Setup
PostgreSQL on RDS and a DynamoDB table, in Terraform from CloudShell in `us-east-1`. Nothing is open to the internet this time, so I don't need my IP. I reach a small test instance with Session Manager and run everything against the database from there.

```
            NAT gateway in public a, for the SSM agent and packages
                         |
              test instance, private a  10.0.11.0/24
                 |                        |
                 | port 5432              | 443 through the NAT
                 |                        |
          RDS PostgreSQL            Secrets Manager (the password)
   private a  10.0.11.0/24          DynamoDB table
   private b  10.0.12.0/24
```

| File | What's in it |
|---|---|
| [versions.tf](versions.tf), [network.tf](network.tf) | Same as earlier labs, with one public subnet because only the NAT gateway needs it |
| [security.tf](security.tf) | Port 5432 from the test instance only, and a role that can read this one secret and use this one table |
| [database.tf](database.tf) | The database and the DynamoDB table |
| [client.tf](client.tf), [client.sh.tftpl](client.sh.tftpl) | The test instance, with `psql` and a loop that writes one row a second |
| [variables.tf](variables.tf) | `multi_az`, off to start with |

Cost: the prices I'm working with are below. With the NAT gateway and the test instance on top, that's about $0.08 an hour with one database in a single AZ and about $0.12 with Multi AZ and a replica. I expect under $1 in total.

## Steps and Evidence

### 1. Is it allowed on the Free plan?
Four security services were blocked in [lab 09](../09-security-services/), so I checked this first:
```
$ aws rds describe-db-instances --query 'length(DBInstances)'
0
$ aws secretsmanager list-secrets --query 'length(SecretList)'
0
$ aws dynamodb list-tables --query 'length(TableNames)'
0
$ aws rds describe-orderable-db-instance-options --engine postgres --db-instance-class db.t4g.micro --query 'OrderableDBInstanceOptions[0].{MultiAZ:MultiAZCapable,Replica:ReadReplicaCapable,Version:EngineVersion}' --output table
| MultiAZ | Replica | Version |
|  True   |  True   |  12.22  |
```
A number from each one and no `SubscriptionRequiredException`, so all three services open. The last command only tells me this instance class supports Multi AZ and replicas. The Free plan could still refuse them when I create the database, so I'll find out when I apply.

Multi AZ costs exactly double, which makes sense since it's a second copy of the instance running all the time:
```
Single-AZ       0.0160000000
Multi-AZ        0.0320000000
```

### 2. How I set it up
The database starts in one AZ. I want to see if turning on Multi AZ later takes the database down, and I can only test that if it starts without it.

I don't set a password anywhere. With `manage_master_user_password` RDS makes the password itself and keeps it in Secrets Manager, and the test instance reads it from there when it needs it. The role on the instance can read that one secret and nothing else.

The loop in [client.sh.tftpl](client.sh.tftpl) opens a new connection and inserts one row every second, and prints the time, the result and the IP address behind the database endpoint. That should give me the length of an outage in seconds, and show me if the address changes.

### 3. The Free plan has a limit on backups
The first apply built the network and then stopped at the database:
```
Error: creating RDS DB Instance (lab12-db): ... api error FreeTierRestrictionError:
The specified backup retention period exceeds the maximum available to free tier customers.
To remove all limitations, upgrade your account plan.
```
I had asked for 7 days. The error doesn't say what the maximum is, so I tried 1 and it was accepted. I didn't try anything between 2 and 6.

The database came up on the second apply, and the password really isn't in the Terraform state:
```
$ terraform state pull | jq '... {password_in_state: ..., managed_secret: ...}'
{
  "password_in_state": false,
  "managed_secret": 1
}
```

### 4. Restarting it in one AZ
I wanted something to compare the failover against, so I started the loop and rebooted the database while it was still in a single AZ:
```
14:34:11 ok id=24 10.0.11.253
14:34:12 FAIL 10.0.11.253       Is the server running on that host and accepting TCP/IP con
...
14:34:22 FAIL 10.0.11.253       Is the server running on that host and accepting TCP/IP con
14:34:24 ok id=25 10.0.11.253
```
That's 12 seconds without writes. The RDS event for `DB instance restarted` is stamped 14:34:30, 6 seconds after the loop was already writing again, so I wouldn't time an outage from the events.

### 5. Turning on Multi AZ
I expected this to go through without an outage, so I left the loop running to check. The apply took 8 minutes 18 seconds, and writes kept working for nearly all of it:
```
14:47:26 ok id=503 10.0.11.253
14:47:27 FAIL 10.0.11.253       Is the server running on that host and accepting TCP/IP con
14:47:28 FAIL 10.0.12.6         Is the server running on that host and accepting TCP/IP con
...
14:47:32 FAIL 10.0.11.253       Is the server running on that host and accepting TCP/IP con
14:47:33 FAIL 10.0.12.6         Is the server running on that host and accepting TCP/IP con
...
14:47:46 FAIL 10.0.12.6         Is the server running on that host and accepting TCP/IP con
14:47:47 ok id=504 10.0.12.6
14:47:49 ok id=505 10.0.11.253
```
So there was an outage, 20 seconds of it, starting about 30 seconds after RDS logged the conversion as finished. That's longer than the plain restart. The address also moved to `10.0.12.6` in private b and then came back to `10.0.11.253`. RDS logged no failover and I don't know why it did that.

### 6. Forcing a failover
This is the test I built the lab for. With the loop running again:
```
$ aws rds reboot-db-instance --db-instance-identifier lab12-db --force-failover
```
```
14:53:13 ok id=626 10.0.11.253
14:53:14 FAIL 10.0.11.253
14:53:18 FAIL 10.0.11.253 psql: error: connection to server at ...
14:53:21 FAIL 10.0.12.6         Is the server running on that host and accepting TCP/IP con
...
14:53:27 FAIL 10.0.12.6         Is the server running on that host and accepting TCP/IP con
14:53:28 ok id=636 10.0.12.6
```
14 seconds. The endpoint name stayed the same and the address behind it moved to private b, so the loop didn't need any changes.

| Test | Writes down for |
|---|---|
| Restart in a single AZ | 12 seconds |
| Turning on Multi AZ | 20 seconds |
| Forced failover | 14 seconds |

The failover took about as long as a restart, so Multi AZ didn't make this faster for me. What it should buy me is that the database comes back when the whole AZ is gone, and I can't break an AZ to compare that. This was also a nearly empty database with one small write a second, so I wouldn't expect these numbers to hold for a busy one.

The ids jumped from 626 to 636, so I checked whether rows went missing:
```
$ db -Atc 'select count(*), min(id), max(id) from heartbeat'
734|1|743
$ ids=$(grep -hoP 'id=\K\d+' /tmp/reboot.log /tmp/convert.log /tmp/failover.log | paste -sd,)
$ echo "$ids" | tr ',' '\n' | wc -l
734
$ db -Atc "select count(*) from heartbeat where id in ($ids)"
734
```
All 734 writes the loop reported as `ok` are in the table, and nothing else is. The 9 missing numbers are a gap in the id sequence and no data was lost. So ids from a sequence can have holes in them after a failover.

Two more things I noticed. The failover command printed `InvalidDBInstanceState`, even though the failover happened. CloudTrail shows the call succeeded at 14:53:06 and the same call failed at 14:53:44 while the database was still `rebooting`. My guess is the CLI retried because it never got an answer to the first one.

The API was also slow to catch up. After converting, `SecondaryAvailabilityZone` showed `None` for several minutes. After the failover, `AvailabilityZone` still said `us-east-1a` while the database was answering from the `us-east-1b` subnet. By about 15:04 it said `us-east-1b` with the standby in `us-east-1a`.

### 7. A read replica won't work with the managed password
Next I tried to add a read replica, and RDS refused:
```
api error InvalidParameterValue: Creating read replicas for source instance with engine postgres
where ManageMasterUserPassword is enabled is not supported.
```
This has nothing to do with the Free plan. Letting RDS manage the password rules out creating a replica from that database. I took the replica out of the Terraform code, and I'll come back to it at the end of the lab with the CLI, after turning the managed password off.

### 8. Rotating the password
RDS owns the secret and rotates it every 7 days without me setting anything up:
```
| Days | Owner | Rotation |
|  7   |  rds  |  True    |
```
The loop reads the password once when it starts and keeps it, like an app that never looks at the secret again. I rotated the secret by hand with the loop running, to see what that app would see:
```
15:04:19 ok id=1046 10.0.12.6
15:04:20 FAIL 10.0.12.6 psql: error: connection to server at ...
...
15:05:13 FAIL 10.0.12.6 psql: error: connection to server at ...
```
I expected that part. An app that holds on to the password stops working at the rotation, and with the default schedule that happens every week.

What I didn't expect was that a fresh login failed too. When I stopped the loop I tried one that read the password from Secrets Manager first, and got `password authentication failed`. Trying again at 15:06:31 worked. The secret's `LastRotatedDate` is 15:05:20, exactly a minute after the loop's first failure. It looks like the database had the new password for about a minute while the secret was still handing out the old one, so reading the secret again isn't enough on its own. An app would also need to retry when a login fails.
