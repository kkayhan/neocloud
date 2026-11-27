#!/usr/bin/env python3
"""
Build telemetry/grafana/neocloud-topology.json: the neocloud CSP datacenter as ONE live flow panel.

Owner 2026-11-02: "build a grafana dashboard, i only want the topology svg, no need for other stuff.
similar to what we have for aifabric". House style (telemetry-stack §0): white canvas, draw.io device
icons, every link split into two directional halves (arrow + live rate pill), port dots = oper-state.
Primitives copied from eda/scenarios/aifabric/telemetry/build-dashboard.py.

What is drawn (topology/gen-topology.py = the port plan):
  edge      internet (AS 64510) -> border-router-1/2 e1-4; BR1 <-> BR2 e1-3; BR-N e1-1/2 -> border-leaf-1/2 e1-3/4
  DC1       ns-spine-N e1-1/2 border leaves, e1-3/4 svc-leaf-1/2, e1-5..10 leaf-3..8 (leaf side e1-31/32,
            border-leaf side e1-1/2)                                                   20 ISLs, rate pills
  DC2       dc2-border-leaf-1/2 (ISL e1-6), DCI border-leaf-N e1-5 <-> dc2-border-leaf-N e1-5 (MACsec Configlet)
  hosts     ESI-LAG pairs, colour only (no pills): fw-1 svc-leaf-1/2 e1-1, shared-service svc-leaf-1/2 e1-2,
            storage-1 leaf-3/4 e1-1, storage-2 leaf-5/6 e1-1, gpu-server-1..4 leaf-7/8 e1-1..4, shared-service-2 dc2-border-leaf e1-7
            (owner 2026-11-12: compute-1..3 + storage-3 removed, storage + shared-service = VRF shared-services)
  backend   rail-leaf-R e1-61..64 -> ew-spine-1..4 e1-R (32 ISLs) and rail-leaf-R e1-S -> gpu-server-S ethR (32 GPU NICs),
            colour only; per E/W spine one pill pair = sum of its 8 ISLs per direction. Drawn mirrored BELOW the
            GPU servers (frontend above the servers, backend below them).
Hosts are Linux sims without metrics => every host cable binds to the SWITCH port:
switch->host = switch :out, host->switch = switch :in, host-side dot = switch oper-state.
Host VPC colours are static (= the `frontend` labels of gen-topology.py FE_HOSTS): green shared-services, teal internet (fw-1);
blue tenant1 / orange tenant2 = GPU tiles.
GPU servers (owner 2026-11-02: "GPU Server N" + "multitenancy at GPU/NIC level similar to aifabric ... use labels"):
neutral card "GPU Server N" + 8 LIVE GPU tiles (GPU G = NIC ethG = rail G): tile fill + tenant pill = the `backend` label of
the GPU's rail Interface (Export neocloud-tenant, resource mode; tenant1 | tenant2 | free), legend = live GPU count per tenant.

Usage: python3 telemetry/build-dashboard.py            (deploy: bash deploy.sh --phase grafana)
       python3 telemetry/build-dashboard.py --check    every dataRef against live Prometheus
"""
import json
import math
import os
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT = HERE / "grafana" / "neocloud-topology.json"
ICON_SWITCH = (HERE / "icon_switch.svg").read_text()
ICON_HOST = (HERE / "icon_host.svg").read_text()
NS = "neocloud"
DS = {"type": "prometheus", "uid": "neocloud-prom"}
FONT = "Inter,Segoe UI,Helvetica,Arial,sans-serif"

# ---- canvas / palette -------------------------------------------------------
W, H = 2460, 1370
INK, MUTED = "#0f172a", "#64748b"
C_SPINE, C_LEAF, C_BL, C_BR, C_INET = "#2c3e50", "#e67e22", "#16a085", "#8e44ad", "#0e7490"
TEN = {"1": ("#dbeafe", "#2563eb"), "2": ("#ffedd5", "#ea580c"), "i": ("#cffafe", "#0e7490"), "s": ("#dcfce7", "#16a34a"), None: ("#f1f5f9", "#94a3b8")}
TNUM = {"1": 1, "2": 2}                              # live tile value: tenant number, 0 = free (no backend label)
TENANT = {0: TEN[None], 1: TEN["1"], 2: TEN["2"]}
S_SW, S_HOST = 56, 34

H5, D5, X1B = "H5-64O-512", "D5", "X1B"
# switch -> (x, y, colour, caption, label side)
SW = {
    "border-router-1":   (1050, 225, C_BR, f"ASBR · {X1B}", "left"),
    "border-router-2":   (1550, 225, C_BR, f"ASBR · {X1B}", "right"),
    "border-leaf-1":     (1050, 360, C_BL, f"border leaf · {X1B}", "right"),
    "border-leaf-2":     (1550, 360, C_BL, f"border leaf · {X1B}", "right"),
    "ns-spine-1":        (1050, 530, C_SPINE, f"N/S spine · {H5}", "left"),
    "ns-spine-2":        (1550, 530, C_SPINE, f"N/S spine · {H5}", "right"),
    "svc-leaf-1":        (540, 735, C_LEAF, D5, "left"),
    "svc-leaf-2":        (700, 735, C_LEAF, D5, "left"),
    "leaf-3":            (890, 735, C_LEAF, H5, "left"),
    "leaf-4":            (1050, 735, C_LEAF, H5, "left"),
    "leaf-5":            (1230, 735, C_LEAF, H5, "left"),
    "leaf-6":            (1390, 735, C_LEAF, H5, "left"),
    "leaf-7":            (1780, 735, C_LEAF, H5, "left"),
    "leaf-8":            (2140, 735, C_LEAF, H5, "left"),
    "dc2-border-leaf-1": (370, 365, C_BL, f"border leaf · {X1B}", "above"),
    "dc2-border-leaf-2": (370, 545, C_BL, f"border leaf · {X1B}", "below"),
}
RAIL_LEAVES = [f"rail-leaf-{r}" for r in range(1, 9)]
EW_SPINES = [f"ew-spine-{k}" for k in range(1, 5)]
Y_RL, Y_EWS = 1110, 1270
for r, n in enumerate(RAIL_LEAVES, 1):
    SW[n] = (1960 + 125 * (r - 4.5), Y_RL, C_LEAF, f"rail {r}", "below")
