#!/usr/bin/env bash
# neocloud — GPU cloud (CSP) datacenter demo for Nokia EDA 26.8 (built on 26.8.2), EDA namespace neocloud.
#   ./deploy.sh [--yes] [--phase] [P]   asks for the EDA URL, admin login, kubeconfig and (whole lab / phase ns) the SR Linux
#                                       26.7 licence (lib/connect.sh), checks the target (preflight), then runs phase P
#   demo.py --cluster kind|talos neocloud deploy [--phase P]   build host: no questions (pinned mode, lib/connect.sh)
#   phases: ns|users|topology|fabrics|backend|edge|vpcs|macsec|hosts|grafana|dashboard|monitoring|upgrade|verify|all
#           (+ netbox, twin: on request, only where netbox/ and twin/ exist; not part of the published bundle)
# all (default) = ns -> users -> topology (skipped when the lab exists) -> fabrics -> backend -> edge -> vpcs
#   -> macsec -> hosts -> grafana -> dashboard -> monitoring -> upgrade -> verify. Phases twin + netbox = on request only
#   (NetBox PARKED 2026-11-16, owner Q1 C: kept in netbox/, not deployed, not used).
# DCI = ONE stretched EVPN domain over both DCs (owner 2026-11-12; replaced the 2026-11-10 hairpin hand-off, git 1f43b12):
#   Fabric frontend owns the DCI ISLs ⇒ one Router + one BridgeDomain per tenant spans DC1 + DC2 (plan.md § ONE STRETCHED DOMAIN).
# Every phase is idempotent except `topology`, which deletes + re-creates the lab (NetworkTopology is one-shot).
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/lib/connect.sh"
source "$HERE/lib/common.sh"
NS=neocloud
M="$HERE/manifests"
YES="" PHASE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y) YES=yes ;;
    --phase)  ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
    *) PHASE="$1" ;;
  esac
  shift
done
PHASE="${PHASE:-all}"
case "$PHASE" in all|ns) NC_NEED_LICENCE=yes ;; esac   # only phase ns loads the licence (lib/connect.sh asks for it)
nc_connect deploy "$YES" || exit 1
K="$KUBECTL"
if [ "$NC_MODE" = interactive ]; then         # demo.py keeps its own log on the build host
  LOGF="$NC_STATE/deploy-$(date +%Y%m%d-%H%M%S).log"
  exec > >(tee -a "$LOGF") 2>&1
  echo "log: $LOGF"
fi
# counts read from the generated topology (WHY: a hardcoded N_HOSTS=14 survived the 2026-11-12 host refactor to 11
# and failed the first redeploy after it at wait_host_pods)
read -r N_SWITCHES N_HOSTS < <(python3 -c 'import sys,yaml; s=yaml.safe_load(open(sys.argv[1]))["spec"]; print(len(s["nodes"]), len(s["simulation"]["simNodes"]))' "$HERE/topology/neocloud-topo.yaml")

# apply_wait <file> <kind> <name...>: kubectl apply, then wait until EDA has committed every named object
# (kubectl apply returns before EDA commits; edactl shows EDA's view)
apply_wait(){
  local f="$1" kind="$2"; shift 2
  $K apply -f "$f" || return 1
  local n want=$# i
  for i in $(seq 1 45); do
    n=0; for o in "$@"; do edactl_cmd -n "$NS" get "$kind" "$o" >/dev/null 2>&1 && n=$((n + 1)); done
    [ "$n" -eq "$want" ] && return 0; sleep 2
  done
  err "$kind: only $n of $want committed by EDA ($*)"; return 1
}

wait_host_pods(){
  log "wait for $N_HOSTS host sim pods Running"
  for _ in $(seq 1 60); do
    local r; r=$($K -n eda-system get pods -l cx-node-namespace=$NS,cx-kind=linux --no-headers 2>/dev/null | grep -c ' Running ' || true)
    echo "  host pods Running=$r/$N_HOSTS"; [ "$r" -ge "$N_HOSTS" ] && return 0; sleep 10
  done; err "host sim pods not Running"; return 1
}

