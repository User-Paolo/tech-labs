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

### 9. Getting deleted rows back
I made a small `customers` table and tried both kinds of backup against the same accident:

| Time | What I did |
|---|---|
| | Added `anna` and `ben` |
| 18:47 to 18:52 | Took a snapshot, about 5 minutes |
| | Added `cara` |
| 18:56:09 | Saved the time as my restore point |
| | Ran `delete from customers`, 3 rows gone |

Point in time recovery can't restore to a moment until the transaction logs have caught up, so I waited until `LatestRestorableTime` passed 18:56:09, which took under 3 minutes. Then I started both restores, and the second one was refused:
```
An error occurred (InstanceQuotaExceeded) when calling the RestoreDBInstanceToPointInTime operation:
You reached the maximum number of instances available with free plan accounts.
```
The main database and the restore from the snapshot were already there, so the limit looks like 2 database instances. The error doesn't give a number. I checked the first copy, deleted it and then ran the second restore.

```
$ db -h "$R" -c "select * from customers"       # restored from the snapshot
 anna | before the snapshot
 ben  | before the snapshot

$ db -h "$R" -c "select * from customers"       # restored to 18:56:09
 anna | before the snapshot
 ben  | before the snapshot
 cara | after the snapshot
```

| Restore | Got back | Time until available |
|---|---|---|
| Snapshot | Everything up to the snapshot | About 7 minutes |
| Point in time | Everything up to my restore point | About 12 minutes |

The original database still had 0 rows after both, because a restore always creates a new database with a new address. So getting the data back is only part of it, the app would also have to be pointed at the new address. Both copies accepted the current password. I only ran each restore once on a very small database, so I wouldn't read much into the difference in time.

### 10. DynamoDB
Same data, very different setup. There's no instance size, subnet or AZ for me to pick, and no password. The test instance gets in with its IAM role:
```
$ aws dynamodb put-item --table-name "$TABLE" --item '{"id":{"S":"anna"},"note":{"S":"first item"}}'
$ aws dynamodb put-item --table-name "$TABLE" --item '{"id":{"S":"ben"},"note":{"S":"extra fields"},"city":{"S":"Oslo"},"orders":{"N":"3"}}'
$ aws dynamodb scan --table-name "$TABLE" --query 'Items[].{id:id.S,note:note.S,city:city.S,orders:orders.N}' --output table
| city | id   | note         | orders |
| Oslo | ben  | extra fields | 3      |
| None | anna | first item   | None   |
```
`ben` has two fields that `anna` doesn't, and I didn't have to change the table for that. PostgreSQL won't do the same without changing the table first:
```
$ db -c "insert into customers (name, city) values ('dan', 'Oslo')"
ERROR:  column "city" of relation "customers" does not exist
```
The role is limited to this one table, so listing tables is denied:
```
$ aws dynamodb list-tables 2>&1 | grep -o AccessDeniedException
AccessDeniedException
```
The other side of this is that the role only allows `GetItem`, `PutItem` and `Scan`, and a scan reads the whole table. Looking things up by anything other than the key takes more planning here than a `where` clause does in PostgreSQL.

Point in time recovery is turned on for the table in [database.tf](database.tf), but I didn't test a restore. I also can't test a failover here, since AWS doesn't give me anything to fail over.

### 11. Back to the read replica
I left this for last because the managed password had to go first, and that deletes its secret. I turned it off and kept the same password, so the loop never noticed:
```
$ aws rds modify-db-instance --db-instance-identifier lab12-db --no-manage-master-user-password --master-user-password "$PW" --apply-immediately
```
This time RDS accepted the replica, so the error in step 7 really was about the password. It took about 8.5 minutes to build, and the loop had 0 failed writes the whole time. It also landed in `us-east-1b`, the same AZ as the main database, so this replica wouldn't have helped if that AZ went down.

Then the three things I wanted to see:
```
$ psql -h "$R" -Atc "select 'read only copy: ' || pg_is_in_recovery()"
read only copy: true
$ psql -h "$R" -c "insert into customers values ('eve', 'written to the replica')"
ERROR:  cannot execute INSERT in a read-only transaction
$ for i in 1 2 3 4 5; do psql -h "$R" -Atc "select 'lag ' || (now() - pg_last_xact_replay_timestamp())"; sleep 2; done
lag 00:00:00.21988
lag 00:00:00.17604
lag 00:00:00.128627
lag 00:00:00.082246
lag 00:00:00.040244
```
So it follows the main database closely, at least with one small write a second.

Promoting it took about 5 minutes and turned it into its own database:
```
read only copy: false
INSERT 0 1
promoted copy has 1 customers
main database has 0 customers
promoted heartbeat 2125
main heartbeat 2496
```
`eve` only exists on the promoted copy, and the heartbeat count on the copy stopped at the moment they split. The main database kept writing with 0 failures.

This is the comparison I wanted from the start:

| | Multi AZ standby | Read replica |
|---|---|---|
| Can I read from it? | No, the AWS docs say a standby can't serve reads | Yes |
| Can I write to it? | No | Not until it's promoted |
| Address | The same endpoint moves to it | Its own address |
| Taking over | Failover, 14 seconds in my test | I promote it, about 5 minutes, then point the app at it |
| Keeping up | Synchronous, according to the AWS docs | 0.04 to 0.22 seconds behind in my test |
| Works with the RDS managed password? | Yes | Not when creating the replica |

I turned the managed password back on afterwards, and that took under a minute.

### 12. Cleaning up
The replica and the snapshot were made with the CLI, so I deleted those first and then ran the destroy:
```
Destroy complete! Resources: 28 destroyed.
```
```
rds: 0
snapshots: 0
auto backups: 0
subnet groups: 0
dynamodb: 0
secrets: 0
nat: 0
elastic ips: 0
instances: 0
vpcs: 0
role: 0
```
The secret went away with the database, so there was nothing left to clean up in Secrets Manager.

I'm not updating the review from [lab 10](../10-well-architected/) this time. It scores lab 07, which still has no data store, and this lab was a separate setup. So the backup and secrets questions there stay as they were, but I've now done both on a real database.

The Free plan limits from this lab are ones I need to remember for the final project:

| Limit | What I saw |
|---|---|
| RDS backups | 7 days refused, 1 day accepted, 2 to 6 not tried |
| RDS instances | A third one refused while 2 existed |
| Multi AZ | Allowed |
| Read replicas | Allowed |

## What Broke and How I Fixed It

**The first apply stopped halfway.** `FreeTierRestrictionError` on the 7 days of backups, after the network had already been created. The NAT gateway was already billing, so I lowered it to 1 and applied again. Terraform only made what was missing.

**The read replica was refused.** Creating one isn't supported while RDS manages the password on the source database. I took it out of the Terraform code, ran the other tests first, and then made the replica with the CLI after turning the managed password off.

**The second restore was refused.** `InstanceQuotaExceeded`, because of the instance limit on the Free plan. I ran the restores one at a time instead of side by side.

**A fresh login failed after the rotation.** I thought the rotated password was broken, but the rotation just hadn't finished. It worked a minute later, and that became part of step 8.

**`terraform output` failed after a break.** CloudShell had restarted and `/tmp` was wiped, and my `TF_DATA_DIR` is in `/tmp`, so I got `Required plugins are not installed`. The state file is in my home folder and survived, so running `terraform init` again fixed it. In another tab `start-session` failed with `Invalid length for parameter Target`, because I wasn't in the Terraform folder and `terraform output` came back empty.
