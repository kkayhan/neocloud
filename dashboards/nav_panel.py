#!/usr/bin/env python3
"""nav_panel.py - the shared "NeoCloud" navigation panel in the EDA GUI for the neocloud lab.

Owner decisions 2026-11-16: Q1 B = a SHORT demo menu (not a copy of Main): category NeoCloud (the NeoCloud Operations
dashboard, the live Grafana topology in a new tab, Transactions, Merge Requests) + Network (Fabrics, AI Backends,
Virtual Networks, Routing Policies, Prefix Sets, Interfaces) + Operations (Alarms, Topologies); Q2 A name "NeoCloud";
Q3 A deploy phase dashboard publishes it, destroy removes it. Routing Policies + Prefix Sets added 2026-11-16 (owner
Q1 A + Q2 A; icons Policy / Ipoe = the routingpolicies Manifest's crd.ui.icon, as in the main menu). neocloud-panel.json (next to this script) is published UNCHANGED; after a GUI edit
of the panel: `pull` (live -> repo), then commit, so the next deploy keeps the edit.

Panel facts (EDA 26.8.2 GUI bundle, skill eda-lab "CUSTOM NAVIGATION PANELS"; same machinery as
scenarios/microseg/dashboards/nav_panel.py): file panels/<name>.json in shared user storage = every user can pick it
in the menu drop-down (the choice is remembered per browser); item formats copied from a GUI-saved panel.

  nav_panel.py publish    upload neocloud-panel.json unchanged (deploy phase dashboard)
  nav_panel.py test       check every menu target against the live EDA (resource kinds, dashboard file, Grafana link)
  nav_panel.py pull       save the live shared panel into neocloud-panel.json (after GUI edits)
  nav_panel.py status     present? live identical to neocloud-panel.json?
  nav_panel.py remove

Env: EDA login as in neocloud_ops.py (default: the saved connection); KUBECTL (default: the saved kubectl) for the CRD check.
"""
import json, os, subprocess, sys
sys.dont_write_bytecode = True        # no __pycache__ in the repo from importing neocloud_ops
import neocloud_ops as no

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "neocloud-panel.json")
PANEL = "NeoCloud"
STORE_PATH = f"panels/{PANEL}.json"
KUBECTL = no.eda_auth.kubectl()


def saved():
    with open(OUT) as f:
        return json.load(f)


def live():
    st, b = no.call("GET", "/core/user-storage/v2/shared/file?path=" + STORE_PATH)
    return (json.loads(json.loads(b)["file-content"]) if st == 200 else None), st


def summary(p):
    return " · ".join(f'{c["categoryName"]} ({", ".join(a.get("uiLabel", a["name"]) for a in c["apps"])})'
                      for c in p["categories"])


def test():
    ok, n = True, 0
    for c in saved()["categories"]:
        for a in c["apps"]:
            n += 1
            nav, label = a["navTarget"], f'{c["categoryName"]} / {a.get("uiLabel")}'
            if nav["edaRoute"] == "resources":
                g, v, plural = nav["targetReference"].split("/")
                p = subprocess.run(KUBECTL + ["get", "crd", f"{plural}.{g}", "-o",
                                    "jsonpath={.spec.versions[*].name}"], capture_output=True, text=True)
                good = p.returncode == 0 and v in p.stdout.split()
                print(f'{"ok  " if good else "FAIL"} {label} -> {nav["targetReference"]}'); ok &= good
            elif nav["edaRoute"] == "external":
                st, _ = no.http("GET", no.EDA + nav["targetReference"])
                print(f'{"ok  " if st == 200 else "FAIL"} {label} -> {nav["targetReference"]} (HTTP {st})'); ok &= st == 200
            elif nav["edaRoute"] == "dashboards":
                st, b = no.call("GET", "/core/user-storage/v2/shared/file?path=designs/" + nav["targetReference"]["fileName"])
                good = st == 200 and json.loads(json.loads(b)["file-content"]).get("name") == nav["targetReference"]["name"]
                print(f'{"ok  " if good else "FAIL"} {label} -> shared dashboard {nav["targetReference"]["fileName"]} '
                      f'(HTTP {st})'); ok &= good
            else:
                print(f'ok   {label} -> built-in page {nav["edaRoute"]}')
    print(f"{n} menu items: {summary(saved())}")
    return ok


def publish():
    p = saved()
    path = "/core/user-storage/v2/shared/file?path=" + STORE_PATH
    body = json.dumps({"file-content": json.dumps(p)})     # the GUI's own save format
    st, b = no.call("PUT", path, body)                      # update; 409 = file does not exist yet
    if st == 409:
        st, b = no.call("POST", path, body)
    if st >= 300:
        sys.exit(f"publish failed: HTTP {st}: {b[:300]}")
    back, st = live()
    print(f"published shared navigation panel '{PANEL}' -> {STORE_PATH}: read back HTTP {st}, identical={back == p}; "
          f"{summary(p)}")
    if back != p:
        sys.exit(1)


def pull():
    p, st = live()
    if p is None:
        sys.exit(f"no live shared panel {STORE_PATH} (HTTP {st})")
    with open(OUT, "w") as f:
        json.dump(p, f, indent=2)
        f.write("\n")
    print(f"saved live {STORE_PATH} -> {OUT}: {summary(p)}")


def status():
    p, st = live()
    if p is None:
        print(f"shared {STORE_PATH}: absent (HTTP {st})")
    else:
        print(f"shared {STORE_PATH}: present; " + ("identical to neocloud-panel.json" if p == saved() else
              "DIFFERS from neocloud-panel.json (GUI edit not saved yet: run pull)"))


def remove():
    st, b = no.call("DELETE", "/core/user-storage/v2/shared/file?path=" + STORE_PATH)
    print(f"remove {STORE_PATH}: HTTP {st} {b[:120]}")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "test":
        sys.exit(0 if test() else 1)
    elif cmd in ("publish", "pull", "status", "remove"):
        globals()[cmd]()
    else:
        sys.exit(__doc__)
