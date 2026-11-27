#!/usr/bin/env bash
# neocloud tenant2 Terraform: one-time setup after every lab deploy — writes terraform.tfvars here and in ../brownfield
# (git-ignored; the EDA address deploy.sh saved, plus the NetBox URL + token when NetBox runs) and runs terraform init
# in both folders. NetBox is parked since 2026-11-16 (owner Q1 C): its URL + token are written only when NetBox runs
# (deploy.sh --phase netbox); use it with -var netbox=true.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ../../lib/connect.sh; nc_resolve
[ -n "${EDA_URL:-}" ] || { echo "EDA address unknown: run ./deploy.sh first (it saves the connection) or set EDA_URL" >&2; exit 1; }
command -v terraform >/dev/null || { echo "terraform is not installed (1.9 or newer: https://developer.hashicorp.com/terraform/install)" >&2; exit 1; }
tok=$($KUBECTL -n neocloud get secret netbox-api-token -o jsonpath='{.data.apiToken}' 2>/dev/null | base64 -d 2>/dev/null || true)
# the address a browser uses (output netbox_prefix is a link): Kind port mapping 9506 on the EDA host
NETBOX_URL="${NETBOX_URL:-http://$(nc_host "$EDA_URL"):9506}"
umask 077
cat > terraform.tfvars <<VARS
# written by setup.sh $(date -u +%FT%TZ) — local only (git-ignored)
eda_url      = "$EDA_URL"
$([ -n "$tok" ] && printf 'netbox_url   = "%s"\nnetbox_token = "%s"\n' "$NETBOX_URL" "$tok")
VARS
printf '# written by terraform/setup.sh %s — local only (git-ignored)\neda_url = "%s"\n' "$(date -u +%FT%TZ)" "$EDA_URL" > ../brownfield/terraform.tfvars
terraform init -input=false
terraform -chdir=../brownfield init -input=false >/dev/null && echo "brownfield: initialised"
echo "ready: terraform plan · terraform apply · terraform destroy   (knobs: -var gpus=2 -var internet=true -var delivery=merge-request)"
