#!/usr/bin/env bash
# One-screen status of both environments + Argo CD + ledger.
source "$(dirname "$0")/../lib.sh"
for env in staging prod; do
  printf '\n%s── %s ──%s\n' "$c_b" "$env" "$c_0"
  kubectl argo rollouts get rollout payment -n payments --context "kind-$env" 2>/dev/null | sed -n '1,12p' || warn "no rollout yet"
done
printf '\n%s── Argo CD ──%s\n' "$c_b" "$c_0"
kubectl "${KSTG[@]}" -n argocd get applications \
  -o custom-columns='APP:.metadata.name,REVISION:.spec.source.targetRevision,SYNC:.status.sync.status,HEALTH:.status.health.status'
printf '\n%s── ledger ──%s\n' "$c_b" "$c_0"
curl -fsS localhost:8088/api/state 2>/dev/null | python3 -c '
import sys,json
for r in json.load(sys.stdin)["releases"][:8]:
    env, img, h, v = r["env"], r["image"].split("/")[-1], r["pod_hash"] or "", r["verdict"]
    print(f"  {env:8} {img:28} {h:12} {v}")' || warn "AI SRE not reachable on :8088"
