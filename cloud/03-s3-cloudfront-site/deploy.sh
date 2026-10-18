#!/usr/bin/env bash
# Usage: bash deploy.sh <bucket> [distribution id]
set -euo pipefail

BUCKET="${1:?usage: bash deploy.sh <bucket> [distribution id]}"
DIST="${2:-}"
cd "$(dirname "$0")"

aws s3 sync site/ "s3://$BUCKET/" --delete

# Clear the CloudFront cache only when a distribution is given
if [ -n "$DIST" ]; then
  aws cloudfront create-invalidation --distribution-id "$DIST" --paths '/*' \
    --query 'Invalidation.[Id,Status]' --output text
fi
