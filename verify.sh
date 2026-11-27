#!/usr/bin/env bash
# neocloud — end-to-end check of the lab (deploy.sh phase verify; safe to run any time, read-only).
#   bash verify.sh
# 1 health    Fabrics frontend/dc2 + Backend + VirtualNetworks Up; every ISL Up; every BGP peer Established;
#             deviations 0
# Tenancy of a GPU = `backend` label (tenant1|tenant2) of its rail Interface (PER GPU since 2026-11-02, owner); the expected results
# are derived from the LIVE labels, so the check stays valid after any booking. A GPU = netns gpuG in its server sim.
# 2 frontend  every endpoint (5 non-GPU hosts + every booked GPU VM's fe-<tenant> leg) -> a SAMPLE of target addresses
#             (the hosts + the lowest booked GPU per server and tenant; owner Q1 B: full mesh overflowed the node ARP
#             table). One subnet per tenant (owner 2026-11-12): reachable = own VPC, or tenant <-> shared-services
#             (route leaking, manifests/leaking.yaml); tenant1 <-> tenant2 isolated; shared-services = ONE ip-vrf with
#             storage 10.10.10.0/24 + shared-service 10.20.20.0/24 (routed between them inside the VRF);
#             fw-1 = VRF internet 203.0.113.130/26 (2026-11-16): reached by tenant1 only (public to public via the 0/0)
# 3 backend   every booked GPU <-> every other booked GPU, all rails, same server included (EDA /64 ::2, route
#             fd00:100::/32): same tenant reachable (cross-rail via the E/W spines), other tenant isolated
#             ⇒ baseline (tenant1 only, 12 GPUs) 132 OK / 0 isolated / 0 wrong; free GPUs have no address
# 5 internet  internet <-> fw-1 (VRF internet) + a tenant1 GPU (leak) both ways; tenant2, storage, shared-service(-2)
#             -> internet isolated; internet -> tenant2 none (except its internet variant)
# 8 links     CheckInterfaces + CheckDefaultBgpPeers workflows (with selectors) Success, 0 LLDPTopologyMisaligned alarms
# 7 alerts    receiver reachable + a 15 s 30 Mb/s iperf3 burst arrives as a PortTrafficHigh notification (Q9 A)
# 9 netbox    NetBox app Instance reachable, pool nb-attach-vlans = NetBox VLAN group (300-399), NetBox holds 28
#             devices + 60 cables synced from EDA (no hairpins since 2026-11-12), scene netbox/new-subnet.sh add (NetBox /24 + VLAN from the NetBox
#             pool + host ping) then remove (owner 2026-11-09 Q7 A)
# 10 DCI     ONE stretched EVPN domain (owner 2026-11-12): DC2 border leaves carry NO tenant VRF (tenants = DC1 only since
#             2026-11-16, owner Q1 A) + the shared-services gateways (VPC stretched 2026-11-16); shared-services there learns
#             each tenant subnet as RT-5 from the DC1 leaves; shared-service-2 pings a GPU per tenant; L2 across the DCI in shared-services (shared-service-2 in DC2 -> shared-service in DC1, right MAC
#             answers; owner 2026-11-16: DC2 = one shared host); one gateway MAC
# 4 edge      internet host: 2 eBGP sessions, learns 100.100.100.0/24 + 203.0.113.128/26 only; border routers hold the full
#             table; VRF internet (border + service leaves, EVPN since 2026-11-16): border leaves 0/0 from the BRs, service
#             leaves 0/0 as RT-5, fw-1 subnet on the border leaves; tenant1 VRF 0/0 = leaked (pref 160);
#             tenant2 (only when onboarded: DC1 leaves 5 + 7) no 0/0, or 0/0 in its internet variant
set -uo pipefail
# VERIFY_SKIP="7 9" skips sections (twin: NetBox, alert-sink, Grafana are plain k8s apps a Branch does not fork)
source "$(dirname "${BASH_SOURCE[0]}")/lib/connect.sh"; nc_resolve
K="$KUBECTL"
NS=neocloud
E(){ $K -n eda-system exec deploy/eda-toolbox -- edactl -n "$NS" "$@" 2>/dev/null; }
rc=0
ok(){ printf '  %-58s %s\n' "$1" "$2"; }

