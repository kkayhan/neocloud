#!/usr/bin/env bash
# neocloud — host networking inside the 11 sims (10 network-multitool + the FRR internet router) (idempotent; a sim's netns config is lost on
# every pod restart ⇒ re-run after one). Called by deploy.sh phase hosts.
#   bash hosts.sh [host ...]        default: all        (gpu-server-N = that server's 8 GPUs + its bond)
#   bash hosts.sh --follow          GPU follower: polls the GPU backend labels + EDA's /64s every 2 s and re-runs
#                                   this script for a GPU server whose labels/prefixes changed (hand edits)
#
# Frontend (tenant VPCs, manifests/vpcs.yaml): bond0 = 802.3ad over the two NICs to the leaf pair (= partner of
#   the all-active ESI-LAG lag-<host>-local); bond0.<vlan> = host address; routes $VPC_ROUTES (the other VPC subnets) +
#   $INET_ROUTES (internet test prefixes) via the anycast gateway .1, so every reachability test (also the ones that must
#   FAIL) goes through the fabric. The default route stays on eth0 (sim pod network = out-of-band).
#   ONE subnet per tenant, no overlap (owner 2026-11-12; was overlapping 10.101/24 + fw + peering subnets):
#     tenant1 100.100.100.0/24 VLAN 101 (public, internet): GPU VMs only (fw-1 + dc2-host-1 left 2026-11-16)
#     tenant2 200.200.200.0/24 VLAN 102 (no internet):      GPU VMs only (dc2-host-2 removed 2026-11-16)
#     shared-services = ONE ip-vrf, two subnets (owner 2026-11-12: storage = generic shared resource):
#       storage 10.10.10.0/24 VLAN 110: storage-1 .11 (leaf-3/4) storage-2 .12 (leaf-5/6)
#       shared-service 10.20.20.0/24 VLAN 111: shared-service .10 (svc-leaf-1/2), shared-service-2 .11 (DC2, owner 2026-11-16)
#     VRF internet: fw-1 203.0.113.130/26 VLAN 120, gateway .129 (owner 2026-11-16 Q2 A: firewall in the internet network)
#   NIC numbers (topology/gen-topology.py): gpu-server-N eth9+eth10, everyone else eth1+eth2.
# GPU servers = PER-GPU TENANCY (owner 2026-11-02, like aifabric: tenant = `backend` label (tenant1|tenant2) of the
#   GPU's rail Interface rail-leaf-<G>-ethernet-1-<S>, read live; no label = free GPU). Inside sim gpu-server-S:
#   root netns = the server/hypervisor: bond0 (eth9+eth10) + bond0.101 + bond0.102 = trunk of every tenant VLAN
#     (LAG label frontend=tenant-trunk), no address.
#   netns gpuG (G = 1..8) = GPU G's VM: railG = macvlan PASSTHRU on NIC ethG (ethG itself stays in the root netns:
#     GOTCHA measured 2026-11-02, moving ethG into a netns breaks the CX sim: cxmgr manages ethG by name in the pod
#     netns, errors "No such device" and every ethN-cx peer of that sim went DOWN, bond included) + railG.1 (gpuVLAN 1)
#     = <EDA /64>::2, route fd00:100::/32 via ::1 (every rail of its
#     tenant; same-server GPUs reach each other only over the fabric, like NVLink off) + frontend leg fe-1|fe-2 =
#     macvlan (bridge) on bond0.<tenant VLAN>, <tenant /24>.(100+10*S+G)/24, default route via the anycast gateway
#     (SR-IOV VF of the frontend NIC) + own lldpd announcing the physical identity (system name gpu-server-S, port ethG).
#   free GPU: ethG.1 without address, no frontend leg. /64s read live from EDA (booked ports only, like aifabric).
# internet (manifests/edge.yaml): eth1.10 100.64.0.11/31 -> BR1, eth2.10 100.64.0.13/31 -> BR2, lo 198.51.100.1 +
#   192.0.2.1, FRR AS 64510 peering both BRs, announcing 198.51.100.0/24 + 192.0.2.0/24 (the "full table"; NO default:
#   the BRs generate the DC's 0/0 themselves, owner 2026-11-12 Q2 B);
#   learned routes (tenant1 100.100.100.0/24) installed by zebra, ECMP over both BRs.
# Every host: hostname = sim name + lldpd (ifname port-id), so the switches' LLDP table names it.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/connect.sh"; nc_resolve
K="$KUBECTL"
NS=neocloud
ONLY=" $* "
rc=0
want(){ [ "$ONLY" = "  " ] || [[ "$ONLY" == *" $1 "* ]]; }

