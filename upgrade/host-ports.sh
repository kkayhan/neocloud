#!/usr/bin/env bash
# Gracefully move servers off (or back onto) one or more switches by setting
# their member ports in every MULTIHOMED LAG Interface to enabled=false|true.
# Runs INSIDE the eda-toolbox pod (edactl + jq there); upgrade/build-pipeline.py embeds it as the body of the
# isolate-hosts / restore-hosts jobs of neocloud-upgrade-pipeline (copied from the upgrade-pipeline demo, 2026-11-27).
#   host-ports.sh <namespace> disable|enable <node> [<node> ...]
# Host side: the leaf port goes down => LACP drops that bond member => the host
# sends everything to the partner leaf; EVPN withdraws the leaf from the ES.
# Spines (no LAG members) are a no-op.
# Which LAGs: ISOLATE_SELECTOR (label selector on the LAG Interface objects, set by the
# pipeline to upgrade-isolate=true = opt-in label from the topology link template).
# Empty selector = every multihomed LAG (undoes any leftover isolation).
set -euo pipefail
NS="$1"; ACTION="$2"; shift 2
case "$ACTION" in disable) VAL=false ;; enable) VAL=true ;; *) echo "action must be disable|enable" >&2; exit 2 ;; esac
NODES_JSON=$(printf '%s\n' "$@" | jq -Rsc 'split("\n") | map(select(length > 0))')
changed=0
SEL=()
[ -n "${ISOLATE_SELECTOR:-}" ] && SEL=(-l "$ISOLATE_SELECTOR")
for name in $(edactl -n "$NS" get interfaces.interfaces.eda.nokia.com "${SEL[@]}" -o json | jq -rs '.[] | select((.spec.type | ascii_downcase) == "lag" and (.spec.members | length) > 1) | .metadata.name'); do
  obj=$(edactl -n "$NS" get interfaces.interfaces.eda.nokia.com "$name" -o json)
  patch=$(echo "$obj" | jq -c --argjson nodes "$NODES_JSON" --argjson val "$VAL" '
    [.spec.members | to_entries[] | select(.value.node as $n | $nodes | index($n))
     | select((if .value.enabled == null then true else .value.enabled end) != $val)
     | {op: "replace", path: "/spec/members/\(.key)/enabled", value: $val}]')
  [ "$patch" = "[]" ] && continue
  edactl -n "$NS" patch interfaces.interfaces.eda.nokia.com "$name" -p "$patch" \
    -m "upgrade: $ACTION server-facing member(s) of $name on $*" >/dev/null
  echo "$ACTION $name members on $*"
  changed=$((changed+1))
done
echo "host-ports: $ACTION done on $* (selector: ${ISOLATE_SELECTOR:-all multihomed LAGs}; $changed LAG(s) changed)"
