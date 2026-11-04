#!/usr/bin/env bash
# Live view of the payment rollout in one environment. Usage: watch.sh staging|prod
source "$(dirname "$0")/../lib.sh"
ENV=${1:-staging}
exec kubectl argo rollouts get rollout payment -n payments --context "kind-$ENV" --watch
