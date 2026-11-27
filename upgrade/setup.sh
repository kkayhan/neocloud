#!/usr/bin/env bash
# neocloud — prepare the fabric upgrade/downgrade scene (deploy.sh phase upgrade; idempotent; changes no switch).
#   1 labels: TopoNodes neocloud-upgrade=true + upgrade-group=a|b, server LAGs (every LAG with a frontend label) upgrade-isolate=true
#     (a fresh deploy gets them from gen-topology.py; this catches an older lab)
#   2 Artifact srlinux-ghcr-26.7.2 (YANG schema) + NodeProfile srlinux-ghcr-26.7.2 (upgrade/nodeprofile-26.7.2.yaml)
#   3 PipelineDefinition neocloud-upgrade-pipeline (generated from Nokia's live one) enabled; Nokia's stays disabled
#     (two enabled pipelines would both run per batch)
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"; . "$HERE/lib/connect.sh"; nc_resolve; K="$KUBECTL"; NS=neocloud
grp(){ local n="$1" num="${1##*-}"; case "$n" in rail-leaf-*) [ "$num" -le 4 ] && echo a || echo b ;; *) [ $((num % 2)) = 1 ] && echo a || echo b ;; esac; }
for n in $($K -n $NS get toponodes -o jsonpath='{.items[*].metadata.name}'); do
  $K -n $NS label toponode "$n" neocloud-upgrade=true upgrade-group="$(grp "$n")" --overwrite >/dev/null
done
$K -n $NS label interfaces.interfaces.eda.nokia.com -l frontend upgrade-isolate=true --overwrite >/dev/null
echo "labels: tranche a = $($K -n $NS get toponodes -l upgrade-group=a --no-headers | wc -l) switches, b = $($K -n $NS get toponodes -l upgrade-group=b --no-headers | wc -l), isolatable server LAGs = $($K -n $NS get interfaces.interfaces.eda.nokia.com -l upgrade-isolate=true --no-headers | wc -l)"
$K apply -f "$HERE/upgrade/nodeprofile-26.7.2.yaml" >/dev/null || exit 1
for _ in $(seq 1 60); do
  [ "$($K -n eda-system get artifacts.artifacts.eda.nokia.com srlinux-ghcr-26.7.2 -o jsonpath='{.status.downloadStatus}' 2>/dev/null)" = Available ] && break; sleep 5
done
echo "Artifact srlinux-ghcr-26.7.2: $($K -n eda-system get artifacts.artifacts.eda.nokia.com srlinux-ghcr-26.7.2 -o jsonpath='{.status.downloadStatus}')"
KUBECTL="$K" python3 "$HERE/upgrade/build-pipeline.py" | sed 's/:.*/ (generated)/'
$K apply -f "$HERE/upgrade/pipeline.yaml" >/dev/null || exit 1
$K -n eda-system patch pipelinedefinition deployimage-pipeline --type=merge -p '{"spec":{"enabled":false}}' >/dev/null
echo "enabled pipelines: $($K get pipelinedefinitions -A -o jsonpath='{range .items[?(@.spec.enabled==true)]}{.metadata.name} {end}')"
