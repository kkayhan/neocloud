# neocloud — onboard a tenant (tenant2) with Terraform: network, GPU booking, login, IPAM record, checks.
# Nokia's EDA providers = one per EDA app + API version (registry namespace nokia-eda); the generic providers fill the
# gaps measured on EDA 26.8.2 (plan.md § TENANT ONBOARDING DEMO + TERRAFORM): http = EDA's REST API at plan time (dry
# run) + Keycloak token, restapi = merge request + admin links, netbox = the lab's IPAM, random/time = password + waits.
terraform {
  required_version = ">= 1.9.0"
  required_providers {
    core-v1       = { source = "nokia-eda/core-v1", version = "1.3.0" }       # transactions, users, roles, results
    interfaces-v1 = { source = "nokia-eda/interfaces-v1", version = "1.1.0" } # GPU port discovery, interface check
    aifabrics-v1  = { source = "nokia-eda/aifabrics-v1", version = "1.1.0" }  # read the GPU Backend
    oam-v1        = { source = "nokia-eda/oam-v1", version = "1.1.0" }        # ping workflows (validation)
    http          = { source = "hashicorp/http", version = "3.6.3" }
    restapi       = { source = "Mastercard/restapi", version = "3.0.0" }
    netbox        = { source = "e-breuninger/netbox", version = "6.0.0" }
    random        = { source = "hashicorp/random", version = "3.9.1" }
    time          = { source = "hashicorp/time", version = "0.14.2" }
  }
}
