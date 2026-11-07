#!/bin/bash
# Status codes and timings from a load test log
awk '{print $1}' "$1" | sort | uniq -c
sort -k2 -n "$1" | awk '{a[NR]=$2} END{print "requests",NR,"p50",a[int(NR*.5)],"p95",a[int(NR*.95)],"p99",a[int(NR*.99)],"max",a[NR]}'
