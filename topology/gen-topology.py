#!/usr/bin/env python3
"""Generate topology/neocloud-topo.yaml, the ONE NetworkTopology of the neocloud CSP datacenter lab.

Design = plan.md § DESIGN + § DECIDED ROUND 1/2 (owner 2026-11-02). SR Linux 26.7.1 everywhere.
  DC1 frontend (Fabric frontend)  ns-spine-1/2 H5 · border-leaf-1/2 X1B (borderLeafs) · svc-leaf-1/2 D5 ·
                                  leaf-3/4 + leaf-5/6 storage, leaf-7/8 GPU (H5)          20 ISLs
  edge (no Fabric, VN internet) border-router-1/2 X1B (ASBR, AS 64500): BR1-BR2, each BR -> both border
                                  leaves, each BR -> internet
  DC1 backend (aifabrics Backend) rail-leaf-1..8 + ew-spine-1..4 (H5)                            32 ISLs
  DC2 (Fabric dc2)                dc2-border-leaf-1/2 X1B, 1 ISL between them
  DCI                             border-leaf-N e1-5 <-> dc2-border-leaf-N e1-5 (MACsec Configlet, disabled)
  DCI = ONE STRETCHED EVPN DOMAIN (owner 2026-11-12: "change the design to One stretched EVPN domain across both
                                  DCs"; supersedes the 2026-11-10 hairpin hand-off, last in git 1f43b12): the DCI ISLs
                                  carry eBGP + eBGP EVPN like any ISL ⇒ no hairpin cables (plan.md § ONE STRETCHED DOMAIN).
H5 = `7220 IXR-H5-64O-512` (owner Q2 A).  Switch labels = short `role` + `fabric` (Q14 A, no marker labels).

Port plan (plain ports, no breakouts):
  ns-spine-N   e1-1 border-leaf-1, e1-2 border-leaf-2, e1-3/4 svc-leaf-1/2, e1-5..10 leaf-3..8
  fe leaves    e1-31 -> ns-spine-1, e1-32 -> ns-spine-2; host ports e1-1.. (svc-leaf e1-1 fw-1, e1-2 shared-service;
               leaf-3/4 e1-1 storage-1; leaf-5/6 e1-1 storage-2; leaf-7/8 e1-1..4 gpu-server-1..4)
  border-leaf  e1-1/2 -> ns-spine-1/2, e1-3 -> border-router-1, e1-4 -> border-router-2, e1-5 DCI
  border-rtr   e1-1 -> border-leaf-1, e1-2 -> border-leaf-2, e1-3 -> other BR, e1-4 -> internet
  ew-spine-N   e1-R -> rail-leaf-R
  rail-leaf-R  e1-61..64 -> ew-spine-1..4; e1-S -> GPU R of gpu-server-S (storage NOT on the rails: owner 2026-11-02, reverses Q7 A)
  dc2-bl-N     e1-5 DCI, e1-6 dc2 ISL, e1-7 shared-service-2 (since 2026-11-16; e1-7/e1-8 were dc2-host-1/-2)
Spine / connector side = LOCAL endpoint of every ISL (aifabrics stripe connector must own the local side).
DCI links: local = DC1 border leaf => Fabric frontend (fabricSelectors site=dc2) owns them.

Hosts (network-multitool, Q14 A): dual-homed = one link with two `local` endpoints => ESI-LAG lag-<link>-local.
  Interface labels (owner 2026-11-16 label tidy-up: `frontend=`/`backend=` = which tenant/VPC a host port serves):
  frontend LAGs `host=<h>, frontend=<tenant1|tenant2|storage|shared-service|tenant-trunk>, upgrade-isolate=true`;
  rail NICs `role=gpu, host=<server>, rail=<r>, backend=tenant1|tenant2` (no backend = free GPU: parked port,
  Backend free pool). Removed 2026-11-16 (nothing selected them): role=host|internet|edge, site on hosts, rail on TopoNodes.
GPU servers (owner 2026-11-02: "rename them as GPU Server 1 ..." + "multitenancy at GPU/NIC level similar to aifabric
  ... use labels"): object name gpu-server-N (k8s names: lowercase, no spaces; "GPU Server N" = display name).
  8 GPUs per server, GPU G = NIC ethG = rail G; tenant PER GPU = the `tenant` label of its rail Interface
  (rail-leaf-G-ethernet-1-S). Inside the server sim each GPU = its own network namespace gpuG (the GPU's VM: rail NIC
  + a frontend leg on its tenant's VLAN, hosts.sh). Frontend bond (eth9/10 -> leaf-7/8) = trunk of ALL tenant VLANs:
  LAG label `frontend=tenant-trunk` (every tenant VLAN selects it), the host decides which GPU sits on which VLAN.
NetworkTopology is one-shot (delete + re-create to change).
"""
import pathlib

