#!/usr/bin/env python3
"""neocloud_ops.py - the "NeoCloud Operations" dashboard in the EDA GUI (Dashboards page) for the neocloud lab.

Owner decision 2026-11-16 (Q1 A EDA GUI dashboard, Q2 A one operator view, Q3 A sections capacity + GPU backend +
tenant isolation + operations, Q4 A start/stop traffic job = traffic/neocloud-traffic.py). Audience: a GPU neocloud.

The dashboard is a JSON file in EDA user storage, the same file the Dashboard Designer saves (shared copy, every
user: /core/user-storage/v2/shared/file?path=designs/neocloud-ops.json). Every tile is an EQL query that EDA runs
live while the page is open. Recipe + tile semantics: skill eda-lab "EDA GUI DASHBOARDS"; sibling generator
scenarios/microseg/dashboards/dc_health.py (DC Health, same machinery).

  neocloud_ops.py build      write neocloud-ops.json next to this script (deterministic)
  neocloud_ops.py test       run every tile's query against the live EDA, print what it would show
  neocloud_ops.py publish    build + upload as a shared dashboard (idempotent, replaces it)
  neocloud_ops.py status     show whether it is published
  neocloud_ops.py remove     delete the shared dashboard

Env: EDA_URL (default: the connection ./deploy.sh saved in .state/), KC_MASTER_USER / KC_MASTER_PASSWORD (Keycloak master admin,
default admin/admin), EDA_ADMIN_USER / EDA_ADMIN_PASSWORD (default admin/admin), SANDBOXJS=<dir>/package lets `test`
run the tiles' JS transformers the way the GUI does:
  curl -sfL https://registry.npmjs.org/@nyariv/sandboxjs/-/sandboxjs-0.9.7.tgz | tar xz -C <dir>

What a dashboard tile CANNOT show (measured 2026-11-16, Kind 26.8.2): transactions and merge requests are not EDB
tables (every EQL path tried returns []), and EQL cannot filter on a CR label (`where (metadata.labels.x = ...)` = 0
rows) ⇒ GPU/tenant tiles read the labels and count them in a transformer.
"""
import json, os, ssl, subprocess, sys, urllib.error, urllib.parse, urllib.request, uuid
from email.utils import formatdate
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
import eda_auth   # noqa: E402  (lib/eda_auth.py: saved connection + Keycloak login)

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "neocloud-ops.json")
STORE_PATH = "designs/neocloud-ops.json"
NAME = "NeoCloud Operations"
NS = "neocloud"
NS_UUID = uuid.UUID("5d1c1a57-8e0c-4d9e-9a3e-0e0c10d00001")   # fixed => stable uuids per title

GOOD, BAD, IDLE, INFO = "#3bb34a", "#c71e1e", "#9aa5b1", "#005aff"
T1, T2, FREE = "#2563eb", "#ea580c", "#cbd5e1"                 # = Grafana topology tenant colours
SEV = [("Critical", "critical", "#c71e1e"), ("Major", "major", "#fc7319"),
       ("Minor", "minor", "#ffac0a"), ("Warning", "warning", "#ffe12b")]
TENANTS = [("tenant1", T1), ("tenant2", T2)]
SERVERS = [f"gpu-server-{s}" for s in range(1, 5)]
RAILS = [f"rail-leaf-{r}" for r in range(1, 9)]
SPINES = [f"ew-spine-{s}" for s in range(1, 5)]


def uid(*parts):
    return str(uuid.uuid5(NS_UUID, "/".join(parts)))


def child(label, color, field, criteria=None, value=None):
    c = {"label": label, "color": color, "field": field, "type": "string"}
    if criteria:
        c.update(criteria=criteria, value=value)
    return c


def api(eql, transformer=None):
    a = {"api": eql, "queryType": "eql", "requestType": "get"}
    if transformer:
        a["dataTransformer"] = transformer
    return a


def count(title, subtitle, eql, children, transformer=None, w=300, h=200):
    return {"id": "dashletCount", "uuid": uid("count", title), "name": "", "type": "dashletCount",
            "title": title, "subtitle": subtitle, "width": w, "height": h,
            "componentConfiguration": {"apiConfiguration": api(eql, transformer),
                                       "additionalConfiguration": {"children": children}},
            "parentFlexType": "row", "fillWidth": False, "showTotal": False,
            "totalLast": False, "verticalList": False, "showPercentage": False}


