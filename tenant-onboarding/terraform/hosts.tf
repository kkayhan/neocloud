# ---- server side: the booked GPUs' pods get their network (stand-in for the cloud's server/k8s tooling) ------------
# In neocloud a GPU pod = network namespace gpuG inside its GPU server sim: rail NIC = the dedicated GPU's NIC (EDA /64),
# frontend leg = macvlan on the tenant VLAN of the server trunk (lightweight pod model, owner Q2b A 2026-11-12).
# hosts.sh reads the GPU labels + /64s from EDA and (re)configures the pods of the listed servers.
locals {
  hosts_sh = abspath("${path.module}/../../hosts.sh")
  # every GPU server, not only the booked ones: a resize or a release also frees GPUs on servers no longer booked
  all_gpu_servers = sort(distinct([for n, p in local.gpu_ports : "gpu-server-${p.server}"]))
}

# after the commit: configure the GPU pods (booked ones get their tenant network, released ones are parked)
resource "terraform_data" "hosts_book" {
  count            = var.delivery == "commit" && var.configure_hosts ? 1 : 0
  triggers_replace = [terraform_data.change_network.output, terraform_data.change_gpus.output]
  provisioner "local-exec" {
    # GPU servers only: the other hosts are configured at deploy and never change here (re-running hosts.sh on a host
    # makes EDA's switch pings to it fail for ≈10-15 s, measured 2026-11-12 on the then dc2-host-2)
    command = "bash ${local.hosts_sh} ${join(" ", local.all_gpu_servers)}"
  }
  depends_on = [data.core-v1_transaction_summary_result.network, data.core-v1_transaction_summary_result.gpu]
}

# on destroy (and before a re-plan's revert): park the released GPUs' pods again. Destroy order = the transaction
# (EDA revert) first, this one after it, because core-v1_transaction.network depends on it.
resource "terraform_data" "hosts_release" {
  count = var.delivery == "commit" && var.configure_hosts ? 1 : 0
  input = { script = local.hosts_sh, servers = local.all_gpu_servers }
  provisioner "local-exec" {
    when    = destroy
    command = "bash ${self.input.script} ${join(" ", self.input.servers)}"
  }
}