declare -A FE=(   # host -> "nic1 nic2 vlan cidr gw net" (vlan "-" = bond only; net = own subnet, never routed via gw)
  [fw-1]="eth1 eth2 120 203.0.113.130/26 203.0.113.129 203.0.113.128/26"
  [shared-service]="eth1 eth2 111 10.20.20.10/24 10.20.20.1"
  [storage-1]="eth1 eth2 110 10.10.10.11/24 10.10.10.1"
  [storage-2]="eth1 eth2 110 10.10.10.12/24 10.10.10.1"
  [gpu-server-1]="eth9 eth10 trunk - -"
  [gpu-server-2]="eth9 eth10 trunk - -"
  [gpu-server-3]="eth9 eth10 trunk - -"
  [gpu-server-4]="eth9 eth10 trunk - -"
  [shared-service-2]="eth1 eth2 111 10.20.20.11/24 10.20.20.1"
)
ORDER="internet fw-1 shared-service storage-1 storage-2 gpu-server-1 gpu-server-2 gpu-server-3 gpu-server-4 shared-service-2"
INET_ROUTES="198.51.100.0/24 192.0.2.0/24"   # internet test prefixes (internet host), via the tenant gateway on EVERY host:
                                              # tenant1 reaches them (0/0 leaked from VRF internet), the others must fail in the fabric
declare -A VLAN=([1]=101 [2]=102)        # tenant -> frontend VLAN on the GPU server trunk
declare -A NET=([1]=100.100.100 [2]=200.200.200)  # tenant -> GPU frontend subnet /24 (gateway .1)
VPC_ROUTES="10.10.10.0/24 10.20.20.0/24 100.100.100.0/24 200.200.200.0/24 203.0.113.128/26"   # every VPC subnet + fw-1's; own subnet skipped (connected)
                                                               # (10.96/12 = the cluster's service range, never route it)

sim_run(){  # sim_run <host> <script>
  $K -n eda-system exec -i "deploy/cx-${NS}--$1-sim" -c "$1" -- sh -s <<<"$2"
}
wait_ports(){  # wait_ports <host> <n>: cxdp plugs ethN ~60 s after the pod is Running
  local h="$1" n="$2" i
  $K -n eda-system rollout status "deploy/cx-${NS}--${h}-sim" --timeout=300s >/dev/null 2>&1 || return 1
  for i in $(seq 1 30); do
    $K -n eda-system exec "deploy/cx-${NS}--$h-sim" -c "$h" -- sh -c \
      "for i in \$(seq 1 $n); do test -e /sys/class/net/eth\$i || exit 1; done" 2>/dev/null && return 0
    sleep 5
  done
  return 1
}

# root lldpd: GPU servers only on the bond NICs (the rail NICs speak LLDP from their GPU VM)
LLDP='hostname "$H" 2>/dev/null; lldpcli show configuration >/dev/null 2>&1 || lldpd -I "$LIF" >/dev/null 2>&1; sleep 1; lldpcli configure lldp portidsubtype ifname >/dev/null 2>&1; true'

