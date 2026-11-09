#!/bin/bash
# Source this from the lab folder after the apply: source helpers.sh
B=$(terraform output -raw bucket)
U=$(terraform output -raw user)

# Runs one aws command with the leaked key
x() {
  env -u AWS_SESSION_TOKEN AWS_ACCESS_KEY_ID="$AK" AWS_SECRET_ACCESS_KEY="$SK" aws "$@" 2>&1 | sed -E 's/[0-9]{12}/123456789012/g'
}

# Gets a session with the leaked key, the way an attacker would keep access
steal_session() {
  local c
  c=$(env -u AWS_SESSION_TOKEN AWS_ACCESS_KEY_ID="$AK" AWS_SECRET_ACCESS_KEY="$SK" aws sts get-session-token --duration-seconds 3600 --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text) || return 1
  SAK=$(cut -f1 <<<"$c") SSK=$(cut -f2 <<<"$c") STOK=$(cut -f3 <<<"$c")
  echo "session ready"
}

# Runs one aws command with that session
xs() {
  AWS_ACCESS_KEY_ID="$SAK" AWS_SECRET_ACCESS_KEY="$SSK" AWS_SESSION_TOKEN="$STOK" aws "$@" 2>&1 | sed -E 's/[0-9]{12}/123456789012/g'
}

# Lists CloudTrail events since $SINCE in the regions the drill touched
trail() {
  for r in us-east-1 eu-west-1 ap-southeast-1; do
    aws cloudtrail lookup-events --region "$r" --lookup-attributes AttributeKey="$1",AttributeValue="$2" --start-time "$SINCE" --output json |
      jq -r --arg r "$r" '.Events[].CloudTrailEvent | fromjson | [.eventTime, $r, .eventName, (.errorCode // "ok"), ((.userIdentity.accessKeyId // "-") | .[0:4] + "..."), .sourceIPAddress] | @tsv'
  done | sort
}
