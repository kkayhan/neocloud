# ---- terraform apply = deliver the change, one of two ways (owner Q6 2026-11-12) ------------------------------------
# a change of the network part (subnet, internet) = a new hash ⇒ its transaction is reverted and a new one committed
# (core-v1_transaction has no in-place update: its Update sends nothing, provider v1.3.0). GPUs: one transaction each.
resource "terraform_data" "change_network" {
  input = sha256(local.json.network)
}
resource "terraform_data" "change_gpus" { # the booking as a whole (merge request, hosts, checks)
  input = sha256(join(",", sort(local.booked)))
}

# A revert must be FINISHED before the next transaction is posted (core-v1_transaction's destroy only starts it; a
# re-create right after = CrValidationErrorTypeDuplicate, measured 2026-11-12) ⇒ a companion, replaced with the network
# transaction and destroyed after it; its destroy step waits until EDA has finished the revert.
resource "terraform_data" "reverted_network" {
  count = var.delivery == "commit" ? 1 : 0
  input = { script = abspath("${path.module}/wait-reverted.sh"), what = "network ${var.tenant}" }
  lifecycle { replace_triggered_by = [terraform_data.change_network] }
  provisioner "local-exec" {
    when    = destroy
    command = "bash ${self.input.script} ${self.input.what}"
  }
}
# commit, transaction 1: the tenant network (VPC + shared-object edits), all or nothing. destroy = EDA revert.
resource "core-v1_transaction" "network" {
  count       = var.delivery == "commit" ? 1 : 0
  description = local.desc.network
  crs         = local.crs_snake.network
  dry_run     = false
  result_type = "normal"
  depends_on  = [terraform_data.gpu_capacity, terraform_data.hosts_release, terraform_data.reverted_network]
  lifecycle {
    replace_triggered_by = [terraform_data.change_network]
    precondition {
      condition     = local.dry_run_ok
      error_message = "The EDA dry run failed (transaction ${coalesce(local.dry_run_id, 0)}): nothing was committed. GUI → Transactions → ${coalesce(local.dry_run_id, 0)} shows why."
    }
  }
}

data "core-v1_transaction_summary_result" "network" {
  count             = var.delivery == "commit" ? 1 : 0
  transaction_id    = core-v1_transaction.network[0].id
  wait_for_complete = true
  lifecycle {
    postcondition {
      condition     = self.success == true
      error_message = "EDA transaction ${self.id} (network) did not succeed (state ${self.state})."
    }
  }
}

# per GPU: when a GPU is released its revert runs asynchronously ⇒ this companion's destroy waits until EDA removed the
# label, then parks that GPU's pod (hosts.sh on its server)
resource "terraform_data" "released" {
  for_each = var.delivery == "commit" ? toset(local.booked) : toset([])
  input = {
    script = abspath("${path.module}/wait-reverted.sh"), interface = each.key
    server = "gpu-server-${local.gpu_ports[each.key].server}", park = var.configure_hosts
  }
  provisioner "local-exec" {
    when    = destroy
    command = "bash ${self.input.script} gpu ${self.input.interface} ${self.input.park ? self.input.server : ""}"
  }
}

# commit, transactions 2..n: ONE booking transaction per GPU (after the network: the Backend group must exist) and, on
# release, ONE release transaction that removes the label. A resize books the new GPUs and releases the dropped ones;
# kept GPUs and the network are not touched (measured 4 → 6 GPUs: 0 lost of 599 pings on a kept GPU, frontend + rail).
# WHY REST + an explicit release instead of core-v1_transaction (destroy = revert): EDA BUNDLES transactions posted at
# the same moment (4 bookings ⇒ bundle 1196) and a bundled transaction cannot be reverted on its own
# ("CannotRevertBundledTransaction", measured 2026-11-12). A release transaction works bundled or not.
resource "restapi_object" "gpu_booking" {
  for_each                  = var.delivery == "commit" ? toset(local.booked) : toset([])
  path                      = "/core/transaction/v2"
  id_attribute              = "id"
  read_path                 = "/core/transaction/v2/result/summary/{id}"
  ignore_all_server_changes = true
  data = jsonencode({
    description = "Book GPU ${local.gpu_ports[each.key].gpu} of GPU Server ${local.gpu_ports[each.key].server} for ${var.tenant} (Terraform)"
    dryRun      = false # the v2 API requires the field (400 DryRunMissing without it)
    resultType  = "normal"
    crs         = jsondecode(local.json["gpu:${each.key}"])
  })
  destroy_method = "POST"
  destroy_path   = "/core/transaction/v2"
  destroy_data = jsonencode({
    description = "Release GPU ${local.gpu_ports[each.key].gpu} of GPU Server ${local.gpu_ports[each.key].server} from ${var.tenant} (Terraform)"
    dryRun      = false
    resultType  = "normal"
    crs = [{ type = { patch = {
      target   = merge(local.patch.iface, { name = each.key, namespace = "neocloud" })
      patchOps = [{ op = "remove", path = "/metadata/labels/backend" }]
    } } }]
  })
  depends_on = [data.core-v1_transaction_summary_result.network, terraform_data.released]
  lifecycle {
    precondition {
      condition     = local.dry_run_ok
      error_message = "The EDA dry run failed (transaction ${coalesce(local.dry_run_id, 0)}): no GPU booked."
    }
  }
}

data "core-v1_transaction_summary_result" "gpu" {
  for_each          = restapi_object.gpu_booking
  transaction_id    = tonumber(each.value.id)
  wait_for_complete = true
  lifecycle {
    postcondition {
      condition     = self.success == true
      error_message = "EDA transaction ${self.id} (GPU booking) did not succeed (state ${self.state})."
    }
  }
}

# merge-request: the whole change (network + GPUs) as ONE merge request on the EDA main branch; a human reviews (Diffs)
# and merges it in the GUI (Merge Requests). WHY restapi, not core-v1_merge_request: that provider drops every spec
# field of the CRs it sends (EDA: "spec.prefixes is required and was missing", measured 2026-11-12).
# terraform destroy = delete the merge request; once MERGED, removing the tenant = revert the merge transaction
# (GUI Transactions → Revert, or demo-reset.sh).
resource "restapi_object" "merge_request" {
  count                     = var.delivery == "merge-request" ? 1 : 0
  path                      = "/core/mergerequest/v1"
  id_attribute              = "id"
  ignore_all_server_changes = true
  data = jsonencode({
    description = local.description
    crs         = jsondecode(local.json.all)
  })
  depends_on = [terraform_data.gpu_capacity]
  lifecycle {
    replace_triggered_by = [terraform_data.change_network, terraform_data.change_gpus]
    precondition {
      condition     = local.dry_run_ok
      error_message = "The EDA dry run failed (transaction ${coalesce(local.dry_run_id, 0)}): no merge request created."
    }
  }
}
