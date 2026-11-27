#!/usr/bin/env python3
"""neocloud — background demo traffic for the "NeoCloud Operations" dashboard (owner 2026-11-16, Q4 A: start/stop job).

  python3 traffic/neocloud-traffic.py start [--rate 20M] [--pairs 4]   start every flow (stops old ones first)
  python3 traffic/neocloud-traffic.py status                           flows running per sim
  python3 traffic/neocloud-traffic.py stop                             stop every flow

Flows follow the LIVE GPU bookings (the `backend` label, via hosts.sh gpu_state), so an onboarded tenant2 gets
traffic on the next `start`:
  backend   per tenant: booked GPUs paired in order (GPU G with GPU G+1 of the same server = different rails ⇒
            rail leaf -> E/W spines -> rail leaf), iperf3 IPv6 over the rail NICs, 2 streams each (ECMP spread),
            at most --pairs pairs per tenant
  storage   each tenant's lowest booked GPU -> a storage server (frontend leg, route leaking)
  dci       shared-service-2 (DC2) -> shared-service (DC1), shared-services VPC (since 2026-11-16; was dc2-host-1 -> fw-1)
  internet  fw-1 (VRF internet) -> internet 198.51.100.1, ping 1200 B every 10 ms (the internet router has no iperf3)
Ports 5301-5399 mark this job's iperf3 processes; stop kills only those (and its own ping), never other tools
(upgrade/traffic.py, verify.sh).
"""
import argparse, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
NEB = os.path.dirname(HERE)
def _kubectl(root):
    """kubectl: env KUBECTL, else the wrapper ./deploy.sh saved in .state/, else plain kubectl"""
    st = os.path.join(root, ".state", "kubectl")
    k = os.environ.get("KUBECTL", "")
    return k if k not in ("", "kubectl") else (st if os.access(st, os.X_OK) else "kubectl")


K = _kubectl(NEB)
NS = "neocloud"
NET = {"1": "100.100.100", "2": "200.200.200"}            # tenant code -> frontend /24 (hosts.sh NET)
STORAGE = {"1": "10.10.10.11", "2": "10.10.10.12"}         # tenant code -> storage server it writes to
SIMS = [f"gpu-server-{s}" for s in range(1, 5)] + ["storage-1", "storage-2", "fw-1", "shared-service", "shared-service-2"]
PING = "ping -q -s 1200 -i 0.01 198.51.100.1"


def sh(host, cmd, check=False):
    p = subprocess.run([K, "-n", "eda-system", "exec", f"deploy/cx-{NS}--{host}-sim", "-c", host, "--",
                        "sh", "-c", cmd], capture_output=True, text=True, stdin=subprocess.DEVNULL)
    if check and p.returncode:
        sys.exit(f"{host}: {p.stderr.strip()[:200]}")
    return p.stdout


def bg(host, cmd):
    """start cmd detached inside the sim (all fds closed, or kubectl exec never returns)"""
    sh(host, f"nohup sh -c '{cmd}' </dev/null >/dev/null 2>&1 &")


def gpus():
    """[(server, gpu, tenant code, backend /64 prefix)] of booked GPUs = hosts.sh gpu_state"""
    script = (f"K={K}; NS={NS}; eval \"$(sed -n '/^gpu_state(){{/,/^}}/p' {NEB}/hosts.sh)\"; gpu_state")
    out = subprocess.run(["bash", "-c", script], capture_output=True, text=True).stdout
    rows = []
    for line in out.splitlines():
        f = line.split()
        if len(f) == 4 and f[2] != "-" and f[3] != "-":
            rows.append((f[0], int(f[1]), f[2], f[3]))
    return sorted(rows, key=lambda r: (r[2], r[0], r[1]))


def stop(quiet=False):
    for h in SIMS:
        sh(h, f"pkill -f 'iperf3 .*-p 53[0-9][0-9]'; pkill -f '{PING}'; true")
    if not quiet:
        print("stopped: every neocloud-traffic flow (iperf3 ports 53xx + internet ping)")


def start(rate, pairs):
    stop(quiet=True)
    booked = gpus()
    if not booked:
        sys.exit("no booked GPU with an EDA /64 (is the lab up? hosts.sh run?)")
    port, flows = 5301, []
    for t in sorted({b[2] for b in booked}):
        mine = [b for b in booked if b[2] == t]
        for a, z in list(zip(mine[0::2], mine[1::2]))[:pairs]:
            sh(z[0], f"ip netns exec gpu{z[1]} iperf3 -s -D -p {port}", check=True)
            bg(a[0], f"ip netns exec gpu{a[1]} iperf3 -6 -c {z[3]}::2 -p {port} -b {rate} -P 2 -t 86400")
            flows.append(f"backend tenant{t}: {a[0]}/gpu{a[1]} -> {z[0]}/gpu{z[1]} (rail {a[1]} -> rail {z[1]})")
            port += 1
        s, g = mine[0][0], mine[0][1]
        dst = STORAGE.get(t, STORAGE["1"])
        target = "storage-1" if dst == STORAGE["1"] else "storage-2"
        sh(target, f"iperf3 -s -D -p {port}", check=True)
        src_ip = f"{NET[t]}.{100 + 10 * int(s.rsplit('-', 1)[1]) + g}"
        bg(s, f"ip netns exec gpu{g} iperf3 -c {dst} -B {src_ip} -p {port} -b {rate} -t 86400")
        flows.append(f"storage tenant{t}: {s}/gpu{g} -> {target} ({dst})")
        port += 1
    sh("shared-service", f"iperf3 -s -D -p {port}", check=True)
    bg("shared-service-2", f"iperf3 -c 10.20.20.10 -p {port} -b {rate} -t 86400")
    flows.append("dci shared-services: shared-service-2 (DC2) -> shared-service (DC1)")
    bg("fw-1", PING)
    flows.append("internet: fw-1 (VRF internet) -> 198.51.100.1 (ping 1200 B / 10 ms)")
    print(f"started {len(flows)} flows at {rate} per stream:\n  " + "\n  ".join(flows))
    print("stop with: python3 traffic/neocloud-traffic.py stop")


def status():
    total = 0
    for h in SIMS:
        # by process NAME (pgrep -f would also match the sh -c that runs pgrep)
        out = [l for l in sh(h, "pgrep -a iperf3; pgrep -a ping; true").splitlines()
               if (" -p 53" in l and "iperf3" in l) or PING in l]
        cl = [l for l in out if " -c " in l or "ping" in l]
        sv = [l for l in out if "iperf3" in l and " -s " in l]
        total += len(cl)
        if cl or sv:
            print(f"  {h:13} senders {len(cl)}  receivers {len(sv)}")
    print(f"neocloud-traffic: {total} sending flow(s)" + ("" if total else " (stopped)"))


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("action", choices=["start", "stop", "status"])
    ap.add_argument("--rate", default="20M", help="iperf3 rate per stream (default 20M)")
    ap.add_argument("--pairs", type=int, default=4, help="max backend GPU pairs per tenant (default 4)")
    a = ap.parse_args()
    {"start": lambda: start(a.rate, a.pairs), "stop": stop, "status": status}[a.action]()
