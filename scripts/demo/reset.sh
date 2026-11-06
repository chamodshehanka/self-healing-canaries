#!/usr/bin/env bash
# Back to the starting line: close demo PRs, restore apps/ + deploy/ on main to the
# demo-baseline tag (via an admin-merged PR — no force-push), point staging at main,
# clear the ledger.
source "$(dirname "$0")/../lib.sh"
need gh git kubectl
cd "$ROOT"
beat "Reset the demo? This closes ALL open PRs in $GITHUB_REPO and resets main's apps/ and deploy/."
for pr in $(gh pr list -R "$GITHUB_REPO" --state open --json number --jq '.[].number'); do
  gh pr close -R "$GITHUB_REPO" "$pr" --delete-branch
done
git push -q origin --delete "$PR1_BRANCH" 2>/dev/null || true
git switch -q main 2>/dev/null || true
git branch -q -D "$PR1_BRANCH" 2>/dev/null || true   # prepare.sh recreates it

git fetch -q origin --tags
BR="reset/$(date +%s)"
git switch -q -c "$BR" origin/main
git checkout demo-baseline -- apps deploy
if git diff --cached --quiet; then
  ok "main already at baseline"; git switch -q main; git branch -q -D "$BR"
else
  git commit -qm "chore: reset demo to baseline"
  git push -q -u origin "$BR"; git switch -q main
  PR_URL=$(gh pr create -R "$GITHUB_REPO" --base main --head "$BR" --title "chore: reset demo" --body "scripts/demo/reset.sh")
  gh pr merge -R "$GITHUB_REPO" "$PR_URL" --squash --admin --delete-branch
fi
git pull -q --ff-only origin main || true

kubectl "${KSTG[@]}" -n argocd patch application payment-staging --type merge \
  -p '{"spec":{"source":{"targetRevision":"main"}}}' >/dev/null
for app in payment-staging payment-prod; do
  kubectl "${KSTG[@]}" -n argocd annotate application "$app" argocd.argoproj.io/refresh=hard --overwrite >/dev/null
done
kubectl "${KSTG[@]}" -n ai-sre rollout restart deploy/ai-sre >/dev/null
ok "reset. Re-run scripts/demo/prepare.sh to re-open PR #1."
