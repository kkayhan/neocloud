# EDA API token for the calls Nokia's providers do not cover (plan-time dry run, merge request, admin links).
# Same flow as the providers use internally: Keycloak master admin reads the secret of client "eda", then a password
# grant as var.eda_username. Read on every plan; a token lives long enough for one plan + apply.
locals {
  kc = "${var.eda_url}/core/httpproxy/v1/keycloak"
}

data "http" "kc_master" {
  url          = "${local.kc}/realms/master/protocol/openid-connect/token"
  method       = "POST"
  insecure     = true
  request_body = "grant_type=password&client_id=admin-cli&username=${urlencode(var.keycloak_admin_username)}&password=${urlencode(var.keycloak_admin_password)}"
  request_headers = { Content-Type = "application/x-www-form-urlencoded" }
  lifecycle {
    postcondition {
      condition     = self.status_code == 200
      error_message = "Keycloak master login failed (HTTP ${self.status_code})."
    }
  }
}

data "http" "eda_client" {
  url             = "${local.kc}/admin/realms/eda/clients?clientId=eda"
  insecure        = true
  request_headers = { Authorization = "Bearer ${jsondecode(data.http.kc_master.response_body).access_token}" }
}

data "http" "eda_client_secret" {
  url             = "${local.kc}/admin/realms/eda/clients/${jsondecode(data.http.eda_client.response_body)[0].id}/client-secret"
  insecure        = true
  request_headers = { Authorization = "Bearer ${jsondecode(data.http.kc_master.response_body).access_token}" }
}

# GOTCHA (measured 2026-11-12, EDA 26.8.2 Keycloak): concurrent password grants for the SAME user fail — 8 parallel
# logins as admin ⇒ 7 × HTTP 400 "invalid_grant: Invalid user credentials", 8 sequential ⇒ 0. Terraform starts the
# providers in parallel and every Nokia provider logs in by itself (they retry: rest_retries 3 / 5 s); ours does not
# ⇒ (1) log in only after two Nokia providers are done, (2) up to 3 attempts in sequence (attempt N+1 only if N failed).
locals {
  login_body = "grant_type=password&client_id=eda&scope=openid&client_secret=${urlencode(jsondecode(data.http.eda_client_secret.response_body).value)}&username=${urlencode(var.eda_username)}&password=${urlencode(var.eda_password)}"
}

data "http" "eda_login" {
  url             = "${local.kc}/realms/eda/protocol/openid-connect/token"
  method          = "POST"
  insecure        = true
  request_body    = local.login_body
  request_headers = { Content-Type = "application/x-www-form-urlencoded" }
  depends_on      = [data.interfaces-v1_interface_list.all, data.aifabrics-v1_backend.gpu]
}

data "http" "eda_login_retry" {
  count           = data.http.eda_login.status_code == 200 ? 0 : 1
  url             = "${local.kc}/realms/eda/protocol/openid-connect/token"
  method          = "POST"
  insecure        = true
  request_body    = local.login_body
  request_headers = { Content-Type = "application/x-www-form-urlencoded" }
}

data "http" "eda_login_retry2" {
  count           = data.http.eda_login.status_code == 200 || try(data.http.eda_login_retry[0].status_code, 0) == 200 ? 0 : 1
  url             = "${local.kc}/realms/eda/protocol/openid-connect/token"
  method          = "POST"
  insecure        = true
  request_body    = local.login_body
  request_headers = { Content-Type = "application/x-www-form-urlencoded" }
  lifecycle {
    postcondition {
      condition     = self.status_code == 200
      error_message = "EDA login as ${var.eda_username} failed 3 times (HTTP ${self.status_code}): ${self.response_body}"
    }
  }
}

locals {
  eda_login_body = (data.http.eda_login.status_code == 200 ? data.http.eda_login.response_body :
    try(data.http.eda_login_retry[0].status_code, 0) == 200 ? data.http.eda_login_retry[0].response_body :
  data.http.eda_login_retry2[0].response_body)
  eda_token = sensitive(jsondecode(local.eda_login_body).access_token)
}