for k, n in enumerate(EW_SPINES, 1):
    SW[n] = (1600 + 240 * (k - 1), Y_EWS, C_SPINE, f"E/W spine · {H5}", "below")

# frontend hosts (not GPU): host -> (x, y, leaf pair, leaf port, tenant, caption)
Y_HOST = 905
HOSTS = {
    "fw-1":           (575, Y_HOST, ("svc-leaf-1", "svc-leaf-2"), 1, "i", "203.0.113.130"),   # VRF internet (2026-11-16)
    "shared-service": (665, Y_HOST, ("svc-leaf-1", "svc-leaf-2"), 2, "s", "10.20.20.10"),
    "storage-1":      (970, Y_HOST, ("leaf-3", "leaf-4"), 1, "s", "storage · 10.10.10.11"),
    "storage-2":      (1310, Y_HOST, ("leaf-5", "leaf-6"), 1, "s", "storage · 10.10.10.12"),
    # DC2 = one host in the shared frontend network (owner 2026-11-16; was dc2-host-1 tenant1 + dc2-host-2 tenant2)
    "shared-service-2": (150, 455, ("dc2-border-leaf-1", "dc2-border-leaf-2"), 7, "s", "10.20.20.11"),
}
INET = (1300, 100)
# GPU servers = cards between the frontend (leaf-7/8 above) and the backend (rail leaves below); tenant per GPU = live
GPU = {f"gpu-server-{s}": 1600 + 240 * (s - 1) for s in range(1, 5)}
CARD_W, CARD_TOP, CARD_BOT = 220, 872, 1000
TILE_W, TILE_H = 22, 62


# ---- svg primitives (aifabric build-dashboard.py) -------------------------------
def place_icon(template, uid, fill, cx, cy, size):
    """Stamp a draw.io glyph. The id must be unique per node: the icon's CSS is keyed on it."""
    icon = template
    old = re.search(r'id="(svg-image-[^"]+)"', icon).group(1)
    icon = icon.replace(old, uid)
    icon = re.sub(r"(\.st0 \{ fill: )[^;]+;", r"\g<1>%s;" % fill, icon, count=1)
    op = icon.find(">", icon.find('<svg version="1.1"'))
    head, rest = icon[: op + 1], icon[op + 1:]
    x, y = cx - size / 2, cy - size / 2
    head = re.sub(r' x="[^"]*"', f' x="{x:.1f}"', head, count=1)
    head = re.sub(r' y="[^"]*"', f' y="{y:.1f}"', head, count=1)
    head = re.sub(r' width="[^"]*"', f' width="{size:.1f}"', head, count=1)
    head = re.sub(r' height="[^"]*"', f' height="{size:.1f}"', head, count=1)
    return head + rest


def text(x, y, s, size=14, fill=INK, weight="600", anchor="middle"):
    return (f'<text x="{x:.1f}" y="{y:.1f}" font-family="{FONT}" font-size="{size}" '
            f'font-weight="{weight}" fill="{fill}" text-anchor="{anchor}">{s}</text>')


def pill_html(lx, ly, size=10, word="rate", extra=""):
    """foreignObject 'pill' centred on (lx, ly); the plugin replaces the word with the live value."""
    return ('<g transform="translate(-0.5 -0.5)"><switch><foreignObject style="overflow: visible; text-align: left;" '
            'pointer-events="none" width="100%" height="100%" requiredFeatures="http://www.w3.org/TR/SVG11/feature#Extensibility">'
            '<div xmlns="http://www.w3.org/1999/xhtml" style="display: flex; align-items: unsafe center; justify-content: unsafe center; '
            f'width: 1px; height: 1px; padding-top: {ly:.0f}px; margin-left: {lx:.0f}px;">'
            '<div style="box-sizing: border-box; font-size: 0; text-align: center;">'
            f'<div style="display: inline-block; font-size: {size}px; font-weight: 600; color: #0f172a; line-height: 1.2; '
            'pointer-events: all; background-color: #ffffff; border: 1px solid #cbd5e1; border-radius: 3px; '
            f'padding: 0px 3px; white-space: nowrap;{extra}">{word}</div></div></div></foreignObject></switch></g>')


