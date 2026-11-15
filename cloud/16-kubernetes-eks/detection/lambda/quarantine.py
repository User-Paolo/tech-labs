import json
import os
from datetime import datetime, timedelta, timezone

import boto3

iam = boto3.client("iam")
sns = boto3.client("sns")
QUARANTINE = "arn:aws:iam::aws:policy/AWSCompromisedKeyQuarantineV3"


def handler(event, context):
    detail = event["detail"]
    who = detail["userIdentity"]
    user = who["userName"]

    # Every call from the key fires this, only the first one has work to do
    attached = iam.list_attached_user_policies(UserName=user)["AttachedPolicies"]
    if any(p["PolicyArn"] == QUARANTINE for p in attached):
        print(json.dumps({"user": user, "event": detail["eventName"], "action": "already locked"}))
        return

    turned_off = []
    for key in iam.list_access_keys(UserName=user)["AccessKeyMetadata"]:
        if key["Status"] == "Active":
            iam.update_access_key(UserName=user, AccessKeyId=key["AccessKeyId"], Status="Inactive")
            turned_off.append(key["AccessKeyId"])

    iam.attach_user_policy(UserName=user, PolicyArn=QUARANTINE)

    # Sessions made from the key before now stop working too
    cutoff = (datetime.now(timezone.utc) + timedelta(seconds=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
    iam.put_user_policy(
        UserName=user,
        PolicyName="revoke-sessions",
        PolicyDocument=json.dumps({
            "Version": "2012-10-17",
            "Statement": [{
                "Effect": "Deny",
                "Action": "*",
                "Resource": "*",
                "Condition": {"DateLessThan": {"aws:TokenIssueTime": cutoff}},
            }],
        }),
    )

    called = datetime.fromisoformat(detail["eventTime"].replace("Z", "+00:00"))
    locked = datetime.now(timezone.utc)
    seconds = round((locked - called).total_seconds())
    lines = [
        "The canary key is locked, nobody had to do anything",
        f"Who: {user}",
        f"What set it off: {detail['eventName']} in {detail['awsRegion']} from {detail.get('sourceIPAddress')}",
        f"Call made: {detail['eventTime']}",
        f"Locked: {locked.strftime('%Y-%m-%dT%H:%M:%SZ')}, {seconds} seconds later",
        f"Keys turned off: {len(turned_off)}",
        "Quarantine policy attached, sessions made before the lock revoked",
    ]
    sns.publish(TopicArn=os.environ["TOPIC_ARN"], Subject="lab16 canary key locked", Message="\n".join(lines))
    print(json.dumps({"user": user, "event": detail["eventName"], "action": "locked", "seconds": seconds, "keys": len(turned_off)}))