# tenant2 is NOT in the baseline (owner 2026-11-12): the demo onboards it live (GUI or Terraform, tenant-onboarding/) ⇒ every
# tenant2 expectation follows its live state: absent | onboarded | onboarded WITH internet
TB=$($K -n $NS get virtualnetworks.services.eda.nokia.com tenant2 --ignore-not-found -o name 2>/dev/null)
TBI=no
[ -n "$TB" ] && [[ " $($K -n $NS get policys.routingpolicies.eda.nokia.com leak-internet-import -o jsonpath='{.spec.statements[*].name}' 2>/dev/null) " == *" tenant2 "* ]] && TBI=yes
echo "== tenant2: $([ -z "$TB" ] && echo 'absent (baseline)' || { [ $TBI = yes ] && echo 'onboarded WITH internet' || echo 'onboarded, no internet'; })"

echo "== 1 health"
# state_up <resource> <label>: waits ≤90 s for Up (right after hosts.sh the DC2 LACP bonds can still be settling:
# fresh deploy 2026-11-02 read tenant2 Degraded seconds before it turned Up)
state_up(){ local s i; for i in $(seq 1 18); do s=$($K -n $NS get "$1" -o jsonpath='{.status.operationalState}' 2>/dev/null); [ "$s" = Up ] && break; sleep 5; done
  ok "$2" "$s"; [ "$s" = Up ] || rc=1; }
for f in frontend dc2; do state_up fabrics.fabrics.eda.nokia.com/$f "Fabric $f"; done
state_up backends.aifabrics.eda.nokia.com/gpu-backend "Backend gpu-backend"
# the 4 VirtualNetworks (owner 2026-11-10 Q1 C: internet + one per tenant + shared-services): Up (same rule as deploy.sh vn_ok)
eval "$(sed -n '/^vn_ok(){/,/^}/p' "$(dirname "${BASH_SOURCE[0]}")/deploy.sh")"
for v in internet tenant1 ${TB:+tenant2} shared-services; do
  for i in $(seq 1 18); do vn_ok $v && break; sleep 5; done
  s=$($K -n $NS get virtualnetworks.services.eda.nokia.com $v -o jsonpath='{.status.operationalState} ({.status.numSubinterfacesOperDown} subif down)' 2>/dev/null)
  vn_ok $v && ok "VirtualNetwork $v" "ok: $s" || { ok "VirtualNetwork $v" "$s"; rc=1; }
done
isl=$(E get isls | awk 'NR>1' ); n=$(wc -l <<<"$isl"); u=$(grep -c ' Up$' <<<"$isl")
ok "ISLs Up (20 frontend + 2 DCI + 1 dc2 + 32 backend)" "$u/$n"; [ "$u" -eq 55 ] && [ "$n" -eq 55 ] || rc=1
p=$(E get defaultbgppeers | awk 'NR>1'); n=$(wc -l <<<"$p"); u=$(awk '$2=="Established"' <<<"$p" | grep -c .)   # column match: grep Established also counts NotEstablished (found 2026-11-10)
ok "default-NI BGP peers Established (ISLs)" "$u/$n"; [ "$u" -eq "$n" ] || rc=1
p=$(E get bgppeers | awk 'NR>1'); n=$(wc -l <<<"$p"); u=$(awk '$2=="Established"' <<<"$p" | grep -c .)
ok "VRF BGP peers Established (8 border routers + 4 VRF internet)" "$u/$n"; [ "$u" -eq 12 ] && [ "$n" -eq 12 ] || rc=1
d=$($K -n $NS get deviations.core.eda.nokia.com --no-headers 2>/dev/null | wc -l); ok "deviations" "$d"; [ "$d" -eq 0 ] || rc=1
# border routers left DRAINED by an interrupted upgrade (pipeline drain-edge without undrain-edge, 2026-11-17):
# per-peer exportPolicies override in VN internet ⇒ fix: .state/kubectl -n eda-system exec -i deploy/eda-toolbox -- bash -s neocloud undrain border-router-1 border-router-2 < upgrade/edge-peers.sh
d=$($K -n $NS get virtualnetworks.services.eda.nokia.com internet -o jsonpath='{range .spec.protocols.bgp.bgpPeers[?(@.spec.exportPolicies)]}{.name} {end}' 2>/dev/null)
ok "border routers drained (want none; upgrade leftover)" "${d:-none}"; [ -z "$d" ] || rc=1

