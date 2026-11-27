#!/usr/bin/env python3
"""neocloud — build upgrade/pipeline.yaml (PipelineDefinition eda-system/neocloud-upgrade-pipeline) from Nokia's LIVE
eda-system/deployimage-pipeline. Pattern = scenarios/upgrade-pipeline/tools/build-pipeline.py (hitless upgrade demo,
Talos 2026-10-20, run 7: 83 packets lost over 6 switches), adapted to neocloud (owner 2026-11-09 Q5 + R5-Q2):

  * scope    : fires only for TopoNodes labelled neocloud-upgrade=true (all 28 neocloud switches; gen-topology.py).
  * isolate-hosts (pre-commit, after apply-drain) / restore-hosts (after post-check-bgp + remove-maintenance):
               disable/enable this batch's member ports of every multihomed LAG labelled upgrade-isolate=true
               (every dual-homed server bond; gen-topology.py link template) ⇒ servers move to the partner leaf
               before the image swap. Body = scenarios/upgrade-pipeline/host-ports.sh (shared, unchanged).
               WHY: a swapped CX sim brings its server LAGs up ≈30 s before BGP/EVPN ⇒ 30 s blackhole per leaf.
  * drain-edge (pre-commit, after apply-drain) / undrain-edge (after post-check-bgp + remove-maintenance, 2026-11-17):
               every BGP peer of VN internet in group br-to-internet / br-to-dc on this batch's border routers gets the
               export policy internet-public-drain / default-route-drain (AS path prepended 3x), removed afterwards.
               Body = upgrade/edge-peers.sh. WHY: EDA's Drain covers DefaultRouters only and the BRs route in VRF edge
               ⇒ a returning BR flapped its sessions, the internet router (graceful-restart helper) kept the stale
               routes and sent return traffic to a BR without routes: 22-29 s loss per run (2026-11-16/17).
  * CheckInterfaces pre + post WITHOUT the DiscardedPackets sub-check: on neocloud it fails sporadically on a healthy
               lab (phase 5, plan.md) ⇒ would abort a batch for nothing. Same list as verify.sh § 8.
  * NO SystemPing pre/post-checks: SystemPing pings every selected switch's system address from every other one;
               neocloud has 3 separate underlays by design (frontend+DC2, GPU backend, BRs) ⇒ cross-domain pairs never
               answer (probe 2026-11-09, 5 nodes: "PartialSuccess 2/10") ⇒ every tranche would abort. BGP + interface
               (+ IslPing, vacuous on IPv6-unnumbered) checks stay; the data plane is measured by upgrade/traffic.py.
  * post-checks strict (failure ⇒ revert batch + rollout stops); waits DRAIN 30 s / CONVERGENCE 45 s.
  * NO traffic-probe/report jobs (upgrade-pipeline pinged every server pair; neocloud has overlapping, isolated tenants
               by design) ⇒ upgrade/traffic.py measures the intended flows from outside.
Usage: python3 upgrade/build-pipeline.py   (writes upgrade/pipeline.yaml)
"""
import copy, json, os, subprocess, sys
from pathlib import Path
import yaml

def _kubectl(root):
    """kubectl: env KUBECTL, else the wrapper ./deploy.sh saved in .state/, else plain kubectl"""
    st = os.path.join(root, ".state", "kubectl")
    k = os.environ.get("KUBECTL", "")
    return k if k not in ("", "kubectl") else (st if os.access(st, os.X_OK) else "kubectl")


K = _kubectl(str(Path(__file__).resolve().parent.parent))
HERE = Path(__file__).resolve().parent
OUT = HERE / "pipeline.yaml"
CHECKS = ["EthernetCRC", "EthernetFrameSize", "EthernetPauseFrames", "CarrierTransitions", "TransceiverHealth",
          "LACPErrors", "IfPacketErrors"]          # = all minus DiscardedPackets (verify.sh § 8)
HOST_PORTS = (HERE / "host-ports.sh").read_text()   # copy of scenarios/upgrade-pipeline/host-ports.sh (2026-11-27: bundle self-contained)
EDGE_PEERS = (HERE / "edge-peers.sh").read_text()
EDGE_PEERS_FN = "edge_peers() {\n" + "\n".join(
    l for l in EDGE_PEERS.splitlines() if not l.startswith("#") and not l.startswith("set -euo")
).replace("exit 2", "return 2") + "\n}\n"
HOST_PORTS_FN = "host_ports() {\n" + "\n".join(
    l for l in HOST_PORTS.splitlines() if not l.startswith("#") and not l.startswith("set -euo")
).replace("exit 2", "return 2") + "\n}\n"