phase_ns(){
  log "PHASE ns — EDA namespace $NS (pools + NodeProfiles from eda), SR Linux 26.7 sim licence on NodeProfile srlinux-ghcr-26.7.1 (seeded copy)"
  bootstrap_ns "$NS" eda || return 1
  nc_licence_check || return 1
  # licence = eda-system ConfigMap (where the seeded cx-srl-* licence CMs live; EDA 26.8.2 ships them EMPTY); value never printed
  $K -n eda-system create configmap neocloud-srl-sim-license --from-file=license.key="$NEOCLOUD_LICENSE" \
    --dry-run=client -o yaml | $K apply -f - >/dev/null || return 1
  # fabric ASNs = private 4-byte (owner Q14 A defaults); only this namespace's pool
  $K -n "$NS" patch indexallocationpool asn-pool --type merge \
    -p '{"spec":{"segments":[{"start":4200000100,"size":1000}]}}' >/dev/null || return 1
  # licence on the namespace's BOOTSTRAP-SEEDED profile copy, not on a new NodeProfile. WHY (MEASURED 2026-11-02):
  # on a re-created namespace the topology workflow did not see a kubectl-created NodeProfile for minutes
  # (NT result Failed `load node profiles … resource not found`, 12 retries over 5 min), seeded copies resolve at
  # once. The seeded copy lives in ns neocloud (dies with it); the eda-system seeded licence CMs stay untouched.
  $K -n "$NS" patch nodeprofile srlinux-ghcr-26.7.1 --type merge -p '{"spec":{"license":"neocloud-srl-sim-license"}}' >/dev/null || return 1
  for _ in $(seq 1 30); do
    edactl_cmd -n "$NS" get nodeprofile srlinux-ghcr-26.7.1 -o yaml 2>/dev/null | grep -q "license: neocloud-srl-sim-license" && return 0; sleep 2
  done
  err "NodeProfile srlinux-ghcr-26.7.1: licence not committed by EDA"; return 1
}

wait_nt_record_gone(){  # a stale NetworkTopology workflow record turns the next create into a no-op
  for _ in $(seq 1 30); do
    edactl_cmd workflow get -A 2>/dev/null | awk -v ns="$NS" '$2==ns && $3=="neocloud"' | grep -q . || return 0; sleep 2
  done
  warn "workflow record of NetworkTopology neocloud still present"
}

phase_topology(){
  log "PHASE topology — delete + create NetworkTopology neocloud ($N_SWITCHES switches, 53 ISLs, $N_HOSTS hosts)"
  python3 "$HERE/topology/gen-topology.py" >/dev/null
  $K -n "$NS" delete backends.aifabrics.eda.nokia.com --all --ignore-not-found 2>/dev/null
  $K -n "$NS" delete networktopology neocloud --ignore-not-found
  $K -n "$NS" delete toponode,topolink,simnode --all --ignore-not-found 2>/dev/null
  for _ in $(seq 1 40); do
    local n; n=$($K -n eda-system get pods -l cx-node-namespace=$NS --no-headers 2>/dev/null | wc -l)
    [ "$n" -eq 0 ] && break; echo "  old lab pods left=$n"; sleep 8
  done
  $K apply -f "$HERE/topology/grouping.yaml"
  # NT = a workflow. Two traps (MEASURED 2026-11-02, fresh deploys after destroy): (1) on a namespace that was
  # deleted + re-bootstrapped, the workflow does not see NodeProfiles created by kubectl for MINUTES (status.result
  # Failed `load node profiles: … resource not found`, 0 TopoNodes; 3 tries over 3.5 min failed, a probe 9 min
  # after the profile's creation succeeded; bootstrap-seeded profiles resolve at once; a brand-new namespace had
  # no lag) ; (2) re-creating the NT while the failed workflow record exists = silent no-op (record clears ≈2 s
  # after the NT delete). ⇒ create; on Failed / not expanded: delete, wait for the record to go, re-create, ≤12 tries.
  local try res
  for try in $(seq 1 12); do
    wait_nt_record_gone
    $K create -f "$HERE/topology/neocloud-topo.yaml" || return 1
    for _ in $(seq 1 12); do
      sleep 5
      [ "$($K -n "$NS" get toponodes --no-headers 2>/dev/null | wc -l)" -gt 0 ] && break 2
      res=$($K -n "$NS" get networktopology neocloud -o jsonpath='{.status.result}' 2>/dev/null)
      [ "$res" = Failed ] && break
    done
    warn "NetworkTopology not expanded (try $try, result '${res:-none}': $($K -n "$NS" get networktopology neocloud -o jsonpath='{.status.message}' 2>/dev/null | head -c 200)) — delete + re-create"
    $K -n "$NS" delete networktopology neocloud --ignore-not-found
    sleep 10
  done
  wait_toponodes_synced "$NS" "$N_SWITCHES" 1500 || return 1
  wait_host_pods || return 1
}

