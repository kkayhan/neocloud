#!/usr/bin/env python3
"""EDA user `terraform` = the identity tenant-onboarding/terraform works as (owner Q2 A, 2026-11-12).

  python3 terraform-user.py ensure    create/repair: user terraform, password terraform, enabled,
                                      member of group system-administrator (same rights as admin)
  python3 terraform-user.py delete    remove it (destroy.sh)
EDA address + admin login: lib/eda_auth.py (env EDA_URL / EDA_ADMIN_USER / EDA_ADMIN_PASSWORD, else the saved connection
and admin / admin).

WHY a user of its own: every change Terraform makes shows under `terraform` in EDA Transactions / Merge Requests,
apart from what a human does as admin. Users are cluster-wide (not in ns neocloud) ⇒ deploy creates, destroy removes.
REST recipe = the one tenant-onboarding/terraform/access.tf proved (2026-11-12): POST /core/admin/users (enabled must be sent,
EDA default = disabled), PUT /core/admin/groups/{g}/users/{u}, PUT /core/admin/users/{u}/resetpassword.
"""
import json, os, ssl, sys, urllib.error, urllib.parse, urllib.request

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
import eda_auth  # noqa: E402

USER, PASSWORD, GROUP = "terraform", "terraform", "system-administrator"
action = sys.argv[1] if len(sys.argv) > 1 else "ensure"
B = eda_auth.eda_url()
C = ssl._create_unverified_context()


def req(method, url, token=None, body=None, form=None):
    h, data = {}, None
    if token: h["Authorization"] = "Bearer " + token
    if body is not None: h["Content-Type"] = "application/json"; data = json.dumps(body).encode()
    if form is not None: h["Content-Type"] = "application/x-www-form-urlencoded"; data = urllib.parse.urlencode(form).encode()
    try:
        with urllib.request.urlopen(urllib.request.Request(url, data=data, headers=h, method=method), context=C, timeout=60) as r:
            raw = r.read(); return r.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()[:300]


def token(username, password):
    st, tok = eda_auth.user_token(B, username, password)
    return tok if st == 200 else None


try:
    t = eda_auth.admin_token(B)
except RuntimeError as e:
    sys.exit(str(e))
user = next((u for u in req("GET", B + "/core/admin/users", t)[1] or [] if u.get("username") == USER), None)

if action == "delete":
    print(f"user {USER}:", req("DELETE", B + f"/core/admin/users/{user['uuid']}", t)[0] if user else "absent")
    sys.exit(0)

group = next((g for g in req("GET", B + "/core/admin/groups", t)[1] if g.get("name") == GROUP), None) or sys.exit(f"group {GROUP} missing")
if not user:
    s, user = req("POST", B + "/core/admin/users", t, body=dict(
        username=USER, firstName="Terraform", lastName="automation", email="terraform@example.com", enabled=True))
    if s not in (200, 201): sys.exit(f"create user {USER}: HTTP {s} {user}")
    if not user or "uuid" not in user:
        user = next(u for u in req("GET", B + "/core/admin/users", t)[1] if u.get("username") == USER)
u = user["uuid"]
if not user.get("enabled", True):
    req("PUT", B + f"/core/admin/users/{u}", t, body={**user, "enabled": True})
if USER not in (req("GET", B + f"/core/admin/groups/{group['uuid']}", t)[1].get("users") or []):
    s, r = req("PUT", B + f"/core/admin/groups/{group['uuid']}/users/{u}", t, body={})
    if s >= 300: sys.exit(f"add {USER} to {GROUP}: HTTP {s} {r}")
if not token(USER, PASSWORD):
    s, r = req("PUT", B + f"/core/admin/users/{u}/resetpassword", t, body=dict(value=PASSWORD, temporary=False))
    if s >= 300: sys.exit(f"set password of {USER}: HTTP {s} {r}")
print(f"user {USER}: enabled, group {GROUP}, login {'OK' if token(USER, PASSWORD) else 'FAILED'}")