def arrow_head(x1, y1, x2, y2, size=7):
    dx, dy = x2 - x1, y2 - y1
    L = math.hypot(dx, dy)
    if L == 0:
        return "", x2, y2
    ux, uy = dx / L, dy / L
    bx, by = x2 - ux * size, y2 - uy * size
    wx, wy = -uy, ux
    half = size * 0.55
    w1 = (bx + wx * half, by + wy * half)
    w2 = (bx - wx * half, by - wy * half)
    return (f"M {w1[0]:.1f} {w1[1]:.1f} L {x2:.1f} {y2:.1f} L {w2[0]:.1f} {w2[1]:.1f} Z", bx, by)


# ---- pill placement: slide each pill along its half until it overlaps nothing ----
PILL_W, PILL_H = 62, 21
obstacles = []      # (x0, y0, x1, y1) boxes pills must avoid (icons, labels)
placed = []         # boxes of pills already placed


def box_overlap(a, b):
    w = min(a[2], b[2]) - max(a[0], b[0])
    h = min(a[3], b[3]) - max(a[1], b[1])
    return w * h if w > 0 and h > 0 else 0.0


def place_pill(x1, y1, mx, my, pref=0.55, lo=0.2, hi=0.95, dy=0.0):
    """Pill on the half from (x1,y1) to its midpoint: lfrac 0 = at the node, 1 = at the midpoint.
    Picks the lfrac closest to `pref` with the least overlap; returns the centre."""
    best = None
    steps = 31
    for i in range(steps):
        f = lo + (hi - lo) * i / (steps - 1)
        cx, cy = x1 + (mx - x1) * f, y1 + (my - y1) * f + dy
        b = (cx - PILL_W / 2, cy - PILL_H / 2, cx + PILL_W / 2, cy + PILL_H / 2)
        score = sum(box_overlap(b, p) for p in placed) * 10 + sum(box_overlap(b, o) for o in obstacles) * 4
        score += abs(f - pref) * 40
        if best is None or score < best[0]:
            best = (score, cx, cy, b)
    placed.append(best[3])
    return best[1], best[2]


links_svg, ports_svg, pills_svg, cells = [], [], [], []

MID_ELLIPSE = ('<g id="cell-mid:{A}:{AIF}:{B}:{BIF}" data-label=""><ellipse cx="{MX:.1f}" cy="{MY:.1f}" '
               'rx="2.5" ry="2.5" fill="#94a3b8" stroke="none"/></g>')
PORT_FILL = ('<g id="cell-{A}:{AIF}:{B}:{BIF}"><ellipse cx="{X:.1f}" cy="{Y:.1f}" rx="{R}" ry="{R}" '
             'fill="#94a3b8" stroke="#475569" stroke-width="1"/></g>')


def half_link(cid, a_ref, mid_ref, x1, y1, ex, ey, arrow, width=4):
    return (f'<g id="cell-{cid}" data-source="{a_ref}" data-target="{mid_ref}">'
            f'<path d="M {x1:.1f} {y1:.1f} L {ex:.1f} {ey:.1f}" fill="none" stroke="#cbd5e1" stroke-width="{width}" '
            'stroke-linecap="round" pointer-events="stroke"/>'
            f'<path d="{arrow}" fill="#cbd5e1" stroke="#cbd5e1" stroke-width="1"/></g>')


def make_link(a, aif, b, bif, p1, p2, fwd, rev, a_oper, b_oper, pills=True, pref=0.55, pref2=None,
              width=4, port_r=5.5, asize=7):
    """1 midpoint + 2 half-segments (+ pills) + 2 port dots, both halves pointing at the midpoint."""
    (x1, y1), (x2, y2) = p1, p2
    mx, my = (x1 + x2) / 2, (y1 + y2) / 2
    mid = f"mid:{a}:{aif}:{b}:{bif}"
    links_svg.append(MID_ELLIPSE.format(A=a, AIF=aif, B=b, BIF=bif, MX=mx, MY=my))
    for (sx, sy, sa, saif, sb, sbif, pr, ref) in (
            (x1, y1, a, aif, b, bif, pref, fwd),
            (x2, y2, b, bif, a, aif, pref if pref2 is None else pref2, rev)):
        ar, ex, ey = arrow_head(sx, sy, mx, my, size=asize)
        links_svg.append(half_link(f"link_id:{sa}:{saif}:{sb}:{sbif}", f"{sa}:{saif}:{sb}:{sbif}", mid,
                                   sx, sy, ex, ey, ar, width))
        if pills:
            # the pill is its own cell on a top layer (same dataRef), so no later cable covers it
            pxy = place_pill(sx, sy, mx, my, pref=pr)
            pills_svg.append(f'<g id="cell-rate:{sa}:{saif}:{sb}:{sbif}">' + pill_html(*pxy) + "</g>")
            cells.append((f"rate:{sa}:{saif}:{sb}:{sbif}", ref, "rate"))
    ports_svg.append(PORT_FILL.format(A=a, AIF=aif, B=b, BIF=bif, X=x1, Y=y1, R=port_r))
    ports_svg.append(PORT_FILL.format(A=b, AIF=bif, B=a, BIF=aif, X=x2, Y=y2, R=port_r))
    cells.append((f"link_id:{a}:{aif}:{b}:{bif}", fwd, "traffic"))
    cells.append((f"link_id:{b}:{bif}:{a}:{aif}", rev, "traffic"))
    cells.append((f"{a}:{aif}:{b}:{bif}", a_oper, "oper"))
    cells.append((f"{b}:{bif}:{a}:{aif}", b_oper, "oper"))