def up_down(title, subtitle, eql, field, good, good_label, bad_label, transformer=None):
    """Two boxes, good (green) and bad (red), no total (a third box wraps out of a 300-wide tile)."""
    return count(title, subtitle, eql,
                 [child(good_label, GOOD, field, "equal", good), child(bad_label, BAD, field, "not_equal", good)],
                 transformer)


def ring(title, eql, slices, key, transformer=None, show_total=True, hide_title=False):
    return {"apiConfiguration": api(eql, transformer),
            "additionalConfiguration": {"title": title, "donutId": uid("donutchart", *key),
                                        "hideTitle": hide_title, "showTotal": show_total, "children": slices,
                                        "thickness": 2, "animation": True, "sliceLabels": 0, "legendStyle": 2}}


def donuts(title, subtitle, rings, w=400, h=300, fill=False):
    return {"id": "dashletDonutChart", "uuid": uid("donut", title), "name": "", "type": "dashletDonutChart",
            "title": title, "subtitle": subtitle, "width": w, "height": h, "parentFlexType": "row",
            "fillWidth": fill, "componentConfigurations": rings}


def line(title, subtitle, eql, transformer=None, unit="bps", w=600, h=350):
    return {"id": "dashletLineChart", "uuid": uid("line", title), "name": "", "type": "dashletLineChart",
            "title": title, "subtitle": subtitle, "width": w, "height": h, "parentFlexType": "row",
            "fillWidth": True,
            "componentConfiguration": {"apiConfiguration": api(eql, transformer),
                                       "additionalConfiguration": {"maxDataPoints": "150", "yAxisUnits": unit,
                                                                   "scalingFunction": "metricPrefix"}}}


def table(title, subtitle, eql, w=700, h=350):
    return {"id": "dashletDataView", "uuid": uid("table", title), "name": "", "type": "dashletDataView",
            "title": title, "subtitle": subtitle, "width": w, "height": h, "parentFlexType": "row",
            "fillWidth": True, "showStatusBar": True, "showFilters": True,
            "componentConfiguration": {"apiConfiguration": api(eql)}}


def row(name, *dashlets):
    return {"uuid": uid("row", name), "name": "", "type": "flexRow", "flexDirection": "row",
            "components": list(dashlets)}


CR = ".namespace.resources.cr."
SRL = ".namespace.node.srl."
IN_NS = f'.namespace.name = "{NS}"'


def any_of(field, values):
    return "(" + " or ".join(f'{field} = "{v}"' for v in values) + ")"


NODE = ".namespace.node.name"
IFNAME = ".namespace.node.srl.interface.name"
GPU_PORTS = any_of(IFNAME, [f"ethernet-1/{s}" for s in range(1, 5)])      # rail-leaf-G e1-S = GPU G of server S
SPINE_PORTS = any_of(IFNAME, [f"ethernet-1/{r}" for r in range(1, 9)])    # ew-spine e1-R = rail-leaf-R

# ---- transformers (JS bodies over `data`, SandboxJS in the GUI; must return NEW objects) ----------------------
IFACES = CR + f'interfaces_eda_nokia_com.v1.interface fields [ metadata.labels as "L", status.operationalState as "State" ] where ({IN_NS})'
# GPU = Interface label role=gpu; tenant = label backend (none = free GPU).
# GOTCHA SandboxJS 0.9.7 (the GUI's JS engine, measured 2026-11-16): `a && a.b` does NOT short-circuit (throws on a
# row without labels) ⇒ always `(r.L || {}).x`.
GPU_TENANT = "return data.filter(r => (r.L || {}).role === 'gpu').map(r => ({ Tenant: r.L.backend || 'free' }));"
GPU_CAPACITY = """const g = data.filter(r => (r.L || {}).role === 'gpu');
const free = g.filter(r => !r.L.backend).length;
return [{ Free: free, Booked: g.length - free }];"""


def gpu_on(server):
    return (f"return data.filter(r => (r.L || {{}}).role === 'gpu' && (r.L || {{}}).host === '{server}')"
            ".map(r => ({ Tenant: r.L.backend || 'free' }));")


GPU_LINKS = "return data.filter(r => (r.L || {}).role === 'gpu').map(r => ({ State: r.State }));"
BACKEND_SWITCHES = "return data.filter(r => (r.L || {}).fabric === 'backend').map(r => ({ State: r.State }));"
BACKEND_ISLS = "return data.filter(r => (r.name || '').startsWith('isl-ew-spine-')).map(r => ({ State: r.State }));"
TENANT_VPCS = "return data.filter(r => r.name !== 'internet' && r.name !== 'shared-services').map(r => ({ State: r.State }));"


