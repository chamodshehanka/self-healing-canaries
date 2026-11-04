#!/usr/bin/env bash
# Fallback: if a notification didn't arrive, build the same payload from the live
# Rollout and hand it to the AI SRE. Usage: trigger-ai-sre.sh staging|prod
source "$(dirname "$0")/../lib.sh"
ENV=${1:-staging}
export RO ENV
RO=$(kubectl --context "kind-$ENV" -n payments get rollout payment -o json)
python3 - <<'PY' | curl -fsS -X POST localhost:8088/investigate -H 'Content-Type: application/json' -d @-
import json, os
env = os.environ["ENV"]; r = json.loads(os.environ["RO"]); a = r["metadata"].get("annotations", {})
print(json.dumps({"event": "aborted", "cluster": env, "env": env, "namespace": "payments", "rollout": "payment",
  "image": r["spec"]["template"]["spec"]["containers"][0]["image"],
  "canaryHash": r["status"].get("currentPodHash"), "stableHash": r["status"].get("stableRS"),
  "gitSha": a.get("scn.dev/git-sha"), "sourcePR": a.get("scn.dev/source-pr"), "sourceBranch": a.get("scn.dev/source-branch")}))
PY
echo; ok "investigation started — watch http://localhost:8088"
