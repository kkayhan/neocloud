# ---- terraform plan = EDA dry run of the exact change ----------------------------------------------------------------
# WHY not a core-v1_transaction with dry_run = true: its destroy = EDA revert, and EDA refuses to revert a dry run
# ("CannotRevertTransactionWithoutChanges", measured 2026-11-12) ⇒ terraform destroy would fail. So the dry run is a
# plan-time REST call (POST /core/transaction/v2, dryRun, resultType debug = keep the per-switch config) and Nokia's
# core-v1 data sources read EDA's verdict + the switch configuration diffs. Nothing to clean up: a dry run changes
# nothing. Runs while the tenant is not onboarded yet (dry run of everything) or when GPUs are added (dry run of the
# added bookings); after an apply there is nothing left to preview.
locals {
  # a release needs no preview (it is a revert of that GPU's own booking); an added GPU is dry-run on its own
  preview         = !local.onboarded || length(local.new_gpus) > 0
  preview_crs     = !local.onboarded ? local.json.all : local.json.gpus_new
  preview_desc    = !local.onboarded ? local.description : local.desc.gpus_new
}

data "http" "dry_run" {
  count    = local.preview ? 1 : 0
  url      = "${var.eda_url}/core/transaction/v2"
  method   = "POST"
  insecure = true
  request_headers = {
    Authorization = "Bearer ${local.eda_token}"
    Content-Type  = "application/json"
  }
  request_body = jsonencode({
    description = "DRY RUN: ${local.preview_desc}"
    dryRun      = true
    resultType  = "debug"
    retain      = true
    crs         = jsondecode(local.preview_crs)
  })
  lifecycle {
    postcondition {
      condition     = self.status_code == 200
      error_message = "EDA refused the dry run (HTTP ${self.status_code}): ${self.response_body}"
    }
  }
}

locals {
  dry_run_id = local.preview ? jsondecode(data.http.dry_run[0].response_body).id : null
}

data "core-v1_transaction_summary_result" "dry_run" {
  count             = local.preview ? 1 : 0
  transaction_id    = local.dry_run_id
  wait_for_complete = true
}

data "core-v1_transaction_execution_result" "dry_run" {
  count             = local.preview ? 1 : 0
  transaction_id    = local.dry_run_id
  wait_for_complete = true
  depends_on        = [data.core-v1_transaction_summary_result.dry_run]
}

locals {
  dry_nodes = local.preview ? sort([for n in coalesce(data.core-v1_transaction_execution_result.dry_run[0].nodes_with_config_changes, []) : n.name]) : []
}

# per switch: the SR Linux configuration before and after the change, as EDA would push it
data "core-v1_transaction_node_config_diff" "dry_run" {
  for_each       = toset(local.dry_nodes)
  transaction_id = local.dry_run_id
  namespace      = "neocloud"
  node           = each.key
  depends_on     = [data.core-v1_transaction_summary_result.dry_run]
}

locals {
  # lines that appear only after / only before (enough to read what changes; full diff: GUI Transactions → the id)
  dry_diff = {
    for n, d in data.core-v1_transaction_node_config_diff.dry_run : n => {
      added   = [for l in setsubtract(compact(split("\n", try(d.after.data, ""))), compact(split("\n", try(d.before.data, "")))) : trimspace(l)]
      removed = [for l in setsubtract(compact(split("\n", try(d.before.data, ""))), compact(split("\n", try(d.after.data, "")))) : trimspace(l)]
    }
  }
  preview_nodes = [for n in distinct(compact([local.first_gpu == "" ? "" : "rail-leaf-${local.gpu_ports[local.first_gpu].gpu}", "leaf-7"])) : n if contains(local.dry_nodes, n)]
  dry_run_ok    = local.preview ? data.core-v1_transaction_summary_result.dry_run[0].success == true : true
}
