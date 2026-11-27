# ---- the change: EDA transaction items = everything onboarding touches, in TWO groups -------------------------------
#   network = the tenant's VPC + the edits of the shared objects (stable: a GPU resize does not touch it)
#     create  the tenant's own objects   ../templates/tenant.yaml.tftpl (same template as the GUI files, render-gui.py)
#     patch   the shared objects         Backend gpu-backend (+ isolation group), Policy leak-shared-import (+ statement);
#                                        internet: Policy leak-internet-import (+ statement), PrefixSet internet-public (+ subnet)
#   gpus    = the GPU bookings: label backend=<tenant> on each booked GPU rail Interface, ONE transaction PER GPU (release =
#             a transaction removing the label) ⇒ a resize touches only the GPUs that change (deliver.tf)
# A JSON patch only ADDS to a shared object; EDA's revert of the transaction (terraform destroy / GUI Revert) puts the
# object back exactly as it was ⇒ Terraform never owns the shared objects (destroying them would break tenant1).
locals {
  prefix_len = split("/", var.subnet)[1]
  gateway    = "${cidrhost(var.subnet, 1)}/${local.prefix_len}"
  rendered = templatefile("${path.module}/../templates/tenant.yaml.tftpl", {
    tenant = var.tenant, subnet = var.subnet, prefix_len = local.prefix_len, gateway = local.gateway,
    vlan = var.vlan, internet = var.internet
  })
  own = [for d in split("\n---\n", local.rendered) : yamldecode(d) if trimspace(replace(d, "/(?m)^#.*$/", "")) != ""]

  patch = {
    backend = { gvk = { group = "aifabrics.eda.nokia.com", version = "v1", kind = "Backend" }, name = "gpu-backend" }
    policy  = { gvk = { group = "routingpolicies.eda.nokia.com", version = "v1", kind = "Policy" } }
    pset    = { gvk = { group = "routingpolicies.eda.nokia.com", version = "v1", kind = "PrefixSet" } }
    iface   = { gvk = { group = "interfaces.eda.nokia.com", version = "v1", kind = "Interface" } }
  }
  statement = { name = var.tenant, match = { prefixSet = "${var.tenant}-subnet" }, action = { policyResult = "Accept" } }

  # every item JSON-encoded on its own (the items have different shapes; a Terraform list would need one type)
  items_network = concat(
    [for o in local.own : jsonencode({ type = { create = { value = o } } })],
    [jsonencode({ type = { patch = {
      target   = merge(local.patch.backend, { namespace = "neocloud" })
      patchOps = [{ op = "add", path = "/spec/gpuIsolationGroups/-", value = { name = var.tenant, interfaceSelectors = ["role=gpu,backend=${var.tenant}"] } }]
    } } })],
    [jsonencode({ type = { patch = {
      target   = merge(local.patch.policy, { name = "leak-shared-import", namespace = "neocloud" })
      patchOps = [{ op = "add", path = "/spec/statements/-", value = local.statement }]
    } } })],
    var.internet ? [
      jsonencode({ type = { patch = {
        target   = merge(local.patch.policy, { name = "leak-internet-import", namespace = "neocloud" })
        patchOps = [{ op = "add", path = "/spec/statements/-", value = local.statement }]
      } } }),
      jsonencode({ type = { patch = {
        target   = merge(local.patch.pset, { name = "internet-public", namespace = "neocloud" })
        patchOps = [{ op = "add", path = "/spec/prefixes/-", value = { prefix = var.subnet, startRange = tonumber(local.prefix_len), endRange = tonumber(local.prefix_len) } }]
      } } }),
    ] : [],
  )
  items_gpu = { for n in local.booked : n => jsonencode({ type = { patch = {
    target   = merge(local.patch.iface, { name = n, namespace = "neocloud" })
    patchOps = [{ op = "add", path = "/metadata/labels/backend", value = var.tenant }]
  } } }) }
  new_gpus = [for n in local.booked : n if !contains(local.mine, n)]

  # camelCase JSON = what EDA's REST API takes (plan-time dry run, merge request)
  json = merge({
    network  = "[${join(",", local.items_network)}]"
    all      = "[${join(",", concat(local.items_network, values(local.items_gpu)))}]"
    gpus_new = "[${join(",", [for n in local.new_gpus : local.items_gpu[n]])}]"
  }, { for n, j in local.items_gpu : "gpu:${n}" => "[${j}]" })

  # snake_case for core-v1_transaction: the provider converts every key snake→camel, a camelCase key would arrive
  # lowercased (interfaceSelectors → interfaceselectors, rejected by EDA: measured 2026-11-12). One regex pass inserts
  # "_" before the LAST remaining hump of every JSON KEY ("…":, greedy prefix); 6 passes cover the longest key.
  # Values stay untouched (a key is the only string followed by ":"), e.g. the patch path /spec/gpuIsolationGroups/-.
  hump  = "/\"([A-Za-z0-9_]*[a-z0-9])([A-Z])([A-Za-z0-9_]*)\":/"
  snake = "\"$${1}_$${2}$${3}\":"
  crs_snake = {
    for k, j in local.json : k => jsondecode(
      replace(replace(replace(replace(replace(replace(j, local.hump, local.snake), local.hump, local.snake),
      local.hump, local.snake), local.hump, local.snake), local.hump, local.snake), local.hump, local.snake)
    )
  }

  description = "Onboard ${var.tenant} (Terraform): ${var.subnet} VLAN ${var.vlan}, ${length(local.booked)} GPU(s), internet ${var.internet ? "yes" : "no"}"
  desc = {
    network = "Onboard ${var.tenant} network (Terraform): ${var.subnet} VLAN ${var.vlan}, internet ${var.internet ? "yes" : "no"}"
    gpus_new = "Book ${length(local.new_gpus)} more GPU(s) for ${var.tenant} (Terraform): ${join(" ", [for n in local.new_gpus : "server${local.gpu_ports[n].server}/GPU${local.gpu_ports[n].gpu}"])}"
  }
}
