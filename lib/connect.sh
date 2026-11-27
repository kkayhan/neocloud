# neocloud — which EDA and which Kubernetes cluster the scripts talk to, and the SR Linux simulator licence.
# Sourced (BEFORE lib/common.sh) by deploy.sh and destroy.sh (nc_connect) and by every other tool (nc_resolve).
#
# Two doors into the same EDA, and both must point at the SAME one:
#   EDA API  (URL + admin login)  EDA users (terraform), the GUI dashboard + navigation panel, the Terraform project
#   kubectl  (kubeconfig)         everything else: the lab objects, edactl inside EDA's toolbox pod, the network
#                                 inside the simulated hosts, the Grafana dashboard's Prometheus + Grafana
#
# interactive (default)  asks for the EDA URL or IP, the EDA admin user + password, the kubeconfig file and its context,
#                        and (deploy of the whole lab or phase ns) the SR Linux 26.7 licence file. Any answer can come
#                        from the environment instead: EDA_URL, EDA_ADMIN_USER, EDA_ADMIN_PASSWORD, NC_KUBECONFIG,
#                        NC_CONTEXT, NEOCLOUD_LICENSE (+ --yes = no confirmation) => unattended runs.
# pinned                 EDA_CLUSTER set (a dispatcher that also sets KUBECONFIG), or KUBECTL + EDA_URL both set: no questions;
#                        EDA_URL from env (else https://$EXT_DOMAIN_NAME), admin login from env, else admin / admin.
# Keycloak (EDA's login server) master admin = admin / admin, the EDA install default (KC_MASTER_USER /
# KC_MASTER_PASSWORD override it): only it can read the secret of EDA's login client, which the API login needs.
#
# The answers, never the password, are saved in .state/connection.env, and .state/kubectl = kubectl pinned to that
# kubeconfig + context, so every tool (hosts.sh, verify.sh, neocloud-ssh, traffic/, upgrade/, tenant-onboarding/ ...)
# reaches the same EDA later without asking.
#
# WHY a licence: 6 of the 28 switches are 7250 IXR-X1B, a licensed platform in EDA's simulator. EDA ships an EMPTY
# licence for every SR Linux release (ConfigMaps eda-system/cx-srl-*-license, 0 bytes, EDA 26.8.2), so without the
# user's own SR Linux 26.7 licence those switches abort at boot. The 7220 IXR models run without one.

NC_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
NC_STATE="$NC_ROOT/.state"
NC_CALLER_KUBECTL="${KUBECTL:-}"          # captured before lib/common.sh defaults KUBECTL to plain kubectl
NC_MODE=interactive
NC_NS=neocloud
NC_NEED_CPU=15 NC_NEED_GIB=42               # pod requests of the lab: 41 pods (38 simulators + Prometheus, Grafana, alert receiver) = 15.2 CPU / 42.2 GiB, measured Kind 2026-11-27

nc_saved(){  # nc_saved KEY: value saved by an earlier run ("" when none)
  [ -f "$NC_STATE/connection.env" ] || return 0
  ( . "$NC_STATE/connection.env" 2>/dev/null; printf '%s' "${!1:-}" )
}

nc_norm_url(){  # "10.1.1.1" | "eda.lab:9443" | "https://eda.lab/core/..." -> https://host[:port]
  local u="$1"
  case "$u" in http://*|https://*) ;; *) u="https://$u" ;; esac
  sed -E 's#^(https?://[^/]+).*#\1#' <<<"$u"
}

nc_host(){  # nc_host <url> -> the bare host name or address
  local h="${1#*://}"; printf '%s' "${h%%[:/]*}"
}

nc_resolve(){  # tools that never ask: KUBECTL + EDA_URL from env, else what deploy.sh saved, else plain kubectl
  # a bare "kubectl" from the user's shell would follow its current context: the saved wrapper wins over it
  if [ -z "${KUBECTL:-}" ] || [ "$KUBECTL" = kubectl ]; then
    if [ -x "$NC_STATE/kubectl" ]; then KUBECTL="$NC_STATE/kubectl"; else KUBECTL=kubectl; fi
  fi
  [ -n "${EDA_URL:-}" ] || EDA_URL=$(nc_saved EDA_URL)
  [ -n "${EDA_URL:-}" ] || { [ -n "${EXT_DOMAIN_NAME:-}" ] && EDA_URL="https://$EXT_DOMAIN_NAME"; }
  [ -n "${EDA_URL:-}" ] && EDA_URL=$(nc_norm_url "$EDA_URL")
  export KUBECTL EDA_URL
}

