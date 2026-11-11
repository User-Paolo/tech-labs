#!/usr/bin/env bash
# Puts the real addresses into a copy of the files, so they never end up in the repo
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
out() { terraform -chdir="$here/../../terraform" output -raw "$1"; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp -r "$here/.." "$tmp/k8s"
sed -i "s#123456789012.dkr.ecr.us-east-1.amazonaws.com/lab16-app#$(out ecr_url)#" "$tmp/k8s/eks/kustomization.yaml"
printf 'DB_HOST=%s\nDB_SECRET_ARN=%s\n' "$(out db_address)" "$(out db_secret_arn)" > "$tmp/k8s/eks/db.env"
# apply by default, or diff to see what would change
kubectl "${1:-apply}" -k "$tmp/k8s/eks"
