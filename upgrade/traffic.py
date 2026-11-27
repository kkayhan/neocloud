#!/usr/bin/env python3
"""neocloud — traffic matrix for the fabric upgrade/downgrade (owner 2026-11-09 Q5: "minimal traffic impact").

9 flows at baseline, 11 with tenant2 onboarded (its 2 flows start only when their GPUs carry backend=tenant2, read live
at start; 2026-11-17), 10 pings/s each, chosen among paths that SHOULD work (neocloud isolates tenants on purpose, so an all-pairs
mesh would be mostly 'loss' by design). Each ping runs INSIDE the source simulator (iputils ping -D -O: timestamped
replies + "no answer yet" lines) and writes /tmp/nbup-<flow>.log there; this script only starts, reads and stops them.

  traffic.py start            start all flows (restarts any running)
  traffic.py watch [-i 1]     live table (refresh every second, owner 2026-11-17): lost so far, longest gap, last reply age (Ctrl-C leaves the pings running)
  traffic.py report [--json]  per-flow sent / lost / longest gap + every gap with its UTC time (attribute to tranches)
  traffic.py stop             report, then stop the pings

Expected during an upgrade (R5-Q2 A): frontend, DCI, shared services, internet = short blips at most (dual-homed
servers are moved to the partner leaf before each swap); GPU backend flows whose rail is in the running tranche go
DARK for that tranche (single-homed GPU NICs; real life: the scheduler drains those GPUs' jobs first).
"""
import argparse, json, re, subprocess, sys, time, datetime as dt
from concurrent.futures import ThreadPoolExecutor

import os
def _kubectl(root):
    """kubectl: env KUBECTL, else the wrapper ./deploy.sh saved in .state/, else plain kubectl"""
    st = os.path.join(root, ".state", "kubectl")
    k = os.environ.get("KUBECTL", "")
    return k if k not in ("", "kubectl") else (st if os.access(st, os.X_OK) else "kubectl")


