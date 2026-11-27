# ---- the knobs of the demo (owner 2026-11-12) --------------------------------------------------------------------
variable "gpus" {
  description = "How many GPUs tenant2 gets. Terraform finds free (untagged) GPU ports and books that many."
  type        = number
  default     = 4
  validation {
    condition     = var.gpus >= 0 && var.gpus <= 32 && floor(var.gpus) == var.gpus
    error_message = "gpus must be a whole number between 0 and 32."
  }
}

variable "internet" {
  description = "true = tenant2 also gets internet (0/0 leaked in, its subnet announced to the border routers)."
  type        = bool
  default     = false
}

variable "delivery" {
  description = "commit = EDA dry run at plan, one transaction at apply (destroy = revert). merge-request = dry run at plan, a merge request at apply that a human merges in the EDA GUI."
  type        = string
  default     = "commit"
  validation {
    condition     = contains(["commit", "merge-request"], var.delivery)
    error_message = "delivery must be commit or merge-request."
  }
}

variable "tenant_login" {
  description = "Create an EDA login for the tenant (user tenant2, read-only on namespace neocloud)."
  type        = bool
  default     = true
}

variable "netbox" {
  description = "Record the tenant's subnet in the lab's NetBox (IPAM). OFF by default since 2026-11-16 (owner Q1 C: NetBox parked, not deployed); true needs deploy.sh --phase netbox + setup.sh."
  type        = bool
  default     = false
}

variable "validate" {
  description = "Run EDA ping workflows after the change and report the results (commit mode)."
  type        = bool
  default     = true
}

variable "configure_hosts" {
  description = "Server side: run hosts.sh for the GPU servers whose GPUs are booked/released (commit mode)."
  type        = bool
  default     = true
}

# ---- the tenant -------------------------------------------------------------------------------------------------
# The host tooling (hosts.sh) and the cabling labels know tenant2 as VLAN 102 / 200.200.200.0/24. The tenant name is
# also the GPU booking label value (backend=<tenant>) and the frontend cabling label value (frontend=<tenant>).
variable "tenant" {
  type    = string
  default = "tenant2"
}
variable "subnet" {
  type    = string
  default = "200.200.200.0/24"
}
variable "vlan" {
  type    = number
  default = 102
}

# ---- where EDA and NetBox are -----------------------------------------------------------------------------------
variable "eda_url" {
  description = "EDA URL; setup.sh writes it into terraform.tfvars from the connection deploy.sh saved."
  type        = string
  default     = ""
  validation {
    condition     = can(regex("^https?://", var.eda_url))
    error_message = "eda_url is empty: run bash setup.sh first (after ./deploy.sh), or pass -var eda_url=https://<EDA address>."
  }
}
variable "eda_username" {
  description = "EDA user Terraform works as (its changes show under this name in Transactions). User terraform = group system-administrator, created by deploy.sh phase users (owner Q2 A, 2026-11-12)."
  type        = string
  default     = "terraform"
}
variable "eda_password" {
  type      = string
  default   = "terraform"
  sensitive = true
}
variable "keycloak_admin_username" {
  description = "Keycloak master admin: used once per run to read the eda client secret (same as Nokia's providers do)."
  type        = string
  default     = "admin"
}
variable "keycloak_admin_password" {
  type      = string
  default   = "admin"
  sensitive = true
}
variable "netbox_url" {
  type    = string
  default = "http://127.0.0.1:9506"
}
variable "netbox_token" {
  description = "NetBox API token (setup.sh writes it from the k8s secret neocloud/netbox-api-token)."
  type        = string
  default     = ""
  sensitive   = true
}