def pivot(prefix, label):
    """Grouped rows {Key, In, Out} -> ONE row {<label> N: In + Out}: one line per rail/spine (series = keys of the
    first transformed row). Sorted so the colours stay put."""
    return (f"const o = {{}};\n"
            f"[...data].sort((a, b) => a.Key.localeCompare(b.Key, undefined, {{ numeric: true }}))"
            f".forEach(r => {{ o[r.Key.replace('{prefix}', '{label} ')] = (Number(r.In) || 0) + (Number(r.Out) || 0); }});\n"
            f"return [o];")


TENANT_SLICES = [child(t, c, "Tenant", "equal", t) for t, c in TENANTS] + [child("free", FREE, "Tenant", "equal", "free")]


def dashboard():
    capacity = row("capacity",
        donuts("GPU allocation", "All GPUs: booked per tenant, free = sellable now (live Interface labels)",
               [ring("GPU allocation", IFACES, TENANT_SLICES, ("all",), GPU_TENANT, hide_title=True)], w=400, h=300),
        count("Sellable GPU capacity", "Free GPUs can be booked by a new or existing tenant",
              IFACES, [child("Free GPUs", GOOD, "Free"), child("Booked GPUs", INFO, "Booked")], GPU_CAPACITY,
              w=300, h=200),
        donuts("GPUs per GPU server", "8 GPUs each; GPU G = NIC ethG = rail G",
               [ring(s.replace("gpu-server-", "GPU Server "), IFACES, TENANT_SLICES, (s,), gpu_on(s))
                for s in SERVERS], w=1000, h=300, fill=True),
    )
    tenants = row("tenants",
        up_down("Tenant VPCs", "One VirtualNetwork per tenant (DC1)",
                CR + f'services_eda_nokia_com.v2.virtualnetwork fields [ name, status.operationalState as "State" ] where ({IN_NS})',
                "State", "Up", "Up", "Down", TENANT_VPCS),
        table("Tenants", "Per tenant VPC: switches it spans, attached ports, BGP sessions, anything down",
              CR + 'services_eda_nokia_com.v2.virtualnetwork fields [ name as "Tenant VPC", status.operationalState as "State",'
                   ' status.numNodes as "Switches", status.numSubinterfaces as "Ports", status.numSubinterfacesOperDown as "Ports down",'
                   ' status.numBGPPeers as "BGP sessions", status.numBGPPeersOperDown as "BGP down" ]'
                   f' where ({IN_NS})', w=900, h=300),
    )
    backend_health = row("backend-health",
        up_down("GPU backend fabric", "Backend gpu-backend (EVPN, RoCEv2 QoS)",
                CR + f'aifabrics_eda_nokia_com.v1.backend fields [ status.operationalState as "State" ] where ({IN_NS})',
                "State", "Up", "Up", "Down"),
        up_down("Backend switches", "8 rail leaves + 4 E/W spines connected and in sync",
                CR + f'core_eda_nokia_com.v1.toponode fields [ metadata.labels as "L", status.node-state as "State" ] where ({IN_NS})',
                "State", "Synced", "Synced", "Not synced", BACKEND_SWITCHES),
        up_down("Backend links", "Rail leaf <-> E/W spine (32 links, 800G)",
                CR + f'fabrics_eda_nokia_com.v1.isl fields [ name, status.operationalState as "State" ] where ({IN_NS})',
                "State", "Up", "Up", "Down", BACKEND_ISLS),
        up_down("Backend BGP sessions", "eBGP underlay + EVPN between rail leaves and spines",
                CR + 'protocols_eda_nokia_com.v2.defaultbgppeer fields [ status.sessionState as "Session" ]'
                     f' where ({IN_NS} and spec.group = "bgpgroup-ebgp-gpu-backend-spine")',
                "Session", "Established", "Established", "Down"),
        up_down("GPU NIC links", "Every GPU's rail NIC (booked and free)", IFACES, "State", "Up", "Up", "Down", GPU_LINKS),
    )
    backend_traffic = row("backend-traffic",
        line("GPU traffic per rail", "GPU ports of each rail leaf, both directions; draws while this page is open",
             SRL + f'interface.traffic-rate fields [ {NODE} as "Key", sum(in-bps) as "In", sum(out-bps) as "Out" ]'
                   f' where ({IN_NS} and {any_of(NODE, RAILS)} and {GPU_PORTS}) sample milliseconds 2000',
             pivot("rail-leaf-", "Rail")),
        line("E/W spine load (ECMP spread)", "Rail-facing ports of each E/W spine, both directions: even lines = "
             "traffic spread evenly over the 4 spines",
             SRL + f'interface.traffic-rate fields [ {NODE} as "Key", sum(in-bps) as "In", sum(out-bps) as "Out" ]'
                   f' where ({IN_NS} and {any_of(NODE, SPINES)} and {SPINE_PORTS}) sample milliseconds 2000',
             pivot("ew-spine-", "Spine")),
    )
    backend_errors = row("backend-errors",
        table("GPU backend errors and discards", "Rail leaves + E/W spines, ports with any non-zero counter since boot",
              SRL + f'interface.statistics fields [ {NODE} as "Switch", {IFNAME} as "Port", in-discarded-packets as "In discards",'
                    ' out-discarded-packets as "Out discards", in-error-packets as "In errors",'
                    ' out-error-packets as "Out errors", in-fcs-error-packets as "FCS errors" ]'
                    f' where ({IN_NS} and {any_of(NODE, RAILS + SPINES)} and {IFNAME} != "mgmt0" and (in-discarded-packets > 0'
                    ' or out-discarded-packets > 0 or in-error-packets > 0 or out-error-packets > 0'
                    ' or in-fcs-error-packets > 0)) order by [ in-discarded-packets descending ]', w=1000, h=300),
    )
    isolation = row("isolation",
        table("Tenant isolation: which routing table knows which subnet",
              "Frontend: per VRF, the tenant / shared / firewall subnets it holds and on how many switches. A tenant VRF holds "
              "its own subnet + shared services (+ internet for tenant1), never another tenant's",
              SRL + 'network-instance.route-table.ipv4-unicast.route fields [ .namespace.node.srl.network-instance.name as "VRF",'
                    ' ipv4-prefix as "Subnet", count(ipv4-prefix) as "Switches" ]'
                    f' where ({IN_NS} and .namespace.node.srl.network-instance.name != "mgmt"'
                    ' and .namespace.node.srl.network-instance.name != "edge" and '
                    + any_of("ipv4-prefix", ["100.100.100.0/24", "200.200.200.0/24", "10.10.10.0/24",
                                             "10.20.20.0/24", "203.0.113.128/26", "0.0.0.0/0"])
                    + ') order by [ VRF ascending ]', w=800, h=400),
        count("Configuration drift", "Switch config changed outside EDA (deviations)",
              CR + f'core_eda_nokia_com.v1.deviation fields [ spec.nodeEndpoint as "Switch" ] where ({IN_NS})',
              [child("Deviations", BAD, "Switch", "not_equal", "")], w=300, h=200),
    )
    operations = row("operations",
        donuts("Active alarms by severity", "Not cleared, not suppressed",
               [ring("Active alarms", '.namespace.alarms.v1.alarm fields [ severity ]'
                     f' where ({IN_NS} and cleared = "false" and suppressed != "true")',
                     [child(l, c, "severity", "equal", v) for l, v, c in SEV], ("alarms",), hide_title=True)],
               w=400, h=300),
        up_down("All switches in sync", "28 switches: frontend, GPU backend, border routers, DC2",
                CR + f'core_eda_nokia_com.v1.toponode fields [ status.node-state as "State" ] where ({IN_NS})',
                "State", "Synced", "Synced", "Not synced"),
        up_down("Frontend fabrics", "Fabric frontend (DC1) + Fabric dc2",
                # the Backend owns two Fabric CRs of its own (gpu-backend-leaves/-spine) ⇒ by name
                CR + f'fabrics_eda_nokia_com.v1.fabric fields [ status.operationalState as "State" ]'
                     f' where ({IN_NS} and (name = "frontend" or name = "dc2"))',
                "State", "Up", "Up", "Down"),
        table("Switch software", "Version and last boot per switch (upgrade progress shows here)",
              SRL + f'system.information fields [ {NODE} as "Switch", version as "Version", last-booted as "Last booted" ]'
                    f' where ({IN_NS}) order by [ last-booted descending ]', w=700, h=300),
    )
    screen = {"name": NAME, "uuid": uid("screen", NAME), "type": "screen", "screenType": "dashboard",
              "url": "Dashboard-0", "partOfNav": True, "startScreen": True, "showFilterBar": False,
              "queryFilters": [],
              "components": [capacity, tenants, backend_health, backend_traffic, backend_errors, isolation, operations]}
    return {"name": NAME, "displayName": NAME, "uuid": uid("dashboard", NAME), "version": "1.0.0",
            "builderVersion": "1.2.0", "showNavigationToolbar": True, "screens": [screen]}


