#!/usr/bin/env bash
# neocloud — drain / undrain the external BGP sessions of the border routers among the given switches (2026-11-17).
# Runs INSIDE the eda-toolbox pod (edactl + jq there); the same body is embedded in the upgrade pipeline's
# drain-edge / undrain-edge jobs by upgrade/build-pipeline.py (like host-ports.sh for the servers).
#   edge-peers.sh <namespace> drain|undrain <node> [<node> ...]
# drain   = every BGP peer of VirtualNetwork $EDGE_VN in a group listed in $EDGE_DRAIN, whose routed interface sits on
#           one of the nodes, gets exportPolicies [<drain policy>] (= the group's routes, AS path prepended 3x)
# undrain = remove that per-peer override ⇒ the group's export policy applies again
# WHY: EDA's Drain covers DefaultRouters only; the border routers route in VRF edge ⇒ without this a returning border
# router attracted the internet's return traffic before it had routes (22-29 s loss per run, 2026-11-16/17).
# Switches that are not border routers = no-op. Any node list, so `undrain <all BRs>` clears leftovers.
set -euo pipefail
NS="$1"; ACTION="$2"; shift 2
case "$ACTION" in drain|undrain) ;; *) echo "action must be drain|undrain" >&2; exit 2 ;; esac
VN="${EDGE_VN:-internet}"
DRAIN="${EDGE_DRAIN:-br-to-internet=internet-public-drain br-to-dc=default-route-drain}"
NODES_JSON=$(printf '%s\n' "$@" | jq -Rsc 'split("\n") | map(select(length > 0))')
MAP_JSON=$(printf '%s\n' $DRAIN | jq -Rsc 'split("\n") | map(select(length > 0) | split("=") | {(.[0]): .[1]}) | add')
vn=$(edactl -n "$NS" get virtualnetworks.services.eda.nokia.com "$VN" -o json)
# routed interface -> Interface object -> node (the Interface's first member)
declare -A NODE_OF
for iface in $(echo "$vn" | jq -r '.spec.routedInterfaces[]?.spec.interface' | sort -u); do
  NODE_OF[$iface]=$(edactl -n "$NS" get interfaces.interfaces.eda.nokia.com "$iface" -o json | jq -r '.spec.members[0].node')
done
ri_iface=$(echo "$vn" | jq -c '[.spec.routedInterfaces[]? | {(.name): .spec.interface}] | add // {}')
ops="[]"; touched=""
while IFS=$'\t' read -r idx name group ri has; do
  pol=$(echo "$MAP_JSON" | jq -r --arg g "$group" '.[$g] // empty'); [ -n "$pol" ] || continue
  iface=$(echo "$ri_iface" | jq -r --arg r "$ri" '.[$r] // empty'); node="${NODE_OF[$iface]:-}"
  echo "$NODES_JSON" | jq -e --arg n "$node" 'index($n) != null' >/dev/null || continue
  path="/spec/protocols/bgp/bgpPeers/$idx/spec/exportPolicies"
  if [ "$ACTION" = drain ]; then
    ops=$(echo "$ops" | jq -c --arg p "$path" --arg v "$pol" '. + [{op: "add", path: $p, value: [$v]}]')
  elif [ "$has" = yes ]; then
    ops=$(echo "$ops" | jq -c --arg p "$path" '. + [{op: "remove", path: $p}]')
  else continue; fi
  touched="$touched $name($node)"
done < <(echo "$vn" | jq -r '.spec.protocols.bgp.bgpPeers | to_entries[] |
           [.key, .value.name, .value.spec.group, .value.spec.interface, (if .value.spec.exportPolicies then "yes" else "no" end)] | @tsv')
if [ "$ops" != "[]" ]; then
  edactl -n "$NS" patch virtualnetworks.services.eda.nokia.com "$VN" -p "$ops" -m "upgrade: $ACTION edge BGP peers on $*" >/dev/null
fi
echo "edge-peers: $ACTION on $*:${touched:- nothing to do (no border router / already $ACTION)}"
