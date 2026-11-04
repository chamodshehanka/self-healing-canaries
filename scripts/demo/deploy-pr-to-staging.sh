#!/usr/bin/env bash
# Point the staging Argo CD app at a PR branch -> the PR's image canaries in staging.
# Usage: deploy-pr-to-staging.sh [branch]   (default: newest open PR)
source "$(dirname "$0")/../lib.sh"
need gh kubectl
BR=${1:-$(gh pr list -R "$GITHUB_REPO" --state open --json number,headRefName --jq 'sort_by(.number) | last | .headRefName')}
[[ -n "$BR" && "$BR" != null ]] || die "no open PR found"

TAG=$(gh api "repos/$GITHUB_REPO/contents/deploy/overlays/staging/kustomization.yaml?ref=$BR" --jq .content \
      | base64 -d | awk '/name: payment/{f=1} f&&/newTag:/{print $2; exit}')
say "staging <- $BR  (payment:$TAG)"
[[ "$TAG" == sha-* ]] || warn "overlay on $BR still at $TAG — has pr-image finished?"

kubectl "${KSTG[@]}" -n argocd patch application payment-staging --type merge \
  -p "{\"spec\":{\"source\":{\"targetRevision\":\"$BR\"}}}" >/dev/null
kubectl "${KSTG[@]}" -n argocd annotate application payment-staging argocd.argoproj.io/refresh=hard --overwrite >/dev/null
ok "Argo CD syncing"
exec "$(dirname "$0")/watch.sh" staging