nc_ask(){  # nc_ask VAR "question" [default] [secret]: read from the terminal, Enter = default
  local __a
  if [ ! -t 0 ]; then                       # unattended: take the default; a question without one needs the env
    if [ -n "${3:-}" ] || [ "${4:-}" = secret ]; then printf -v "$1" '%s' "${3:-}"; return 0; fi
    err "no terminal to ask '$2': set it through the environment (see README)"; return 1
  fi
  if [ "${4:-}" = secret ]; then
    read -rsp "$2: " __a; echo >&2
  else
    read -rp "$2${3:+ [$3]}: " __a
  fi
  printf -v "$1" '%s' "${__a:-${3:-}}"
}

nc_write_state(){  # nc_write_state <kubectl binary> <kubeconfig|""> <context|"">: wrapper + connection.env
  local bin="$1" kc="$2" ctx="$3"
  mkdir -p "$NC_STATE"
  {
    echo '#!/usr/bin/env bash'
    echo "# written by deploy.sh/destroy.sh: kubectl pinned to the cluster of the EDA at $EDA_URL"
    printf 'exec %q' "$bin"
    [ -n "$kc" ] && printf ' --kubeconfig=%q' "$kc"
    [ -n "$ctx" ] && printf ' --context=%q' "$ctx"
    echo ' "$@"'
  } > "$NC_STATE/kubectl.new" && chmod 755 "$NC_STATE/kubectl.new" && mv "$NC_STATE/kubectl.new" "$NC_STATE/kubectl"
  {
    echo "# neocloud connection (written $(date -u +%FT%TZ)); no password is stored"
    printf 'EDA_URL=%q\nEDA_ADMIN_USER=%q\nNC_KUBECONFIG=%q\nNC_CONTEXT=%q\nNEOCLOUD_LICENSE=%q\n' \
      "$EDA_URL" "$EDA_ADMIN_USER" "$kc" "$ctx" "${NEOCLOUD_LICENSE:-$(nc_saved NEOCLOUD_LICENSE)}"
  } > "$NC_STATE/connection.env"
}

nc_connect_pinned(){
  local kw bin kc="" ctx=""
  NC_MODE=pinned
  KUBECTL="${NC_CALLER_KUBECTL:-kubectl}"
  [ -n "${EDA_URL:-}" ] || { [ -n "${EXT_DOMAIN_NAME:-}" ] && EDA_URL="https://$EXT_DOMAIN_NAME"; }
  [ -n "${EDA_URL:-}" ] || { err "EDA_URL is not set (pinned mode: KUBECTL or EDA_CLUSTER given)"; return 1; }
  EDA_URL=$(nc_norm_url "$EDA_URL")
  EDA_ADMIN_USER="${EDA_ADMIN_USER:-admin}" EDA_ADMIN_PASSWORD="${EDA_ADMIN_PASSWORD:-admin}"
  NEOCLOUD_LICENSE="${NEOCLOUD_LICENSE:-$(nc_saved NEOCLOUD_LICENSE)}"
  # the saved wrapper must keep working outside this run: resolve the binary and pin KUBECONFIG + context
  read -ra kw <<<"$KUBECTL"
  bin=$(command -v "${kw[0]}") || { err "kubectl '${kw[0]}' not found"; return 1; }
  if [ "$(readlink -f "$bin")" = "$(readlink -f "$NC_STATE/kubectl" 2>/dev/null)" ]; then
    return 0                                          # the caller passed the saved wrapper itself
  fi
  if [ "${#kw[@]}" -gt 1 ]; then                      # KUBECTL with its own flags: keep them verbatim
    mkdir -p "$NC_STATE"
    { echo '#!/usr/bin/env bash'; printf 'exec'; printf ' %q' "$bin" "${kw[@]:1}"; echo ' "$@"'; } > "$NC_STATE/kubectl"
    chmod 755 "$NC_STATE/kubectl"
    printf 'EDA_URL=%q\nEDA_ADMIN_USER=%q\nNEOCLOUD_LICENSE=%q\n' "$EDA_URL" "$EDA_ADMIN_USER" "$NEOCLOUD_LICENSE" > "$NC_STATE/connection.env"
    KUBECTL="$NC_STATE/kubectl"
    return 0
  fi
  [ -n "${KUBECONFIG:-}" ] && kc=$(readlink -f "${KUBECONFIG%%:*}")
  ctx=$("$bin" config current-context 2>/dev/null)
  nc_write_state "$bin" "$kc" "$ctx"
  KUBECTL="$NC_STATE/kubectl"
}

