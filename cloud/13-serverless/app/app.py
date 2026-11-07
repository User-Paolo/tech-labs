import json
import os
import time

import boto3

table = boto3.resource("dynamodb").Table(os.environ["TABLE"])
first_request = True


def handler(event, context):
    global first_request
    cold, first_request = first_request, False

    path = event["rawPath"]
    if path == "/boom":
        raise RuntimeError("broken on purpose")
    if path == "/slow":
        time.sleep(1)

    result = table.update_item(
        Key={"id": "visits"},
        UpdateExpression="ADD hits :one",
        ExpressionAttributeValues={":one": 1},
        ReturnValues="UPDATED_NEW",
    )

    return {
        "statusCode": 200,
        "headers": {"content-type": "application/json"},
        "body": json.dumps(
            {
                "page": os.environ["PAGE_VERSION"],
                "visits": int(result["Attributes"]["hits"]),
                "cold": cold,
            }
        ),
    }
