#!/usr/bin/env bash
# neocloud — cabling-mistake scene (owner 2026-11-09, phase 5 link validation). Makes a server announce the WRONG name
# over LLDP, as if its cables were plugged into the ports meant for another server, so EDA's LLDP-vs-topology check
# raises LLDPTopologyMisaligned on that TopoLink ("Expected neighbor … is [storage-2, eth1] but found [storage-1, eth1]")
# and the notifier sends it to alert-sink. Nothing changes in EDA or on the switches.
#   bash miswire.sh on  [host] [pretend-name]    default: storage-2 announces "storage-1"
#   bash miswire.sh off [host]                   back to its real name
# Measured 2026-11-09: alarm 18 s after `on`, CLEAR 18 s after `off`, both delivered to alert-sink.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/connect.sh"; nc_resolve
act=${1:-}; h=${2:-storage-2}; as=${3:-storage-1}
case "$act" in
  on)  name=$as ;;
  off) name=$h ;;
  *) echo "usage: $0 on|off [host] [pretend-name]"; exit 2 ;;
esac
$KUBECTL -n eda-system exec "deploy/cx-neocloud--$h-sim" -c "$h" -- lldpcli configure system hostname "$name" >/dev/null
echo "$h now announces LLDP system name '$name' ($([ "$act" = on ] && echo 'miswired: alarm in ~20 s' || echo 'fixed: CLEAR in ~20 s'))"