nc_connect_interactive(){
  local kc ctx n i list cur def kb
  echo "neocloud — GPU cloud datacenter demo for Nokia EDA. Answers in [brackets] are the default (Enter)."
  if [ -z "${EDA_URL:-}" ]; then nc_ask EDA_URL "EDA URL or IP address (the address of the EDA web UI)" "$(nc_saved EDA_URL)" || return 1; fi
  [ -n "$EDA_URL" ] || { err "no EDA address given"; return 1; }
  EDA_URL=$(nc_norm_url "$EDA_URL")
  if [ -z "${EDA_ADMIN_USER:-}" ]; then def=$(nc_saved EDA_ADMIN_USER); nc_ask EDA_ADMIN_USER "EDA admin user" "${def:-admin}" || return 1; fi
  EDA_ADMIN_USER="${EDA_ADMIN_USER:-admin}"
  if [ -z "${EDA_ADMIN_PASSWORD+x}" ]; then
    nc_ask EDA_ADMIN_PASSWORD "EDA password for $EDA_ADMIN_USER (hidden; Enter = admin)" "" secret || return 1
  fi
  EDA_ADMIN_PASSWORD="${EDA_ADMIN_PASSWORD:-admin}"
  kc="${NC_KUBECONFIG:-}"
  if [ -z "$kc" ]; then
    def=$(nc_saved NC_KUBECONFIG); def="${def:-${KUBECONFIG:-$HOME/.kube/config}}"; def="${def%%:*}"
    echo "kubectl access to the Kubernetes cluster EDA runs on is needed too: it builds the simulated hosts and the dashboard."
    nc_ask kc "kubeconfig file of that cluster" "$def" || return 1
  fi
  kc="${kc/#\~/$HOME}"
  [ -f "$kc" ] || { err "kubeconfig '$kc' not found"; return 1; }
  kc=$(readlink -f "$kc")
  kb=$(command -v kubectl) || { err "kubectl is not installed (https://kubernetes.io/docs/tasks/tools/)"; return 1; }
  ctx="${NC_CONTEXT:-}"
  if [ -z "$ctx" ]; then
    mapfile -t list < <("$kb" --kubeconfig="$kc" config get-contexts -o name 2>/dev/null)
    [ "${#list[@]}" -gt 0 ] || { err "no context in $kc"; return 1; }
    cur=$("$kb" --kubeconfig="$kc" config current-context 2>/dev/null)
    if [ "${#list[@]}" -eq 1 ]; then
      ctx="${list[0]}"
    else
      def=$(nc_saved NC_CONTEXT); [[ " ${list[*]} " == *" $def "* ]] || def="$cur"
      for i in "${!list[@]}"; do printf '  %2d) %s%s\n' $((i + 1)) "${list[$i]}" "$([ "${list[$i]}" = "$def" ] && echo '   (default)')"; done
      nc_ask n "context of the EDA cluster (number or name)" "$def" || return 1
      if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#list[@]}" ]; then ctx="${list[$((n - 1))]}"; else ctx="$n"; fi
      [[ " ${list[*]} " == *" $ctx "* ]] || { err "context '$ctx' is not in $kc"; return 1; }
    fi
  fi
  if [ "${NC_NEED_LICENCE:-}" = yes ] && [ -z "${NEOCLOUD_LICENSE:-}" ]; then
    echo "The 6 border switches (7250 IXR-X1B) need your own SR Linux 26.7 licence file: EDA's simulator ships none."
    nc_ask NEOCLOUD_LICENSE "SR Linux 26.7 licence file" "$(nc_saved NEOCLOUD_LICENSE)" || return 1
  fi
  NEOCLOUD_LICENSE="${NEOCLOUD_LICENSE:-}"; NEOCLOUD_LICENSE="${NEOCLOUD_LICENSE/#\~/$HOME}"   # destroy never asks: may be unset (set -u)
  [ -n "$NEOCLOUD_LICENSE" ] && [ -f "$NEOCLOUD_LICENSE" ] && NEOCLOUD_LICENSE=$(readlink -f "$NEOCLOUD_LICENSE")
  nc_write_state "$kb" "$kc" "$ctx"
  KUBECTL="$NC_STATE/kubectl"
  NC_CTX_SHOWN="$ctx ($kc)"
}

