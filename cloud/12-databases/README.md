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
| [database.tf](database.tf) | The database, an optional read replica and the DynamoDB table |
| [client.tf](client.tf), [client.sh.tftpl](client.sh.tftpl) | The test instance, with `psql` and a loop that writes one row a second |
| [variables.tf](variables.tf) | `multi_az` and `read_replica`, both off to start with |

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
