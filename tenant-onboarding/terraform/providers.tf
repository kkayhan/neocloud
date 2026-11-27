# ---- Nokia EDA providers: each logs in to EDA's Keycloak itself (password grant as var.eda_username) -------------
locals {
  eda_common = {
    base_url                = var.eda_url
    tls_skip_verify         = true # lab: EDA's self-signed certificate
    rest_timeout            = "300s"
    username                = var.eda_username
    password                = var.eda_password
    keycloak_admin_username = var.keycloak_admin_username
    keycloak_admin_password = var.keycloak_admin_password
  }
}

# GOTCHA core-v1 1.3.0 names its login settings eda_username / eda_password / kc_username / kc_password; the app
# providers (1.1.0) call them username / password / keycloak_admin_* (terraform providers schema, 2026-11-12)
provider "core-v1" {
  base_url        = local.eda_common.base_url
  tls_skip_verify = local.eda_common.tls_skip_verify
  rest_timeout    = local.eda_common.rest_timeout
  eda_username    = local.eda_common.username
  eda_password    = local.eda_common.password
  kc_username     = local.eda_common.keycloak_admin_username
  kc_password     = local.eda_common.keycloak_admin_password
}
provider "interfaces-v1" {
  base_url                = local.eda_common.base_url
  tls_skip_verify         = local.eda_common.tls_skip_verify
  rest_timeout            = local.eda_common.rest_timeout
  username                = local.eda_common.username
  password                = local.eda_common.password
  keycloak_admin_username = local.eda_common.keycloak_admin_username
  keycloak_admin_password = local.eda_common.keycloak_admin_password
}
provider "aifabrics-v1" {
  base_url                = local.eda_common.base_url
  tls_skip_verify         = local.eda_common.tls_skip_verify
  rest_timeout            = local.eda_common.rest_timeout
  username                = local.eda_common.username
  password                = local.eda_common.password
  keycloak_admin_username = local.eda_common.keycloak_admin_username
  keycloak_admin_password = local.eda_common.keycloak_admin_password
}
provider "oam-v1" {
  base_url                = local.eda_common.base_url
  tls_skip_verify         = local.eda_common.tls_skip_verify
  rest_timeout            = local.eda_common.rest_timeout
  username                = local.eda_common.username
  password                = local.eda_common.password
  keycloak_admin_username = local.eda_common.keycloak_admin_username
  keycloak_admin_password = local.eda_common.keycloak_admin_password
}

# ---- EDA REST API directly (merge requests, admin links): bearer token from the auth.tf data sources -------------
provider "restapi" {
  uri                  = var.eda_url
  insecure             = true
  write_returns_object = true
  headers = {
    Authorization = "Bearer ${local.eda_token}"
    Content-Type  = "application/json"
  }
}

# GOTCHA (2026-11-16): Terraform configures this provider even when var.netbox = false (no NetBox resource in use)
# and e-breuninger/netbox 6.0.0 rejects an empty token ("Missing NetBox API token") ⇒ placeholder while NetBox is parked.
provider "netbox" {
  server_url         = var.netbox_url
  api_token          = var.netbox ? var.netbox_token : "netbox-parked-not-used"
  skip_version_check = true
}
