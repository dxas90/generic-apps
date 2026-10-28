#!/usr/bin/env bash
# kong-kind-setup.sh
#
# Single script: provision Kong on kind + full Gateway API demo
# (http-routing guide + cross-namespace routing guide).
#
# Usage:
#   bash kong-kind-setup.sh                  # full run: cluster + infra + demo
#   bash kong-kind-setup.sh --skip-cluster   # skip kind create (reuse kind-seed)
#   bash kong-kind-setup.sh --skip-infra     # skip cluster+operator (demo only)
#   bash kong-kind-setup.sh --demo-only      # alias for --skip-infra
#   bash kong-kind-setup.sh --destroy        # delete cluster and exit
#   bash kong-kind-setup.sh --cleanup        # delete demo resources only
#
# Fixes applied vs the official Kong + Gateway API guides:
#   1. kong:3.9 (OSS) — kong/kong-gateway:3.x is Enterprise, blocks /config 403
#   2. Declarative config pushed directly via Admin API — workaround for Kong
#      Operator 2.3 KIC informer-cache race (HTTPRoute controller never enqueues
#      existing objects on initial list, so KIC holds empty config forever)
#   3. Port conflict detection — avoids ERR_INVALID_HTTP_RESPONSE when another
#      process (k8sgpt, devtools…) already owns the preferred port
#   4. kind export kubeconfig on every run — prevents "context does not exist"
set -euo pipefail

# ── config ────────────────────────────────────────────────────────────────────
CLUSTER_NAME=seed
CONTEXT=kind-${CLUSTER_NAME}
KONG_NS=kong
SYSTEM_NS=kong-system
OPERATOR_TAG=2.3
DP_IMAGE=kong:3.9
GWAPI_VERSION=v1.6.3
KONG_HOSTNAME=kong.127.0.0.1.nip.io
PREFERRED_PORT=9080
# ─────────────────────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()      { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[FAIL]${NC}  $*" >&2; exit 1; }
section() {
  echo
  echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}${CYAN}  $*${NC}"
  echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════${NC}"
}

# ── arg parsing ───────────────────────────────────────────────────────────────
SKIP_CLUSTER=false
SKIP_INFRA=false
DESTROY=false
CLEANUP=false
for arg in "$@"; do
  case $arg in
    --skip-cluster) SKIP_CLUSTER=true ;;
    --skip-infra|--demo-only) SKIP_INFRA=true; SKIP_CLUSTER=true ;;
    --destroy)  DESTROY=true ;;
    --cleanup)  CLEANUP=true ;;
  esac
done

# ── shared helpers ────────────────────────────────────────────────────────────
find_free_port() {
  local p=$1
  while lsof -nP -iTCP:${p} -sTCP:LISTEN &>/dev/null 2>&1; do
    local owner; owner=$(lsof -nP -iTCP:${p} -sTCP:LISTEN 2>/dev/null | awk 'NR==2{print $1}')
    warn "Port ${p} taken by '${owner}' — trying $((p+1))..."
    (( p++ ))
  done
  echo "$p"
}

wait_deploy() {
  kubectl --context "$CONTEXT" rollout status "deployment/$1" \
    -n "$2" --timeout=120s
}

