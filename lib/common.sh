#!/usr/bin/env bash
# Shared helpers for EDA scenario deploy/destroy scripts.
# Cluster selection: $KUBECTL, set by lib/connect.sh to the cluster chosen at deploy time.

# exported so child scripts (e.g. configure-gpus.sh launched via `bash ...`) inherit
# the chosen wrapper, not just KUBECONFIG.
export KUBECTL="${KUBECTL:-kubectl}"
GREEN="\033[0;32m"; RED="\033[0;31m"; YELLOW="\033[0;33m"; RESET="\033[0m"
log()  { echo -e "${GREEN}=== $* ===${RESET}"; }
warn() { echo -e "${YELLOW}! $*${RESET}"; }
err()  { echo -e "${RED}ERROR: $*${RESET}" >&2; }

# Run edactl inside the in-cluster eda-toolbox pod (follows $KUBECTL's cluster).
edactl_cmd() {
  local pod
  pod=$($KUBECTL -n eda-system get pods -l eda.nokia.com/app=eda-toolbox \
        --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  [[ -n "$pod" ]] || { err "eda-toolbox pod not found (KUBECTL=$KUBECTL, ctx=$($KUBECTL config current-context 2>/dev/null))"; return 1; }
  $KUBECTL -n eda-system exec "$pod" -- edactl "$@"
}

# bootstrap_ns <ns> [from-ns]  — provision pools + nodeprofiles. Self-healing:
# - already bootstrapped (asn-pool sentinel present) -> skip.
# - ns exists but NOT bootstrapped (hollow shell from an incomplete teardown) ->
#   delete + wait + re-bootstrap (edactl bootstrap is NOT idempotent: it errors
#   "ToNamespace already exists" on an existing ns, so we must start clean).
# - ns absent -> bootstrap.
bootstrap_ns() {
  local ns="$1" from="${2:-eda}"
  # fully bootstrapped? (asn-pool is a bootstrap sentinel)
  if $KUBECTL get indexallocationpool asn-pool -n "$ns" >/dev/null 2>&1; then
    log "namespace $ns already bootstrapped — skipping"
    return 0
  fi
  # Exists but NOT fully bootstrapped — either a hollow k8s ns OR a stale EDA
  # Namespace CR (eda-system) with no k8s ns. `edactl namespace bootstrap` is NOT
  # idempotent (errors "ToNamespace already exists"), and `kubectl delete ns` does
  # NOT remove the EDA Namespace CR. So clear via `edactl delete namespace` (removes
  # EDB record + k8s ns + pools) before bootstrapping clean.
  if $KUBECTL get namespaces.core.eda.nokia.com -n eda-system "$ns" >/dev/null 2>&1 \
     || $KUBECTL get ns "$ns" >/dev/null 2>&1; then
    warn "namespace $ns exists but is not fully bootstrapped — clearing stale state via edactl"
    edactl_cmd delete namespace "$ns" 2>/dev/null || $KUBECTL delete ns "$ns" --ignore-not-found 2>/dev/null || true
    $KUBECTL wait --for=delete ns/"$ns" --timeout=150s 2>/dev/null || true
  fi
  log "bootstrapping namespace $ns (from $from)"
  edactl_cmd namespace bootstrap create --from-namespace "$from" "$ns"
}

# wait_toponodes_synced <ns> <count> [timeout_s]
wait_toponodes_synced() {
  local ns="$1" want="$2" timeout="${3:-420}" i=0 synced total
  log "waiting for $want toponodes Synced in $ns (timeout ${timeout}s)"
  while (( i < timeout )); do
    total=$($KUBECTL get toponode -n "$ns" --no-headers 2>/dev/null | wc -l)
    synced=$($KUBECTL get toponode -n "$ns" --no-headers 2>/dev/null | grep -c Synced || true)
    echo "  [${i}s] synced=${synced}/${total}"
    (( total >= want && synced >= want )) && { log "all $want toponodes Synced"; return 0; }
    sleep 15; i=$((i+15))
  done
  err "timeout waiting for toponodes Synced in $ns"; return 1
}

# wait_resource_field <ns> <kind/name> <jsonpath> <want> [timeout_s]
wait_resource_field() {
  local ns="$1" res="$2" jp="$3" want="$4" timeout="${5:-200}" i=0 got
  log "waiting for $res $jp=$want in $ns"
  while (( i < timeout )); do
    got=$($KUBECTL get "$res" -n "$ns" -o jsonpath="$jp" 2>/dev/null || true)
    echo "  [${i}s] $jp=$got"
    [[ "$got" == "$want" ]] && return 0
    sleep 10; i=$((i+10))
  done
  warn "timeout waiting for $res $jp=$want (got '$got')"; return 1
}