nc_licence_check(){  # the licence file exists, is not empty and names SR Linux 26.7 (its content is never printed)
  local f="${NEOCLOUD_LICENSE:-}"
  [ -n "$f" ] || { err "no SR Linux 26.7 licence file given (NEOCLOUD_LICENSE): the 7250 IXR-X1B switches cannot boot without it"; return 1; }
  [ -s "$f" ] || { err "licence file '$f' is missing or empty"; return 1; }
  if grep -qE 'SRL_26_7|SRL_26_\*|SRL_\*' "$f"; then
    echo "  SR Linux licence: $f (covers SR Linux 26.7)"
  else
    warn "licence file '$f' does not name SR Linux 26.7 (SRL_26_7_*): the X1B switches may abort at boot"
  fi
}

nc_preflight(){  # nc_preflight deploy|destroy: is everything there? (fails hard only on what would break the run)
  local verb="$1" rc=0 img ver dom ip host n cap c m
  log "preflight — EDA $EDA_URL, kubectl ${NC_CTX_SHOWN:-$KUBECTL}"
  [ "${BASH_VERSINFO[0]}" -ge 4 ] || { err "bash 4 or newer needed (this is bash $BASH_VERSION)"; rc=1; }
  python3 -c 'import sys; sys.exit(sys.version_info < (3, 9))' 2>/dev/null || { err "python3 3.9 or newer needed"; rc=1; }
  python3 -c 'import yaml' 2>/dev/null || { err "python3 module yaml missing (Debian/Ubuntu: apt install python3-yaml; else pip install pyyaml)"; rc=1; }
  img=$($KUBECTL -n eda-system get deploy eda-api -o jsonpath='{.spec.template.spec.containers[0].image}' 2>&1) \
    || { err "kubectl cannot read EDA's deployment eda-system/eda-api with this kubeconfig/context: $img"; return 1; }
  ver="${img##*:}"
  echo "  Kubernetes side: EDA $ver"
  # the two doors must open the same EDA: compare the URL with the address EDA itself is configured for
  dom=$($KUBECTL -n eda-system get engineconfig -o jsonpath='{.items[0].spec.cluster.external.domainName}' 2>/dev/null)
  ip=$($KUBECTL -n eda-system get engineconfig -o jsonpath='{.items[0].spec.cluster.external.ipv4Address}' 2>/dev/null)
  host=$(nc_host "$EDA_URL")
  if [ -n "$dom$ip" ] && [ "$host" != "$dom" ] && [ "$host" != "$ip" ]; then
    warn "the EDA behind this kubeconfig calls itself '$dom'${ip:+ ($ip)}, the URL says '$host': make sure both are the same EDA"
  fi
  python3 "$NC_ROOT/lib/eda_auth.py" check || rc=1
  if [ "$verb" = deploy ]; then
    [[ "$ver" == 26.8.* ]] || warn "built and tested on EDA 26.8.2; this EDA runs $ver"
    $KUBECTL get crd backends.aifabrics.eda.nokia.com >/dev/null 2>&1 \
      && echo "  AI Fabrics app (Backend): installed" \
      || { err "the AI Fabrics app (aifabrics.eda.nokia.com, Backend CRD) is not installed: install it from the EDA Store first"; rc=1; }
    $KUBECTL -n eda get nodeprofile srlinux-ghcr-26.7.1 >/dev/null 2>&1 \
      && echo "  NodeProfile srlinux-ghcr-26.7.1 in namespace eda (SR Linux 26.7.1 for the simulated switches): present" \
      || { err "NodeProfile srlinux-ghcr-26.7.1 missing in EDA namespace 'eda' (it ships with EDA 26.8)"; rc=1; }
    local app crd label
    for app in "prom exports.prom.eda.nokia.com Prometheus-Exporter" "notifiers notifiers.notifiers.eda.nokia.com Notifiers"; do
      read -r _ crd label <<<"$app"
      if $KUBECTL get crd "$crd" >/dev/null 2>&1; then
        echo "  ${label//-/ } app: installed"
      elif $KUBECTL -n eda-system get catalogs.appstore.eda.nokia.com eda-catalog-builtin-apps >/dev/null 2>&1; then
        echo "  ${label//-/ } app: not installed => installed by the deploy (catalog eda-catalog-builtin-apps)"
      else
        err "${label//-/ } app missing and catalog eda-catalog-builtin-apps not found: install it from the EDA Store"; rc=1
      fi
    done
    if [ "${NC_NEED_LICENCE:-}" = yes ]; then nc_licence_check || rc=1; fi
    cap=$($KUBECTL get nodes -o jsonpath='{range .items[*]}{.status.allocatable.cpu}{" "}{.status.allocatable.memory}{"\n"}{end}' 2>/dev/null \
      | python3 -c '
import sys
cpu = mem = 0.0
for line in sys.stdin:
    c, m = line.split()
    cpu += float(c[:-1]) / 1000 if c.endswith("m") else float(c)
    units = {"Ki": 2**10, "Mi": 2**20, "Gi": 2**30, "Ti": 2**40, "K": 1e3, "M": 1e6, "G": 1e9}
    u = next((k for k in units if m.endswith(k)), "")
    mem += float(m[:len(m) - len(u)]) * units.get(u, 1) / 2**30
print(f"{cpu:.0f} {mem:.0f}")' 2>/dev/null)
    if [ -n "$cap" ]; then
      read -r c m <<<"$cap"
      echo "  cluster capacity: $c CPU / $m GiB allocatable in total (the lab requests about $NC_NEED_CPU CPU / $NC_NEED_GIB GiB, on top of EDA itself)"
      [ "$c" -ge $((NC_NEED_CPU * 2)) ] && [ "$m" -ge $((NC_NEED_GIB * 2)) ] \
        || warn "the cluster looks small for EDA + this lab: simulator pods may stay Pending"
    fi
  fi
  n=$($KUBECTL -n "$NC_NS" get toponodes --no-headers 2>/dev/null | wc -l)
  if [ "$n" -gt 0 ]; then
    echo "  namespace $NC_NS: exists with $n switches$([ "$verb" = deploy ] && echo ' => the deploy updates it in place')"
  else
    echo "  namespace $NC_NS: $([ "$verb" = deploy ] && echo 'not there yet => built from scratch' || echo 'no lab found')"
  fi
  [ $rc -eq 0 ] || err "preflight failed: nothing was changed"
  return $rc
}

nc_confirm(){  # nc_confirm <what> [yes]
  if [ "$NC_MODE" = pinned ] || [ -n "${2:-}" ]; then return 0; fi
  local a
  nc_ask a "$1 Continue? (yes/no)" "no" || return 1
  [[ "$a" =~ ^[yY] ]] || { echo "stopped: nothing was changed"; return 1; }
}

nc_connect(){  # nc_connect deploy|destroy [yes]: settle the connection, preflight, confirm
  # pinned = a dispatcher (EDA_CLUSTER), or KUBECTL AND EDA_URL both given; a stray KUBECTL alone stays interactive
  if [ -n "${EDA_CLUSTER:-}" ] || { [ -n "$NC_CALLER_KUBECTL" ] && [ -n "${EDA_URL:-}" ]; }; then
    nc_connect_pinned || return 1
  else
    nc_connect_interactive || return 1
  fi
  export KUBECTL EDA_URL EDA_ADMIN_USER EDA_ADMIN_PASSWORD NEOCLOUD_LICENSE
  nc_preflight "$1" || return 1
  if [ "$1" = deploy ]; then
    nc_confirm "This builds the neocloud demo in EDA namespace '$NC_NS' on $EDA_URL (28 simulated switches, 10 simulated hosts, a Grafana dashboard; 8 to 10 minutes from scratch)." "${2:-}"
  else
    nc_confirm "This DELETES EDA namespace '$NC_NS' on $EDA_URL with everything in it, plus the demo's EDA user 'terraform', GUI dashboard, Grafana proxy and Exports." "${2:-}"
  fi
}
