# ---- tenant self-service: an EDA login for the tenant ------------------------------------------------------------------
# user tenant2, group tenant2, role neocloud:tenant2-viewer (read every resource of namespace neocloud) + cluster role
# tenant2-gui (read the GUI routes and EDB tables, so the login can open the EDA GUI).
# LIMIT (EDA RBAC): rules are per resource TYPE and namespace, not per object ⇒ the tenant can READ the other tenant's
# objects in the same namespace. Hard isolation in EDA = one namespace per tenant (not this lab's design).
# Nokia core-v1 creates role / group / user; the LINKS are REST calls (measured 2026-11-12: EDA refuses roles on group
# create, the provider never sends roles on update, user groups + password are not applied) ⇒ REST calls
# (restapi_object PUTs; the roles list = a curl call, see below).
resource "random_password" "tenant" {
  count            = var.tenant_login ? 1 : 0
  length           = 16
  special          = true
  override_special = "!#%+-_"
}

# created AFTER the network transaction: EDA bundles transactions posted at the same moment, and a bundled network
# transaction could not be reverted by terraform destroy (CannotRevertBundledTransaction, measured 2026-11-12)
resource "core-v1_auth_role" "tenant_viewer" {
  count       = var.tenant_login ? 1 : 0
  depends_on  = [data.core-v1_transaction_summary_result.network]
  name        = "${var.tenant}-viewer"
  namespace   = "neocloud"
  description = "${var.tenant}: read-only on namespace neocloud (Terraform)"
  resource_rules = [{ api_groups = ["*"], resources = ["*"], permissions = "read" }]
}

resource "core-v1_cluster_auth_role" "tenant_gui" {
  count       = var.tenant_login ? 1 : 0
  depends_on  = [data.core-v1_transaction_summary_result.network]
  name        = "${var.tenant}-gui"
  description = "${var.tenant}: open the EDA GUI and read state tables (Terraform)"
  table_rules = [{ path = ".**", permissions = "read" }]
  url_rules   = [{ path = "/**", permissions = "read" }]
}

resource "core-v1_auth_user_group" "tenant" {
  count       = var.tenant_login ? 1 : 0
  name        = var.tenant
  description = "Users of ${var.tenant} (Terraform)"
  # destroy order: the group BEFORE its roles (EDA 409 RoleReferencedByGroup when a role is deleted first, 2026-11-12)
  depends_on = [core-v1_auth_role.tenant_viewer, core-v1_cluster_auth_role.tenant_gui]
}

resource "core-v1_auth_user" "tenant" {
  count      = var.tenant_login ? 1 : 0
  username   = var.tenant
  first_name = var.tenant
  last_name  = "operator"
  email      = "${var.tenant}@example.com"
  enabled    = true # EDA default = disabled (measured 2026-11-12)
}

# group → roles: EDA takes ONLY PUT /core/admin/groups/{uuid}/roles with a JSON ARRAY (a full group PUT with roles =
# 200 but ignored, measured 2026-11-12); restapi_object only sends JSON objects ⇒ one curl call, run by Terraform.
resource "terraform_data" "tenant_group_roles" {
  count            = var.tenant_login ? 1 : 0
  triggers_replace = [core-v1_auth_user_group.tenant[0].uuid, core-v1_auth_role.tenant_viewer[0].name, core-v1_cluster_auth_role.tenant_gui[0].name]
  provisioner "local-exec" {
    command = "curl -sfk -o /dev/null -X PUT -H \"Authorization: Bearer $EDA_TOKEN\" -H 'Content-Type: application/json' -d '${jsonencode(["neocloud:${core-v1_auth_role.tenant_viewer[0].name}", core-v1_cluster_auth_role.tenant_gui[0].name])}' ${var.eda_url}/core/admin/groups/${core-v1_auth_user_group.tenant[0].uuid}/roles && echo 'group ${var.tenant}: roles set'"
    environment = { EDA_TOKEN = local.eda_token }
  }
}

# user → group
resource "restapi_object" "tenant_membership" {
  count                     = var.tenant_login ? 1 : 0
  path                      = "/core/admin/groups/${core-v1_auth_user_group.tenant[0].uuid}/users/${core-v1_auth_user.tenant[0].uuid}"
  object_id                 = "member"
  create_method             = "PUT"
  create_path               = "/core/admin/groups/${core-v1_auth_user_group.tenant[0].uuid}/users/${core-v1_auth_user.tenant[0].uuid}"
  read_path                 = "/core/admin/groups/${core-v1_auth_user_group.tenant[0].uuid}"
  destroy_method            = "DELETE"
  destroy_path              = "/core/admin/groups/${core-v1_auth_user_group.tenant[0].uuid}/users/${core-v1_auth_user.tenant[0].uuid}"
  data                      = jsonencode({})
  ignore_all_server_changes = true
}

# user → password (output tenant_login shows it)
resource "restapi_object" "tenant_password" {
  count                     = var.tenant_login ? 1 : 0
  path                      = "/core/admin/users/${core-v1_auth_user.tenant[0].uuid}/resetpassword"
  object_id                 = "password"
  create_method             = "PUT"
  create_path               = "/core/admin/users/${core-v1_auth_user.tenant[0].uuid}/resetpassword"
  read_path                 = "/core/admin/users/${core-v1_auth_user.tenant[0].uuid}"
  update_method             = "PUT"
  destroy_method            = "GET"
  destroy_path              = "/core/admin/users/${core-v1_auth_user.tenant[0].uuid}"
  data                      = jsonencode({ value = random_password.tenant[0].result, temporary = false })
  ignore_all_server_changes = true
}
