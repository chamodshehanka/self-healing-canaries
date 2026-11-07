#!/usr/bin/env bash
# The human step. Merge the PR -> main -> Argo CD syncs prod with the exact image
# staging just judged. Staging goes back to following main.
# Usage: merge.sh [pr-number]   (default: newest open PR)
source "$(dirname "$0")/../lib.sh"
need gh kubectl
PR=${1:-$(gh pr list -R "$GITHUB_REPO" --state open --json number --jq 'map(.number) | max')}
[[ -n "$PR" && "$PR" != null ]] || die "no open PR"
gh pr view -R "$GITHUB_REPO" "$PR" --json title,headRefName --jq '"\(.title)  [\(.headRefName)]"'
beat "Merge PR #$PR (this is the human in the loop)"
gh pr merge -R "$GITHUB_REPO" "$PR" --squash --delete-branch

kubectl "${KSTG[@]}" -n argocd patch application payment-staging --type merge \
  -p '{"spec":{"source":{"targetRevision":"main"}}}' >/dev/null
for app in payment-staging payment-prod; do
  kubectl "${KSTG[@]}" -n argocd annotate application "$app" argocd.argoproj.io/refresh=hard --overwrite >/dev/null
done
ok "merged; prod syncing from main"
[[ "${NO_WATCH:-0}" == 1 ]] || exec "$(dirname "$0")/watch.sh" prod
