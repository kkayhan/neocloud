# neocloud — brownfield: bring the EXISTING tenant1 VirtualNetwork under Terraform without touching the network.
#   terraform init · terraform plan -generate-config-out=tenant1.tf (Terraform writes the HCL from live EDA) ·
#   terraform apply (adopts it: 0 changes) · edit tenant1.tf (e.g. a description) · terraform plan = field-level diff
# Typed resources (services-v2_virtual_network) = the declarative style of Nokia's docs; tenant2 uses transactions.
terraform {
  required_version = ">= 1.9.0"
  required_providers {
    services-v2 = { source = "nokia-eda/services-v2", version = "1.1.0" }
  }
}

variable "eda_url" {
  description = "EDA URL; ../terraform/setup.sh writes it into terraform.tfvars here."
  type        = string
}

# logs in as EDA user terraform (group system-administrator, created by the lab deploy), like ../terraform does
provider "services-v2" {
  base_url        = var.eda_url
  tls_skip_verify = true
  rest_timeout    = "300s"
  username        = "terraform"
  password        = "terraform"
}

import {
  to = services-v2_virtual_network.tenant_a
  id = "neocloud/tenant1"
}