def dashlets(d):
    def walk(c):
        if c.get("type", "").startswith("dashlet"):
            yield c
        for x in c.get("components", []):
            yield from walk(x)
    for s in d["screens"]:
        yield from walk(s)


# ---------------------------------------------------------------------------- EDA API
EDA = eda_auth.eda_url(required=False)
CTX = ssl._create_unverified_context()
KC_PATHS = ["/core/httpproxy/v1/keycloak", "/core/proxy/v1/identity"]   # Kind 26.8.2 | Talos (dc_health.py)


def http(method, url, headers=None, data=None):
    req = urllib.request.Request(url, method=method, headers=headers or {}, data=data)
    try:
        with urllib.request.urlopen(req, context=CTX, timeout=60) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


_TOKEN = None


def token():
    global _TOKEN
    if not _TOKEN:
        try:
            _TOKEN = eda_auth.admin_token(EDA)
        except RuntimeError as e:
            sys.exit(str(e))
    return _TOKEN


def call(method, path, body=None):
    h = {"Authorization": f"Bearer {token()}"}
    if body is not None:
        h["Content-Type"] = "application/json"
        body = body.encode()
    return http(method, EDA + path, h, body)


def eql(q):
    q = q.split(" sample milliseconds")[0]          # line charts stream; test = one snapshot
    st, b = call("GET", "/core/query/v1/eql?query=" + urllib.parse.quote(q))
    if st != 200:
        return None, f"HTTP {st}: {b[:300]}"
    return json.loads(b).get("data", []), None