def rim(n, toward, r=None):
    """Point on switch n's icon rim, in the direction of point `toward`."""
    x, y = SW[n][0], SW[n][1]
    r = r or S_SW / 2 + 3
    dx, dy = toward[0] - x, toward[1] - y
    L = math.hypot(dx, dy) or 1
    return x + dx / L * r, y + dy / L * r


def isl(a, ap, b, bp, **kw):
    """switch<->switch: both ends have metrics, each direction = that end's egress."""
    aif, bif = f"ethernet-1/{ap}", f"ethernet-1/{bp}"
    pa, pb = (SW[a][0], SW[a][1]), (SW[b][0], SW[b][1])
    make_link(a, aif, b, bif, rim(a, pb), rim(b, pa), fwd=f"{a}:{aif}:out", rev=f"{b}:{bif}:out",
              a_oper=f"oper-state:{a}:{aif}", b_oper=f"oper-state:{b}:{bif}", **kw)


def edge(sw, sp, host, hif, p2, p1=None, **kw):
    """switch<->host: the host has no metrics, so host->switch = switch INBOUND."""
    swif = f"ethernet-1/{sp}"
    make_link(sw, swif, host, hif, p1 or rim(sw, p2), p2, fwd=f"{sw}:{swif}:out", rev=f"{sw}:{swif}:in",
              a_oper=f"oper-state:{sw}:{swif}", b_oper=f"oper-state:{sw}:{swif}", **kw)


# ---- node + label boxes first, so pills keep clear of icons and labels ---------
def node_box(cx, cy, size, pad=4):
    return (cx - size / 2 - pad, cy - size / 2 - pad, cx + size / 2 + pad, cy + size / 2 + pad)


def label_box(x, y, txt, size, anchor):
    w = len(txt) * size * 0.58
    x0 = x - w / 2 if anchor == "middle" else (x - w if anchor == "end" else x)
    return (x0, y - size, x0 + w, y + 4)


def sw_label(n):
    """(x, y, anchor) of a switch's name; caption 14 px below it."""
    x, y, _c, _cap, side = SW[n]
    if side == "above":
        return x, y - S_SW / 2 - 22, "middle"
    if side == "below":
        return x, y + S_SW / 2 + 16, "middle"
    return (x - S_SW / 2 - 8, y + 1, "end") if side == "left" else (x + S_SW / 2 + 8, y + 1, "start")


for n, (x, y, _c, cap, _s) in SW.items():
    obstacles.append(node_box(x, y, S_SW))
    lx, ly_, anc = sw_label(n)
    obstacles.append(label_box(lx, ly_, n, 13, anc))
    obstacles.append(label_box(lx, ly_ + 14, cap, 9, anc))
for h, (x, y, *_r) in HOSTS.items():
    obstacles.append(node_box(x, y, S_HOST, pad=8))
obstacles.append(node_box(*INET, S_HOST, pad=8))
for g, gx in GPU.items():
    obstacles.append((gx - CARD_W / 2, CARD_TOP, gx + CARD_W / 2, CARD_BOT))

# ═══════════ edge: internet, border routers ═══════════
for bi, br in enumerate(["border-router-1", "border-router-2"], 1):
    edge(br, 4, "internet", f"eth{bi}", (INET[0] + (-10 if bi == 1 else 10), INET[1] + S_HOST / 2 + 2), pref=0.6)
isl("border-router-1", 3, "border-router-2", 3, pref=0.6)
for bi, br in enumerate(["border-router-1", "border-router-2"]):
    for li, bl in enumerate(["border-leaf-1", "border-leaf-2"]):
        isl(br, 1 + li, bl, 3 + bi, pref=0.5)

# ═══════════ DC1 frontend Fabric: spine = local, 20 ISLs ═══════════
FE_DOWN = ["border-leaf-1", "border-leaf-2", "svc-leaf-1", "svc-leaf-2"] + [f"leaf-{i}" for i in range(3, 9)]
for si, sp in enumerate(["ns-spine-1", "ns-spine-2"]):
    for k, leaf in enumerate(FE_DOWN, 1):
        bp = (1 + si) if leaf.startswith("border-leaf") else 31 + si
        isl(sp, k, leaf, bp, pref=0.62 if leaf.startswith("border") else 0.5, pref2=0.62)

# ═══════════ DC2 + DCI ═══════════
isl("dc2-border-leaf-1", 6, "dc2-border-leaf-2", 6, pref=0.6)
for a, b in (("border-leaf-1", "dc2-border-leaf-1"), ("border-leaf-2", "dc2-border-leaf-2")):
    isl(a, 5, b, 5, pref=0.4, pref2=0.6)

# ═══════════ frontend hosts: ESI-LAG pairs, colour only ═══════════
for h, (hx, hy, pair, port, ten, cap) in HOSTS.items():
    for k, leaf in enumerate(pair):
        hp = (hx + (-7 if k == 0 else 7), hy - S_HOST / 2 - 2) if not h.startswith("dc2") else \
             (hx + S_HOST / 2 + 2, hy + (-7 if k == 0 else 7))
        edge(leaf, port, h, f"eth{k + 1}", hp, pills=False, width=2.5, port_r=4, asize=6)