wait_dp_ready() {
  # wait_dp_ready <gateway-name> <namespace>
  local gw="$1" ns="$2" pod ready
  local deadline=$(( $(date +%s) + 300 ))
  while true; do
    pod=$(kubectl --context "$CONTEXT" -n "$ns" get pods \
      -l "gateway.networking.k8s.io/gateway-name=${gw}" \
      --field-selector=status.phase=Running \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [[ -n "$pod" ]]; then
      ready=$(kubectl --context "$CONTEXT" -n "$ns" get pod "$pod" \
        -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo false)
      [[ "$ready" == "true" ]] && { echo "$pod"; return; }
    fi
    (( $(date +%s) > deadline )) && die "DataPlane for gateway/$gw in $ns not Ready after 5 min."
    sleep 5
  done
}

push_kong_config() {
  # push_kong_config <admin_svc> <namespace> <yaml_string>
  local svc="$1" ns="$2" yaml_cfg="$3"
  local cp_secret certdir pf_port status

  cp_secret=$(kubectl --context "$CONTEXT" get secret -n "$ns" \
    -o name | grep "^secret/controlplane-" | head -1)
  [[ -z "$cp_secret" ]] && { warn "No controlplane secret in $ns — skipping push."; return 0; }

  certdir=$(mktemp -d)
  trap "rm -rf '$certdir'" RETURN
  kubectl --context "$CONTEXT" get "$cp_secret" -n "$ns" \
    -o jsonpath='{.data.tls\.crt}' | base64 -d > "$certdir/cp.crt"
  kubectl --context "$CONTEXT" get "$cp_secret" -n "$ns" \
    -o jsonpath='{.data.tls\.key}' | base64 -d > "$certdir/cp.key"
  kubectl --context "$CONTEXT" get "$cp_secret" -n "$ns" \
    -o jsonpath='{.data.ca\.crt}'  | base64 -d > "$certdir/ca.crt"

  pf_port=$(find_free_port 19444)
  kubectl --context "$CONTEXT" -n "$ns" port-forward \
    --address 127.0.0.1 "svc/$svc" "${pf_port}:8444" >/dev/null 2>&1 &
  local pf_pid=$!
  sleep 3

  status=$(curl -sk \
    --cert "$certdir/cp.crt" --key "$certdir/cp.key" --cacert "$certdir/ca.crt" \
    -o "$certdir/resp.json" -w "%{http_code}" \
    -X POST "https://localhost:${pf_port}/config?flatten_errors=1" \
    -F "config=${yaml_cfg}" 2>/dev/null)

  kill "$pf_pid" 2>/dev/null || true

  if [[ "$status" == "200" || "$status" == "201" ]]; then
    ok "Kong config pushed to $ns (HTTP $status)."
  else
    warn "Kong config push to $ns returned HTTP $status"
  fi
}

port_forward_bg() {
  # port_forward_bg <svc> <ns> <host_port>:<svc_port> — prints PID
  local svc="$1" ns="$2" ports="$3"
  pkill -f "port-forward.*${svc}.*${ports}" 2>/dev/null || true
  sleep 1
  kubectl --context "$CONTEXT" -n "$ns" port-forward \
    --address 127.0.0.1 "svc/$svc" "$ports" >/dev/null 2>&1 &
  echo $!
}

PASS=0; FAIL=0
check() {
  # check <label> <url> <expected_code> [curl_args...]
  local label="$1" url="$2" want="$3"; shift 3
  local resp code body
  resp=$(curl -si --max-time 5 "$@" "$url" 2>&1)
  code=$(echo "$resp" | grep -m1 "^HTTP" | awk '{print $2}')
  body=$(echo "$resp" | tail -1)
  printf '  %-58s' "$label"
  if [[ "$code" == "$want" ]]; then
    echo -e "  ${GREEN}PASS${NC} ($code)  $body"
    (( PASS++ )) || true
  else
    echo -e "  ${RED}FAIL${NC} — got $code, want $want"
    (( FAIL++ )) || true
  fi
}

# ── destroy ───────────────────────────────────────────────────────────────────
if $DESTROY; then
  info "Deleting cluster ${CLUSTER_NAME}..."
  kind delete cluster --name "${CLUSTER_NAME}" && ok "Cluster deleted." || warn "Cluster not found."
  exit 0
fi

# ── cleanup (demo resources only) ─────────────────────────────────────────────
if $CLEANUP; then
  section "Cleanup — demo resources"
  kind export kubeconfig --name "${CLUSTER_NAME}" 2>/dev/null || true
  info "Removing Part 1 resources from kong ns..."
  kubectl --context "$CONTEXT" delete httproute foo-route bar-route -n kong 2>/dev/null || true
  kubectl --context "$CONTEXT" delete deploy foo-app bar-app bar-canary-app -n kong 2>/dev/null || true
  kubectl --context "$CONTEXT" delete svc foo-svc bar-svc bar-svc-canary -n kong 2>/dev/null || true
  info "Removing Part 2 namespaces..."
  for ns in infra-ns site-ns store-ns no-external-access; do
    kubectl --context "$CONTEXT" delete namespace "$ns" --ignore-not-found 2>/dev/null || true
  done
  ok "Cleanup done. Cluster and Kong Operator are still running."
  exit 0
fi

# ── prereqs ───────────────────────────────────────────────────────────────────
for cmd in docker kind kubectl helm jq curl lsof; do
  command -v "$cmd" &>/dev/null || die "Missing prerequisite: $cmd"
done
ok "Prerequisites OK."

PROXY_PORT=$(find_free_port "${PREFERRED_PORT}")
ADMIN_PF_PORT=$(find_free_port 18444)
ok "Proxy port: ${PROXY_PORT}  Admin temp port: ${ADMIN_PF_PORT}"

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 1 — INFRASTRUCTURE
# ══════════════════════════════════════════════════════════════════════════════
if ! $SKIP_INFRA; then

section "Phase 1a — kind cluster"

if ! $SKIP_CLUSTER; then
  if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    warn "Cluster '${CLUSTER_NAME}' already exists — reusing."
  else
    info "Creating kind cluster '${CLUSTER_NAME}'..."
    cat <<EOF | kind create cluster --config -
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${CLUSTER_NAME}
nodes:
  - role: control-plane
    extraPortMappings:
      - containerPort: 80
        hostPort: 8080
        protocol: TCP
      - containerPort: 443
        hostPort: 8443
        protocol: TCP
EOF
    ok "Cluster created."
  fi
fi
kind export kubeconfig --name "${CLUSTER_NAME}" 2>/dev/null
kubectl cluster-info --context "${CONTEXT}" &>/dev/null || die "Cannot reach ${CONTEXT}"
ok "Context ${CONTEXT} reachable."

section "Phase 1b — Gateway API CRDs (${GWAPI_VERSION})"
kubectl apply --context "${CONTEXT}" --server-side -f \
  "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GWAPI_VERSION}/standard-install.yaml"
kubectl wait --context "${CONTEXT}" --for=condition=Established \
  crd/gatewayclasses.gateway.networking.k8s.io \
  crd/gateways.gateway.networking.k8s.io \
  crd/httproutes.gateway.networking.k8s.io \
  --timeout=120s
ok "Gateway API CRDs ready."

section "Phase 1c — Kong Operator (${OPERATOR_TAG})"
helm repo add kong https://charts.konghq.com --force-update &>/dev/null
helm repo update kong &>/dev/null
helm upgrade --install kong-operator kong/kong-operator \
  --kube-context "${CONTEXT}" \
  --namespace "${SYSTEM_NS}" --create-namespace \
  --set image.tag="${OPERATOR_TAG}" \
  --set env.ENABLE_CONTROLLER_KONNECT=false \
  --wait --timeout=3m
OPERATOR_DEPLOY=$(kubectl --context "${CONTEXT}" -n "${SYSTEM_NS}" \
  get deploy -o jsonpath='{.items[0].metadata.name}')
kubectl --context "${CONTEXT}" -n "${SYSTEM_NS}" \
  rollout status "deployment/${OPERATOR_DEPLOY}" --timeout=180s
ok "Kong Operator ready: ${OPERATOR_DEPLOY}"

section "Phase 1d — Kong Gateway in ${KONG_NS} (baseline smoke-test gateway)"
kubectl --context "${CONTEXT}" create namespace "${KONG_NS}" \
  --dry-run=client -o yaml | kubectl --context "${CONTEXT}" apply -f -

kubectl --context "${CONTEXT}" apply -f - <<EOF
apiVersion: gateway-operator.konghq.com/v2beta1
kind: GatewayConfiguration
metadata:
  name: kong-configuration
  namespace: ${KONG_NS}
spec:
  dataPlaneOptions:
    deployment:
      podTemplateSpec:
        spec:
          containers:
            - name: proxy
              image: ${DP_IMAGE}
---
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: kong
spec:
  controllerName: konghq.com/gateway-operator
  parametersRef:
    group: gateway-operator.konghq.com
    kind: GatewayConfiguration
    name: kong-configuration
    namespace: ${KONG_NS}
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: kong
  namespace: ${KONG_NS}
spec:
  gatewayClassName: kong
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      hostname: ${KONG_HOSTNAME}
      allowedRoutes:
        namespaces:
          from: All
EOF
kubectl --context "${CONTEXT}" wait \
  --for=condition=Accepted=True gatewayclass/kong --timeout=120s
ok "GatewayClass accepted."

info "Waiting for kong DataPlane pod..."
KONG_DP_POD=$(wait_dp_ready "kong" "${KONG_NS}")
ok "DataPlane pod ${KONG_DP_POD} is Ready."

info "Deploying smoke-test echo backend..."
kubectl --context "${CONTEXT}" apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: echo
  namespace: ${KONG_NS}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: echo
  template:
    metadata:
      labels:
        app: echo
    spec:
      containers:
        - name: echo
          image: hashicorp/http-echo:1.0.0
          args: ["-listen=:5678", "-text=Hello from Kong Gateway!"]
          ports:
            - containerPort: 5678
---
apiVersion: v1
kind: Service
metadata:
  name: echo
  namespace: ${KONG_NS}
spec:
  selector:
    app: echo
  ports:
    - name: http
      port: 80
      targetPort: 5678
EOF
wait_deploy "echo" "${KONG_NS}"

kubectl --context "${CONTEXT}" apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: echo
  namespace: ${KONG_NS}
spec:
  parentRefs:
    - name: kong
      namespace: ${KONG_NS}
      sectionName: http
  hostnames:
    - ${KONG_HOSTNAME}
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /echo
      backendRefs:
        - name: echo
          port: 80
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: api
  namespace: ${KONG_NS}
spec:
  parentRefs:
    - name: kong
      namespace: ${KONG_NS}
  hostnames:
    - ${KONG_HOSTNAME}
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /api
      backendRefs:
        - name: echo
          port: 80
EOF

info "Waiting for operator initial sync..."
DEADLINE=$(( $(date +%s) + 120 ))
while true; do
  kubectl --context "${CONTEXT}" logs -n "${SYSTEM_NS}" \
    "deployment/${OPERATOR_DEPLOY}" 2>/dev/null \
    | grep -q "Successfully synced configuration to Kong" && break
  (( $(date +%s) > DEADLINE )) && die "Operator never synced within 120s."
  sleep 3
done
ok "Operator initial sync confirmed."

KONG_ADMIN_SVC=$(kubectl --context "${CONTEXT}" -n "${KONG_NS}" get svc -o json \
  | jq -r '.items[] | select(.spec.ports[0].port == 8444) | .metadata.name' | head -1)
ECHO_IP=$(kubectl --context "${CONTEXT}" get svc echo -n "${KONG_NS}" \
  -o jsonpath='{.spec.clusterIP}')

push_kong_config "$KONG_ADMIN_SVC" "$KONG_NS" "_format_version: '3.0'
services:
- name: echo
  host: ${ECHO_IP}
  port: 80
  protocol: http
  routes:
  - name: echo-route
    paths: [/echo]
    hosts: [${KONG_HOSTNAME}]
    strip_path: false
  - name: api-route
    paths: [/api]
    hosts: [${KONG_HOSTNAME}]
    strip_path: false"

KONG_PROXY_SVC=$(kubectl --context "${CONTEXT}" -n "${KONG_NS}" get svc -o json \
  | jq -r '.items[] | select(any(.spec.ports[]; .port == 80)) | .metadata.name' \
  | grep -v '^echo$' | head -1)

# quick smoke test
SMOKE_PF_PID=$(port_forward_bg "$KONG_PROXY_SVC" "$KONG_NS" "${PROXY_PORT}:80")
sleep 3
SMOKE=$(curl -so /dev/null -w "%{http_code}" --max-time 5 \
  "http://${KONG_HOSTNAME}:${PROXY_PORT}/echo" 2>/dev/null)
kill "$SMOKE_PF_PID" 2>/dev/null || true
[[ "$SMOKE" == "200" ]] && ok "Smoke test passed (${KONG_HOSTNAME}:${PROXY_PORT}/echo -> 200)." \
  || warn "Smoke test returned $SMOKE — continuing anyway."

else
  # --skip-infra: recover context and find existing services
  kind export kubeconfig --name "${CLUSTER_NAME}" 2>/dev/null
  kubectl cluster-info --context "${CONTEXT}" &>/dev/null || die "Cannot reach ${CONTEXT}"
  OPERATOR_DEPLOY=$(kubectl --context "${CONTEXT}" -n "${SYSTEM_NS}" \
    get deploy -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || true
  KONG_PROXY_SVC=$(kubectl --context "${CONTEXT}" -n "${KONG_NS}" get svc -o json 2>/dev/null \
    | jq -r '.items[] | select(any(.spec.ports[]; .port == 80)) | .metadata.name' \
    | grep -v '^echo$' | head -1) || true
  KONG_ADMIN_SVC=$(kubectl --context "${CONTEXT}" -n "${KONG_NS}" get svc -o json 2>/dev/null \
    | jq -r '.items[] | select(.spec.ports[0].port == 8444) | .metadata.name' | head -1) || true
  [[ -z "$KONG_PROXY_SVC" ]] && die "Kong proxy not found in $KONG_NS. Run without --skip-infra first."
  ok "Reusing existing infra: proxy=$KONG_PROXY_SVC admin=$KONG_ADMIN_SVC"
fi

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 2 — DEMO: HTTP ROUTING (http-routing guide)
# ══════════════════════════════════════════════════════════════════════════════
section "Phase 2 — HTTP Routing demo"
# From https://gateway-api.sigs.k8s.io/guides/user-guides/http-routing/
#
# Both routes bind to the existing 'kong' Gateway in the kong namespace.
# Gateway listener uses allowedRoutes.namespaces.from: All so routes
# from other namespaces can also attach (needed for Phase 3).
#
#   foo.example.com/login        -> foo-svc        (PathPrefix match)
#   bar.example.com/* env:canary -> bar-svc-canary  (header match, higher precedence)
#   bar.example.com/*            -> bar-svc         (default fallback)

info "Deploying http-routing backends (foo-svc, bar-svc, bar-svc-canary) in ${KONG_NS}..."
kubectl --context "$CONTEXT" apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: foo-app
  namespace: ${KONG_NS}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: foo-app
  template:
    metadata:
      labels:
        app: foo-app
    spec:
      containers:
        - name: echo
          image: hashicorp/http-echo:1.0.0
          args: ["-listen=:5678", "-text=foo-svc: login page"]
          ports:
            - containerPort: 5678
---
apiVersion: v1
kind: Service
metadata:
  name: foo-svc
  namespace: ${KONG_NS}
spec:
  selector:
    app: foo-app
  ports:
    - port: 8080
      targetPort: 5678
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: bar-app
  namespace: ${KONG_NS}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: bar-app
  template:
    metadata:
      labels:
        app: bar-app
    spec:
      containers:
        - name: echo
          image: hashicorp/http-echo:1.0.0
          args: ["-listen=:5678", "-text=bar-svc: stable"]
          ports:
            - containerPort: 5678
---
apiVersion: v1
kind: Service
metadata:
  name: bar-svc
  namespace: ${KONG_NS}
spec:
  selector:
    app: bar-app
  ports:
    - port: 8080
      targetPort: 5678
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: bar-canary-app
  namespace: ${KONG_NS}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: bar-canary-app
  template:
    metadata:
      labels:
        app: bar-canary-app
    spec:
      containers:
        - name: echo
          image: hashicorp/http-echo:1.0.0
          args: ["-listen=:5678", "-text=bar-svc-canary: canary build"]
          ports:
            - containerPort: 5678
---
apiVersion: v1
kind: Service
metadata:
  name: bar-svc-canary
  namespace: ${KONG_NS}
spec:
  selector:
    app: bar-canary-app
  ports:
    - port: 8080
      targetPort: 5678
EOF
for d in foo-app bar-app bar-canary-app; do wait_deploy "$d" "$KONG_NS"; done
ok "HTTP-routing backends ready."

info "Deploying foo-route and bar-route HTTPRoutes..."
kubectl --context "$CONTEXT" apply -f - <<'YAMLEOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: foo-route
  namespace: kong
spec:
  parentRefs:
  - name: kong
    namespace: kong
  hostnames:
  - "foo.example.com"
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /login
    backendRefs:
    - name: foo-svc
      port: 8080
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: bar-route
  namespace: kong
spec:
  parentRefs:
  - name: kong
    namespace: kong
  hostnames:
  - "bar.example.com"
  rules:
  - matches:
    - headers:
      - type: Exact
        name: env
        value: canary
    backendRefs:
    - name: bar-svc-canary
      port: 8080
  - backendRefs:
    - name: bar-svc
      port: 8080
YAMLEOF
ok "foo-route and bar-route applied."

FOO_IP=$(kubectl --context "$CONTEXT" get svc foo-svc       -n "$KONG_NS" -o jsonpath='{.spec.clusterIP}')
BAR_IP=$(kubectl --context "$CONTEXT" get svc bar-svc       -n "$KONG_NS" -o jsonpath='{.spec.clusterIP}')
BAR_C_IP=$(kubectl --context "$CONTEXT" get svc bar-svc-canary -n "$KONG_NS" -o jsonpath='{.spec.clusterIP}')
ECHO_IP=$(kubectl --context "$CONTEXT" get svc echo         -n "$KONG_NS" -o jsonpath='{.spec.clusterIP}')

push_kong_config "$KONG_ADMIN_SVC" "$KONG_NS" "_format_version: '3.0'
services:
- name: echo
  host: ${ECHO_IP}
  port: 80
  protocol: http
  routes:
  - name: echo-route
    paths: [/echo]
    hosts: [${KONG_HOSTNAME}]
    strip_path: false
  - name: api-route
    paths: [/api]
    hosts: [${KONG_HOSTNAME}]
    strip_path: false
- name: foo-svc
  host: ${FOO_IP}
  port: 8080
  protocol: http
  routes:
  - name: foo-login
    paths: [/login]
    hosts: [foo.example.com]
    strip_path: false
- name: bar-svc
  host: ${BAR_IP}
  port: 8080
  protocol: http
  routes:
  - name: bar-default
    paths: [/]
    hosts: [bar.example.com]
    strip_path: false
- name: bar-svc-canary
  host: ${BAR_C_IP}
  port: 8080
  protocol: http
  routes:
  - name: bar-canary
    paths: [/]
    hosts: [bar.example.com]
    strip_path: false
    headers:
      env:
      - canary"

P1_PORT=$(find_free_port 9081)
PF1_PID=$(port_forward_bg "$KONG_PROXY_SVC" "$KONG_NS" "${P1_PORT}:80")
sleep 3

section "Phase 2 Tests — HTTP Routing"
echo
check "foo.example.com/login    -> foo-svc (200)"         \
  "http://127.0.0.1:${P1_PORT}/login" "200" -H "Host: foo.example.com"
check "foo.example.com/other    -> 404 (no /other rule)"  \
  "http://127.0.0.1:${P1_PORT}/other" "404" -H "Host: foo.example.com"
check "bar.example.com/         -> bar-svc stable (200)"  \
  "http://127.0.0.1:${P1_PORT}/"      "200" -H "Host: bar.example.com"
check "bar.example.com/ env:canary -> bar-svc-canary (200)" \
  "http://127.0.0.1:${P1_PORT}/"      "200" -H "Host: bar.example.com" -H "env: canary"
echo
echo "  Response bodies:"
printf '    foo /login  ->  '; curl -s --max-time 3 -H "Host: foo.example.com" "http://127.0.0.1:${P1_PORT}/login"
printf '    bar stable  ->  '; curl -s --max-time 3 -H "Host: bar.example.com" "http://127.0.0.1:${P1_PORT}/"
printf '    bar canary  ->  '; curl -s --max-time 3 -H "Host: bar.example.com" -H "env: canary" "http://127.0.0.1:${P1_PORT}/"

kill "$PF1_PID" 2>/dev/null || true

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 3 — DEMO: CROSS-NAMESPACE ROUTING (multiple-ns guide)
# ══════════════════════════════════════════════════════════════════════════════
section "Phase 3 — Cross-Namespace Routing demo"
# From https://gateway-api.sigs.k8s.io/guides/user-guides/multiple-ns/
#
# Topology:
#   infra-ns   Gateway: shared-gateway
#              allowedRoutes.namespaces.from: Selector
#              only ns labelled shared-gateway-access=true may attach
#
#   site-ns    HTTPRoute home  -> home svc (catch-all)
#              HTTPRoute login -> login-v1 (w:90) + login-v2 (w:10)
#
#   store-ns   HTTPRoute store -> store svc (/store prefix)
#
#   no-external-access   (no label — routes here cannot attach)
#
# ReferenceGrant:
#   store-ns grants HTTPRoutes in site-ns to reference Services in store-ns
#   A "cross-ns-no-grant" route is deployed WITHOUT the matching grant
#   to demonstrate the rejection behaviour.

info "Creating namespaces..."
kubectl --context "$CONTEXT" apply -f - <<'YAMLEOF'
apiVersion: v1
kind: Namespace
metadata:
  name: infra-ns
  labels:
    shared-gateway-access: "true"
---
apiVersion: v1
kind: Namespace
metadata:
  name: site-ns
  labels:
    shared-gateway-access: "true"
---
apiVersion: v1
kind: Namespace
metadata:
  name: store-ns
  labels:
    shared-gateway-access: "true"
---
apiVersion: v1
kind: Namespace
metadata:
  name: no-external-access
YAMLEOF
ok "Namespaces ready (infra-ns, site-ns, store-ns, no-external-access)."

info "Deploying site-ns backends (home, login-v1, login-v2)..."
kubectl --context "$CONTEXT" apply -f - <<'YAMLEOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: home
  namespace: site-ns
spec:
  replicas: 1
  selector:
    matchLabels:
      app: home
  template:
    metadata:
      labels:
        app: home
    spec:
      containers:
        - name: echo
          image: hashicorp/http-echo:1.0.0
          args: ["-listen=:5678", "-text=site-ns/home: default page"]
          ports:
            - containerPort: 5678
---
apiVersion: v1
kind: Service
metadata:
  name: home
  namespace: site-ns
spec:
  selector:
    app: home
  ports:
    - port: 8080
      targetPort: 5678
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: login-v1
  namespace: site-ns
spec:
  replicas: 1
  selector:
    matchLabels:
      app: login-v1
  template:
    metadata:
      labels:
        app: login-v1
    spec:
      containers:
        - name: echo
          image: hashicorp/http-echo:1.0.0
          args: ["-listen=:5678", "-text=site-ns/login-v1: stable (weight 90)"]
          ports:
            - containerPort: 5678
---
apiVersion: v1
kind: Service
metadata:
  name: login-v1
  namespace: site-ns
spec:
  selector:
    app: login-v1
  ports:
    - port: 8080
      targetPort: 5678
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: login-v2
  namespace: site-ns
spec:
  replicas: 1
  selector:
    matchLabels:
      app: login-v2
  template:
    metadata:
      labels:
        app: login-v2
    spec:
      containers:
        - name: echo
          image: hashicorp/http-echo:1.0.0
          args: ["-listen=:5678", "-text=site-ns/login-v2: canary (weight 10)"]
          ports:
            - containerPort: 5678
---
apiVersion: v1
kind: Service
metadata:
  name: login-v2
  namespace: site-ns
spec:
  selector:
    app: login-v2
  ports:
    - port: 8080
      targetPort: 5678
YAMLEOF

info "Deploying store-ns backend (store)..."
kubectl --context "$CONTEXT" apply -f - <<'YAMLEOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: store
  namespace: store-ns
spec:
  replicas: 1
  selector:
    matchLabels:
      app: store
  template:
    metadata:
      labels:
        app: store
    spec:
      containers:
        - name: echo
          image: hashicorp/http-echo:1.0.0
          args: ["-listen=:5678", "-text=store-ns/store: product catalog"]
          ports:
            - containerPort: 5678
---
apiVersion: v1
kind: Service
metadata:
  name: store
  namespace: store-ns
spec:
  selector:
    app: store
  ports:
    - port: 8080
      targetPort: 5678
YAMLEOF
for d in home login-v1 login-v2; do wait_deploy "$d" site-ns; done
wait_deploy "store" store-ns
ok "Phase 3 backends ready."

info "Deploying shared-gateway in infra-ns..."
kubectl --context "$CONTEXT" apply -f - <<'YAMLEOF'
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: shared-gateway
  namespace: infra-ns
spec:
  gatewayClassName: kong
  listeners:
  - name: http
    protocol: HTTP
    port: 80
    hostname: "foo.example.com"
    allowedRoutes:
      namespaces:
        from: Selector
        selector:
          matchLabels:
            shared-gateway-access: "true"
YAMLEOF
kubectl --context "$CONTEXT" wait \
  --for=jsonpath='{.status.conditions[?(@.type=="Accepted")].status}=True' \
  gateway/shared-gateway -n infra-ns --timeout=120s
ok "shared-gateway Accepted."

info "Waiting for shared-gateway DataPlane..."
SG_DP_POD=$(wait_dp_ready "shared-gateway" "infra-ns")
ok "shared-gateway DataPlane $SG_DP_POD is Ready."

info "Deploying cross-namespace HTTPRoutes..."
kubectl --context "$CONTEXT" apply -f - <<'YAMLEOF'
# site-ns: catch-all default
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: home
  namespace: site-ns
spec:
  parentRefs:
  - name: shared-gateway
    namespace: infra-ns
  rules:
  - backendRefs:
    - name: home
      port: 8080
---
# site-ns: weighted login split
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: login
  namespace: site-ns
spec:
  parentRefs:
  - name: shared-gateway
    namespace: infra-ns
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /login
    backendRefs:
    - name: login-v1
      port: 8080
      weight: 90
    - name: login-v2
      port: 8080
      weight: 10
---
# store-ns: /store prefix
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: store
  namespace: store-ns
spec:
  parentRefs:
  - name: shared-gateway
    namespace: infra-ns
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /store
    backendRefs:
    - name: store
      port: 8080
YAMLEOF
ok "Cross-namespace HTTPRoutes applied."

info "Deploying ReferenceGrants..."
kubectl --context "$CONTEXT" apply -f - <<'YAMLEOF'
# Allows HTTPRoutes in site-ns to reference Services in store-ns.
# Without this grant a cross-ns backendRef is rejected.
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: allow-site-to-store
  namespace: store-ns
spec:
  from:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    namespace: site-ns
  to:
  - group: ""
    kind: Service
---
# Allows HTTPRoutes in site-ns to reference Services in site-ns.
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: allow-site-internal
  namespace: site-ns
spec:
  from:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    namespace: site-ns
  to:
  - group: ""
    kind: Service
YAMLEOF
ok "ReferenceGrants applied."

info "Deploying cross-ns-no-grant (negative demo — backendRef should be rejected)..."
kubectl --context "$CONTEXT" apply -f - <<'YAMLEOF'
# This route has a backendRef to store-ns/store from site-ns,
# but there is no ReferenceGrant in store-ns allowing THIS specific route.
# The allow-site-to-store grant covers general HTTPRoutes from site-ns,
# so this actually WILL work — to show a true rejection, we point at a
# non-existent namespace so no grant can ever exist.
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: cross-ns-no-grant
  namespace: site-ns
spec:
  parentRefs:
  - name: shared-gateway
    namespace: infra-ns
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /forbidden
    backendRefs:
    - name: store
      namespace: no-external-access
      port: 8080
YAMLEOF
echo "  (no-external-access has no Services and no ReferenceGrant — this backendRef is invalid)"

info "Waiting for operator to sync shared-gateway config..."
INFRA_ADMIN_SVC=$(kubectl --context "$CONTEXT" -n infra-ns get svc -o json \
  | jq -r '.items[] | select(.spec.ports[0].port == 8444) | .metadata.name' | head -1)
[[ -z "$INFRA_ADMIN_SVC" ]] && die "Cannot find admin svc in infra-ns."

DEADLINE=$(( $(date +%s) + 120 ))
while true; do
  kubectl --context "$CONTEXT" logs -n "${SYSTEM_NS}" \
    "deployment/${OPERATOR_DEPLOY:-kong-operator-kong-operator-controller-manager}" 2>/dev/null \
    | grep -q "Successfully synced configuration to Kong" && break
  (( $(date +%s) > DEADLINE )) && { warn "Operator sync not confirmed — pushing anyway."; break; }
  sleep 3
done

HOME_IP=$(kubectl --context "$CONTEXT" get svc home    -n site-ns  -o jsonpath='{.spec.clusterIP}')
LV1_IP=$(kubectl --context "$CONTEXT"  get svc login-v1 -n site-ns  -o jsonpath='{.spec.clusterIP}')
LV2_IP=$(kubectl --context "$CONTEXT"  get svc login-v2 -n site-ns  -o jsonpath='{.spec.clusterIP}')
STORE_IP=$(kubectl --context "$CONTEXT" get svc store  -n store-ns -o jsonpath='{.spec.clusterIP}')

push_kong_config "$INFRA_ADMIN_SVC" "infra-ns" "_format_version: '3.0'
services:
- name: home
  host: ${HOME_IP}
  port: 8080
  protocol: http
  routes:
  - name: home-default
    paths: [/]
    hosts: [foo.example.com]
    strip_path: false
- name: login-v1
  host: ${LV1_IP}
  port: 8080
  protocol: http
  routes:
  - name: login-stable
    paths: [/login]
    hosts: [foo.example.com]
    strip_path: false
- name: store
  host: ${STORE_IP}
  port: 8080
  protocol: http
  routes:
  - name: store-route
    paths: [/store]
    hosts: [foo.example.com]
    strip_path: false"

INFRA_PROXY_SVC=$(kubectl --context "$CONTEXT" -n infra-ns get svc -o json \
  | jq -r '.items[] | select(any(.spec.ports[]; .port == 80)) | .metadata.name' | head -1)
[[ -z "$INFRA_PROXY_SVC" ]] && die "Cannot find infra-ns proxy service."

P2_PORT=$(find_free_port 9082)
PF2_PID=$(port_forward_bg "$INFRA_PROXY_SVC" "infra-ns" "${P2_PORT}:80")
sleep 3

section "Phase 3 Tests — Cross-Namespace Routing"
echo
check "foo.example.com/         -> site-ns/home (200)"         \
  "http://127.0.0.1:${P2_PORT}/"      "200" -H "Host: foo.example.com"
check "foo.example.com/login    -> site-ns/login-v1|v2 (200)"  \
  "http://127.0.0.1:${P2_PORT}/login" "200" -H "Host: foo.example.com"
check "foo.example.com/store    -> store-ns/store (200)"       \
  "http://127.0.0.1:${P2_PORT}/store" "200" -H "Host: foo.example.com"
check "wrong.example.com/       -> 404 (hostname not matched)" \
  "http://127.0.0.1:${P2_PORT}/"      "404" -H "Host: wrong.example.com"
echo
echo "  Response bodies:"
printf '    /         ->  '; curl -s --max-time 3 -H "Host: foo.example.com" "http://127.0.0.1:${P2_PORT}/"
printf '    /login    ->  '; curl -s --max-time 3 -H "Host: foo.example.com" "http://127.0.0.1:${P2_PORT}/login"
printf '    /store    ->  '; curl -s --max-time 3 -H "Host: foo.example.com" "http://127.0.0.1:${P2_PORT}/store"
echo
echo "  ReferenceGrant rejection check (cross-ns-no-grant -> no-external-access):"
kubectl --context "$CONTEXT" get httproute cross-ns-no-grant -n site-ns \
  -o jsonpath='{.status.parents[0].conditions}' 2>/dev/null \
  | python3 -c "
import sys, json
try:
  conds = json.load(sys.stdin)
  for c in conds:
    print(f\"    {c['type']:25s} {c['reason']:30s} {c.get('message','')[:70]}\")
except Exception as e:
  print('    (status not yet populated —', e, ')')
" 2>/dev/null

kill "$PF2_PID" 2>/dev/null || true

# ══════════════════════════════════════════════════════════════════════════════
# SUMMARY
# ══════════════════════════════════════════════════════════════════════════════
section "Summary"
echo
printf '  %-30s %s\n' "Gateway API version:"  "$GWAPI_VERSION"
printf '  %-30s %s\n' "Kong OSS image:"        "$DP_IMAGE"
printf '  %-30s %s\n' "Phase 1 gateway:"       "kong/${KONG_NS} (${KONG_HOSTNAME})"
printf '  %-30s %s\n' "Phase 2 gateway:"       "shared-gateway/infra-ns (foo.example.com)"
echo
echo "  Tests: ${PASS} passed, ${FAIL} failed"
echo
echo "  All HTTPRoutes:"
kubectl --context "$CONTEXT" get httproute -A 2>&1
echo
echo "  ReferenceGrants:"
kubectl --context "$CONTEXT" get referencegrant -A 2>&1
echo
echo "  Re-open port-forwards to test manually:"
echo "    kubectl --context kind-seed -n ${KONG_NS} port-forward svc/${KONG_PROXY_SVC} ${P1_PORT}:80"
echo "    kubectl --context kind-seed -n infra-ns   port-forward svc/${INFRA_PROXY_SVC} ${P2_PORT}:80"
echo
echo "  Phase 2 curl commands (port ${P1_PORT}):"
echo "    curl -si -H 'Host: foo.example.com'              http://127.0.0.1:${P1_PORT}/login"
echo "    curl -si -H 'Host: bar.example.com'              http://127.0.0.1:${P1_PORT}/"
echo "    curl -si -H 'Host: bar.example.com' -H 'env: canary' http://127.0.0.1:${P1_PORT}/"
echo
echo "  Phase 3 curl commands (port ${P2_PORT}):"
echo "    curl -si -H 'Host: foo.example.com' http://127.0.0.1:${P2_PORT}/"
echo "    curl -si -H 'Host: foo.example.com' http://127.0.0.1:${P2_PORT}/login"
echo "    curl -si -H 'Host: foo.example.com' http://127.0.0.1:${P2_PORT}/store"
echo
echo "  Destroy cluster:        bash $0 --destroy"
echo "  Remove demo resources:  bash $0 --cleanup"
echo
[[ $FAIL -eq 0 ]] && ok "All tests passed." || warn "${FAIL} test(s) failed."
