# Tenant onboarding: tenant2 by hand, then by Terraform

After a deploy the GPU cloud has one tenant, **tenant1**. This part of the demo onboards a second tenant,
**tenant2**, on the running fabric, twice:

1. **By hand in the EDA GUI.** You create tenant2's objects and edit a few shared ones. EDA configures every switch.
2. **Revert.** One revert of the transaction, and tenant2 is gone again, switch for switch.
3. **Terraform.** The same tenant2 comes back with `terraform apply`, with the number of GPUs as a variable.

Both ways give the same result on the switches; only the IDs EDA hands out from its pools (EVPN instance, VXLAN
VNI, route target) differ.

What tenant2 gets: the subnet **200.200.200.0/24** on VLAN 102 in data center 1, access to the shared services
(storage 10.10.10.0/24 and shared-service 10.20.20.0/24), and never a path to tenant1. Internet access is optional.
Its GPUs are booked from the free pool: GPU 5-8 of GPU Server 2 with four GPUs. Each GPU is a small VM inside its GPU
server with the GPU's own rail NIC (backend) and a leg on VLAN 102 (frontend). The GPU servers' frontend bonds already
carry tenant2's VLAN, so the GPUs attach as soon as tenant2's network exists.

## Files

| Path | What |
|---|---|
| `gui/tenant2.yaml`, `gui/tenant2-internet.yaml` | Every object of the GUI act, complete, ready to paste into the GUI's YAML editor: the new ones, the edited shared ones, and the four GPU bookings. |
| `templates/tenant.yaml.tftpl` | tenant2's own objects (Prefix Set, 2 leak Policies, Virtual Network): the one source for the GUI files (`python3 render-gui.py`) and for Terraform. |
| `terraform/` | The Terraform project. Run `bash setup.sh` in it once after every lab deploy. |
| `brownfield/` | Brings the existing tenant1 under Terraform without changing it. Reset with `bash forget.sh`. **Never** run `terraform destroy` there: it would delete tenant1. |
| `demo-reset.sh` | Back to the starting point, whichever way tenant2 was made (Terraform, the GUI, a merged merge request). |

## Act 1: the GUI

Create (paste each object from `gui/tenant2.yaml` into the form's YAML view):

1. Routing Policies → Prefix Sets → `tenant2-subnet`.
2. Routing Policies → Policies → `leak-tenant2-export` and `leak-tenant2-import`.
3. Virtual Networks → Virtual Networks → `tenant2`: router, bridge domain, anycast gateway 200.200.200.1, VLAN 102.

Edit (shared objects, one addition each):

4. Routing Policies → Policies → `leak-shared-import`: add statement `tenant2`.
5. Fabrics → AI Backends → `gpu-backend`: add isolation group `tenant2` with selector `role=gpu,backend=tenant2`.
6. Topology → Interfaces → `rail-leaf-5-ethernet-1-2` … `rail-leaf-8-ethernet-1-2`: add label `backend=tenant2`.
   This books GPU 5-8 of GPU Server 2.
7. Internet variant only (`gui/tenant2-internet.yaml`): the router also selects `fabric=frontend,role=borderleaf`,
   `leak-tenant2-import` gets statement `internet-default`, Policy `leak-internet-import` gets statement `tenant2`,
   and Prefix Set `internet-public` gets 200.200.200.0/24.

Commit everything in one go from the Basket, or object by object. On the server side, run `bash hosts.sh gpu-server-2`
from the repository root, or keep `bash hosts.sh --follow` running in a terminal: it follows every GPU label change.
To undo: Transactions → Revert (or Restore), then `bash hosts.sh gpu-server-2`.

## Act 2: Terraform

Needs Terraform 1.9 or newer. It downloads Nokia's EDA providers from the Terraform registry.

```bash
cd tenant-onboarding/terraform
bash setup.sh
```

Terraform logs in to EDA as its own user, `terraform` (password `terraform`, group system-administrator), which the
lab deploy creates. Every dry run, transaction and merge request it makes therefore shows user **terraform** in the
GUI, apart from what you click as admin.

| Command | What EDA does |
|---|---|
| `terraform plan -var gpus=4` | Finds free GPU ports and **dry-runs the exact change in EDA** (the Transactions page shows the dry run). The plan prints EDA's verdict and the SR Linux configuration lines it would add on a GPU rail leaf and on leaf-7. Nothing changes. |
| `terraform apply -var gpus=4` | Transaction "Onboard tenant2 network" (the Virtual Network and the edits of the shared objects), then one "Book GPU G of GPU Server S" transaction per GPU. Then: the GPU VMs are configured, a read-only EDA login `tenant2` is created (password: `terraform output -raw tenant_password`), and EDA ping workflows run with their results printed. |
| `terraform apply -var gpus=6` | The plan dry-runs only the two added GPUs; the apply books just those two. The network and the GPUs already booked are not touched. |
| `terraform apply -var internet=true` | Internet variant: the network transaction is reverted and committed again with internet. |
| `terraform apply -var delivery=merge-request` | Same dry run; the apply creates **one merge request** instead of committing. A human merges it in the GUI (Merge Requests → Diffs → Merge), then runs `bash ../../hosts.sh gpu-server-2`. |
| `terraform destroy` | One "Release GPU" transaction per GPU, then **EDA reverts** the network transaction: the switches are back where they started. In merge-request mode destroy only deletes the merge request; remove a merged tenant2 with `bash ../demo-reset.sh`. |

Brownfield (optional), from `tenant-onboarding/brownfield/` after `setup.sh`:
`terraform plan -generate-config-out=tenant1.tf` writes tenant1's existing Virtual Network as Terraform code from
live EDA, and `terraform apply` adopts it with 0 changes. Edit a field in `tenant1.tf` and `terraform plan` shows the
field-level difference. Reset with `bash forget.sh`.

### Ways of driving EDA it shows

| Way | Where |
|---|---|
| Declarative intent: the tenant as EDA objects in one template | `templates/`, `terraform/crs.tf` |
| Discovery: free GPUs read live from EDA, none hard-coded | `terraform/discovery.tf` |
| Dry run at plan time, with a preview of the switch configuration | `terraform/preview.tf` |
| One atomic transaction, reverted on destroy | `terraform/deliver.tf` |
| Small edits of shared objects (JSON patch; the revert restores them) | `terraform/crs.tf` |
| Four-eyes: a merge request a human merges | `terraform/deliver.tf` (`delivery = merge-request`) |
| Tenant self-service login with EDA's role-based access | `terraform/access.tf` |
| Validation with EDA's own ping workflows | `terraform/validate.tf` |
| Brownfield: import an existing tenant, field-level differences | `brownfield/` |
| Server side after the network change | `terraform/hosts.tf` |

## Good to know

- With an anycast gateway, an EDA ping workflow from the switches gets an answer only on the leaf the host's bond
  hashes to, so "pass" means at least 1 of the 2 leaves answered. Right after a fresh onboarding they can read 0 of 2
  for a minute; `terraform apply -replace='oam-v1_ping.check["gpu-pod"]'` runs them again.
- tenant2 **with internet** reaches tenant1: both public subnets sit in the border leaves' internet VRF, which routes
  between them like internet traffic. Without internet the two tenants never meet.
- Role-based access in EDA is per resource type and namespace, so the tenant login can also read tenant1's objects
  (read only).
- Nokia's EDA providers do not yet cover everything this demo needs (merge requests with full objects, user and group
  links, a working label filter on the interface list); those gaps are filled with direct calls to EDA's REST API,
  each commented where it is used.