def main():
    live = json.loads(subprocess.check_output(
        [K, "-n", "eda-system", "get", "pipelinedefinition", "deployimage-pipeline", "-o", "json"]))
    spec = copy.deepcopy(live["spec"])
    spec["enabled"] = True
    spec["description"] = ("neocloud fabric OS upgrade/downgrade: Nokia's deployimage-pipeline + server isolation/restore "
                           "around the image swap, strict post-checks, no DiscardedPackets counter check.")
    timers = {"DRAIN_WAIT_FOR": "30", "WAIT_FOR_CONVERGENCE": "45"}
    for e in spec["env"]:
        if e["name"] in timers:
            e["value"] = timers.pop(e["name"])
    if timers:
        sys.exit(f"Nokia pipeline env lacks {sorted(timers)}")
    spec["env"] += [{"name": "RESTORE_SETTLE", "value": "15"},
                    {"name": "ISOLATE_SELECTOR", "value": "upgrade-isolate=true"},
                    {"name": "EDGE_VN", "value": "internet"},
                    {"name": "EDGE_DRAIN", "value": "br-to-internet=internet-public-drain br-to-dc=default-route-drain"}]
    for t in spec["triggers"]["events"]["resourceTrigger"]:
        t["labels"] = ["neocloud-upgrade=true"]

    new = []
    for j in spec["jobs"]:
        new.append(j)
        if j["name"] == "apply-drain":
            new.append({
                "name": "isolate-hosts",
                "description": "move servers to the partner leaf: disable this batch's multihomed LAG members",
                "needs": ["apply-drain"], "runsIn": "eda-toolbox",
                "env": [{"name": "NODES", "value": "${{ transaction.inputs.nodes }}"}],
                "steps": [{"id": "isolate", "name": "Disable server-facing LAG members",
                           "run": HOST_PORTS_FN + 'host_ports "$EDAPL_TRANSACTION_NAMESPACE" disable $NODES\nsleep 5'}],
            })
            new.append({
                "name": "drain-edge",
                "description": "border routers of this batch: external BGP routes AS-path prepended (VRF edge is not covered by Drain)",
                "needs": ["apply-drain"], "runsIn": "eda-toolbox",
                "env": [{"name": "NODES", "value": "${{ transaction.inputs.nodes }}"}],
                "steps": [{"id": "drain", "name": "Prepend the border routers' external BGP routes",
                           "run": EDGE_PEERS_FN + 'edge_peers "$EDAPL_TRANSACTION_NAMESPACE" drain $NODES\nsleep 10'}],
            })
    jobs = {j["name"]: j for j in new}
    for n in ("pre-check-interfaces", "post-check-interfaces"):
        jobs[n]["with"][0]["value"]["checkStateCounters"] = {"checks": list(CHECKS)}   # copy: no YAML anchors
    for n in ("pre-check-system-ping", "post-check-system-ping"):
        del jobs[n]
    jobs["apply-drain"]["needs"] = [x for x in jobs["apply-drain"]["needs"] if x != "pre-check-system-ping"]
    jobs["set-ztp"]["needs"] = ["apply-drain", "isolate-hosts", "drain-edge", "validate-deploy-env"]
    jobs["put-maintenance"]["needs"] = ["apply-drain", "isolate-hosts", "drain-edge", "set-ztp", "validate-deploy-env"]
    jobs["post-check-bgp"]["needs"] = ["wait-for-convergence"]
    jobs["restore-hosts"] = {
        "name": "restore-hosts",
        "description": "servers back onto the upgraded switch, only after BGP is proven up",
        "needs": ["remove-maintenance", "post-check-bgp", "isolate-hosts"], "runsIn": "eda-toolbox",
        "env": [{"name": "NODES", "value": "${{ transaction.inputs.nodes }}"}],
        "steps": [{"id": "restore", "name": "Enable server-facing LAG members",
                   "run": 'sleep "$RESTORE_SETTLE"\n' + HOST_PORTS_FN +
                          'host_ports "$EDAPL_TRANSACTION_NAMESPACE" enable $NODES\nsleep 10'}],
    }
    jobs["undrain-edge"] = {
        "name": "undrain-edge",
        "description": "border routers back to normal export policies, only after BGP is proven up",
        "needs": ["remove-maintenance", "post-check-bgp", "drain-edge"], "runsIn": "eda-toolbox",
        "env": [{"name": "NODES", "value": "${{ transaction.inputs.nodes }}"}],
        "steps": [{"id": "undrain", "name": "Remove the border routers' drain export policies",
                   "run": 'sleep "$RESTORE_SETTLE"\n' + EDGE_PEERS_FN +
                          'edge_peers "$EDAPL_TRANSACTION_NAMESPACE" undrain $NODES\nsleep 10'}],
    }
    jobs["post-check-interfaces"]["needs"] = ["restore-hosts", "undrain-edge"]
    jobs["post-check-isl-ping"]["needs"] = ["post-check-interfaces"]
    for n in ("post-check-bgp", "post-check-interfaces", "post-check-isl-ping"):
        jobs[n].pop("allowFailure", None)
    # maintenance mode rejects config ("can not change config in maintenance mode") ⇒ leave it right after
    # post-check-bgp, then restore the servers (upgrade-pipeline run 3)
    jobs["remove-maintenance"]["needs"] = ["put-maintenance", "post-check-bgp"]

    order = [j["name"] for j in new if j["name"] in jobs]
    for n in ("post-check-bgp", "remove-maintenance"):
        order.remove(n)
    at = order.index("post-check-interfaces")
    order[at:at] = ["post-check-bgp", "remove-maintenance", "restore-hosts", "undrain-edge"]
    spec["jobs"] = [jobs[n] for n in order]

    doc = {"apiVersion": "core.eda.nokia.com/v1", "kind": "PipelineDefinition",
           "metadata": {"name": "neocloud-upgrade-pipeline", "namespace": "eda-system",
                        "labels": {"eda.nokia.com/resourcetype": "deployimage-pipeline-definition"}},
           "spec": spec}
    yaml.add_representer(str, lambda d, v: d.represent_scalar("tag:yaml.org,2002:str", v,
                                                              style="|" if "\n" in v else None))
    OUT.write_text("# GENERATED by upgrade/build-pipeline.py from the live eda-system/deployimage-pipeline (Nokia, EDA "
                   "26.8.2). Edit the generator, not this file.\n" + yaml.dump(doc, sort_keys=False, width=200))
    print(f"wrote {OUT} ({len(order)} jobs): " + " -> ".join(order))


if __name__ == "__main__":
    sys.exit(main())
