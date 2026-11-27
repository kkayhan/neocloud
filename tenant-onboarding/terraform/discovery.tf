# ---- discovery: read the live fabric, decide which GPUs the tenant gets -------------------------------------------
# A GPU = one rail Interface (role=gpu, host=gpu-server-S, rail=G): GPU G of GPU Server S, leaf port rail-leaf-G e1-S.
# Free GPU = no backend label (parked port, the Backend renders nothing for it). Booking = add label backend=<tenant>.
# GOTCHA interfaces-v1 1.1.0: the data source's labelselector is sent as `labelselector`, EDA 26.8.2 only honours
# `labelSelector` ⇒ the filter is ignored (all 164 Interfaces come back, measured 2026-11-12) ⇒ we filter here.
data "interfaces-v1_interface_list" "all" {
  namespace = "neocloud"
}

data "aifabrics-v1_backend" "gpu" {
  namespace = "neocloud"
  name      = "gpu-backend"
}

locals {
  labels = { for i in data.interfaces-v1_interface_list.all.items : i.metadata.name => coalesce(i.metadata.labels, {}) }
  gpu_ports = {
    for n, l in local.labels : n => {
      server = tonumber(trimprefix(lookup(l, "host", "gpu-server-0"), "gpu-server-"))
      gpu    = tonumber(lookup(l, "rail", "0"))
      tenant = lookup(l, "backend", "")
    } if lookup(l, "role", "") == "gpu"
  }
  # stable order = GPU Server 1..4, GPU 1..8 (sort key "SS-GG|name"). Already ours first, then free ones ⇒ a re-plan
  # after the apply picks the same GPUs (they now carry our label) ⇒ no churn; gpus = 6 after 4 = same 4 + next 2 free.
  key       = { for n, p in local.gpu_ports : n => format("%02d-%02d|%s", p.server, p.gpu, n) }
  mine      = [for k in sort([for n, p in local.gpu_ports : local.key[n] if p.tenant == var.tenant]) : split("|", k)[1]]
  free      = [for k in sort([for n, p in local.gpu_ports : local.key[n] if p.tenant == ""]) : split("|", k)[1]]
  candidate = concat(local.mine, local.free)
  booked    = slice(local.candidate, 0, min(var.gpus, length(local.candidate)))
  servers   = sort(distinct([for n in local.booked : "gpu-server-${local.gpu_ports[n].server}"]))
  # the tenant is "onboarded" when its isolation group exists in the Backend (GUI act or a previous apply)
  groups    = [for g in coalesce(data.aifabrics-v1_backend.gpu.spec.gpu_isolation_groups, []) : g.name]
  onboarded = contains(local.groups, var.tenant)
}

# fail at plan, before anything is sent, when there are not enough free GPUs
resource "terraform_data" "gpu_capacity" {
  input = local.booked
  lifecycle {
    precondition {
      condition     = length(local.candidate) >= var.gpus
      error_message = "Asked for ${var.gpus} GPUs, but only ${length(local.free)} are free (+ ${length(local.mine)} already ${var.tenant}'s)."
    }
  }
}