phase_fabrics(){
  log "PHASE fabrics — Fabric frontend (DC1, 20 ISLs + 2 DCI) + Fabric dc2 (1 ISL): eBGP unnumbered IPv6 + eBGP EVPN"
  $K apply -f "$M/fabrics.yaml" || return 1
  local f rc=0
  for f in frontend dc2; do
    wait_resource_field "$NS" fabrics.fabrics.eda.nokia.com/$f '{.status.operationalState}' Up 600 || rc=1
  done
  return $rc
}

phase_backend(){
  log "PHASE backend — aifabrics Backend gpu-backend (stripe gpu-backend-leaves + connector gpu-backend-spine, EVPN, tenant1; tenant2 is onboarded live by the demo, tenant-onboarding/)"
  $K apply -f "$M/backend.yaml" || return 1
  wait_resource_field "$NS" backends.aifabrics.eda.nokia.com/gpu-backend '{.status.operationalState}' Up 600
}

phase_edge(){
  log "PHASE edge — leaking.yaml (who reaches what) + VirtualNetwork internet: border routers AS 64500 (VRF edge, full table, generated 0/0) + VRF internet on the DC1 border leaves (AS 64501, leaks 0/0 into tenant1)"
  # leaking.yaml FIRST: every leak PrefixSet/Policy (edge.yaml + vpcs.yaml reference them; owner redesign 2026-11-12)
  $K apply -f "$M/leaking.yaml" -f "$M/edge.yaml" || return 1
  # ONE VirtualNetwork since 2026-11-10 (owner Q1 C; was edge + internet). Its 2 peers to the internet host come up
  # only in phase hosts (FRR) ⇒ wait for existence here, for Up (minus those 2) in phase vpcs
  local i; for i in $(seq 1 30); do edactl_cmd -n "$NS" get virtualnetworks internet >/dev/null 2>&1 && return 0; sleep 2; done; return 1
}