NS = "neocloud"
NODE_PROFILE = "srlinux-ghcr-26.7.1"       # all 28 switches = the namespace's bootstrap-seeded copy, licence set by deploy.sh phase ns
H5, D5, X1B = "7220 IXR-H5-64O-512", "7220 IXR-D5", "7250 IXR-X1B"
HOST_IMAGE = "ghcr.io/srl-labs/network-multitool"
FRR_IMAGE = "quay.io/frrouting/frr:10.7.1"   # internet host: real routing stack, zebra installs BGP routes (gobgpd + static
                                              # ECMP lost 17-21 s per BR upgrade, measured 2026-11-09)

NS_SPINES = ["ns-spine-1", "ns-spine-2"]
BORDER_LEAVES = ["border-leaf-1", "border-leaf-2"]
SVC_LEAVES = ["svc-leaf-1", "svc-leaf-2"]
FE_LEAVES = [f"leaf-{i}" for i in range(3, 9)]
BRS = ["border-router-1", "border-router-2"]
EW_SPINES = [f"ew-spine-{i}" for i in range(1, 5)]
RAIL_LEAVES = [f"rail-leaf-{i}" for i in range(1, 9)]
DC2_BL = ["dc2-border-leaf-1", "dc2-border-leaf-2"]

# frontend hosts: name -> (leaf pair, leaf port, subnet or None, first NIC)
# frontend label = the VLAN the host's ESI-LAG joins (manifests/vpcs.yaml): tenant1 | tenant2 = tenant VPCs;
# storage | shared-service = the two subnets of the shared-services VPC (ONE ip-vrf); tenant-trunk = every tenant VLAN;
# internet = fw-1's public subnet in VRF internet (2026-11-16).
# owner 2026-11-12: compute-1..3 + storage-3 REMOVED, storage = generic shared resource (not per tenant), storage-1 on
# leaf-3/4, storage-2 on leaf-5/6, NEW shared-service host on the service leaves next to fw-1 (fw-1 unchanged, tenant1)
FE_HOSTS = {
    "fw-1":           (SVC_LEAVES, 1, "internet", 1),   # firewall in the internet network (owner 2026-11-16 Q2 A)
    "shared-service": (SVC_LEAVES, 2, "shared-service", 1),
    "storage-1":      (["leaf-3", "leaf-4"], 1, "storage", 1),
    "storage-2":      (["leaf-5", "leaf-6"], 1, "storage", 1),
    # GPU servers: eth1..8 = rail NICs, eth9+eth10 = frontend bond = trunk of every tenant VLAN ("all")
    **{f"gpu-server-{s}": (["leaf-7", "leaf-8"], s, "tenant-trunk", 9) for s in range(1, 5)},
    # DC2 = ONE host, in the shared frontend network (owner 2026-11-16 Q1 A; replaced dc2-host-1 tenant1 + dc2-host-2 tenant2)
    "shared-service-2": (DC2_BL, 7, "shared-service", 1),
}
# baseline booking per GPU (GPU 1..8 = rail 1..8; 1 | 2 = tenant1 | tenant2, - = free; a | b until 2026-11-16). tenant2 is NOT in the baseline (owner
# 2026-11-12: the demo onboards it live, GUI or Terraform, tenant-onboarding/) ⇒ tenant1 12, free 20
# (was 2026-11-02 → 11-12: "aaaaaaaa", "aaaabbbb", "bbbbbb--", "bb------" = tenant1 12, tenant2 12, free 8)
BASELINE = {1: "11111111", 2: "1111----", 3: "--------", 4: "--------"}
# backend rail NICs: server -> [(rail, leaf port, host NIC, tenant or None)]
RAIL_HOSTS = {f"gpu-server-{s}": [(r, s, r, None if t == "-" else t) for r, t in enumerate(BASELINE[s], 1)]
              for s in range(1, 5)}
# storage hosts have NO rail NICs (owner 2026-11-02: "there was a mistake, please remove the connection between storage
# nodes and the gpu backend" — reverses Q7 A); storage = frontend only (bond to its leaf pair)


def flow(d):
    parts = []
    for k, v in d.items():
        if isinstance(v, dict):
            v = flow(v)
        elif isinstance(v, str) and (v.isdigit() or " " in v or v == "" or v in ("true", "false")):
            v = f'"{v}"'
        parts.append(f"{k}: {v}")
    return "{ " + ", ".join(parts) + " }"