# ---------------------------------------------------------------------------- test (mimics the GUI)
def node_bin():
    import glob
    for p in [os.environ.get("NODE", ""), "/usr/bin/node"] + glob.glob(os.path.expanduser(
            "~/.venv-playwright/lib/python3*/site-packages/playwright/driver/node")):
        if p and os.access(p, os.X_OK):
            return p
    return None


def transform(body, rows):
    sbx, node = os.environ.get("SANDBOXJS"), node_bin()
    if not (sbx and node):
        return None, "skipped (set SANDBOXJS=<unpacked @nyariv/sandboxjs> to run transformers)"
    js = ("const S=require(process.argv[1]+'/dist/cjs/Sandbox.js');const Sandbox=S.default||S;"
          "let s='';process.stdin.on('data',c=>s+=c).on('end',()=>{const i=JSON.parse(s);"
          "console.log(JSON.stringify(new Sandbox().compile(i.body)({data:i.data,isSet:()=>false}).run()))})")
    p = subprocess.run([node, "-e", js, sbx], input=json.dumps({"body": body, "data": rows}),
                       capture_output=True, text=True)
    if p.returncode:
        return None, p.stderr.strip()[:300]
    return json.loads(p.stdout), None


def get(row, path):                                  # lodash get
    cur = row
    for k in path.split("."):
        if not isinstance(cur, dict) or k not in cur:
            return None
        cur = cur[k]
    return cur


def crit(c, want, got):                              # GUI DCr()
    if isinstance(got, (dict, list)):
        got = json.dumps(got)
    if c == "equal":
        return got == want
    if c == "not_equal":
        return got != want
    try:
        if c == "greater_than":
            return float(got) > float(want)
        if c == "less_than":
            return float(got) < float(want)
    except (TypeError, ValueError):
        return False
    return False


def counters(children, rows):                        # GUI qEr(): count dashlet
    out = []
    for ch in children:
        if ch.get("criteria"):
            v = sum(1 for r in rows if crit(ch["criteria"], ch["value"], get(r, ch["field"])))
        else:
            v = rows[-1].get(ch["field"]) if rows else None       # GUI: value of the last row
        out.append(f'{ch["label"]}={v}')
    return out


def slices(children, rows):                          # GUI dDr(): donut; a slice of 0 is hidden
    out = []
    for ch in children:
        if ch.get("criteria"):
            v = sum(1 for r in rows if crit(ch["criteria"], ch["value"], get(r, ch["field"])))
        else:
            v = sum(r[ch["field"]] for r in rows if isinstance(r.get(ch["field"]), (int, float)))
        if v:
            out.append(f'{ch["label"]}={v}')
    return out or ["no data (GUI: 'No data to display')"]