# vn_ok <vn>: the VirtualNetwork is Up. `exp` = per-VN number of subinterfaces allowed Down while Degraded (empty: none
# expected; a single-active ES would need 1 per standby subinterface, which EDA reports Down).
vn_ok(){ $K -n "$NS" get virtualnetworks.services.eda.nokia.com "$1" -o json 2>/dev/null | python3 -c '
import json,sys
exp={}   # no single-active ES in the lab ⇒ every VN must be Up
s=json.load(sys.stdin).get("status",{}); n=sys.argv[1]; st=s.get("operationalState")
import os
pre={"internet":2} if os.environ.get("VN_PRE_HOSTS") else {}   # internet: 2 BR peers to the internet host, which runs FRR only after phase hosts
oth=sum(v for k,v in s.items() if k.endswith("OperDown") and k not in ("numSubinterfacesOperDown","numBGPPeersOperDown"))
oth+=max(0,s.get("numBGPPeersOperDown",0)-pre.get(n,0))
if st=="Up" or (st=="Degraded" and oth==0 and s.get("numSubinterfacesOperDown")==exp.get(n,0)): print("ok"); sys.exit(0)
print(st); sys.exit(1)' "$1" >/dev/null; }

phase_vpcs(){
  log "PHASE vpcs — one VirtualNetwork per tenant, stretched over DC1 + DC2 (one EVPN domain): tenant1 100.100.100.0/24 (tenant2 = onboarded live by the demo, tenant-onboarding/), shared-services (DC1), route leaking (+ X1B ESI-label Configlet)"
  # leak Policies = leaking.yaml, applied in phase edge
  $K apply -f "$M/vpcs.yaml" || return 1
  # X1B ESs (26.3.2 AND 26.7.1) stay down (no-esi-label) until the Configlet lands, and its Update fails until EDA has rendered
  # the ESs (= the VPCs committed) ⇒ wait for the VirtualNetworks in EDA, then the Configlet, then Up (an ES exists
  # as soon as its LAG does, checked live 2026-11-12; DC2's only ES = shared-service-2 since 2026-11-16)
  local vn rc=0
  for _ in $(seq 1 45); do
    edactl_cmd -n "$NS" get virtualnetworks tenant1 >/dev/null 2>&1 \
      && edactl_cmd -n "$NS" get virtualnetworks shared-services >/dev/null 2>&1 && break; sleep 2
  done
  apply_wait "$M/esi-label.yaml" configlets dc2-esi-no-label || rc=1
  for vn in tenant1 shared-services internet; do
    # VN_PRE_HOSTS: the 2 internet-host peers in VN internet stay down until phase hosts ⇒ allowed
    # here only; verify.sh uses the same function without it = strict
    local i; for i in $(seq 1 60); do VN_PRE_HOSTS=1 vn_ok $vn && break; sleep 5; done
    VN_PRE_HOSTS=1 vn_ok $vn && echo "  VirtualNetwork $vn ok" || { err "VirtualNetwork $vn not Up"; rc=1; }
  done
  return $rc
}

phase_macsec(){
  log "PHASE macsec — Configlet dci-macsec on the DCI ports (MACsec config present, admin-disabled; owner Q4 B)"
  if ! $K -n "$NS" get secret neocloud-macsec-keys >/dev/null 2>&1; then
    $K -n "$NS" create secret generic neocloud-macsec-keys \
      --from-literal=cak="$(python3 -c 'import secrets; print(secrets.token_hex(32))')" \
      --from-literal=ckn="$(python3 -c 'import secrets; print(secrets.token_hex(32))')" >/dev/null || return 1
  fi
  local cak ckn
  cak=$($K -n "$NS" get secret neocloud-macsec-keys -o jsonpath='{.data.cak}' | base64 -d)
  ckn=$($K -n "$NS" get secret neocloud-macsec-keys -o jsonpath='{.data.ckn}' | base64 -d)
  # keys = hex only ⇒ plain sed substitution is safe (no envsubst needed on the deploying machine)
  sed -e "s/\${CAK}/$cak/g" -e "s/\${CKN}/$ckn/g" "$M/macsec.yaml.tmpl" | $K apply -f - || return 1
  local n
  for _ in $(seq 1 30); do
    edactl_cmd -n "$NS" get configlets dci-macsec >/dev/null 2>&1 && return 0; sleep 2
  done
  err "Configlet dci-macsec not committed"; return 1
}

phase_hosts(){
  log "PHASE hosts — bonds + tenant VLANs, one VM (netns) per GPU from its tenant label (EDA /64 + frontend leg), internet router (FRR)"
  KUBECTL="$K" bash "$HERE/hosts.sh"
}

phase_grafana(){
  # Live topology of the whole lab (owner 2026-11-02: "i only want the topology svg ... similar to what we
  # have for aifabric"): own Export CRs (eda-system, namespace neocloud only) + own Prometheus + Grafana in
  # k8s ns $NS, published via HttpProxy neocloud-grafana. Same shape as aifabric phase_grafana.
  local T="$HERE/telemetry" psum gsum
  log "PHASE grafana — Exports + Prometheus + Grafana in ns $NS, dashboard 'NeoCloud datacenter'"
  python3 "$T/build-dashboard.py" || return 1
  if ! $K get crd exports.prom.eda.nokia.com >/dev/null 2>&1; then
    log "  Prometheus exporter app missing (fresh cluster) — AppInstaller prom.eda.nokia.com"
    local ai; ai=$($K create -f "$T/apps.yaml" -o name) || return 1
    for _ in $(seq 1 60); do
      [ "$($K -n eda-system get "$ai" -o jsonpath='{.status.result}' 2>/dev/null)" = Completed ] \
        && $K get crd exports.prom.eda.nokia.com >/dev/null 2>&1 && break; sleep 5
    done
    $K get crd exports.prom.eda.nokia.com >/dev/null 2>&1 || { err "prom exporter app not installed ($ai)"; return 1; }
  fi
  $K apply -f "$T/exports.yaml" || return 1
  $K -n "$NS" create configmap neocloud-prometheus-config --from-file="$T/prometheus.yml" \
    --dry-run=client -o yaml | $K apply -f - >/dev/null
  $K -n "$NS" create configmap neocloud-grafana-provisioning --from-file="$T/grafana/datasource.yml" \
    --from-file="$T/grafana/dashboards.yml" --dry-run=client -o yaml | $K apply -f - >/dev/null
  # dashboard JSON > 256 KB = too big for client-side apply's last-applied annotation
  # (telemetry-stack §22) => server-side apply
  $K -n "$NS" create configmap neocloud-grafana-dashboards --from-file="$T/grafana/neocloud-topology.json" \
    --dry-run=client -o yaml | $K apply --server-side --force-conflicts --field-manager=neocloud-deploy -f - >/dev/null || return 1
  # GF_SERVER_ROOT_URL must name the EDA address the browser uses (__EDA_URL__ in stack.yaml)
  sed "s#__EDA_URL__#$EDA_URL#" "$T/stack.yaml" | $K apply -f - || return 1
  $K apply -f "$T/httpproxy.yaml" || return 1
  # Restart a pod ONLY when its config changed (checksum annotation on the pod template; unchanged => no-op
  # patch). WHY: Prometheus history lives in an emptyDir. The dashboard JSON needs no restart: its directory
  # mount updates live (kubelet <= ~90 s + provider 10 s).
  psum=$(cksum < "$T/prometheus.yml" | cut -d' ' -f1)
  gsum=$( (cat "$T/grafana/datasource.yml" "$T/grafana/dashboards.yml" "$T/stack.yaml"; echo "$EDA_URL") | cksum | cut -d' ' -f1)
  $K -n "$NS" patch deploy prometheus -p "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"neocloud/config\":\"$psum\"}}}}}" | sed 's/^/  /'
  $K -n "$NS" patch deploy grafana -p "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"neocloud/config\":\"$gsum\"}}}}}" | sed 's/^/  /'
  $K -n "$NS" rollout status deploy/prometheus --timeout=180s || return 1
  $K -n "$NS" rollout status deploy/grafana --timeout=240s || return 1
  echo "  URL: $EDA_URL/core/httpproxy/v1/neocloud-grafana/d/neocloud-topology/"
}

phase_dashboard(){
  # EDA GUI dashboard "NeoCloud Operations" (owner 2026-11-16 Q1-Q4 A): shared file designs/neocloud-ops.json in EDA
  # user storage, every tile a live EQL query. Repo file wins: every deploy republishes it (GUI edits are overwritten).
  # + the shared navigation panel "NeoCloud" that opens it (owner 2026-11-16 Q1 B short demo menu, Q3 A deploy publishes)
  log "PHASE dashboard — EDA GUI dashboard NeoCloud Operations + navigation panel NeoCloud (shared)"
  python3 "$HERE/dashboards/neocloud_ops.py" publish || return 1
  KUBECTL="$K" python3 "$HERE/dashboards/nav_panel.py" publish
}

phase_monitoring(){
  # Monitoring + alerting (owner 2026-11-09 Q9 A): traffic-rate Threshold + EDA notifiers app -> in-lab webhook
  # receiver alert-sink (k8s ns $NS). Files: monitoring/ (notifiers-app.yaml, alert-sink.yaml, monitoring.yaml).
  local D="$HERE/monitoring"
  log "PHASE monitoring — Threshold port-traffic-high + notifiers app -> local alert receiver alert-sink"
  if ! $K get crd providers.notifiers.eda.nokia.com >/dev/null 2>&1; then
    log "  notifiers app missing (fresh cluster) — AppInstaller notifiers.eda.nokia.com"
    local ai; ai=$($K create -f "$D/notifiers-app.yaml" -o name) || return 1
    for _ in $(seq 1 60); do
      [ "$($K -n eda-system get "$ai" -o jsonpath='{.status.result}' 2>/dev/null)" = Completed ] \
        && $K get crd notifiers.notifiers.eda.nokia.com >/dev/null 2>&1 && break; sleep 5
    done
    $K get crd notifiers.notifiers.eda.nokia.com >/dev/null 2>&1 || { err "notifiers app not installed ($ai)"; return 1; }
  fi
  $K -n eda-system rollout status deploy/eda-notifier --timeout=300s || return 1
  $K apply -f "$D/alert-sink.yaml" || return 1
  $K -n "$NS" rollout status deploy/alert-sink --timeout=300s || return 1
  # the Provider/Notifier admission webhooks live in the notifier pod: retry while it settles
  local i; for i in $(seq 1 12); do $K apply -f "$D/monitoring.yaml" && return 0; sleep 10; done
  return 1
}

phase_netbox(){
  # NetBox as IPAM for day-2 allocations (owner 2026-11-09 Q7 A). Files: netbox/ (netbox-app.yaml, netbox.yaml,
  # instance.yaml, seed.py, allocation.yaml, new-subnet.sh). Order matters (all measured 2026-11-09):
  #   app ⇒ NetBox pods (first start ≈10-15 min of migrations on the loaded node) ⇒ v1 token ⇒ Instance (app creates
  #   site neocloud) ⇒ seed (waits for the site) ⇒ wait 28 devices in NetBox ⇒ restart eda-netbox (full cache) ⇒
  #   Allocation ⇒ touch TopoLinks (cables, ≈3 min: the link reconciler never retries its startup "no instances found").
  local D="$HERE/netbox"
  [ -d "$D" ] || { err "phase netbox: the NetBox scene (netbox/) is not part of this copy of the demo"; return 2; }
  # browser + scripts reach NetBox on a Kind extraPortMapping 9506 -> NodePort 32760 of the EDA host (build host)
  NETBOX_URL="${NETBOX_URL:-http://$(nc_host "$EDA_URL"):9506}"
  log "PHASE netbox — NetBox (IPAM) + EDA NetBox app: VLAN pool from NetBox, EDA inventory into NetBox"
  if ! $K get crd instances.netbox.eda.nokia.com >/dev/null 2>&1; then
    log "  NetBox app missing (fresh cluster) — AppInstaller netbox.eda.nokia.com"
    local ai; ai=$($K create -f "$D/netbox-app.yaml" -o name) || return 1
    for _ in $(seq 1 60); do
      [ "$($K -n eda-system get "$ai" -o jsonpath='{.status.result}' 2>/dev/null)" = Completed ] \
        && $K get crd allocations.netbox.eda.nokia.com >/dev/null 2>&1 && break; sleep 5
    done
    $K get crd allocations.netbox.eda.nokia.com >/dev/null 2>&1 || { err "NetBox app not installed ($ai)"; return 1; }
  fi
  $K -n eda-system rollout status deploy/eda-netbox --timeout=300s || return 1
  $K apply -f "$D/netbox.yaml" || return 1
  log "  wait for NetBox (first start runs its database migrations)"
  # readyReplicas, not `rollout status`: a Deployment that once exceeded its progress deadline stays failed for
  # rollout status until the next rollout (2026-11-09)
  local i; for i in $(seq 1 180); do
    [ "$($K -n "$NS" get deploy netbox -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" = 1 ] && break; sleep 10
  done
  [ "$($K -n "$NS" get deploy netbox -o jsonpath='{.status.readyReplicas}')" = 1 ] || { err "NetBox not ready after 30 min"; return 1; }
  # NetBox 4.7's image only auto-creates v2 tokens (Bearer nbt_…); the EDA app sends "Token <key>" ⇒ classic v1 token
  $K -n "$NS" exec deploy/netbox -- /opt/netbox/venv/bin/python /opt/netbox/netbox/manage.py shell -c "
from users.models import Token, User
from users.choices import TokenVersionChoices as V
u = User.objects.get(username='admin')
Token.objects.filter(user=u, version=V.V1).exists() or Token.objects.create(user=u, version=V.V1, token='$($K -n "$NS" get secret netbox-api-token -o jsonpath='{.data.apiToken}' | base64 -d)', description='EDA neocloud (v1)')
" >/dev/null 2>&1 || { err "NetBox v1 token"; return 1; }
  $K apply -f "$D/instance.yaml" || return 1
  for _ in $(seq 1 40); do
    [ "$($K -n "$NS" get instances.netbox.eda.nokia.com netbox -o jsonpath='{.status.reachable}' 2>/dev/null)" = true ] && break; sleep 3
  done
  python3 "$D/seed.py" || return 1
  # devices: the running controller retries its "role is missing" TopoNodes with backoff ⇒ wait for all of them in
  # NetBox BEFORE the restart. A restart while it is still creating them = the new pod caches only part (13/28 seen
  # 2026-11-09) and then loops forever on "Device name must be unique per site and tenant" for the rest.
  local tok n; tok=$($K -n "$NS" get secret netbox-api-token -o jsonpath='{.data.apiToken}' | base64 -d)
  # wait until all devices exist OR the count stops moving for 60 s (final E2E 2026-11-09: the first pod created 0 in
  # 10 min, the restarted one then created all 28 ⇒ only a restart DURING creation is harmful)
  local prev=-1 still=0
  for i in $(seq 1 120); do
    n=$(curl -s -m 10 -H "Authorization: Token $tok" "$NETBOX_URL/api/dcim/devices/?limit=1" | python3 -c 'import json,sys;print(json.load(sys.stdin)["count"])' 2>/dev/null)
    [ "${n:-0}" -ge "$N_SWITCHES" ] && break
    if [ "${n:-0}" = "$prev" ]; then still=$((still + 1)); [ "$still" -ge 12 ] && break; else still=0; prev=${n:-0}; fi
    sleep 5
  done
  log "  NetBox devices from EDA: ${n:-0}/$N_SWITCHES"
  # restart = fresh cache with every device; the TopoLink reconciler never retries its startup "no instances found"
  $K -n eda-system rollout restart deploy/eda-netbox && $K -n eda-system rollout status deploy/eda-netbox --timeout=300s || return 1
  for i in $(seq 1 60); do
    $K -n eda-system logs deploy/eda-netbox 2>/dev/null | grep -q 'synced DeviceTypes' && [ "$($K -n eda-system get pods --no-headers 2>/dev/null | grep -c '^eda-netbox-')" = 1 ] && break; sleep 3
  done
  $K apply -f "$D/allocation.yaml" || return 1
  for _ in $(seq 1 60); do $K -n "$NS" get indexallocationpool nb-attach-vlans >/dev/null 2>&1 && break; sleep 3; done
  $K -n "$NS" get indexallocationpool nb-attach-vlans -o jsonpath='  pool nb-attach-vlans {.spec.segments}{"\n"}' || { err "pool nb-attach-vlans missing"; return 1; }
  $K -n "$NS" annotate topolinks --all neocloud/netbox-sync="$(date +%s)" --overwrite >/dev/null
  log "  NetBox UI $NETBOX_URL (admin/admin) — cables sync in the background (≈6 s per link)"
}

phase_upgrade(){
  # fabric downgrade/upgrade scene (owner 2026-11-09 Q5): labels, 26.7.2 NodeProfile, neocloud-upgrade-pipeline.
  # Prepares only; the run itself = bash upgrade/run.sh 26.7.2|26.7.1 (RUNBOOK scene 12).
  log "PHASE upgrade — tranche labels, NodeProfile srlinux-ghcr-26.7.2, PipelineDefinition neocloud-upgrade-pipeline"
  KUBECTL="$K" bash "$HERE/upgrade/setup.sh"
}

phase_twin(){
  # digital twin = EDA Branch `twin`. NOT part of `all` (DECIDED owner 2026-11-10 Q2 A; was last in `all` 11-09 →
  # 11-10): run `--phase twin` when the twin is wanted. It doubles the simulators (CPU requests ≈49 % → 93 %). ≈30 min.
  # Needs fs.inotify.max_user_instances 8192 on the Kind host (build host: /etc/sysctl.d/99-kind-branch-inotify.conf).
  [ -f "$HERE/twin/twin.sh" ] || { err "phase twin: the twin scripts (twin/) are not part of this copy of the demo"; return 2; }
  log "PHASE twin — EDA Branch twin (digital twin of the whole lab), twin hosts, twin UI :9501"
  [ "$(sysctl -n fs.inotify.max_user_instances 2>/dev/null || echo 0)" -ge 8192 ] \
    || warn "fs.inotify.max_user_instances < 8192: twin pods may fail with 'too many open files'"
  KUBECTL="$K" bash "$HERE/twin/twin.sh" up
}

phase_users(){
  log "PHASE users — EDA user terraform (group system-administrator) = the identity of tenant-onboarding/terraform (owner Q2 A 2026-11-12)"
  python3 "$HERE/tenant-onboarding/terraform-user.py" ensure
}

phase_verify(){
  log "PHASE verify — fabrics, Backend, deviations, traffic matrix"
  KUBECTL="$K" bash "$HERE/verify.sh"
}

case "$PHASE" in
  ns)       phase_ns ;;
  users)    phase_users ;;
  macsec)   phase_macsec ;;
  hosts)    phase_hosts ;;
  verify)   phase_verify ;;
  grafana)  phase_grafana ;;
  monitoring) phase_monitoring ;;
  dashboard) phase_dashboard ;;
  netbox)   phase_netbox ;;
  upgrade)  phase_upgrade ;;
  twin)     phase_twin ;;
  topology) phase_topology ;;
  fabrics)  phase_fabrics ;;
  backend)  phase_backend ;;
  edge)     phase_edge ;;
  vpcs)     phase_vpcs ;;
  all)
    phase_ns || exit 1
    phase_users || exit 1
    if [ "$($K -n "$NS" get toponodes --no-headers 2>/dev/null | wc -l)" -ge "$N_SWITCHES" ]; then
      log "topology already present — skipping (run --phase topology to rebuild)"
    else
      phase_topology || exit 1
    fi
    phase_fabrics || exit 1
    phase_backend || exit 1
    phase_edge || exit 1
    phase_vpcs || exit 1
    phase_macsec || exit 1
    phase_hosts || exit 1
    phase_grafana || exit 1
    phase_dashboard || exit 1
    phase_monitoring || exit 1
    phase_upgrade || exit 1
    phase_verify
    ;;
  *) err "unknown phase '$PHASE'"; exit 2 ;;
esac