# gpu_state: "<server> <gpu> <tenant|-> <prefix|->" per GPU: tenant = 1|2 = live `backend` label of its rail Interface
# (tenant1|tenant2, "tenant" stripped: the internal short code of VLAN/NET/fe-<x>), prefix = the /64
# EDA rendered on that leaf port (subinterface index 1; booked ports only)
gpu_state(){
  local pfx lab
  pfx=$($K -n eda-system exec deploy/eda-toolbox -- edactl -n "$NS" query \
    '.namespace.node.srl.interface.subinterface.ipv6.address fields [ip-prefix] where (.namespace.node.srl.interface.subinterface.index = 1)' 2>/dev/null \
    | awk '$5 ~ /^fd/ {sub(/::1\/64$/, "", $5); print $2, $3, $5}')
  lab=$($K -n "$NS" get interfaces.interfaces.eda.nokia.com -l role=gpu \
    -o jsonpath='{range .items[*]}{.metadata.labels.host} {.metadata.labels.rail} {.metadata.labels.backend}{"\n"}{end}')
  awk 'FILENAME == ARGV[1] {pf[$1 " " $2] = $3; next}
       NF >= 2 {s = $1; sub(/^gpu-server-/, "", s); k = "rail-leaf-" $2 " ethernet-1/" s
                t = (NF == 3 ? $3 : "-"); sub(/^tenant/, "", t)
                print $1, $2, t, (k in pf ? pf[k] : "-")}' <(echo "$pfx") <(echo "$lab") | sort -k1,1 -k2n
}

if [ "${1:-}" = --follow ]; then
  declare -A LAST
  echo "following the GPU backend labels (role=gpu Interfaces) + EDA /64s every 2 s; Ctrl-C stops"
  while true; do
    st=$(gpu_state)
    for s in 1 2 3 4; do
      sig=$(grep "^gpu-server-$s " <<<"$st")
      [ -n "$sig" ] || continue
      if [ "$sig" != "${LAST[$s]:-}" ]; then
        echo "$(date +%T) gpu-server-$s: $(awk '{printf "G%s=%s ", $2, $3}' <<<"$sig")"
        KUBECTL="$K" bash "$0" "gpu-server-$s" | sed 's/^/  /'
        LAST[$s]=$sig
      fi
    done
    sleep 2
  done
fi

STATE=$(gpu_state)

gpu_script(){  # gpu_script <server> -> shell lines for its 8 GPU VMs (netns gpuG)
  local h="$1" s="${1#gpu-server-}" g t p out="" N vl ip
  while read -r _ g t p; do
    N="ip netns exec gpu$g"
    out+="ip netns list | grep -qw gpu$g || ip netns add gpu$g
ip link del eth$g.1 2>/dev/null; sysctl -qw net.ipv6.conf.eth$g.disable_ipv6=1; ip link set eth$g up
if ! $N ip link show rail$g >/dev/null 2>&1; then
  ip link del g$g-rail 2>/dev/null; ip link add g$g-rail link eth$g type macvlan mode passthru
  ip link set g$g-rail netns gpu$g; $N ip link set g$g-rail name rail$g
fi
$N sh -c 'ip link set lo up; sysctl -qw net.ipv4.ip_forward=0 net.ipv6.conf.all.forwarding=0 net.ipv6.conf.all.accept_ra=0 net.ipv6.conf.default.accept_ra=0
  ip link set rail$g up; ip link show rail$g.1 >/dev/null 2>&1 || ip link add link rail$g name rail$g.1 type vlan id 1
  echo 0 > /proc/sys/net/ipv6/conf/rail$g.1/accept_ra; ip link set rail$g.1 up'
lldpcli -u /run/lldpd-gpu$g.sock show configuration >/dev/null 2>&1 || $N lldpd -u /run/lldpd-gpu$g.sock -I rail$g >/dev/null 2>&1
"
    if [ "$t" != - ] && [ "$p" != - ]; then
      vl=${VLAN[$t]}; net=${NET[$t]}; ip="$net.$((100 + 10 * s + g))"
      out+="$N sh -c 'for a in \$(ip -6 -o addr show dev rail$g.1 scope global | awk \"{print \\\$4}\"); do [ \"\$a\" = \"$p::2/64\" ] || ip -6 addr del \"\$a\" dev rail$g.1; done
  ip -6 addr replace $p::2/64 dev rail$g.1 nodad; ip -6 route replace fd00:100::/32 via $p::1 dev rail$g.1'
for o in 1 2; do [ \$o = $t ] || $N ip link del fe-\$o 2>/dev/null; done
if ! $N ip link show fe-$t >/dev/null 2>&1; then
  ip link del g$g-fe 2>/dev/null; ip link add g$g-fe link bond0.$vl type macvlan mode bridge
  ip link set g$g-fe netns gpu$g; $N ip link set g$g-fe name fe-$t
fi
$N sh -c 'ip link set fe-$t up; [ \"\$(ip -4 -o addr show dev fe-$t | awk \"{print \\\$4}\")\" = $ip/24 ] || { ip -4 addr flush dev fe-$t; ip addr add $ip/24 dev fe-$t; }
  ip route replace default via $net.1 dev fe-$t; arping -q -U -c 1 -I fe-$t $ip >/dev/null 2>&1 || true'
echo \"    GPU $g  tenant$t  rail$g.1 $p::2/64  fe-$t $ip/24\"
"
    else
      out+="$N ip -6 addr flush dev rail$g.1 scope global; $N ip link del fe-1 2>/dev/null; $N ip link del fe-2 2>/dev/null
echo \"    GPU $g  $([ "$t" = - ] && echo 'free (no backend label): parked' || echo "tenant$t, /64 not yet rendered by EDA (re-run)")\"
"
    fi
    # LLDP identity = the PHYSICAL cabling: server name + NIC ethG (EDA compares it with the TopoLink: announcing
    # gpu-server-S-gpuG / railG raised LLDPTopologyMisaligned on all 32 rail links, measured 2026-11-09)
    out+="sleep 0.3; lldpcli -u /run/lldpd-gpu$g.sock configure system hostname $h >/dev/null 2>&1; lldpcli -u /run/lldpd-gpu$g.sock configure ports rail$g lldp portidsubtype local eth$g description eth$g >/dev/null 2>&1
"
  done < <(grep "^$h " <<<"$STATE")
  echo "$out"
}

