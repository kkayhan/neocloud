# ---- after the change: EDA's own check workflows, results back in Terraform (commit mode) ----------------------------
# EDA Ping workflow = a ping sourced from the switch inside the tenant's VRF. The VRF gateway is anycast (same .1 on
# every leaf) ⇒ a host answers its OWN leaf ⇒ ping only from the switches the target host is attached to (measured
# 2026-11-12: leaf-7 → dc2-host-1 Failed, dc2-border-leaf-1 → dc2-host-1 Success); both switches of the host's ESI-LAG.
# ⇒ PASS = at least one of the two leaves gets the answer (result Success or PartialSuccess "1/2"), measured warm
# 2026-11-12. Cold (pings right after the commit, switches still learning the new host) = 0/2 ⇒ 30 s settle first.
# Workflow objects cannot be updated ⇒ re-created (new name) whenever the change changes.
locals {
  run       = substr(sha256("${terraform_data.change_network.output}${terraform_data.change_gpus.output}"), 0, 8)
  check_on  = var.delivery == "commit" && var.validate
  first_gpu = length(local.booked) > 0 ? local.booked[0] : ""
  # GPU pod frontend address = <subnet>.(100 + 10 × server + GPU), the leaf pair of the GPU servers = leaf-7/8 (hosts.sh)
  first_gpu_ip = local.first_gpu == "" ? "" : cidrhost(var.subnet, 100 + 10 * local.gpu_ports[local.first_gpu].server + local.gpu_ports[local.first_gpu].gpu)
  # the GPU pods are the tenant's only frontend hosts since 2026-11-16 (dc2-host-2 removed, owner Q1 A)
  pings = local.first_gpu == "" ? {} : { "gpu-pod" = { nodes = ["leaf-7", "leaf-8"], address = local.first_gpu_ip, what = "frontend leg of the first booked GPU pod" } }
}

resource "time_sleep" "settle" {
  count           = local.check_on ? 1 : 0
  create_duration = "30s"
  triggers        = { run = local.run }
  depends_on      = [terraform_data.hosts_book]
}

resource "oam-v1_ping" "check" {
  for_each = local.check_on ? local.pings : {}
  metadata = { name = "${var.tenant}-${each.key}-${local.run}", namespace = "neocloud" }
  spec = {
    nodes            = each.value.nodes
    network_instance = "${var.tenant}-vrf"
    address          = each.value.address
    count            = 3
    timeout_seconds  = 10
  }
  depends_on = [time_sleep.settle]
  lifecycle {
    replace_triggered_by = [terraform_data.change_network, terraform_data.change_gpus]
    # oam-v1 1.1.0 plans its server-filled fields (status, alarms, node_selectors…) as unknown on EVERY plan ⇒ an
    # in-place update the resource does not support ⇒ ignore all; a new change still re-creates it (replace_triggered_by)
    ignore_changes = all
  }
}

# a ping workflow takes a few seconds; read the result afterwards
resource "time_sleep" "checks" {
  count           = local.check_on ? 1 : 0
  create_duration = "25s"
  triggers        = { run = local.run }
  depends_on      = [oam-v1_ping.check]
}

data "oam-v1_ping" "check" {
  for_each   = local.check_on ? local.pings : {}
  namespace  = "neocloud"
  name       = oam-v1_ping.check[each.key].metadata.name
  depends_on = [time_sleep.checks]
}