for s, (g, gx) in enumerate(GPU.items(), 1):
    for k, leaf in enumerate(("leaf-7", "leaf-8")):
        edge(leaf, s, g, f"eth{9 + k}", (gx + (-30 if k == 0 else 30), CARD_TOP - 2),
             pills=False, width=2.5, port_r=4, asize=6)

# ═══════════ backend: GPU NICs (rail-leaf-R e1-S -> gpu-server-S ethR) + 32 ISLs, colour only ═══════════
NIC_X = {r: (r - 4.5) * 24 for r in range(1, 9)}
for s, (g, gx) in enumerate(GPU.items(), 1):
    for r, rl in enumerate(RAIL_LEAVES, 1):
        rx = SW[rl][0] + (s - 2.5) * 9
        edge(rl, s, g, f"eth{r}", (gx + NIC_X[r], CARD_BOT + 2), p1=(rx, Y_RL - S_SW / 2 - 3),
             pills=False, width=2, port_r=3.5, asize=5)
for k, ew in enumerate(EW_SPINES, 1):
    for r, rl in enumerate(RAIL_LEAVES, 1):
        p_rl = (SW[rl][0] + (k - 2.5) * 9, Y_RL + S_SW / 2 + 3)
        p_ew = (SW[ew][0] + (r - 4.5) * 6, Y_EWS - S_SW / 2 - 3)
        make_link(ew, f"ethernet-1/{r}", rl, f"ethernet-1/{60 + k}", p_ew, p_rl,
                  fwd=f"{ew}:ethernet-1/{r}:out", rev=f"{rl}:ethernet-1/{60 + k}:out",
                  a_oper=f"oper-state:{ew}:ethernet-1/{r}", b_oper=f"oper-state:{rl}:ethernet-1/{60 + k}",
                  pills=False, width=2, port_r=3.5, asize=5)

# ═══════════ nodes ═══════════
bg, nodes, titles = [], [], []
HALO = ' stroke="#ffffff" stroke-width="5" paint-order="stroke" stroke-linejoin="round"'


def area(x0, y0, x1, y1, title):
    bg.append(f'<rect x="{x0}" y="{y0}" width="{x1 - x0}" height="{y1 - y0}" rx="14" fill="#f8fafc" '
              'stroke="#e2e8f0" stroke-width="1.5"/>')
    # title in the node layer (drawn after the cables), haloed
    titles.append(text(x0 + 16, y0 + 20, title, size=12, fill=MUTED, weight="700", anchor="start")
                  .replace("<text ", '<text stroke="#f8fafc" stroke-width="5" paint-order="stroke" ', 1))


area(830, 62, 1770, 278, "edge · border routers AS 64500 (iBGP) · internet AS 64510 · VRF internet on the border leaves")
area(470, 300, 2440, 1002, "DC1 frontend · Fabric frontend · VPCs tenant1 / tenant2 / shared-services")
area(30, 275, 455, 600, "DC2 · Fabric dc2 · stretched EVPN over DCI")
area(1440, 1022, 2440, 1355, "DC1 GPU backend · Backend gpu-backend · 8 rails · tenant per GPU = label of its NIC")

for n, (x, y, col, cap, _s) in SW.items():
    nodes.append(place_icon(ICON_SWITCH, f"svg-image-{n}", col, x, y, S_SW))
    lx, ly_, anc = sw_label(n)
    lab = text(lx, ly_, n, size=13, anchor=anc)
    sub = text(lx, ly_ + 14, cap, size=9, fill=col if col != C_SPINE else MUTED, weight="700", anchor=anc)
    if SW[n][4] in ("above", "below"):           # sits on cables: white halo
        lab, sub = (t.replace("<text ", f"<text{HALO} ", 1) for t in (lab, sub))
    nodes += [lab, sub]

nodes.append(place_icon(ICON_HOST, "svg-image-internet", C_INET, INET[0], INET[1], S_HOST))
nodes.append(text(INET[0] + S_HOST / 2 + 8, INET[1] + 1, "internet", size=13, anchor="start"))
nodes.append(text(INET[0] + S_HOST / 2 + 8, INET[1] + 15, "AS 64510 · 0/0, 198.51.100/24", size=9, fill=MUTED,
                  weight="600", anchor="start"))
for h, (hx, hy, pair, port, ten, cap) in HOSTS.items():
    nodes.append(place_icon(ICON_HOST, f"svg-image-{h}", TEN[ten][1], hx, hy, S_HOST))
    if pair[0].startswith("dc2"):
        nodes.append(text(hx, hy + S_HOST / 2 + 13, h, size=11))
        nodes.append(text(hx, hy + S_HOST / 2 + 25, cap, size=9, fill=TEN[ten][1], weight="700"))
    else:
        nodes.append(text(hx, hy + S_HOST / 2 + 14, h, size=11))
        nodes.append(text(hx, hy + S_HOST / 2 + 26, {"1": "tenant1", "2": "tenant2", "s": "shared-services", "i": "internet"}.get(ten, "no tenant"), size=9,
                          fill=TEN[ten][1], weight="700"))
        nodes.append(text(hx, hy + S_HOST / 2 + 37, cap, size=8, fill=MUTED, weight="600"))