for h in $ORDER; do
  want "$h" || continue
  if [ "$h" = internet ]; then
    echo "--> internet (FRR AS 64510: eth1.10 -> border-router-1, eth2.10 -> border-router-2)"
    wait_ports internet 2 || { echo "    internet: pod or NICs not ready"; rc=1; continue; }
    # FRR (since 2026-11-09, was gobgpd): zebra installs the BGP-learned routes ⇒ a BR that goes away is dropped from
    # the ECMP set when its session drops. gobgpd + static ECMP kept hashing flows to a rebooting BR: 17.5 s (tenant2)
    # and 20.9 s (tenant1) lost during the fabric upgrade (phase 8 run 1). FRR image: watchfrr = PID-1's child ⇒ never
    # restart FRR (the pod would restart and lose this config); bgpd started next to zebra, config loaded with vtysh;
    # bgpd </dev/null >/dev/null or kubectl exec never returns (hung 2026-11-09). No lldpd in the image.
    sim_run internet "hostname internet 2>/dev/null
for n in 1 2; do ip link set eth\$n up; ip link show eth\$n.10 >/dev/null 2>&1 || ip link add link eth\$n name eth\$n.10 type vlan id 10; ip link set eth\$n.10 up; done
ip -4 addr flush dev eth1.10; ip addr add 100.64.0.11/31 dev eth1.10
ip -4 addr flush dev eth2.10; ip addr add 100.64.0.13/31 dev eth2.10
ip addr replace 198.51.100.1/32 dev lo; ip addr replace 192.0.2.1/32 dev lo
ip route del 203.0.113.0/24 2>/dev/null
ip route replace 100.64.0.0/24 nexthop via 100.64.0.10 dev eth1.10 nexthop via 100.64.0.12 dev eth2.10 2>/dev/null
sed -i 's/^bgpd=no/bgpd=yes/' /etc/frr/daemons
touch /etc/frr/vtysh.conf
pgrep -x bgpd >/dev/null || /usr/lib/frr/bgpd -d -F traditional -A 127.0.0.1 </dev/null >/dev/null 2>&1
sleep 2
cat > /etc/frr/inet.conf <<'CONF'
ip route 198.51.100.0/24 Null0
ip route 192.0.2.0/24 Null0
ip prefix-list INET-OWN seq 5 permit 198.51.100.0/24
ip prefix-list INET-OWN seq 10 permit 192.0.2.0/24
route-map INET-OUT permit 10
 match ip address prefix-list INET-OWN
