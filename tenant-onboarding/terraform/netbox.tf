# ---- IPAM: record the tenant's subnet in the lab's NetBox (the EDA NetBox app already syncs EDA's inventory there) --
# The VLAN ID stays the fixed tenant VLAN (hosts.sh + the GPU server trunks know it); NetBox is the record of the
# tenant's address block (tenant neocloud, description = which VPC uses it). destroy removes the record.
data "netbox_tenant" "neocloud" {
  count = var.netbox ? 1 : 0
  slug  = "neocloud"
}

resource "netbox_prefix" "tenant" {
  count       = var.netbox ? 1 : 0
  prefix      = var.subnet
  status      = "active"
  tenant_id   = data.netbox_tenant.neocloud[0].id
  description = "${var.tenant}: EDA VirtualNetwork ${var.tenant}, VLAN ${var.vlan} (Terraform)"
}
