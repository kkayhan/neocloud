#!/usr/bin/env python3
"""EDA login + connection helpers for the neocloud tools (dashboards/, tenant-onboarding/, deploy.sh preflight).

Which EDA and which Kubernetes cluster: env EDA_URL / KUBECTL first, else what deploy.sh saved in .state/
(connection.env + the kubectl wrapper pinned to the kubeconfig and context the person chose), else plain kubectl.

EDA REST login = password grant through EDA's confidential Keycloak client `eda`. Its secret is read with the
Keycloak master admin (env KC_MASTER_USER / KC_MASTER_PASSWORD, default admin / admin, the EDA install default).
Admin actions run as EDA_ADMIN_USER / EDA_ADMIN_PASSWORD (default admin / admin).
Keycloak is reached through EDA's own proxy: /core/httpproxy/v1/keycloak, else /core/proxy/v1/identity (both ship
with EDA 26.8).

  python3 lib/eda_auth.py check     log in as the EDA admin, print the EDA user count (deploy.sh preflight)
"""
from __future__ import annotations

import json
import os
import shlex
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

sys.dont_write_bytecode = True
STATE = Path(__file__).resolve().parent.parent / ".state"
KC_PATHS = ("/core/httpproxy/v1/keycloak", "/core/proxy/v1/identity")
FORM = {"Content-Type": "application/x-www-form-urlencoded"}

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE          # EDA ships a self-signed certificate


def saved(key: str) -> str:
    """A value deploy.sh saved in .state/connection.env ("" when absent)."""
    f = STATE / "connection.env"
    if f.is_file():
        for line in f.read_text().splitlines():
            k, _, v = line.partition("=")
            if k.strip() == key and v.strip():
                return shlex.split(v)[0]
    return ""


def eda_url(required: bool = True) -> str:
    url = os.environ.get("EDA_URL") or saved("EDA_URL")
    if not url and os.environ.get("EXT_DOMAIN_NAME"):
        url = "https://" + os.environ["EXT_DOMAIN_NAME"]
    if url and "://" not in url:
        url = "https://" + url
    if not url and required:
        sys.exit("EDA address unknown: run ./deploy.sh first (it saves the connection) or set EDA_URL")
    return url.rstrip("/")


def kubectl() -> list[str]:
    """The kubectl command line: env KUBECTL, else the wrapper deploy.sh saved, else plain kubectl."""
    if os.environ.get("KUBECTL") and os.environ["KUBECTL"] != "kubectl":
        return shlex.split(os.environ["KUBECTL"])
    if os.access(STATE / "kubectl", os.X_OK):
        return [str(STATE / "kubectl")]
    return ["kubectl"]


def http(method: str, url: str, headers: dict | None = None, data: bytes | None = None):
    req = urllib.request.Request(url, method=method, headers=headers or {}, data=data)
    try:
        with urllib.request.urlopen(req, context=CTX, timeout=60) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


_KC: dict = {}


def _keycloak(url: str) -> tuple[str, str]:
    """(Keycloak base path that works, secret of client `eda`), via the Keycloak master admin; cached per URL."""
    if url in _KC:
        return _KC[url]
    st = 0
    for kc in KC_PATHS:
        try:
            st, b = http("POST", f"{url}{kc}/realms/master/protocol/openid-connect/token", FORM,
                         urllib.parse.urlencode({"client_id": "admin-cli", "grant_type": "password",
                                                 "username": os.environ.get("KC_MASTER_USER", "admin"),
                                                 "password": os.environ.get("KC_MASTER_PASSWORD", "admin")}).encode())
        except urllib.error.URLError as e:
            raise RuntimeError(f"EDA not reachable at {url}: {e.reason}") from None
        if st == 200:
            break
    else:
        raise RuntimeError(f"Keycloak master login failed: HTTP {st} (set KC_MASTER_USER / KC_MASTER_PASSWORD "
                           "if EDA's Keycloak admin is not admin / admin)")
    mt = json.loads(b)["access_token"]
    st, b = http("GET", f"{url}{kc}/admin/realms/eda/clients?clientId=eda", {"Authorization": f"Bearer {mt}"})
    if st != 200 or not json.loads(b):
        raise RuntimeError(f"Keycloak client 'eda' not readable: HTTP {st}")
    _KC[url] = (kc, json.loads(b)[0]["secret"])
    return _KC[url]


def user_token(url: str, user: str, password: str) -> tuple[int, str]:
    """(HTTP status, access token or error text) for a password grant through client `eda`."""
    kc, secret = _keycloak(url)
    st, b = http("POST", f"{url}{kc}/realms/eda/protocol/openid-connect/token", FORM,
                 urllib.parse.urlencode({"client_id": "eda", "client_secret": secret, "grant_type": "password",
                                         "scope": "openid", "username": user, "password": password}).encode())
    try:
        j = json.loads(b)
    except ValueError:
        return st, b[:200]
    return st, j.get("access_token") or j.get("error_description") or j.get("error") or b[:200]


def admin_token(url: str) -> str:
    user = os.environ.get("EDA_ADMIN_USER", "admin")
    st, tok = user_token(url, user, os.environ.get("EDA_ADMIN_PASSWORD", "admin"))
    if st != 200:
        hint = " (log in to the EDA GUI once: a fresh EDA asks the admin to set a new password)" \
            if "not fully set up" in tok else ""
        raise RuntimeError(f"EDA login as {user} failed: HTTP {st} {tok}{hint}")
    return tok


def check() -> int:
    url = eda_url()
    try:
        tok = admin_token(url)
        st, b = http("GET", f"{url}/core/admin/users", {"Authorization": f"Bearer {tok}"})
        if st != 200:
            raise RuntimeError(f"GET /core/admin/users -> HTTP {st}")
    except RuntimeError as e:
        print(f"  EDA API {url}: {e}")
        return 1
    print(f"  EDA API {url}: login as {os.environ.get('EDA_ADMIN_USER', 'admin')} OK ({len(json.loads(b))} EDA users)")
    return 0


if __name__ == "__main__":
    if sys.argv[1:] == ["check"]:
        sys.exit(check())
    sys.exit(__doc__)