K = _kubectl(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
# id, source sim, netns (GPU VM) or "", ping args, what it proves, upgrade tranche that takes it offline (or ""),
# [optional] GPU Interfaces that must carry backend=tenant2 (else the flow is skipped: tenant2 = onboarded by the demo only)
FLOWS = [
    # one subnet per tenant since 2026-11-12: tenant1 100.100.100.0/24 (internet), tenant2 200.200.200.0/24; shared-services
    # ip-vrf = storage 10.10.10.0/24 + shared-service 10.20.20.0/24, stretched to DC2 (shared-service-2) since 2026-11-16;
    # fw-1 = VRF internet 203.0.113.130 since 2026-11-16 ⇒ tenant frontend endpoints = the GPU VMs' frontend legs
    # (gpu-server-2: GPU 1-4 tenant1, 5-8 tenant2 when onboarded)
    ("dci-shared", "shared-service-2", "", "10.20.20.10",                   "DC2 shared-service-2 -> DC1 shared-service (L2 over the DCI)", ""),
    ("dci-storage","shared-service-2", "", "10.10.10.11",                   "DC2 shared-service-2 -> storage-1 (routed in shared-services)", ""),
    ("storage",    "storage-1",    "",     "10.10.10.12",                   "storage-1 -> storage-2 (leaf-3/4 -> 5/6, L2)", ""),
    ("shared-svc", "storage-1",    "",     "10.20.20.10",                   "storage -> shared-service (routed inside VRF shared-services)", ""),
    ("shared-t1",  "gpu-server-1", "gpu3", "10.10.10.11",                   "tenant1 GPU 3 frontend leg -> storage-1 (route leaking)", ""),
    ("shared-t2",  "gpu-server-2", "gpu5", "10.10.10.12",                   "tenant2 GPU 5 frontend leg -> storage-2 (route leaking)", "",
     ["rail-leaf-5-ethernet-1-2"]),
    # internet flows start on the tenant side: the internet router runs FRR (busybox ping, no -D/-O); same path both ways
    ("inet-fw",    "fw-1",         "",     "198.51.100.1",                  "fw-1 (VRF internet, svc-leaf) -> internet (EVPN -> BL -> BR1/BR2)", ""),
    ("inet-t1b",   "gpu-server-1", "gpu1", "192.0.2.1",                     "tenant1 GPU 1 of server 1 -> internet, second prefix", ""),
    ("gpu-fe",     "gpu-server-1", "gpu2", "203.0.113.130",                 "tenant1 GPU 2 of server 1 (leaf-7/8) -> fw-1 (VRF internet, svc-leaf)", ""),
    ("be-t1",      "gpu-server-2", "gpu1", "-6 fd00:100:201:1::2",          "backend tenant1 rail 1 -> rail 2 (E/W spines)", "a"),
    # tenant2 with 4 GPUs = GPU 5-8 of GPU Server 2 (Terraform / GUI files) ⇒ GPU 5 -> GPU 6 of the same server (was server 3
    # GPU 6 = never booked by the demo ⇒ 100 % loss, found 2026-11-17)
    ("be-t2",      "gpu-server-2", "gpu5", "-6 fd00:100:601:2::2",          "backend tenant2 rail 5 -> rail 6", "b",
     ["rail-leaf-5-ethernet-1-2", "rail-leaf-6-ethernet-1-2"]),
]
LOG = "/tmp/nbup-{}.log"
NOLOG = "__nbup_nolog__"


def tenant2_gpus():
    r = subprocess.run([K, "-n", "neocloud", "get", "interfaces.interfaces.eda.nokia.com", "-l", "role=gpu,backend=tenant2",
                        "-o", "jsonpath={.items[*].metadata.name}"], capture_output=True, text=True, timeout=60)
    return set(r.stdout.split())


def sh(host, ns, cmd, check=False):
    full = f"ip netns exec {ns} sh -c '{cmd}'" if ns else cmd
    r = subprocess.run([K, "-n", "eda-system", "exec", f"deploy/cx-neocloud--{host}-sim", "-c", host, "--", "sh", "-c", full],
                       capture_output=True, text=True, timeout=60)
    if check and r.returncode:
        sys.exit(f"{host}: {r.stderr.strip()}")
    return r.stdout


def start():
    stop_pings()
    t2, n, skipped = tenant2_gpus(), 0, []
    for fid, host, ns, args, _, _, *need in FLOWS:
        if need and not set(need[0]) <= t2:
            sh(host, ns, f"rm -f {LOG.format(fid)}"); skipped.append(fid); continue   # old log would show in report
        sh(host, ns, f"nohup ping -D -O -n -i 0.1 -W 1 {args} </dev/null >{LOG.format(fid)} 2>&1 &", check=True); n += 1
    print(f"started {n} flows at {dt.datetime.now(dt.timezone.utc):%H:%M:%S} UTC (10 pps each)"
          + (f"; skipped {', '.join(skipped)} (tenant2 not onboarded)" if skipped else ""))


def stop_pings():
    for host, ns in sorted({(f[1], f[2]) for f in FLOWS}):
        sh(host, ns, "pkill -f \"ping -D -O -n -i 0.1\" ; true")


RX = re.compile(r"^\[(\d+\.\d+)\] (?:\d+ bytes from .*icmp_seq=(\d+)|no answer yet for icmp_seq=(\d+))")


def parse(text):
    """-> dict(sent, lost, gaps=[(t_start, seconds)], last_ok_age)"""
    ok, miss = {}, {}
    for line in text.splitlines():
        m = RX.match(line)
        if not m:
            continue
        t = float(m.group(1))
        if m.group(2):
            ok.setdefault(int(m.group(2)), t)
        else:
            miss.setdefault(int(m.group(3)), t)
    seqs = sorted(set(ok) | set(miss))
    if not seqs:
        return {"sent": 0, "lost": 0, "gaps": [], "age": None}
    lost = [s for s in range(seqs[0], seqs[-1] + 1) if s not in ok]
    gaps, run = [], []
    for s in lost:
        if run and s != run[-1] + 1:
            gaps.append(run); run = []
        run.append(s)
    if run:
        gaps.append(run)
    times = {**miss, **ok}
    gap_out = [(times.get(g[0], 0.0), round(len(g) * 0.1, 1)) for g in gaps]
    return {"sent": seqs[-1] - seqs[0] + 1, "lost": len(lost), "gaps": gap_out,
            "age": round(time.time() - max(ok.values()), 1) if ok else None}


def collect():
    # all logs read IN PARALLEL (one kubectl exec per flow ≈ 0.3-0.5 s; sequential = several s ⇒ too slow for a 1 s
    # watch, owner 2026-11-17)
    with ThreadPoolExecutor(max_workers=len(FLOWS)) as ex:
        texts = list(ex.map(lambda f: sh(f[1], f[2], f"cat {LOG.format(f[0])} 2>/dev/null || echo {NOLOG}"), FLOWS))
    out = {}
    for (fid, host, ns, args, what, tr, *_), text in zip(FLOWS, texts):
        if text.strip() != NOLOG:   # skipped flow (tenant2 not onboarded) = no log = no row
            out[fid] = {**parse(text), "what": what, "offline_in": tr}
    return out


def table(res):
    hdr = f"{'flow':11} {'sent':>6} {'lost':>5} {'longest':>8}  {'now':5}  path"
    lines = [hdr]
    for fid, r in res.items():
        longest = max((g[1] for g in r["gaps"]), default=0.0)
        now = "dark" if r["age"] is None or r["age"] > 2 else "ok"
        note = f"  (offline by design in tranche {r['offline_in']})" if r["offline_in"] else ""
        lines.append(f"{fid:11} {r['sent']:>6} {r['lost']:>5} {longest:>7.1f}s  {now:5}  {r['what']}{note}")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("action", choices=["start", "watch", "report", "stop"])
    ap.add_argument("-i", type=float, default=1)
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    if a.action == "start":
        return start()
    if a.action == "watch":
        try:
            while True:
                t0 = time.time(); res = collect()
                print(f"\033[2J\033[H== neocloud upgrade traffic  {dt.datetime.now(dt.timezone.utc):%H:%M:%S} UTC "
                      f"(refresh {a.i:g} s) ==\n" + table(res), flush=True)
                time.sleep(max(0.0, a.i - (time.time() - t0)))
        except KeyboardInterrupt:
            return
    res = collect()
    if a.json:
        print(json.dumps(res))
    else:
        print(table(res))
        for fid, r in res.items():
            for t, sec in r["gaps"]:
                print(f"  gap {fid:11} {dt.datetime.fromtimestamp(t, dt.timezone.utc):%H:%M:%S} UTC  {sec:.1f} s")
    if a.action == "stop":
        stop_pings()


if __name__ == "__main__":
    sys.exit(main())