def ep(node, port):
    return f"{{ node: {node}, interface: ethernet-1-{port} }}"


def upgrade_group(n):
    """owner 2026-11-09 R5-Q2 A: tranche a = rails 1-4 + every odd switch of frontend/edge/dc2/E-W spines, b = rest
    ⇒ one of every redundant pair per tranche; GPU G (single-homed on rail G) is offline while its rail upgrades"""
    num = int(n.rsplit("-", 1)[1])
    if n.startswith("rail-leaf-"):
        return "a" if num <= 4 else "b"
    return "a" if num % 2 else "b"


def main():
    out = []
    w = out.append
    w("# GENERATED by topology/gen-topology.py — edit the generator, not this file.")
    w("# neocloud CSP DC lab: 28 SR Linux 26.7.1 switches (frontend Fabric, GPU Backend, 2 ASBRs, DC2),")
    w("# 11 hosts (network-multitool + the FRR internet router). One-shot NetworkTopology.")
    w("apiVersion: topologies.eda.nokia.com/v1")
    w("kind: NetworkTopology")
    w("metadata:")
    w("  name: neocloud")
    w(f"  namespace: {NS}")
    w("spec:")
    w("  operation: Create")
    w("  nodeTemplates:")
    for name, platform, labels in [
        ("ns-spine", H5, {"role": "spine", "fabric": "frontend"}),
        ("fe-leaf-h5", H5, {"role": "leaf", "fabric": "frontend"}),
        ("fe-leaf-d5", D5, {"role": "leaf", "fabric": "frontend"}),
        ("fe-border-leaf", X1B, {"role": "borderleaf", "fabric": "frontend"}),
        ("border-router", X1B, {"role": "border-router"}),
        ("ew-spine", H5, {"role": "spine", "fabric": "backend"}),
        ("rail-leaf", H5, {"role": "leaf", "fabric": "backend"}),
        ("dc2-border-leaf", X1B, {"role": "borderleaf", "fabric": "dc2"}),
    ]:
        # eda.nokia.com/role = long-form copy of role: the NetBox app (device role) and the GUI topology tiers read it
        # neocloud-upgrade = scope of PipelineDefinition neocloud-upgrade-pipeline (upgrade/, owner 2026-11-09 Q5)
        labels = {**labels, "eda.nokia.com/role": labels["role"], "eda.nokia.com/security-profile": "managed",
                  "neocloud-upgrade": "true"}
        w(f"    - name: {name}")
        w(f"      nodeProfile: {NODE_PROFILE}")
        w(f"      platform: {platform}")
        w(f"      labels: {flow(labels)}")
    w("  nodes:")
    for n in NS_SPINES:
        w(f"    - {{ name: {n}, template: ns-spine, labels: {{ upgrade-group: {upgrade_group(n)} }} }}")
    for n in BORDER_LEAVES:
        w(f"    - {{ name: {n}, template: fe-border-leaf, labels: {{ upgrade-group: {upgrade_group(n)} }} }}")
    for n in SVC_LEAVES:
        w(f"    - {{ name: {n}, template: fe-leaf-d5, labels: {{ upgrade-group: {upgrade_group(n)} }} }}")
    for n in FE_LEAVES:
        w(f"    - {{ name: {n}, template: fe-leaf-h5, labels: {{ upgrade-group: {upgrade_group(n)} }} }}")
    for n in BRS:
        w(f"    - {{ name: {n}, template: border-router, labels: {{ upgrade-group: {upgrade_group(n)} }} }}")
    for n in EW_SPINES:
        w(f"    - {{ name: {n}, template: ew-spine, labels: {{ upgrade-group: {upgrade_group(n)} }} }}")
    for n in RAIL_LEAVES:
        w(f"    - {{ name: {n}, template: rail-leaf, labels: {{ upgrade-group: {upgrade_group(n)} }} }}")
    for n in DC2_BL:
        w(f"    - {{ name: {n}, template: dc2-border-leaf, labels: {{ upgrade-group: {upgrade_group(n)} }} }}")

    w("  linkTemplates:")
    w("    - { name: isl-frontend, type: InterSwitch, labels: { role: interSwitch, fabric: frontend } }")
    w("    - { name: isl-backend, type: InterSwitch, labels: { role: interSwitch, fabric: backend } }")
    w("    - { name: isl-dc2, type: InterSwitch, labels: { role: interSwitch, fabric: dc2 } }")
    w("    - { name: dci, type: InterSwitch, labels: { role: interSwitch, fabric: dci } }")
    w("    # BR links = routed links of VRF edge, VirtualNetwork internet (no Fabric): tagged, so the border leaves can put them in VRF internet")
    w("    - { name: edge, type: InterSwitch, encapType: Dot1q }")
    w("    - { name: host, type: Edge, encapType: Dot1q }")

    w("  links:")
    topo_map, sims = [], []

    def isl(tmpl, a, ap, b, bp):
        w(f"    - {{ name: {a}-e{ap}-{b}-e{bp}, template: {tmpl}, endpoints: "
          f"[ {{ local: {ep(a, ap)}, remote: {ep(b, bp)} }} ] }}")

    w("    # frontend ISLs (spine = local)")
    fe_down = BORDER_LEAVES + SVC_LEAVES + FE_LEAVES
    for si, sp in enumerate(NS_SPINES):
        for k, leaf in enumerate(fe_down, 1):
            isl("isl-frontend", sp, k, leaf, (1 + si) if leaf in BORDER_LEAVES else 31 + si)
    w("    # backend ISLs (E/W spine = local, the stripe connector)")
    for si, sp in enumerate(EW_SPINES):
        for r, leaf in enumerate(RAIL_LEAVES, 1):
            isl("isl-backend", sp, r, leaf, 61 + si)
    w("    # DC2 + DCI (DCI local = DC1 border leaf)")
    isl("isl-dc2", DC2_BL[0], 6, DC2_BL[1], 6)
    for a, b in zip(BORDER_LEAVES, DC2_BL):
        isl("dci", a, 5, b, 5)
    w("    # edge: BR -> border leaves, BR1 <-> BR2 (BR = local)")
    for bi, br in enumerate(BRS):
        for li, bl in enumerate(BORDER_LEAVES):
            isl("edge", br, 1 + li, bl, 3 + bi)
    isl("edge", BRS[0], 3, BRS[1], 3)
    w("    # internet uplinks (internet host eth1 -> BR1, eth2 -> BR2)")
    for bi, br in enumerate(BRS, 1):
        w(f"    - {{ name: internet-{br}, template: host, endpoints: "
          f"[ {{ local: {ep(br, 4)} }} ] }}")
        topo_map.append((br, "ethernet-1-4", "internet", f"eth{bi}"))
    sims.append("internet")

    w("    # frontend hosts: all-active ESI-LAG (two local endpoints)")
    for h, (pair, port, subnet, nic) in FE_HOSTS.items():
        labels = {"host": h, **({"frontend": subnet} if subnet else {}),
                  # opt-in: the upgrade pipeline moves this dual-homed server to the partner leaf before a swap
                  "upgrade-isolate": "true"}
        w(f"    - {{ name: {h}, template: host, labels: {flow(labels)}, endpoints: "
          f"[ {{ local: {ep(pair[0], port)} }}, {{ local: {ep(pair[1], port)} }} ] }}")
        topo_map.append((pair[0], f"ethernet-1-{port}", h, f"eth{nic}"))
        topo_map.append((pair[1], f"ethernet-1-{port}", h, f"eth{nic + 1}"))
        sims.append(h)
    w("    # backend rail NICs (single-homed): one per GPU, GPU G = rail G; tenant label = baseline booking")
    for h, nics in RAIL_HOSTS.items():
        for rail, port, nic, tenant in nics:
            labels = {"role": "gpu", "host": h, "rail": str(rail), **({"backend": f"tenant{tenant}"} if tenant else {})}
            w(f"    - {{ name: {h}-gpu{rail}, template: host, labels: {flow(labels)}, endpoints: "
              f"[ {{ local: {ep(f'rail-leaf-{rail}', port)} }} ] }}")
            topo_map.append((f"rail-leaf-{rail}", f"ethernet-1-{port}", h, f"eth{nic}"))

    w("  simulation:")
    w("    simNodeTemplates:")
    w(f"      - {{ name: host, type: Linux, image: {HOST_IMAGE} }}")
    w(f"      - {{ name: frr, type: Linux, image: {FRR_IMAGE} }}   # internet router (the PE-CE router left 2026-11-12, owner Q9 B)")
    w("    simNodes:")
    for s in sims:
        w(f"      - {{ name: {s}, template: {'frr' if s == 'internet' else 'host'} }}")
    w("    # explicit sim wiring (never mix with wildcards)")
    w("    topologies:")
    for node, ifname, sim, eth in topo_map:
        w(f"      - {{ node: {node}, interface: {ifname}, simNode: {sim}, simNodeInterface: {eth} }}")

    dst = pathlib.Path(__file__).with_name("neocloud-topo.yaml")
    dst.write_text("\n".join(out) + "\n")
    print(f"wrote {dst} ({len(out)} lines, {len(sims)} hosts, {len(topo_map)} host NICs)")


if __name__ == "__main__":
    main()
