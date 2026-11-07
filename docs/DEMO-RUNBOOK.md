# Demo runbook: Self-Healing Canaries (ArgoCon NA)

Demo time is about 12 minutes, split into two parts. Each beat lists the command to run, what to point at on screen, and the fallback.

## Screens to have open

| Tab | URL / command |
|---|---|
| Terminal A (driver) | `scripts/demo/*` |
| Terminal B (agent) | `kubectl --context kind-staging -n ai-sre logs -f deploy/ai-sre -c ai-sre` (AURA itself: `-c aura`) |
| Rollouts UI, staging | `kubectl argo rollouts dashboard --context kind-staging` → http://localhost:3100 |
| Rollouts UI, prod | `kubectl argo rollouts dashboard --context kind-prod -p 3101` → http://localhost:3101 |
| Grafana | http://localhost:3000 → *Self-Healing Canaries* dashboard |
| AI SRE ledger | http://localhost:8088 |
| GitHub | the repo's Pull requests tab |
| Argo CD (optional) | https://localhost:8443 |

---

## T-1 day: setup (about 15 minutes)

1. Fork/push this repo to GitHub, then set `GITHUB_REPO` and `IMAGE_OWNER` in `demo.env` (and in the
   `newName:` lines in `deploy/overlays/*/kustomization.yaml`).
2. **Actions → release → Run workflow** (tag `v1.0.0`). This builds payment, inventory, loadgen and ai-sre for
   amd64 and arm64.
3. Set the 4 GHCR packages (`scn-*`) to **public**, so the kind clusters can pull without a secret.
4. Run `cp ai-sre/.env.example ai-sre/.env` and fill in `NEBIUS_API_KEY` (Token Factory) and a **fine-grained PAT**. The PAT should cover only this repo, with
   Contents and Pull requests set to read/write.
5. Run `scripts/protect-main.sh`. After this, a PR is required to change main.
6. Run `scripts/up.sh`, which creates the two kind clusters and everything on them.
7. Run `scripts/demo/status.sh`. Both rollouts should be `Healthy` on `v1.0.0`, and the ledger should show `passed` for both envs.
8. Run `scripts/demo/prepare.sh`. It tags `demo-baseline`, opens **PR #1** and waits for its image to build.
9. **Rehearse the full run, then `scripts/demo/reset.sh` + `scripts/demo/prepare.sh`.** Do this at least 3 times.
10. Record a fallback video of one full successful run.

Offline-ish rehearsal: `scripts/build-local.sh` loads the images into kind without GHCR. Argo CD still needs GitHub access.

---

## Part 1: a PR in staging (about 6 minutes)

### Beat 1: the PR (30s)
Open PR #1 on GitHub. Point at the checks: tests are green and the build is green. The PR "migrates to inventory v2 + PSP v2".

### Beat 2: deploy the PR to staging (instant)
```bash
scripts/demo/deploy-pr-to-staging.sh feat/inventory-v2-psp-v2
```
Show the Rollouts UI for staging: the canary sits at **1%** through Gateway API, and the AnalysisRun starts.

### Beat 3: the gate vs the witnesses (about 45s)
On the Grafana staging row:
- **Error rate per ReplicaSet**: the canary hash rises to ~30%.
- **Service-wide**: about 0.3%, below the 1% line. *"This is what your SLO alert sees."*
- **p95 per ReplicaSet**: the canary is *faster*.

In the Rollouts UI AnalysisRun, `canary-error-rate` fails and the two dry-run metrics are labelled dry-run.
**Abort → 100% stable**, in well under a minute.

### Beat 4: the loop closes on its own
Terminal B / http://localhost:8088. The notification arrived and nobody ran anything. Narrate the tool calls as they scroll:
`compare_environments` → `query_prometheus` (canary hash) → `query_loki_logs` (all errors are sku-7/8/9,
"no 'available' field") → `get_commit` / `get_file_contents` → `push_files` to the PR branch → `add_issue_comment`.

> **Fallback:** if no investigation starts within about 20s, run `scripts/demo/trigger-ai-sre.sh staging`.
> If the agent's patch fails CI, run `scripts/demo/fallback-fix.sh pr1`.

### Beat 5: verification (about 90s CI; talk over it)
Show the PR comment with the evidence. `pr-image` rebuilds the image and bumps the overlay, Argo CD syncs, and a new
canary starts. While it runs, go back to slides: *"What just happened"*.
The canary passes: 1 → 25 → 50 → 100. Ledger: `staging … passed`.

### Beat 6: merge, the human step
```bash
scripts/demo/merge.sh
```
*"Merging is the promotion. Prod gets the exact image staging judged."*

---

## Part 2: prod sees what staging couldn't (about 6 minutes)

### Beat 7: the prod canary fails
`merge.sh` opens the prod rollout watch. Canary at 1%, and the gate fails (~10% of canary requests).
Service-wide in prod: about 0.1%. Abort.

### Beat 8: the agent compares environments
On the ledger page, the same image `passed` in staging and `failed` in prod. Agent steps to narrate:
- `compare_environments` → *"same image passed staging"*
- Loki-prod: every error is `JPY` / `ap-northeast`, `limit_exceeded: amount_minor=650000`
- reads `deploy/overlays/*/loadgen.env` → *"staging never sends JPY"*
- `create_branch` → `push_files` (code fix **and** JPY added to staging's profile) → `create_pull_request`

> **Fallback:** `scripts/demo/trigger-ai-sre.sh prod`, or `scripts/demo/fallback-fix.sh pr2`.

### Beat 9: back through staging
```bash
scripts/demo/deploy-pr-to-staging.sh          # picks the newest open PR (the agent's)
```
This is the bonus moment. Staging now sends JPY, so the **old stable** pods start failing JPY. The
service-wide dry run goes **red (~10%)** while the canary-scoped gate passes the fix.
*"An aggregate gate would have blocked the fix."*

### Beat 10: merge → prod green
```bash
scripts/demo/merge.sh
```
Prod canary passes 1 → 25 → 50 → 100. End on the ledger page.

---

## Reset between rehearsals
```bash
scripts/demo/reset.sh && scripts/demo/prepare.sh
```

## Known gotchas
- **Argo CD vs Rollouts on HTTPRoute weights.** The Applications ignore `.spec.rules[].backendRefs[].weight`.
  If you remove that, self-heal fights the canary.
- **No traffic means Inconclusive, not pass.** If the loadgen isn't running, the AnalysisRun pauses. Check
  `kubectl --context kind-staging -n payments logs deploy/loadgen`.
- **Argo CD polling is set to 15s** (`timeout.reconciliation`). With a GitHub webhook, sync is instant.
- **Metric names** come from otelhttp v0.57 (`http_server_duration_milliseconds_*`, `http_status_code`).
  When you bump otelhttp to the stable semconv (`http_server_request_duration_seconds_*`,
  `http_response_status_code`), update `deploy/base/analysis-template.yaml`, the dashboard and the playbook.
- **The agent's PR author is you** when it uses your PAT. Use a machine user or GitHub App if you want
  required reviews (`REVIEWS=1 scripts/protect-main.sh`).
