# ---- what the audience reads -----------------------------------------------------------------------------------------
output "gpus_booked" {
  description = "GPU ports booked for the tenant (Interface = rail-leaf-<GPU>-ethernet-1-<server>)"
  value = [for n in local.booked : "GPU ${local.gpu_ports[n].gpu} of GPU Server ${local.gpu_ports[n].server} (${n})"]
}

output "gpus_free_before" {
  value = length(local.free)
}

output "eda_dry_run" {
  description = "terraform plan: EDA dry run of the exact change"
  value = local.preview ? {
    transaction      = local.dry_run_id
    success          = data.core-v1_transaction_summary_result.dry_run[0].success
    switches_changed = length(local.dry_nodes)
    switches         = local.dry_nodes
    errors           = data.core-v1_transaction_execution_result.dry_run[0].general_errors
  } : null
}

output "eda_config_preview" {
  description = "terraform plan: SR Linux lines added / removed on 2 sample switches (the first booked GPU's rail leaf + a frontend leaf of the GPU servers); every switch = GUI Transactions → the dry run"
  value = local.preview ? {
    for n in local.preview_nodes : n => {
      lines_added   = length(local.dry_diff[n].added)
      lines_removed = length(local.dry_diff[n].removed)
      added         = slice(sort(local.dry_diff[n].added), 0, min(25, length(local.dry_diff[n].added)))
    }
  } : null
}

output "eda_transaction" {
  description = "terraform apply (commit): the EDA transactions, network + one booking per GPU (destroy: GPU releases, then the network revert)"
  value = var.delivery == "commit" ? {
    network = { id = core-v1_transaction.network[0].id, success = data.core-v1_transaction_summary_result.network[0].success, user = data.core-v1_transaction_summary_result.network[0].username }
    gpus    = { for n, t in restapi_object.gpu_booking : "GPU ${local.gpu_ports[n].gpu} of GPU Server ${local.gpu_ports[n].server}" => tonumber(t.id) }
  } : null
}

output "eda_merge_request" {
  description = "terraform apply (merge-request): review + merge it in the EDA GUI (Merge Requests)"
  value       = var.delivery == "merge-request" ? "merge request ${restapi_object.merge_request[0].id}: EDA GUI → Merge Requests → ${restapi_object.merge_request[0].id} → Diffs → Merge" : null
}

output "checks" {
  description = "EDA ping workflows after the change (from the switches the target is attached to)"
  value = local.check_on ? {
    for k, p in data.oam-v1_ping.check : k => {
      what    = local.pings[k].what
      address = local.pings[k].address
      result  = try(p.status.result, "pending")
      summary = try(p.status.summary, "")
      pass    = contains(["Success", "PartialSuccess"], try(p.status.result, "")) # anycast gateway: 1 of 2 leaves answers
    }
  } : null
}

output "tenant_login" {
  description = "EDA login for the tenant (password: terraform output -raw tenant_password)"
  value       = var.tenant_login ? "EDA GUI ${var.eda_url} · user ${var.tenant} · group ${var.tenant} · roles neocloud:${var.tenant}-viewer + ${var.tenant}-gui" : null
}

output "tenant_password" {
  value     = var.tenant_login ? random_password.tenant[0].result : null
  sensitive = true
}

output "netbox_prefix" {
  value = var.netbox ? "NetBox ${var.netbox_url}/ipam/prefixes/${netbox_prefix.tenant[0].id}/ (${var.subnet}, tenant neocloud)" : null
}
