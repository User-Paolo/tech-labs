#!/bin/bash
# Bursts: usage URL=... bash load.sh requests_per_second seconds path
for s in $(seq 1 "$2"); do
  for i in $(seq 1 "$1"); do curl -s -o /dev/null -m 30 -w '%{http_code} %{time_total}\n' "$URL$3" & done
  sleep 1
done
wait
