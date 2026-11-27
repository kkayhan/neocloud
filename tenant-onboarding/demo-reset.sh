#!/usr/bin/env bash
# neocloud — reset the tenant onboarding demo to the baseline (tenant1 only, 20 free GPUs), whatever made tenant2:
#   1 Terraform state present        ⇒ terraform destroy (GPU releases + EDA revert of the network transaction)
#   2 tenant2 objects still present ⇒ GUI act or a merged merge request: delete tenant2's own objects, put the shared
#     objects back to the repo baseline (backend.yaml, leaking.yaml, edge.yaml), remove the backend=tenant2 GPU labels
#   3 the tenant login (cluster-wide EDA user / group / cluster role; the namespace role is deleted with step 2)
#   4 server side: hosts.sh parks the released GPU pods · brownfield folder forgets tenant1 (never destroys it)
#   bash tenant-onboarding/demo-reset.sh                 reset the demo on a running lab
#   bash tenant-onboarding/demo-reset.sh --lab-destroy   (destroy.sh) the namespace is about to go: only drop the local Terraform
#                                               state + the cluster-wide tenant login; nothing reverted in the fabric
# Step 2 uses kubectl (Kubernetes-API transactions: fine for a reset, they skip EDA pipelines, none exist in neocloud).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib/connect.sh"; nc_resolve
K="$KUBECTL"; NS=neocloud; M="$HERE/../manifests"
LAB_DESTROY=no; [ "${1:-}" = --lab-destroy ] && LAB_DESTROY=yes

echo "== 1 Terraform"
if [ $LAB_DESTROY = yes ]; then
  rm -f "$HERE/terraform/terraform.tfstate" "$HERE/terraform/terraform.tfstate.backup"; echo "   local state dropped (lab destroy)"
elif [ -n "$(terraform -chdir="$HERE/terraform" state list 2>/dev/null | grep -v '^data\.')" ]; then
  terraform -chdir="$HERE/terraform" destroy -auto-approve -input=false -no-color | grep -E 'Destroy complete|Error|release of|revert \(' || true
else
  echo "   no Terraform state"
fi

echo "== 2 leftover tenant2 objects (GUI act / merged merge request)"
if [ $LAB_DESTROY = yes ]; then echo "   skipped (lab destroy)"
# any tenant2 trace counts: a half-done GUI act can leave only the PrefixSet/Policies (found 2026-11-16: reset said "none")
elif $K -n $NS get virtualnetworks.services.eda.nokia.com tenant2 >/dev/null 2>&1 || \
   $K -n $NS get prefixsets.routingpolicies.eda.nokia.com tenant2-subnet >/dev/null 2>&1 || \
   $K -n $NS get policys.routingpolicies.eda.nokia.com leak-tenant2-export >/dev/null 2>&1 || \
   $K -n $NS get policys.routingpolicies.eda.nokia.com leak-tenant2-import >/dev/null 2>&1 || \
   [ "$($K -n $NS get backends.aifabrics.eda.nokia.com gpu-backend -o jsonpath='{.spec.gpuIsolationGroups[*].name}' 2>/dev/null)" != tenant1 ] || \
   $K -n $NS get policys.routingpolicies.eda.nokia.com leak-shared-import leak-internet-import -o jsonpath='{.items[*].spec.statements[*].name}' 2>/dev/null | grep -qw tenant2 || \
   [ -n "$($K -n $NS get interfaces.interfaces.eda.nokia.com -l role=gpu,backend=tenant2 -o name 2>/dev/null)" ]; then
  $K -n $NS delete virtualnetworks.services.eda.nokia.com tenant2 --ignore-not-found
  $K apply -f "$M/backend.yaml" -f "$M/leaking.yaml" -f "$M/edge.yaml" 2>&1 | grep -vE 'unchanged|^Warning: resource .* last-applied-configuration'
  $K -n $NS delete policys.routingpolicies.eda.nokia.com leak-tenant2-export leak-tenant2-import --ignore-not-found
  $K -n $NS delete prefixsets.routingpolicies.eda.nokia.com tenant2-subnet --ignore-not-found
  for i in $($K -n $NS get interfaces.interfaces.eda.nokia.com -l role=gpu,backend=tenant2 -o name); do $K -n $NS label "$i" backend-; done
else
  echo "   none"
fi

echo "== 3 tenant login (EDA user / group / roles tenant2)"
python3 -I - "$HERE/../lib" <<'PY'
import os, sys
sys.path.insert(0, sys.argv[1]); import eda_auth as ea
B = ea.eda_url()
# admin rights: the EDA admin when its password is given (destroy.sh), else user terraform (group system-administrator,
# created by deploy phase users) so a later reset needs no password
user, pw = ("terraform", "terraform") if "EDA_ADMIN_PASSWORD" not in os.environ else (os.environ.get("EDA_ADMIN_USER", "admin"), os.environ["EDA_ADMIN_PASSWORD"])
st, t = ea.user_token(B, user, pw)
if st != 200:
    st, t = ea.user_token(B, "admin", "admin")
if st != 200:
    sys.exit(f"   EDA login failed (as {user}, then admin): HTTP {st} {t}; set EDA_ADMIN_PASSWORD")
H = {"Authorization": "Bearer " + t}
def call(m, path):
    st, b = ea.http(m, B + path, H)
    import json
    return st, (json.loads(b) if st == 200 and b.strip() else None)
for u in call("GET", "/core/admin/users")[1] or []:
    if u.get("username") == "tenant2": print("   user tenant2:", call("DELETE", f"/core/admin/users/{u['uuid']}")[0])
for g in call("GET", "/core/admin/groups")[1] or []:
    if g.get("name") == "tenant2": print("   group tenant2:", call("DELETE", f"/core/admin/groups/{g['uuid']}")[0])
for path in ("/core/admin/roles/tenant2-gui", "/core/admin/namespaces/neocloud/roles/tenant2-viewer"):
    if call("GET", path)[0] == 200: print("  ", path.rsplit("/", 1)[1] + ":", call("DELETE", path)[0])
print("   done")
PY

echo "== 4 server side + brownfield"
[ $LAB_DESTROY = yes ] || bash "$HERE/../hosts.sh" gpu-server-1 gpu-server-2 gpu-server-3 gpu-server-4 | grep -cE 'free \(no backend label\)' | sed 's/^/   GPU pods parked: /'
bash "$HERE/brownfield/forget.sh" | sed 's/^/   /'
[ $LAB_DESTROY = yes ] && exit 0
echo "== baseline: $($K -n $NS get virtualnetworks.services.eda.nokia.com --no-headers | awk '{print $1}' | tr '\n' ' ')· Backend groups $($K -n $NS get backends.aifabrics.eda.nokia.com gpu-backend -o jsonpath='{.spec.gpuIsolationGroups[*].name}') · tenant2 GPUs $($K -n $NS get interfaces.interfaces.eda.nokia.com -l role=gpu,backend=tenant2 --no-headers 2>/dev/null | wc -l)"
