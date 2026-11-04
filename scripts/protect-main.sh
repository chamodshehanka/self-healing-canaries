#!/usr/bin/env bash
# The human-in-the-loop boundary: nothing lands on main without a pull request.
# The AI SRE's token can push branches and open PRs; a human merges.
#
# REVIEWS=1 additionally requires an approving review. Only use it if the AI SRE
# runs as a separate GitHub identity (machine user / GitHub App) — you can't
# approve PRs you authored, and with a personal PAT the agent's PRs are "yours".
source "$(dirname "$0")/lib.sh"
need gh
REVIEWS=${REVIEWS:-0}
gh api -X PUT "repos/$GITHUB_REPO/branches/main/protection" --input - <<JSON
{
  "required_status_checks": null,
  "enforce_admins": false,
  "required_pull_request_reviews": {"required_approving_review_count": $REVIEWS},
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false
}
JSON
ok "main requires a PR ($REVIEWS approving reviews)"
