#!/bin/bash
# Spread out: usage URL=... bash even.sh requests_per_second seconds path
for i in $(seq 1 $(($1 * $2))); do curl -s -o /dev/null -m 30 -w '%{http_code} %{time_total}\n' "$URL$3" & sleep 0.03; done
wait