for s, (g, gx) in enumerate(GPU.items(), 1):
    # neutral card = the physical server; one live tile per GPU (cells keyed <server>:<rail> = its NIC's Interface)
    bg.append(f'<rect x="{gx - CARD_W / 2:.1f}" y="{CARD_TOP}" width="{CARD_W}" height="{CARD_BOT - CARD_TOP}" rx="10" '
              'fill="#ffffff" stroke="#94a3b8" stroke-width="1.2"/>')
    nodes.append(place_icon(ICON_HOST, f"svg-image-{g}", "#76b900", gx - 92, CARD_TOP + 22, 24))
    nodes.append(text(gx - 76, CARD_TOP + 21, f"GPU Server {s}", size=13, anchor="start"))
    nodes.append(text(gx - 76, CARD_TOP + 35, "1 VM per GPU · NIC G → rail G", size=8.5, fill=MUTED, weight="600",
                      anchor="start"))
    for r in range(1, 9):
        tx, ty = gx + NIC_X[r], CARD_BOT - 6 - TILE_H
        bg.append(f'<g id="cell-tenant-tile:{g}:{r}"><rect x="{tx - TILE_W / 2:.1f}" y="{ty}" width="{TILE_W}" '
                  f'height="{TILE_H}" rx="4" fill="{TENANT[0][0]}" stroke="#94a3b8" stroke-width="0.8"/></g>')
        cells.append((f"tenant-tile:{g}:{r}", f"tenant:{g}:{r}", "tenant-card"))
        nodes.append(text(tx, ty + 12, "GPU", size=6.5, fill=MUTED, weight="700"))
        nodes.append(text(tx, ty + 28, str(r), size=13, fill=INK, weight="700"))
        nodes.append(f'<g id="cell-tenant-label:{g}:{r}">'
                     + pill_html(tx, ty + 47, size=9, word="t",
                                 extra=" font-weight: 800; padding: 0px 2px; border-radius: 5px;")
                     + "</g>")
        cells.append((f"tenant-label:{g}:{r}", f"tenant:{g}:{r}", "tenant-label"))

# per E/W spine: sum of its 8 ISLs per direction (spine out = toward the rail leaves = up on the drawing)
for ew in EW_SPINES:
    x, y = SW[ew][0], SW[ew][1]
    for d, dy, glyph in (("out", -11, "▲"), ("in", 13, "▼")):
        nodes.append(text(x + S_SW / 2 + 10, y + dy + 4, glyph, size=10, fill=MUTED, weight="700", anchor="start"))
        pills_svg.append(f'<g id="cell-ews:{ew}:{d}">' + pill_html(x + S_SW / 2 + 52, y + dy, size=10) + "</g>")
        cells.append((f"ews:{ew}:{d}", f"ews:{ew}:{d}", "rate"))

# title + legend
deco = [text(24, 34, "neocloud CSP datacenter — live traffic", size=21, anchor="start", weight="700"),
        text(24, 55, "28 × SR Linux 26.7.1 (7220 IXR-H5-64O-512 / D5, 7250 IXR-X1B) · DC1 frontend + GPU backend · "
                     "DC2 over DCI · internet edge", size=12, fill=MUTED, weight="500", anchor="start")]
lx, ly = 24, H - 20
deco.append(text(lx, ly, "link:", size=12, fill="#475569", weight="700", anchor="start"))
xx = lx + 38


def legend_traffic(levels):
    global xx
    out = []
    for col, lab in levels:
        out.append(f'<rect x="{xx}" y="{ly - 9}" width="22" height="10" rx="2" fill="{col}" stroke="#475569" stroke-width="0.5"/>')
        out.append(text(xx + 27, ly, lab, size=11, fill="#475569", weight="500", anchor="start"))
        xx += 27 + len(lab) * 6.6 + 18
    return out


# ---- thresholds (per DIRECTION, bits/s) = aifabric's (same simulator, same idle levels) ------
# idle (LLDP/BGP): a port ~0.2-1 kb/s => grey; anything that carries pings or more = green;
# red kept far above what the simulator forwards (the SR Linux rate gauge spikes, telemetry-stack §21l)
UPPER = [("#FFFF00", 1000000), ("#FF8000", 10000000), ("#FF3154", 100000000)]
T_LINK = [("#bec8d2", 0), ("#4BDD33", 5000)] + UPPER
deco += legend_traffic([("#bec8d2", "idle"), ("#4BDD33", "traffic"), ("#FFFF00", "> 1 Mb/s"),
                        ("#FF8000", "> 10 Mb/s"), ("#FF3154", "> 100 Mb/s")])
xx += 10
deco.append(text(xx, ly, "port:", size=12, fill="#475569", weight="700", anchor="start"))
xx += 40
for col, lab in [("#4BDD33", "up"), ("#FF3154", "down")]:
    deco.append(f'<circle cx="{xx + 5}" cy="{ly - 4}" r="5" fill="{col}" stroke="#475569" stroke-width="1"/>')
    deco.append(text(xx + 15, ly, lab, size=11, fill="#475569", weight="500", anchor="start"))
    xx += 15 + len(lab) * 6.6 + 18