router bgp 64510
 bgp router-id 198.51.100.1
 no bgp ebgp-requires-policy
 timers bgp 3 9
 neighbor 100.64.0.10 remote-as 64500
 neighbor 100.64.0.10 description border-router-1
 neighbor 100.64.0.12 remote-as 64500
 neighbor 100.64.0.12 description border-router-2
 address-family ipv4 unicast
  network 198.51.100.0/24
  network 192.0.2.0/24
  neighbor 100.64.0.10 route-map INET-OUT out
  neighbor 100.64.0.12 route-map INET-OUT out
  maximum-paths 2
 exit-address-family
CONF
vtysh -c 'conf t' -c 'no router bgp 64510' >/dev/null 2>&1; vtysh -f /etc/frr/inet.conf >/dev/null
sleep 5
echo \"    FRR bgpd up: \$(vtysh -c 'show bgp ipv4 unicast summary' | awk '/^100\\.64\\.0/ {printf \"%s=%s \", \$1, \$10}')\"" || rc=1
    continue
  fi
  read -r n1 n2 vlan cidr gw own <<<"${FE[$h]}"; own=${own:-${cidr%.*}.0/24}
  nmax=${n2#eth}
  echo "--> $h (bond0 = $n1 + $n2, ${vlan/-/no} VLAN ${cidr/-/})"
  wait_ports "$h" "$nmax" || { echo "    $h: pod or NICs not ready"; rc=1; continue; }
  fe="ip link show bond0 >/dev/null 2>&1 || ip link add bond0 type bond mode 802.3ad miimon 100 lacp_rate fast xmit_hash_policy layer3+4
for m in $n1 $n2; do
  [ \"\$(basename \"\$(readlink /sys/class/net/\$m/master 2>/dev/null)\" 2>/dev/null)\" = bond0 ] || { ip link set \$m down; ip link set \$m master bond0; }
  ip link set \$m up
done
ip link set bond0 up
echo \"    bond0 slaves: \$(cat /sys/class/net/bond0/bonding/slaves)\""
  if [ "$vlan" = trunk ]; then
    fe+="
for v in ${VLAN[1]} ${VLAN[2]}; do ip link show bond0.\$v >/dev/null 2>&1 || ip link add link bond0 name bond0.\$v type vlan id \$v; ip link set bond0.\$v up; done
echo \"    frontend trunk bond0.${VLAN[1]} + bond0.${VLAN[2]} (no address; GPU VMs attach per tenant)\""
  elif [ "$vlan" != - ]; then
    fe+="
sysctl -qw net.ipv4.conf.all.arp_ignore=1 net.ipv4.conf.all.arp_announce=2
for d in \$(ls /sys/class/net | grep '^bond0\\.'); do [ \$d = bond0.$vlan ] || ip link del \$d; done
ip link show bond0.$vlan >/dev/null 2>&1 || ip link add link bond0 name bond0.$vlan type vlan id $vlan
ip link set bond0.$vlan up
[ \"\$(ip -4 -o addr show dev bond0.$vlan | awk '{print \$4}')\" = $cidr ] || { ip -4 addr flush dev bond0.$vlan; ip addr add $cidr dev bond0.$vlan; }
for a in \$(ip -4 -o addr show dev bond0.$vlan | awk '{print \$4}'); do [ \$a = $cidr ] || ip addr del \$a dev bond0.$vlan; done
for r in $VPC_ROUTES $INET_ROUTES; do [ \$r = $own ] || ip route replace \$r via $gw dev bond0.$vlan; done
for r in 10.100.0.0/14 10.104.0.0/13 10.112.0.0/16 10.199.255.0/24 203.0.113.0/24 10.110.0.0/24; do ip route del \$r 2>/dev/null; done   # retired routes (pre-2026-11-12 + old shared 10.110/24)
arping -q -U -c 1 -I bond0.$vlan ${cidr%/*} >/dev/null 2>&1 || true
echo \"    frontend bond0.$vlan $cidr gw $gw\""
  fi
  LIF="eth[1-9]*"; [ "$vlan" = trunk ] && LIF="$n1,$n2"
  sim_run "$h" "H=$h; LIF='$LIF'; $LLDP
echo 0 > /proc/sys/net/ipv6/conf/all/accept_ra; echo 0 > /proc/sys/net/ipv6/conf/default/accept_ra
$fe
$([ "$vlan" = trunk ] && gpu_script "$h")" || rc=1
done
exit $rc