def test():
    ok = True
    for d in dashlets(dashboard()):
        t = d["type"].replace("dashlet", "")
        for cc in d.get("componentConfigurations") or [d["componentConfiguration"]]:
            add = cc.get("additionalConfiguration") or {}
            name = d["title"] + (f" / {add['title']}" if len(d.get("componentConfigurations") or []) > 1 else "")
            q = cc["apiConfiguration"]["api"]
            st, b = call("POST", "/core/query/v1/parse/eql", json.dumps({"eqlString": q}))
            if st != 200:
                print(f"FAIL {t:9} {name}: EQL does not parse: HTTP {st} {b[:200]}"); ok = False; continue
            rows, err = eql(q)
            if err:
                print(f"FAIL {t:9} {name}: {err}"); ok = False; continue
            if cc["apiConfiguration"].get("dataTransformer"):
                tr, terr = transform(cc["apiConfiguration"]["dataTransformer"], rows)
                if terr:
                    print(f"     {'':9} transformer: {terr}")
                    if tr is None and not terr.startswith("skipped"):
                        ok = False
                rows = tr if tr is not None else rows
            if t == "Count":
                shown = counters(add["children"], rows)
            elif t == "DonutChart":
                shown = slices(add["children"], rows)
                if add.get("showTotal"):
                    shown.append(f"total={len(rows)}")
            elif t == "LineChart":
                shown = [f"{k}={v}" for k, v in (rows[0] if rows else {}).items()]
            else:
                cols = [k for k in (rows[0] if rows else {}) if not k.startswith(".namespace.name")]
                shown = [f"{len(rows)} rows", "cols: " + ", ".join(cols)] + \
                        ["  " + " | ".join(str(r.get(k)) for k in cols) for r in rows[:12]]
            print(f"ok   {t:9} {name}: " + ("; ".join(shown) if t != "DataView" else "\n       ".join(shown)))
            if not rows and t in ("Count", "LineChart", "DataView") and d["title"] not in (
                    "Configuration drift", "GPU backend errors and discards"):
                print(f"WARN {t:9} {name}: query returned no rows")
    return ok


# ---------------------------------------------------------------------------- publish
def build():
    d = dashboard()
    with open(OUT, "w") as f:
        json.dump(d, f, indent=2)
        f.write("\n")
    return d


def publish():
    d = build()
    d["lastChanged"] = formatdate(usegmt=True)
    path = "/core/user-storage/v2/shared/file?path=" + STORE_PATH
    body = json.dumps({"file-content": json.dumps(d)})    # the GUI's own save format
    st, b = call("PUT", path, body)                        # update; 409 = file does not exist yet
    if st == 409:
        st, b = call("POST", path, body)
    if st >= 300:
        sys.exit(f"publish failed: HTTP {st}: {b[:300]}")
    st, b = call("GET", path)
    back = json.loads(json.loads(b)["file-content"]) if st == 200 else {}
    same = back.get("screens") == d["screens"]
    print(f"published shared dashboard '{NAME}' -> {STORE_PATH}: "
          f"{sum(1 for _ in dashlets(back))} tiles, read back HTTP {st}, identical={same}")
    if not same:
        sys.exit(1)


def status():
    st, b = call("GET", "/core/user-storage/v2/shared/directory?path=designs")
    entries = json.loads(b).get("entries", []) if st == 200 else []
    hit = [e for e in entries if e.get("name") == os.path.basename(STORE_PATH)]
    print(f"shared {STORE_PATH}: " + (f"present, modified {hit[0].get('modification-time')}" if hit else
                                      f"absent (HTTP {st})"))
    return bool(hit)


def remove():
    st, b = call("DELETE", "/core/user-storage/v2/shared/file?path=" + urllib.parse.quote(STORE_PATH))
    print(f"remove {STORE_PATH}: HTTP {st} {b[:120]}")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "build"
    if cmd == "build":
        d = build(); print(f"wrote {OUT} ({sum(1 for _ in dashlets(d))} tiles)")
    elif cmd == "test":
        sys.exit(0 if test() else 1)
    elif cmd == "publish":
        publish()
    elif cmd == "status":
        status()
    elif cmd == "remove":
        remove()
    else:
        sys.exit(__doc__)
