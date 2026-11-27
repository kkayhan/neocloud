#!/usr/bin/env bash
# neocloud — wait until EDA has finished reverting one of the tenant's transactions (called by Terraform, deliver.tf).
# WHY: core-v1_transaction's destroy only POSTs the revert and returns while EDA is still publishing it; a re-create
# right after (gpus 2 → 4) failed with CrValidationErrorTypeDuplicate (txn 1162 still OK-Publishing, 2026-11-12).
#   wait-reverted.sh network <tenant>          done when the Backend has no group <tenant> and no VirtualNetwork <tenant>
#   wait-reverted.sh gpu <interface> <server>  done when the GPU rail Interface has no backend label; then hosts.sh parks
#                                              that GPU's pod on <server>
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../../lib/connect.sh"; nc_resolve
what="$1" t="$2" left=""
for i in $(seq 1 60); do
  if [ "$what" = network ]; then
    g=$($KUBECTL -n neocloud get backends.aifabrics.eda.nokia.com gpu-backend -o jsonpath='{.spec.gpuIsolationGroups[*].name}' 2>/dev/null)
    v=$($KUBECTL -n neocloud get virtualnetworks.services.eda.nokia.com "$t" --ignore-not-found -o name 2>/dev/null)
    left=""; [[ " $g " == *" $t "* ]] && left="group $t "; [ -n "$v" ] && left+="VirtualNetwork $t"
  else
    left=$($KUBECTL -n neocloud get interfaces.interfaces.eda.nokia.com "$t" -o jsonpath='{.metadata.labels.backend}' 2>/dev/null)
  fi
  if [ -z "$left" ]; then
    [ "$what" = gpu ] && echo "EDA release of $t complete after $((i * 2)) s" || echo "EDA revert ($what $t) complete after $((i * 2)) s"
    # one hosts.sh per server at a time (several GPUs of one server are released in parallel: concurrent runs raced,
    # "Nexthop has invalid gateway", 2026-11-12)
    if [ "$what" = gpu ] && [ -n "${3:-}" ]; then
      $(command -v flock >/dev/null && echo flock "/tmp/neocloud-hosts-$3.lock") bash "$HERE/../../hosts.sh" "$3" 2>&1 | grep -E '^-->|free'
    fi
    exit 0
  fi
  sleep 2
done
echo "EDA revert ($what $t) not complete after 120 s, still present: $left"; exit 1
