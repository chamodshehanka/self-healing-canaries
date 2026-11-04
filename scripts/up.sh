#!/usr/bin/env bash
# One-time setup (night before the talk, ~10 min):
#   two kind clusters (staging, prod)
#   per cluster: Envoy Gateway, Argo Rollouts (+ Gateway API plugin, notifications),
#                OTel Collector, Prometheus, Loki, Jaeger
#   staging only: Grafana (both envs), AI SRE (+ Grafana MCP), Argo CD (manages both)
source "$(dirname "$0")/lib.sh"
need kind kubectl helm docker perl
[[ -f "$ROOT/ai-sre/.env" ]] || die "create ai-sre/.env first (cp ai-sre/.env.example ai-sre/.env)"
command -v kubectl-argo-rollouts >/dev/null || warn "kubectl argo rollouts plugin not found (brew install argoproj/tap/kubectl-argo-rollouts)"

# ── clusters ────────────────────────────────────────────────────────────────
for c in staging prod; do
  if kind get clusters | grep -qx "$c"; then ok "cluster $c exists"
  else say "creating kind cluster $c"; kind create cluster --config "$ROOT/platform/kind/$c.yaml"; fi
done

export STAGING_NODE_IP PROD_NODE_IP ARCH
STAGING_NODE_IP=$(node_ip staging)
PROD_NODE_IP=$(node_ip prod)
case "$(docker exec staging-control-plane uname -m)" in
  x86_64) ARCH=amd64 ;; aarch64|arm64) ARCH=arm64 ;; *) die "unknown node arch" ;;
esac
ok "staging=$STAGING_NODE_IP prod=$PROD_NODE_IP arch=$ARCH"

# ── per-cluster platform ────────────────────────────────────────────────────
platform() {
  local c=$1; local k=(--context "kind-$c")
  export DEPLOY_ENV=$c CLUSTER=$c
  if [[ $c == staging ]]; then export AI_SRE_URL="http://ai-sre.ai-sre.svc:8080"
  else export AI_SRE_URL="http://${STAGING_NODE_IP}:30808"; fi

  say "[$c] Envoy Gateway $ENVOY_GATEWAY_VERSION"
  helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm --version "$ENVOY_GATEWAY_VERSION" \
    -n envoy-gateway-system --create-namespace --kube-context "kind-$c" --wait >/dev/null
  kubectl "${k[@]}" apply -f "$ROOT/platform/gateway/gateway.yaml"

  say "[$c] Argo Rollouts $ARGO_ROLLOUTS_VERSION (+ gatewayAPI plugin $GATEWAYAPI_PLUGIN_VERSION, notifications -> $AI_SRE_URL)"
  kubectl "${k[@]}" create namespace argo-rollouts --dry-run=client -o yaml | kubectl "${k[@]}" apply -f -
  kubectl "${k[@]}" apply -n argo-rollouts \
    -f "https://github.com/argoproj/argo-rollouts/releases/download/${ARGO_ROLLOUTS_VERSION}/install.yaml" >/dev/null
  render "$ROOT/platform/rollouts/config.yaml" | kubectl "${k[@]}" apply -f -
  render "$ROOT/platform/rollouts/notifications.yaml" | kubectl "${k[@]}" apply -f -
  kubectl "${k[@]}" -n argo-rollouts rollout restart deploy/argo-rollouts >/dev/null

  say "[$c] observability: OTel Collector, Prometheus, Loki, Jaeger"
  kubectl "${k[@]}" apply -f "$ROOT/platform/observability/namespace.yaml"
  render "$ROOT/platform/observability/otel-collector.yaml" | kubectl "${k[@]}" apply -f -
  render "$ROOT/platform/observability/prometheus.yaml" | kubectl "${k[@]}" apply -f -
  kubectl "${k[@]}" apply -f "$ROOT/platform/observability/loki.yaml" -f "$ROOT/platform/observability/jaeger.yaml"
  kubectl "${k[@]}" -n observability rollout restart deploy/otel-collector deploy/prometheus >/dev/null
}
platform staging
platform prod

