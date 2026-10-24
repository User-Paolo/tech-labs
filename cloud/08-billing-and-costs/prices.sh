#!/usr/bin/env bash
# What one Linux instance costs per hour in us-east-1 under each pricing model
# Usage: bash prices.sh [instance type]
set -euo pipefail
TYPE="${1:-t3.micro}"
ROW='%-22s %-5s %-17s %10s %10s\n'

# Price List API: On Demand and Reserved Instances
PRODUCT=$(aws pricing get-products --region us-east-1 --service-code AmazonEC2 --filters \
  Type=TERM_MATCH,Field=regionCode,Value=us-east-1 \
  Type=TERM_MATCH,Field=usagetype,Value="BoxUsage:$TYPE" \
  Type=TERM_MATCH,Field=operatingSystem,Value=Linux \
  Type=TERM_MATCH,Field=tenancy,Value=Shared \
  Type=TERM_MATCH,Field=preInstalledSw,Value=NA \
  Type=TERM_MATCH,Field=capacitystatus,Value=Used \
  --query 'PriceList[0]' --output text)

{
  echo "$PRODUCT" | jq -r '
    (.terms.OnDemand[] | .priceDimensions[] | ["On Demand", "-", "-", (.pricePerUnit.USD | tonumber)]),
    (.terms.Reserved[] | . as $t
      | (if $t.termAttributes.LeaseContractLength == "1yr" then 1 else 3 end) as $years
      | ([$t.priceDimensions[] | select(.unit == "Hrs") | .pricePerUnit.USD | tonumber] | add // 0) as $hourly
      | ([$t.priceDimensions[] | select(.unit == "Quantity") | .pricePerUnit.USD | tonumber] | add // 0) as $upfront
      | ["Reserved \($t.termAttributes.OfferingClass)", $t.termAttributes.LeaseContractLength,
         $t.termAttributes.PurchaseOption, ($hourly + $upfront / ($years * 8760))])
    | @tsv'

  # Savings Plans API
  aws savingsplans describe-savings-plans-offering-rates --region us-east-1 \
    --products EC2 --service-codes AmazonEC2 --usage-types "BoxUsage:$TYPE" --operations RunInstances \
    --filters name=region,values=us-east-1 name=tenancy,values=shared name=productDescription,values=Linux/UNIX \
    --max-results 1000 \
    --query 'searchResults[].[savingsPlanOffering.planType,savingsPlanOffering.durationSeconds,savingsPlanOffering.paymentOption,rate]' \
    --output text | awk -F'\t' '{printf "%s plan\t%dyr\t%s\t%s\n", $1, $2 / 31536000, $3, $4}'

  # Spot price right now, per AZ
  aws ec2 describe-spot-price-history --region us-east-1 --instance-types "$TYPE" \
    --product-descriptions Linux/UNIX --start-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --query 'SpotPriceHistory[].[AvailabilityZone,SpotPrice]' --output text \
    | awk -F'\t' '{printf "Spot\t-\t%s\t%s\n", $1, $2}'
} | sort -t$'\t' -k4 -g | {
  printf "$ROW" "$TYPE" "term" "payment or AZ" "per hour" "per month"
  while IFS=$'\t' read -r model term payment rate; do
    printf "$ROW" "$model" "$term" "$payment" "$(printf '%.4f' "$rate")" "$(awk -v r="$rate" 'BEGIN { printf "%.2f", r * 730 }')"
  done
}
