#!/usr/bin/env bash
# neocloud — remove the whole lab: Backend, NetworkTopology, the EDA namespace (switches, hosts, pools,
# every service object), plus the eda-system objects the lab owns (licence ConfigMap, topology grouping,
# dashboard HttpProxy neocloud-grafana + Export CRs neocloud-*, upgrade pipeline), the EDA GUI dashboard + navigation
# panel and the EDA user terraform. Kept: the Prometheus exporter + notifiers apps (others may use them), files on disk.
#   ./destroy.sh [--yes]                            asks for the EDA URL, admin login, kubeconfig (saved answers = defaults)
#   demo.py --cluster kind|talos neocloud destroy   build host: no questions (pinned mode)
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/lib/connect.sh"
source "$HERE/lib/common.sh"
NS=neocloud
YES=""
case "${1:-}" in --yes|-y) YES=yes ;; -h|--help) sed -n '2,7p' "$0"; exit 0 ;; esac
nc_connect destroy "$YES" || exit 1
K="$KUBECTL"

# digital twin (twin/twin.sh): a Branch of a lab being destroyed is useless and holds ≈27 cpu requests
if [ -f "$HERE/twin/twin.sh" ] && $K -n eda-system get branches.core.eda.nokia.com twin >/dev/null 2>&1; then log "remove Branch twin first"; bash "$HERE/twin/twin.sh" down; fi
log "tenant onboarding demo leftovers (Terraform state, tenant2 login = cluster-wide EDA user/group/role): tenant-onboarding/demo-reset.sh"
bash "$HERE/tenant-onboarding/demo-reset.sh" --lab-destroy 2>&1 | sed 's/^/  /' || true
log "EDA user terraform (cluster-wide, created by deploy phase users)"
python3 "$HERE/tenant-onboarding/terraform-user.py" delete 2>&1 | sed 's/^/  /' || true
log "delete Configlets + VirtualNetworks first (objects on top of the Backend/Fabrics block their delete; aifabric dry-run 1131)"
# every RoutedInterface / BGP group / BGP peer lives INSIDE a VirtualNetwork (owner 2026-11-10 Q1 A) ⇒ goes with it;
# standalone objects referencing a VN router would block the VN delete (213 s vs 48.8 s, measured 2026-11-09)
# monitoring: Threshold (its alarms clear with it), Notifier, Provider; alert-sink goes with the k8s ns; the notifiers
# app stays installed (cluster-wide, like the Prometheus exporter app)
$K delete -f "$HERE/monitoring/monitoring.yaml" --ignore-not-found 2>/dev/null
# NetBox scene objects (netbox/new-subnet.sh: BD + IRB on a tenant VRF + VLAN, label neocloud-scene=netbox) reference a
# VN router ⇒ before the VNs; then Allocation + Instance (pool nb-attach-vlans + NetBox pods go with the namespace;
# the NetBox app stays installed, cluster-wide)
$K -n "$NS" delete vlans.services.eda.nokia.com,irbinterfaces.services.eda.nokia.com,bridgedomains.services.eda.nokia.com \
  -l neocloud-scene=netbox --ignore-not-found 2>/dev/null
[ -d "$HERE/netbox" ] && $K delete -f "$HERE/netbox/allocation.yaml" -f "$HERE/netbox/instance.yaml" --ignore-not-found 2>/dev/null
$K -n "$NS" delete configlets.config.eda.nokia.com --all --ignore-not-found 2>/dev/null
$K -n "$NS" delete virtualnetworks.services.eda.nokia.com --all --ignore-not-found 2>/dev/null
for _ in $(seq 1 45); do
  n=$( { edactl_cmd -n "$NS" get configlets; edactl_cmd -n "$NS" get virtualnetworks; } 2>/dev/null | grep -cvE '^NAME|^Error|^$')
  [ "$n" -eq 0 ] && break; sleep 2
done

log "delete Backends in $NS (frees the tenant VRFs + underlay before the switches go)"
$K -n "$NS" delete backends.aifabrics.eda.nokia.com --all --ignore-not-found 2>/dev/null

log "delete NetworkTopologies in $NS (a stale workflow record makes the next create of the same name a no-op)"
$K -n "$NS" delete networktopologies.topologies.eda.nokia.com --all --ignore-not-found 2>/dev/null

log "delete eda-system objects of the lab: licence ConfigMap, topology grouping, dashboard HttpProxy + Export CRs"
log "  (Grafana/Prometheus pods go with ns $NS)"
$K -n eda-system delete configmap neocloud-srl-sim-license --ignore-not-found
$K -n eda-system delete httpproxy neocloud-grafana --ignore-not-found
python3 "$HERE/dashboards/neocloud_ops.py" remove || true   # EDA GUI dashboard NeoCloud Operations (shared user storage)
python3 "$HERE/dashboards/nav_panel.py" remove || true      # its navigation panel NeoCloud
$K -n eda-system delete pipelinedefinition neocloud-upgrade-pipeline --ignore-not-found   # upgrade/ (Artifact srlinux-ghcr-26.7.2 kept)
$K delete -f "$HERE/telemetry/exports.yaml" --ignore-not-found 2>/dev/null
$K delete -f "$HERE/topology/grouping.yaml" --ignore-not-found 2>/dev/null

log "delete EDA namespace $NS (edactl removes the EDB record + k8s ns + pools)"
if $K -n eda-system get namespaces.core.eda.nokia.com "$NS" >/dev/null 2>&1; then
  edactl_cmd delete namespace "$NS" || $K -n eda-system delete namespaces.core.eda.nokia.com "$NS" --ignore-not-found
fi
$K wait --for=delete ns/"$NS" --timeout=300s 2>/dev/null || true
for _ in $(seq 1 36); do
  n=$($K -n eda-system get pods -l cx-node-namespace=$NS --no-headers 2>/dev/null | wc -l)
  [ "$n" -eq 0 ] && break; echo "  lab pods left=$n"; sleep 10
done
left=$(edactl_cmd workflow get -A 2>/dev/null | awk -v ns="$NS" '$2==ns' | wc -l)
[ "$left" -eq 0 ] || warn "$left workflow record(s) still listed for ns $NS: edactl workflow get -A | grep $NS"
log "neocloud torn down (files kept on disk)"
