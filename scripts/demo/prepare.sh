#!/usr/bin/env bash
# Night before: tag the baseline and open demo PR #1 so its image is already built.
# On stage, deploying PR #1 to staging is then instant (no CI wait).
source "$(dirname "$0")/../lib.sh"
need gh git
cd "$ROOT"
[[ -z "$(git status --porcelain)" ]] || die "working tree not clean"
git fetch -q origin --tags

say "tagging demo-baseline = origin/main (scripts/demo/reset.sh restores to this)"
git tag -f demo-baseline origin/main >/dev/null
git push -q -f origin demo-baseline

if git ls-remote --exit-code --heads origin "$PR1_BRANCH" >/dev/null; then
  die "branch $PR1_BRANCH already exists — run scripts/demo/reset.sh first"
fi

say "creating PR #1 on $PR1_BRANCH"
git switch -q -c "$PR1_BRANCH" origin/main
cp -R demo/pr1/apps/. apps/
git add apps
git commit -q -m "feat(payment): migrate to inventory v2 API and PSP v2 (minor units)"
git push -q -u origin "$PR1_BRANCH"
git switch -q main

gh pr create -R "$GITHUB_REPO" --base main --head "$PR1_BRANCH" \
  --title "feat(payment): migrate to inventory v2 + PSP v2" --body "$(cat <<'MD'
Inventory v1 and PSP v1 are deprecated next quarter.

- **Inventory v2**: `/v2/stock/{sku}` — no server-side aggregation.
- **PSP v2**: amounts in minor units (`toMinorUnits`).

✅ unit tests pass · ✅ builds · ✅ liveness/readiness unchanged
MD
)"

say "waiting for pr-image to build the image and bump the overlays"
sleep 10
RUN=$(gh run list -R "$GITHUB_REPO" --branch "$PR1_BRANCH" --workflow pr-image.yml -L 1 --json databaseId --jq '.[0].databaseId')
gh run watch -R "$GITHUB_REPO" "$RUN" --exit-status
ok "PR #1 ready. On stage: scripts/demo/deploy-pr-to-staging.sh"
