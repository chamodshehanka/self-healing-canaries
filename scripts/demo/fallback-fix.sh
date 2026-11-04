#!/usr/bin/env bash
# Plan B if the live agent's patch doesn't build: push the known-good fix.
#   fallback-fix.sh pr1   -> push fix A (multi-warehouse stock) to PR #1's branch
#   fallback-fix.sh pr2   -> open a PR with fix B (zero-decimal currencies) + staging JPY traffic
source "$(dirname "$0")/../lib.sh"
need gh git
cd "$ROOT"; git fetch -q origin
case "${1:-}" in
  pr1)
    git switch -q -C "$PR1_BRANCH" "origin/$PR1_BRANCH"
    cp -R demo/fixes/pr1-staging/apps/. apps/
    git commit -qam "fix: sum per-warehouse stock for multi-warehouse SKUs (inventory v2)"
    git push -q origin "$PR1_BRANCH"; git switch -q main
    ok "pushed fix A to $PR1_BRANCH" ;;
  pr2)
    BR="ai-sre/fix-fallback-$(date +%s)"
    git switch -q -c "$BR" origin/main
    cp -R demo/fixes/pr2-prod/. .
    git add apps deploy/overlays/staging/loadgen.env
    git commit -qm "fix: zero-decimal currencies in toMinorUnits; staging sends prod's currency mix"
    git push -q -u origin "$BR"; git switch -q main
    gh pr create -R "$GITHUB_REPO" --base main --head "$BR" \
      --title "fix: JPY minor units (prod canary aborted)" \
      --body "PSP v2 takes minor units; JPY has none. \`toMinorUnits\` multiplied every currency by 100, so ¥1,500 was sent as 150,000 and rejected (limit_exceeded). Staging never sent JPY — this PR also adds prod's currency mix to staging's load profile."
    ok "opened fallback PR from $BR" ;;
  *) die "usage: fallback-fix.sh pr1|pr2" ;;
esac