# ── staging-only: Grafana, AI SRE, Argo CD ──────────────────────────────────
k=("${KSTG[@]}")

say "[staging] Grafana (datasources for both envs)"
kubectl "${k[@]}" -n observability create configmap grafana-dashboards \
  --from-file="$ROOT/platform/grafana/dashboards/" --dry-run=client -o yaml | kubectl "${k[@]}" apply -f -
render "$ROOT/platform/grafana/grafana.yaml" | kubectl "${k[@]}" apply -f -
kubectl "${k[@]}" -n observability rollout restart deploy/grafana >/dev/null

say "[staging] AI SRE ($AI_SRE_IMAGE)"
kubectl "${k[@]}" create namespace ai-sre --dry-run=client -o yaml | kubectl "${k[@]}" apply -f -
kubectl "${k[@]}" -n ai-sre create secret generic ai-sre-env --from-env-file="$ROOT/ai-sre/.env" \
  --dry-run=client -o yaml | kubectl "${k[@]}" apply -f -
render "$ROOT/ai-sre/k8s.yaml" | kubectl "${k[@]}" apply -f -

say "[staging] Argo CD $ARGOCD_VERSION"
kubectl "${k[@]}" create namespace argocd --dry-run=client -o yaml | kubectl "${k[@]}" apply -f -
kubectl "${k[@]}" apply -n argocd --server-side --force-conflicts \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml" >/dev/null
kubectl "${k[@]}" -n argocd patch configmap argocd-cm --type merge --patch-file "$ROOT/platform/argocd/argocd-cm-patch.yaml"
kubectl "${k[@]}" apply -f "$ROOT/platform/argocd/server-nodeport.yaml"
kubectl "${k[@]}" -n argocd rollout restart statefulset/argocd-application-controller deploy/argocd-repo-server >/dev/null

say "[staging] registering prod cluster with Argo CD"
export PROD_CA PROD_CERT PROD_KEY
PROD_CA=$(kubectl config view --raw -o jsonpath='{.clusters[?(@.name=="kind-prod")].cluster.certificate-authority-data}')
PROD_CERT=$(kubectl config view --raw -o jsonpath='{.users[?(@.name=="kind-prod")].user.client-certificate-data}')
PROD_KEY=$(kubectl config view --raw -o jsonpath='{.users[?(@.name=="kind-prod")].user.client-key-data}')
render "$ROOT/platform/argocd/cluster-prod.yaml" | kubectl "${k[@]}" apply -f -

say "waiting for Argo CD"
kubectl "${k[@]}" -n argocd wait --for=condition=Available deploy --all --timeout=300s >/dev/null
render "$ROOT/platform/argocd/applications.yaml" | kubectl "${k[@]}" apply -f -

say "waiting for observability + AI SRE"
for c in staging prod; do
  kubectl --context "kind-$c" -n observability wait --for=condition=Available deploy --all --timeout=300s >/dev/null
done
kubectl "${k[@]}" -n ai-sre wait --for=condition=Available deploy/ai-sre --timeout=180s >/dev/null || warn "ai-sre not ready yet: kubectl --context kind-staging -n ai-sre get pods"

PASS=$(kubectl "${k[@]}" -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
cat <<EOF

${c_b}Setup complete.${c_0}
  Grafana         http://localhost:3000          (admin/admin)
  AI SRE ledger   http://localhost:8088
  Argo CD         https://localhost:8443         (admin / ${PASS})
  Prometheus      http://localhost:9090 (staging)   http://localhost:9091 (prod)
  Jaeger          http://localhost:16686 (staging)  http://localhost:16687 (prod)
  Rollouts UI     kubectl argo rollouts dashboard --context kind-staging   (and kind-prod -p 3101)

Next: scripts/demo/status.sh   then   scripts/demo/prepare.sh   (see docs/DEMO-RUNBOOK.md)
EOF