# pings <sim> <lines "netns target"...>: pings inside the sim (netns "-" = the sim's own), ≤12 at a time, prints
# "<netns> <target> OK|FAIL"; OK = at least one of 2 replies (first packet may wait for ND/ARP on the far leaf).
# WHY ≤12: the first per-GPU run fired up to ~250 pings at once per sim (1500 in all) and kubelet killed cxdp in
# 20 neocloud sims at that moment ⇒ stuck links (eda-lab § CX SIM CXDP LIVENESS RESTART). ROOT CAUSE (MEASURED 2026-11-02):
# the Talos node's ARP table is ONE table for every netns on the node (gc_thresh3 1024 default); the full mesh of 24
# GPU VMs' frontend legs overflowed it ("neighbor table overflow" in dmesg) ⇒ kubelet "no route to host" to pod IPs
# ⇒ cxdp liveness kills in neocloud AND aifabric. ⇒ each sim flushes the neighbours its pings created right after.
pings(){ local h=$1; shift
  printf '%s\n' "$@" | $K -n eda-system exec -i "deploy/cx-${NS}--$h-sim" -c "$h" -- sh -c '
    i=0; while read -r n t; do [ -n "$t" ] || continue; ( x=""; [ "$n" = - ] || x="ip netns exec $n"
      if $x ping -c 2 -i 0.5 -W 1 -q "$t" >/dev/null 2>&1; then echo "$n $t OK"; else echo "$n $t FAIL"; fi ) &
      i=$((i + 1)); [ $((i % 12)) -eq 0 ] && wait; done; wait
    for d in $(ls /sys/class/net | grep "^bond0\\."); do ip neigh flush dev $d; done
    for n in $(ip netns list | cut -d" " -f1); do ip netns exec $n ip neigh flush all; done' 2>/dev/null; }

# GPU state from EDA: "<server> <gpu> <tenant|-> <prefix|->" (hosts.sh gpu_state = the same join)
eval "$(sed -n '/^gpu_state(){/,/^}/p' "$(dirname "$0")/hosts.sh")"
STATE=$(gpu_state)

echo "== 2 frontend VPCs (one subnet per tenant, both tenants <-> shared-services by route leaking)"
# endpoint table: sim netns address vpc (1 = tenant1 100.100.100.0/24, 2 = tenant2 200.200.200.0/24, s = shared-services,
# i = VRF internet: fw-1 203.0.113.130/26 since 2026-11-16)
# s = shared-services ip-vrf: storage 10.10.10.0/24 + shared-service 10.20.20.0/24 (owner 2026-11-12; was storage-3 10.110.0.10,
# with storage-1/-2 + compute-1..3 inside the tenants)
EP="fw-1 - 203.0.113.130 i
shared-service - 10.20.20.10 s
storage-1 - 10.10.10.11 s
storage-2 - 10.10.10.12 s
shared-service-2 - 10.20.20.11 s"
NETA=100.100.100 NETB=200.200.200
EP+=$'\n'$(awk -v na=$NETA -v nb=$NETB '$3 != "-" {s = $1; sub(/gpu-server-/, "", s); printf "%s gpu%s %s.%d %s\n", $1, $2, ($3 == "1" ? na : nb), 100 + 10 * s + $2, $3}' <<<"$STATE")
# expected result of <source vpc> -> <target vpc> (manifests/leaking.yaml): own VPC OK; tenant <-> shared OK; 1 <-> 2 never,
# EXCEPT when tenant2 has internet: both public subnets sit in VRF internet on the DC1 border leaves ⇒ the border leaf
# routes 1 <-> 2 like public-to-public internet traffic (measured 2026-11-12; accepted by owner 2026-11-12, plan.md)
expect(){ awk -v sv="$1" -v tip="$3" -v tbi="$TBI" '
  $3 == tip { tv = $4 }
  END { r = "FAIL"
        if (tv == sv) r = "OK"
        else if ((sv == "1" || sv == "2") && tv == "s") r = "OK"
        else if (sv == "s" && (tv == "1" || tv == "2")) r = "OK"
        else if (tbi == "yes" && ((sv == "1" && tv == "2") || (sv == "2" && tv == "1"))) r = "OK"
        else if ((sv == "i" && tv == "1") || (sv == "1" && tv == "i")) r = "OK"     # fw-1 <-> tenant1: public to public
        else if (tbi == "yes" && ((sv == "i" && tv == "2") || (sv == "2" && tv == "i"))) r = "OK"
        print r }' <<<"$EP"; }
# targets = SAMPLE (owner Q1 B 2026-11-02: keep the node ARP limit, shrink the test): the plain hosts + ONE GPU per
# (server, tenant) = its lowest booked GPU.
TG=$(awk '($2 == "-" || !seen[$1 " " $4]++) && !ip[$3]++' <<<"$EP")
good=0 iso=0 bad=0 want=0
for h in $(awk '{print $1}' <<<"$EP" | sort -u); do
  lines=()
  while read -r sh sn sip sv; do
    [ "$sh" = "$h" ] || continue
    while read -r th tn tip tv; do [ "$tip" = "$sip" ] || lines+=("$sn $tip"); done <<<"$TG"
  done <<<"$EP"
  while read -r n ip res; do
    [ -n "$ip" ] || continue
    read -r sip sv <<<"$(awk -v h=$h -v n=$n '$1==h && $2==n {print $3, $4}' <<<"$EP")"
    exp=$(expect "$sv" "$sip" "$ip")
    [ "$exp" = OK ] && want=$((want+1))
    if [ "$exp" = OK ] && [ "$res" = OK ]; then good=$((good+1))
    elif [ "$exp" = FAIL ] && [ "$res" = FAIL ]; then iso=$((iso+1))
    else bad=$((bad+1)); echo "  WRONG: $h/$n ($sv $sip) -> $ip $res (expected $exp)"; fi
  done <<<"$(pings "$h" "${lines[@]}")"
done
ok "frontend sample OK / isolated / wrong (baseline see plan)" "$good / $iso / $bad"; [ $bad -eq 0 ] && [ $good -eq $want ] || rc=1

echo "== 3 backend GPU NICs (same tenant reachable, other tenant isolated)"
# booked GPU table: server netns address tenant
BK=$(awk '$3 != "-" && $4 != "-" {printf "%s gpu%s %s::2 %s\n", $1, $2, $4, $3}' <<<"$STATE")
nb=$(awk '$3 != "-" && $4 == "-"' <<<"$STATE" | wc -l)
[ "$nb" -eq 0 ] || { echo "  $nb booked GPU(s) without an EDA /64"; rc=1; }
good=0 iso=0 bad=0 want=0
for h in $(awk '{print $1}' <<<"$BK" | sort -u); do
  lines=()
  while read -r sh sn sa st; do
    [ "$sh" = "$h" ] || continue
    while read -r th tn ta tt; do [ "$ta" = "$sa" ] || lines+=("$sn $ta"); done <<<"$BK"
  done <<<"$BK"
  while read -r n ip res; do
    [ -n "$ip" ] || continue
    st=$(awk -v h=$h -v n=$n '$1==h && $2==n {print $4}' <<<"$BK"); tt=$(awk -v a=$ip '$3==a {print $4}' <<<"$BK")
    [ "$st" = "$tt" ] && want=$((want+1))
    if [ "$st" = "$tt" ] && [ "$res" = OK ]; then good=$((good+1))
    elif [ "$st" != "$tt" ] && [ "$res" = FAIL ]; then iso=$((iso+1))
    else bad=$((bad+1)); echo "  WRONG: $h/$n -> $ip $res (tenant $st -> $tt)"; fi
  done <<<"$(pings "$h" "${lines[@]}")"
done
ok "backend matrix OK / isolated / wrong (tenant1 only: 132/0/0)" "$good / $iso / $bad"; [ $bad -eq 0 ] && [ $good -eq $want ] || rc=1
ok "GPUs tenant1 / tenant2 / free (baseline 12/0/20)" \
  "$(awk '$3=="1"' <<<"$STATE" | wc -l) / $(awk '$3=="2"' <<<"$STATE" | wc -l) / $(awk '$3=="-"' <<<"$STATE" | wc -l)"

echo "== 4 edge routing (full table on the border routers, 0/0 on the border leaves, leaked into tenant1)"
n=$($K -n eda-system exec deploy/cx-${NS}--internet-sim -c internet -- vtysh -c 'show bgp ipv4 unicast summary' 2>/dev/null \
  | awk '/^100\.64\.0\./ && $10 ~ /^[0-9]+$/' | wc -l)   # FRR: an Established neighbour shows a prefix count
ok "internet eBGP sessions to the BRs Established" "$n/2"; [ "$n" -eq 2 ] || rc=1
r=$($K -n eda-system exec deploy/cx-${NS}--internet-sim -c internet -- vtysh -c 'show ip route bgp' 2>/dev/null \
  | awk '/^B/ {print $2}' | sort -u | tr '\n' ' ')
want_inet="100.100.100.0/24 203.0.113.128/26 "; [ $TBI = yes ] && want_inet="100.100.100.0/24 200.200.200.0/24 203.0.113.128/26 "   # + tenant2 in its internet variant
ok "internet host learns from the DC (want ${want_inet% })" "${r:-none}"; [ "$r" = "$want_inet" ] || rc=1
RT='.namespace.node.srl.network-instance.route-table.ipv4-unicast.route fields [route-type, active, preference]'
rt(){ E query "$RT where (.namespace.node.name = \"$1\" and .namespace.node.srl.network-instance.name = \"$2\" and ipv4-prefix = \"$3\")" | awk 'NR > 1 && NF > 5 && $(NF-1) == "true" {print $6, $(NF-2), $NF; exit}'; }
r=$(rt border-router-1 edge 198.51.100.0/24); ok "border-router-1 VRF edge: 198.51.100.0/24 (full table)" "${r:-missing}"; [ -n "$r" ] || rc=1
for bl in border-leaf-1 border-leaf-2; do
  r=$(rt $bl internet 0.0.0.0/0); ok "$bl VRF internet: 0/0 from the BRs" "${r:-missing}"; [ -n "$r" ] || rc=1
  r=$(rt $bl internet 198.51.100.0/24); ok "$bl VRF internet: no internet prefixes" "${r:-none}"; [ -z "$r" ] || rc=1
  r=$(rt $bl tenant1-vrf 0.0.0.0/0); ok "$bl tenant1: active 0/0 = leaked from internet, pref 160" "${r:-missing}"; [[ "$r" == "internet "*" 160" ]] || rc=1
  r=$(rt $bl internet 203.0.113.128/26); ok "$bl VRF internet: fw-1 subnet from the service leaves" "${r:-missing}"; [ -n "$r" ] || rc=1
done
for sl in svc-leaf-1 svc-leaf-2; do   # VRF internet stretched to the service leaves (EVPN, 2026-11-16)
  r=$(rt $sl internet 0.0.0.0/0); ok "$sl VRF internet: 0/0 = RT-5 from the border leaves" "${r:-missing}"; [ -n "$r" ] || rc=1
done
# tenant2 (when onboarded): no 0/0 without internet; with internet the DC1 leaves learn the leaked 0/0 as RT-5
if [ -n "$TB" ]; then for n in leaf-5 leaf-7; do
  r=$(rt $n tenant2-vrf 0.0.0.0/0)
  if [ $TBI = yes ]; then ok "$n tenant2: 0/0 (internet variant)" "${r:-missing}"; [ -n "$r" ] || rc=1
  else ok "$n tenant2: no 0/0 (no internet service)" "${r:-none}"; [ -z "$r" ] || rc=1; fi
done; fi

echo "== 5 internet reachability (tenant1 only, via the leak; no NAT, tenant1 is public)"
# a GPU VM of each tenant: the lowest booked one
read -r ga gna gia _ <<<"$(awk '$4 == "1" && $2 != "-"' <<<"$EP" | head -1)"
read -r gb gnb gib _ <<<"$(awk '$4 == "2" && $2 != "-"' <<<"$EP" | head -1)"
# from the internet host ALWAYS with source 198.51.100.1: its link address 100.64.0.x is no internet test prefix, so a
# host's reply to it leaves via the host's own default route (eth0, pod network) instead of the fabric (found 2026-11-12)
inet(){ printf '%s\n' "$@" | $K -n eda-system exec -i deploy/cx-${NS}--internet-sim -c internet -- sh -c \
  'while read -r t; do ping -c 2 -W 1 -q -I 198.51.100.1 $t >/dev/null 2>&1 && echo "- $t OK" || echo "- $t FAIL"; done' 2>/dev/null; }
wb=FAIL; [ $TBI = yes ] && wb=OK   # tenant2 reaches / is reached from the internet only in its internet variant
r=$(inet 203.0.113.130 "$gia" ${gib:-})
for l in "203.0.113.130 OK fw-1 (VRF internet)" "$gia OK GPU $ga/$gna" ${gib:+"$gib $wb GPU $gb/$gnb (tenant2)"}; do
  read -r t want desc <<<"$l"; got=$(awk -v t=$t '$2==t {print $3}' <<<"$r")
  ok "internet -> $desc (want $want)" "$got"; [ "$got" = "$want" ] || rc=1
done
for l in "fw-1 - OK" "$ga $gna OK" ${gb:+"$gb $gnb $wb"} "storage-1 - FAIL" "shared-service - FAIL" "shared-service-2 - FAIL"; do
  read -r h n want <<<"$l"; got=$(pings "$h" "$n 198.51.100.1" | awk '{print $3}'); d=$h; [ "$n" = - ] || d="$h/$n"
  ok "$d -> internet 198.51.100.1 (want $want)" "$got"; [ "$got" = "$want" ] || rc=1
done

if [[ " ${VERIFY_SKIP:-} " == *" 7 "* ]]; then echo "== 7 skipped (VERIFY_SKIP)"; else
echo "== 7 monitoring + alerting (Threshold port-traffic-high -> notifier lab-alarms -> alert-sink)"
# active test: 15 s of 30 Mb/s storage-1 -> storage-2 (leaf-3/4 -> leaf-5/6 over the spines) must reach the receiver as a
# PortTrafficHigh alert (was compute-1 -> compute-2 until 2026-11-12)
SINK(){ $K -n eda-system exec deploy/eda-toolbox -- curl -s -m 5 http://alert-sink.neocloud.svc:8080/alerts 2>/dev/null; }
n0=$(SINK | python3 -c 'import sys,json; print(sum("PortTrafficHigh" in str(r["message"]) for r in json.load(sys.stdin)))' 2>/dev/null)
if [ -z "$n0" ]; then ok "alert receiver reachable from EDA" "NO"; rc=1
else
  ok "alert receiver reachable from EDA" "yes ($n0 PortTrafficHigh alerts so far)"
  $K -n eda-system exec deploy/cx-${NS}--storage-2-sim -c storage-2 -- sh -c 'pgrep -x iperf3 >/dev/null || iperf3 -s -D' 2>/dev/null
  # NEW raise after the burst started (received >= t0, not a CLEAR). WHY not "count went up": the sink keeps only its
  # last 200 alerts; after heavy traffic (traffic/neocloud-traffic.py) it is full and the count stays flat (2026-11-16)
  t0=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  $K -n eda-system exec deploy/cx-${NS}--storage-1-sim -c storage-1 -- iperf3 -c 10.10.10.12 -t 15 -b 30M >/dev/null 2>&1 &
  got=no; for _ in $(seq 1 12); do sleep 5
    n=$(SINK | python3 -c 'import sys,json; print(sum(r["received"] >= sys.argv[1] and "PortTrafficHigh" in str(r["message"]) and "CLEAR" not in str(r["message"].get("title", "")) for r in json.load(sys.stdin)))' "$t0" 2>/dev/null)
    [ "${n:-0}" -gt 0 ] && { got=yes; break; }; done; wait
  ok "30 Mb/s burst -> PortTrafficHigh alert delivered" "$got"; [ $got = yes ] || rc=1
fi
fi

echo "== 8 link validation (EDA check workflows + LLDP vs topology)"
# CheckInterfaces + CheckDefaultBgpPeers WITH selectors (empty spec = checks nothing and still says Success; IslPing
# says Success even with an ISL cut on this IPv6-unnumbered underlay: both measured 2026-11-09 ⇒ not used here).
# Counter sub-check DiscardedPackets left out: it fails a node whenever ANY port's discard counter moves during its
# 30 s window: on a healthy lab 3 of 5 runs failed on sporadic discards (rail-leaf GPU ports, border-router-2 e1-4)
# although a quiet 5-min window showed 0 discards on all 956 ports; source NOT pinned (not cross-tenant pings, not
# steady host frames: an idle GPU NIC sends only LLDP) (measured 2026-11-09, plan.md § PHASE 5).
SEL='[ "fabric=frontend", "fabric=backend", "fabric=dc2", "role=border-router" ]'
ts=$(date +%s)
cat <<EOW | $K create -f - >/dev/null 2>&1
apiVersion: interfaces.eda.nokia.com/v1
kind: CheckInterfaces
metadata: { name: verify-interfaces-$ts, namespace: $NS }
spec:
  nodeSelectors: $SEL
  checkStateCounters: { checks: [ EthernetCRC, EthernetFrameSize, EthernetPauseFrames, CarrierTransitions, TransceiverHealth, LACPErrors, IfPacketErrors ] }
---
apiVersion: protocols.eda.nokia.com/v2
kind: CheckDefaultBgpPeers
metadata: { name: verify-bgp-peers-$ts, namespace: $NS }
spec: { nodeSelectors: $SEL }
EOW
wf(){ local i st; for i in $(seq 1 60); do st=$($K -n $NS get "$1" -o jsonpath='{.metadata.annotations.workflows\.core\.eda\.nokia\.com/state}' 2>/dev/null)
  [ "$st" = Completed ] || [ "$st" = Failed ] && break; sleep 3; done; echo "$st"; }
wf checkinterfacess.interfaces.eda.nokia.com/verify-interfaces-$ts >/dev/null
r=$($K -n $NS get checkinterfacess.interfaces.eda.nokia.com/verify-interfaces-$ts -o json 2>/dev/null | python3 -c '
import json,sys; st=json.load(sys.stdin).get("status",{}); u=d=0
for n in st.get("details",[]): a=n.get("aggregateCount",{}); u+=a.get("up",0); d+=a.get("down",0)
print(st.get("result","?"), f"{u}/{u+d} up")' 2>/dev/null)
ok "CheckInterfaces (all switches)" "$r"; [[ "$r" == Success* ]] && [[ "$r" != *" 0/0 "* ]] || rc=1
wf checkdefaultbgppeerss.protocols.eda.nokia.com/verify-bgp-peers-$ts >/dev/null
r=$($K -n $NS get checkdefaultbgppeerss.protocols.eda.nokia.com/verify-bgp-peers-$ts -o jsonpath='{.status.result}' 2>/dev/null)
ok "CheckDefaultBgpPeers (all switches)" "$r"; [[ "$r" == *successful* ]] && [[ "$r" != *" 0/0 "* ]] || rc=1
$K -n $NS delete checkinterfacess.interfaces.eda.nokia.com/verify-interfaces-$ts checkdefaultbgppeerss.protocols.eda.nokia.com/verify-bgp-peers-$ts >/dev/null 2>&1
n=$(E query '.namespace.alarms.v1.current-alarm fields [name] where (.namespace.alarms.v1.current-alarm.type = "LLDPTopologyMisaligned")' | grep -c LLDP)
ok "LLDP neighbours that contradict the topology" "$n"; [ "$n" -eq 0 ] || rc=1

if [[ " ${VERIFY_SKIP:-} " == *" 9 "* ]]; then echo "== 9 skipped (VERIFY_SKIP)"
# NetBox PARKED since 2026-11-16 (owner Q1 C): section 9 runs only when deploy.sh --phase netbox put it back
elif ! $K -n $NS get instances.netbox.eda.nokia.com netbox >/dev/null 2>&1; then echo "== 9 NetBox: not deployed (parked; deploy.sh --phase netbox) — skipped"; else
echo "== 9 NetBox (IPAM for day-2 allocations, EDA inventory in NetBox)"
NETBOX_URL="${NETBOX_URL:-http://$(nc_host "$EDA_URL"):9506}"
NBQ(){ curl -s -m 10 -H "Authorization: Token $($K -n $NS get secret netbox-api-token -o jsonpath='{.data.apiToken}' | base64 -d)" \
  "$NETBOX_URL/api/$1" | python3 -c 'import json,sys;print(json.load(sys.stdin)["count"])' 2>/dev/null; }
r=$($K -n $NS get instances.netbox.eda.nokia.com netbox -o jsonpath='{.status.reachable}' 2>/dev/null)
ok "EDA NetBox app reaches NetBox" "${r:-missing}"; [ "$r" = true ] || rc=1
r=$($K -n $NS get indexallocationpool nb-attach-vlans -o jsonpath='{.spec.segments}' 2>/dev/null)
ok "pool nb-attach-vlans (from NetBox VLAN group)" "${r:-missing}"; [ "$r" = '[{"size":100,"start":300}]' ] || rc=1
# cables trickle in ≈6 s per link after the deploy's TopoLink touch ⇒ wait up to 10 min for all 60
for _ in $(seq 1 60); do [ "$(NBQ 'dcim/cables/?limit=1')" = 60 ] && break; sleep 10; done   # 66 with the 2026-11-10 → 11-12 hairpins
r="$(NBQ 'dcim/devices/?limit=1') devices, $(NBQ 'dcim/cables/?limit=1') cables"
ok "EDA inventory in NetBox (want 28 devices, 60 cables)" "$r"; [ "$r" = "28 devices, 60 cables" ] || rc=1
out=$(bash "$(dirname "${BASH_SOURCE[0]}")/netbox/new-subnet.sh" add 1 verify fw-1 2>&1); echo "$out" | sed 's/^/    /'
echo "$out" | grep -q PASS && ok "new VPC subnet from NetBox (/24 + VLAN), host ping" "PASS" || { ok "new VPC subnet from NetBox" "FAIL"; rc=1; }
bash "$(dirname "${BASH_SOURCE[0]}")/netbox/new-subnet.sh" remove 1 verify fw-1 2>&1 | sed 's/^/    /'
fi

echo "== 10 DCI = one stretched EVPN domain (Fabric frontend runs eBGP EVPN over the DCI ISLs)"
# tenants = DC1 only (owner 2026-11-16 Q1 A: no tenant device in DC2): the DC2 border leaves hold no tenant network
# instance; their shared-services VRF reaches the tenants through the RT-5 copies of the tenant subnets that the DC1
# leaves advertise in shared-services-vrf (leaked locally on the DC1 leaves, re-advertised)
for n in dc2-border-leaf-1 dc2-border-leaf-2; do
  r=$(E query ".namespace.node.srl.network-instance fields [ type ] where (.namespace.node.name = \"$n\")" | awk 'NR > 1 && $3 ~ /^tenant/ {printf "%s ", $3}')
  ok "$n: no tenant network instance (tenants = DC1 only)" "${r:-none}"; [ -z "$r" ] || rc=1
  for pf in 100.100.100.0/24 ${TB:+200.200.200.0/24}; do
    r=$(rt $n shared-services-vrf $pf); ok "$n shared-services: tenant subnet $pf = RT-5 from DC1" "${r:-missing}"; [ "$r" = "shared-services-vrf bgp-evpn 170" ] || rc=1
  done
  # the stretched VPC brings every gateway of shared-services to DC2 ⇒ storage 10.10.10.0/24 is LOCAL there (IRB), not RT-5
  # (measured 2026-11-16: "shared-services-vrf local 0"); shared-service-2 -> storage-1 itself is in section 2
  r=$(rt $n shared-services-vrf 10.10.10.0/24); ok "$n shared-services: storage gateway 10.10.10.0/24 local (VPC stretched 2026-11-16)" "${r:-missing}"; [ "$r" = "shared-services-vrf local 0" ] || rc=1
done
# shared-service-2 (DC2) -> the lowest booked GPU of each tenant (DC1, frontend leg): crosses the DCI in shared-services,
# enters the tenant VRF on the DC1 leaf (route leaking); the reply leaks back on leaf-7/8
for l in "$gia GPU $ga/$gna (tenant1)" ${gib:+"$gib GPU $gb/$gnb (tenant2)"}; do read -r a desc <<<"$l"
  r=$($K -n eda-system exec deploy/cx-${NS}--shared-service-2-sim -c shared-service-2 -- sh -c "ping -c 3 -i 0.3 -W 1 -q $a >/dev/null 2>&1 && echo OK || echo FAIL" 2>/dev/null)
  ok "shared-service-2 (DC2) -> $a $desc" "$r"; [ "$r" = OK ] || rc=1
done
# L2 across the DCI: shared-service-2 (DC2) reaches shared-service (DC1) in the same subnet and the right MAC answers
# (owner 2026-11-16: DC2 = one host in the shared frontend network; was dc2-host-1/-2 -> their tenant's DC1 endpoint);
# its gateway .1 = the ONE anycast MAC 00:00:5e:00:01:01 (no per-DC MAC since 2026-11-12)
for l in "shared-service-2 shared-service - bond0 10.20.20.10"; do read -r h t tn tif a <<<"$l"
  # ping + ARP read in ONE exec (the pings helper flushes the neighbours afterwards)
  read -r r mac <<<"$($K -n eda-system exec deploy/cx-${NS}--$h-sim -c $h -- sh -c \
    "ping -c 2 -i 0.5 -W 1 -q $a >/dev/null 2>&1 && echo -n 'OK ' || echo -n 'FAIL '; ip neigh show $a | awk '{print \$5}'" 2>/dev/null)"
  x=""; [ "$tn" = - ] || x="ip netns exec $tn"
  want=$($K -n eda-system exec deploy/cx-${NS}--$t-sim -c $t -- $x cat /sys/class/net/$tif/address 2>/dev/null)
  d=$t; [ "$tn" = - ] || d="$t/$tn"
  ok "$h -> $a over L2 across the DCI = $d" "$r ${mac:-no-arp}"; [ "$r" = OK ] && [ "$mac" = "$want" ] || rc=1
  g=${a%.*}.1; gm=$($K -n eda-system exec deploy/cx-${NS}--$h-sim -c $h -- sh -c "ping -c 1 -W 1 -q $g >/dev/null 2>&1; ip neigh show $g | awk '{print \$5}'" 2>/dev/null)
  ok "$h gateway $g MAC (want the one anycast MAC)" "${gm:-no-arp}"; [ "$gm" = 00:00:5e:00:01:01 ] || rc=1
done

[ $rc -eq 0 ] && echo "== neocloud verify: ALL PASS" || echo "== neocloud verify: PROBLEMS (rc=$rc)"
exit $rc
