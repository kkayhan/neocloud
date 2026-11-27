#!/usr/bin/env bash
# neocloud — move the WHOLE fabric (28 switches) to another SR Linux release with ONE DeployImagePipeline
# (owner 2026-11-09 Q5: "full fabric downgrade and upgrade ... split into redundant halves, minimal traffic impact").
#   bash upgrade/run.sh 26.7.2      # upgrade   (26.7.1 -> 26.7.2)
#   bash upgrade/run.sh 26.7.1      # downgrade (back)
# = what the presenter does in the GUI: Workflows -> Deploy Image Pipeline -> Create, Node Profile
#   srlinux-ghcr-<ver>, tranches tranche-a (upgrade-group=a) then tranche-b (upgrade-group=b), no canary.
# Each tranche = one transaction (TopoNode nodeProfile + version) ⇒ one run of neocloud-upgrade-pipeline over its 14
# switches in parallel. Starts upgrade/traffic.py first (unless TRAFFIC=0) and prints its report + gaps at the end.
# Prints every 20 s: workflow state, versions per tranche, newest pipeline runners.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"; . "$HERE/lib/connect.sh"; nc_resolve; K="$KUBECTL"; NS=neocloud
VER="${1:?usage: run.sh 26.7.2|26.7.1}"
# UNIQUE name per run (found 2026-11-17): EDA keeps every finished workflow by name; a DeployImagePipeline created with
# the name of an old COMPLETED workflow (e.g. neocloud-fabric-26-7-1 from 2026-11-09) never starts
NAME="neocloud-fabric-${VER//./-}-$(date -u +%m%d-%H%M)"
E(){ $K -n eda-system exec deploy/eda-toolbox -- edactl "$@" 2>/dev/null; }
$K -n $NS get nodeprofile "srlinux-ghcr-$VER" >/dev/null || { echo "no NodeProfile srlinux-ghcr-$VER (bash upgrade/setup.sh)"; exit 1; }
# never two rollouts at once (2026-11-17: owner started one in the GUI while this script was about to start its own)
busy=$($K -n eda-system exec deploy/eda-toolbox -- edactl -n $NS workflow get 2>/dev/null | awk '/Kind=DeployImagePipeline/ && $NF == "RUNNING" {print $1" "$3}')
[ -z "$busy" ] || { echo "a Deploy Image Pipeline is already running (workflow $busy): wait for it, nothing started"; exit 1; }
[ "${TRAFFIC:-1}" = 1 ] && python3 "$HERE/upgrade/traffic.py" start && sleep 10
last=$(E pipeline | awk 'NR>1 && $1~/^[0-9]+$/{r=$1} END{print r+0}')
cat <<YAML | $K apply -f - || exit 1
apiVersion: os.eda.nokia.com/v1
kind: DeployImagePipeline
metadata: { name: $NAME, namespace: $NS }
spec:
  nodeProfile: srlinux-ghcr-$VER
  tranches:
    - { name: tranche-a, nodeSelectors: [ "upgrade-group=a" ] }
    - { name: tranche-b, nodeSelectors: [ "upgrade-group=b" ] }
YAML
t0=$(date +%s); echo "started $NAME at $(date -u +%T) UTC (pipeline runners after #$last belong to it)"
while :; do
  st=$($K -n $NS get deployimagepipelines.os.eda.nokia.com "$NAME" -o jsonpath='{.metadata.annotations.workflows\.core\.eda\.nokia\.com/state}' 2>/dev/null)
  echo "---- +$(( $(date +%s) - t0 ))s $(date -u +%T) workflow=${st:-?}"
  for g in a b; do
    echo "  tranche $g: $($K -n $NS get toponodes -l upgrade-group=$g -o jsonpath='{range .items[*]}{.spec.version}/{.status.node-state}{"\n"}{end}' | sort | uniq -c | tr -s ' ' | paste -sd' ')"
  done
  E pipeline | awk -v l="$last" '$1~/^[0-9]+$/ && $1>l' | sed 's/^/  runner /'
  case "$st" in Completed|Failed|Terminated) break ;; esac
  sleep 20
done
echo "workflow $st after $(( $(date +%s) - t0 )) s"
[ "${TRAFFIC:-1}" = 1 ] && python3 "$HERE/upgrade/traffic.py" stop
[ "$st" = Completed ]