xx += 10
deco.append(text(xx, ly, "GPUs:", size=12, fill="#475569", weight="700", anchor="start"))
xx += 44
for t in (1, 2, 0):                                  # live GPU count per tenant (+ free) = cell gpus:<t>
    name = {1: "tenant1", 2: "tenant2", 0: "free"}[t]
    deco.append(f'<rect x="{xx}" y="{ly - 11}" width="64" height="14" rx="7" fill="{TENANT[t][0]}" '
                f'stroke="{TENANT[t][1]}" stroke-width="1"/>')
    deco.append(text(xx + 32, ly, name, size=10, fill=TENANT[t][1], weight="700"))
    pills_svg.append(f'<g id="cell-gpus:{t}">' + pill_html(xx + 80, ly - 4, size=11, word="n",
                     extra=" font-weight: 700; padding: 0px 4px;") + "</g>")
    cells.append((f"gpus:{t}", f"gpus:{t}", "count"))
    xx += 104
deco.append(text(24, ly - 24, "arrow = direction · pill = live rate per direction · host and backend cables: colour only · "
                 "E/W spine pills = sum of its 8 ISLs (▲ to the rail leaves, ▼ from them) · GPU tile = tenant of that GPU (live EDA label)",
                 size=11, fill="#94a3b8", weight="500", anchor="start"))

SVG = (f'<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" '
       f'viewBox="0 0 {W} {H}" width="{W}" height="{H}">'
       f'<rect width="{W}" height="{H}" fill="#ffffff"/>'
       + "".join(bg) + "".join(links_svg) + "".join(titles) + "".join(nodes)
       + "".join(pills_svg) + "".join(ports_svg) + "".join(deco) + "</svg>")


# ---- panelConfig ------------------------------------------------------------
def thr(name, levels):
    return [f"  {name}: &{name}"] + [f'    - {{ color: "{c}", level: {lv} }}' for c, lv in levels]


# Anchors MUST sit under `anchors:` or the plugin drops the whole config (telemetry-stack §22).
pc = ["---", "anchors:"]
pc += thr("thresholds-operstate", [("#FF3154", 0), ("#4BDD33", 1)])
pc += thr("thresholds-traffic", T_LINK)
pc += thr("thresholds-tenant-card", [(TENANT[t][0], t) for t in sorted(TENANT)])
pc += thr("thresholds-tenant-text", [(TENANT[t][1], t) for t in sorted(TENANT)])
pc += ["  label-config: &label-config", "    separator: replace", "    units: bps", "    decimalPoints: 0",
       "  count-config: &count-config", "    separator: replace", "    units: none", "    decimalPoints: 0",
       "  tenant-config: &tenant-config", "    separator: replace", "    valueMappings:",
       '      - { value: null, text: "?" }', '      - { value: 0, text: "free" }',
       '      - { value: 1, text: "T1" }', '      - { value: 2, text: "T2" }']
pc += ["", "cellIdPreamble: cell-", "cells:"]
for cid, dref, kind in cells:
    pc += [f"  {cid}:", f"    dataRef: {dref}"]
    if kind == "traffic":
        pc += ["    fillColor:", "      thresholds: *thresholds-traffic",
               "    strokeColor:", "      thresholds: *thresholds-traffic"]
    elif kind == "rate":
        pc += ["    label: *label-config"]
    elif kind == "count":
        pc += ["    label: *count-config"]
    elif kind == "tenant-card":
        pc += ["    fillColor:", "      thresholds: *thresholds-tenant-card"]
    elif kind == "tenant-label":
        pc += ["    label: *tenant-config", "    labelColor:", "      thresholds: *thresholds-tenant-text"]
    else:
        pc += ["    fillColor:", "      thresholds: *thresholds-operstate"]
PANELCONFIG = "\n".join(pc) + "\n"


# ---- dashboard ----------------------------------------------------------------
def target(ref, expr, legend):
    # instant + last_over_time: the exporter omits whole switches for a while (telemetry-stack §23; windows below)
    return {"datasource": DS, "refId": ref, "expr": expr, "legendFormat": legend, "editorMode": "code",
            "instant": True, "range": False, "interval": "1s", "exemplar": False}


SEL = f'namespace_name="{NS}"'
# GOTCHA measured 2026-11-02 on this lab (28 switches, ~1700 port series, one exporter): whole switches go missing
# from the exporter for a while (not idle ports: rail-leaf-7 incl. its busy mgmt0 = 6 of 60 rate samples in 5 min).
# Max gap on a fresh lab: oper-state 60 s, rate 135 s (first lab: 40 / 50 s) => aifabric's 20 s window left up to 48
# of 428 dataRefs blank, rotating per switch. last_over_time returns the NEWEST sample, so a wide window costs nothing
# while a switch reports; it only holds the last known value while that switch is silent.
WIN_OPER, WIN = "2m", "3m"


def ews_expr(metric):
    """E/W spine ports e1-1..8 (one per rail leaf), summed per spine."""
    return (f'sum by (node_name) (last_over_time({metric}{{{SEL},node_name=~"ew-spine-[1-4]",'
            f'interface_name=~"ethernet-1/[1-8]"}}[{WIN}]))')


RES = f'namespace_resources_cr_interfaces_eda_nokia_com_v1_interface{{{SEL},role="gpu",backend="{{t}}"}}'


def tenant_expr():
    """value = tenant number (0 = free) per GPU, keyed <server>:<rail> (= its NIC's Interface CR labels host, rail)."""
    parts = []
    for name, t in (("", 0), ("tenant1", 1), ("tenant2", 2)):
        sel = RES.replace("{t}", name)
        parts.append(f'(label_join(max by (host, rail) ({sel}), "gpu", ":", "host", "rail") * {t})')
    return " or ".join(parts)


