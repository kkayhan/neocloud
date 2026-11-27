#!/usr/bin/env bash
# neocloud brownfield demo reset: Terraform FORGETS tenant1 (state rm) — tenant1 itself is untouched.
# NEVER run terraform destroy here: it would DELETE the live tenant1 VirtualNetwork.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
terraform state rm services-v2_virtual_network.tenant_a 2>/dev/null || echo "nothing to forget"
rm -f tenant1.tf terraform.tfstate terraform.tfstate.backup
echo "brownfield reset: next demo = terraform plan -generate-config-out=tenant1.tf"
