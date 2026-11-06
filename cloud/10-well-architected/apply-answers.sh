#!/usr/bin/env bash
# Saves answers.json into the review, safe to run again
set -euo pipefail
export AWS_DEFAULT_REGION=us-east-1
WL=$(aws wellarchitected list-workloads --workload-name-prefix lab07-review --query 'WorkloadSummaries[0].WorkloadId' --output text)

jq -c '.[]' answers.json | while read -r a; do
  q=$(jq -r .question <<<"$a")
  notes=$(jq -r .notes <<<"$a")
  if [ "$(jq -r .applicable <<<"$a")" = false ]; then
    aws wellarchitected update-answer --workload-id "$WL" --lens-alias wellarchitected --question-id "$q" --no-is-applicable --reason OUT_OF_SCOPE --notes "$notes" >/dev/null </dev/null
  else
    mapfile -t choices < <(jq -r '.choices[]' <<<"$a")
    aws wellarchitected update-answer --workload-id "$WL" --lens-alias wellarchitected --question-id "$q" --is-applicable --selected-choices "${choices[@]}" --notes "$notes" >/dev/null </dev/null
  fi
  echo "saved: $q"
done

aws wellarchitected get-lens-review --workload-id "$WL" --lens-alias wellarchitected --query 'LensReview.PillarReviewSummaries[].{Pillar:PillarName,High:RiskCounts.HIGH,Medium:RiskCounts.MEDIUM,None:RiskCounts.NONE,NA:RiskCounts.NOT_APPLICABLE,Unanswered:RiskCounts.UNANSWERED}' --output table