def count_expr(name):
    return f'count({RES.replace("{t}", name)}) or vector(0)'


TARGETS = [
    target("A", f"last_over_time(node_srl_interface_oper_state{{{SEL}}}[{WIN_OPER}])",
           "oper-state:{{node_name}}:{{interface_name}}"),
    target("B", f"last_over_time(node_srl_interface_traffic_rate_out_bps{{{SEL}}}[{WIN}])",
           "{{node_name}}:{{interface_name}}:out"),
    target("C", f"last_over_time(node_srl_interface_traffic_rate_in_bps{{{SEL}}}[{WIN}])",
           "{{node_name}}:{{interface_name}}:in"),
    target("D", ews_expr("node_srl_interface_traffic_rate_out_bps"), "ews:{{node_name}}:out"),
    target("E", ews_expr("node_srl_interface_traffic_rate_in_bps"), "ews:{{node_name}}:in"),
    target("G", tenant_expr(), "tenant:{{gpu}}"),
    target("J", count_expr("tenant1"), "gpus:1"),
    target("K", count_expr("tenant2"), "gpus:2"),
    target("L", count_expr(""), "gpus:0"),
]
flow = {
    "id": 1, "type": "andrewbmchugh-flow-panel", "title": "", "transparent": True,
    "datasource": DS, "gridPos": {"h": 31, "w": 24, "x": 0, "y": 0}, "interval": "1s",
    "targets": TARGETS,
    "fieldConfig": {"defaults": {}, "overrides": []},
    "options": {"svg": SVG, "panelConfig": PANELCONFIG, "siteConfig": "",
                "animationsEnabled": True, "animationControlEnabled": True, "highlighterEnabled": True,
                "highlighterSelection": "", "panZoomEnabled": False, "testDataEnabled": False,
                "timeSliderEnabled": False, "timeSliderMode": "local",
                "debuggingCtr": {"colorsCtr": 0, "dataCtr": 0, "displaySvgCtr": 0, "mappingsCtr": 0,
                                 "timingsCtr": 0}},
}
dash = {
    # no "id"/"version": Grafana keeps its DB copy over a file with an older version
    "uid": "neocloud-topology", "title": "NeoCloud datacenter",
    "description": "NeoCloud demo: live traffic + port state on every link of the 28 switches; tenant per GPU (per NIC label)",
    "tags": ["neocloud"], "timezone": "browser", "editable": False,
    "refresh": "5s", "time": {"from": "now-5m", "to": "now"},
    "timepicker": {"refresh_intervals": ["5s", "10s", "30s"]},
    "schemaVersion": 41, "graphTooltip": 0, "panels": [flow], "templating": {"list": []},
    "annotations": {"list": []},
}


def check():
    """Evaluate every target in live Prometheus, build the legend keys, check every dataRef."""
    st = Path(__file__).resolve().parent.parent / ".state" / "kubectl"   # the wrapper ./deploy.sh saved
    k = os.environ.get("KUBECTL", "")
    kubectl = k if k not in ("", "kubectl") else (str(st) if os.access(st, os.X_OK) else "kubectl")
    keys = {}
    for t in TARGETS:
        q = subprocess.run([kubectl, "-n", NS, "exec", "deploy/prometheus", "--", "wget", "-qO-",
                            "--post-data", "query=" + t["expr"].replace("%", "%25").replace("&", "%26")
                            .replace("+", "%2B"),
                            "http://localhost:9090/api/v1/query"], capture_output=True, text=True)
        try:
            res = json.loads(q.stdout)["data"]["result"]
        except Exception:
            print(f"target {t['refId']}: query failed: {q.stdout[:200]} {q.stderr[:200]}")
            return 1
        for r in res:
            k = re.sub(r"\{\{(\w+)\}\}", lambda m: r["metric"].get(m.group(1), ""), t["legendFormat"])
            keys[k] = float(r["value"][1])
        print(f"target {t['refId']}: {len(res)} series")
    refs = sorted({d for _, d, _ in cells})
    miss = [d for d in refs if d not in keys]
    print(f"dataRefs resolved: {len(refs) - len(miss)}/{len(refs)}")
    for d in miss[:30]:
        print("  MISSING", d)
    down = sorted(d for d in refs if d.startswith("oper-state:") and keys.get(d) == 0)
    print(f"ports down: {len(down)}" + "".join(f"\n  DOWN {d}" for d in down))
    ten = {0: "free", 1: "T1", 2: "T2"}
    for g in GPU:
        print(f"  {g}: " + " ".join(f"G{r}={ten.get(keys.get(f'tenant:{g}:{r}'), '?')}" for r in range(1, 9)))
    print("  GPUs tenant1 / tenant2 / free: " + " / ".join(str(int(keys.get(f"gpus:{t}", -1))) for t in (1, 2, 0)))
    return 1 if miss else 0


if __name__ == "__main__":
    if "--check" in sys.argv:
        sys.exit(check())
    OUT.write_text(json.dumps(dash, indent=2, ensure_ascii=False) + "\n")
    n_links = len([c for c in cells if c[0].startswith("link_id:")]) // 2
    print(f"wrote {OUT.name}: {OUT.stat().st_size:,} B · svg {len(SVG):,} B · {n_links} links · "
          f"{len([c for c in cells if c[2] == 'rate'])} pills · {len(cells)} cells")
