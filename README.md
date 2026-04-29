# Azure Local Lab — Hands-On Learning Environment

This repository provides everything you need to deploy an emulated [Azure Local](https://learn.microsoft.com/azure/azure-local/whats-new) (formerly Azure Stack HCI) environment in Azure using [Jumpstart LocalBox](https://jumpstart.azure.com/azure_jumpstart_localbox/getting_started), along with progressive learning exercises to master the technology.

## What You'll Learn

- How Azure Local extends Azure into on-premises environments
- Nested virtualization architecture and cluster management
- Virtual machine lifecycle management through Azure Arc
- AKS (Azure Kubernetes Service) on Azure Local
- Monitoring, security, and governance for hybrid infrastructure
- Azure Policy for Arc-enabled resources

## Architecture Overview

LocalBox runs a **Standard_E32s_v6** Azure VM with nested Hyper-V, hosting:

| VM Name | Role | Parent Host |
|---------|------|-------------|
| **LocalBox-Client** | Primary host (Azure VM) | Azure |
| **AzLHOST1** | Azure Local node 1 | LocalBox-Client |
| **AzLHOST2** | Azure Local node 2 | LocalBox-Client |
| **AzLMGMT** | Nested hypervisor | LocalBox-Client |
| **JumpstartDC** | Domain controller | AzLMGMT |
| **Vm-Router** | RRAS router | AzLMGMT |

## Quick Start

### Linux / macOS / WSL (Bash)

```bash
# 1. Check prerequisites
./deploy/prerequisites.sh

# 2. Deploy — the script auto-detects settings and prompts for the rest
./deploy/deploy.sh --resource-group myLocalBoxLab --location swedencentral

# 3. Start learning!
# Open exercises/00-explore-architecture.md
```

### Windows (PowerShell)

```powershell
# 1. Check prerequisites
.\deploy\prerequisites.ps1

# 2. Deploy — the script auto-detects settings and prompts for the rest
.\deploy\deploy.ps1 -ResourceGroup myLocalBoxLab -Location swedencentral

# 3. Start learning!
# Open exercises\00-explore-architecture.md
```

The deploy script will automatically retrieve your tenant ID and the AzureStackHCI Resource Provider
service principal, then interactively ask for your VM password and optional settings (with sensible defaults).
If you prefer to pre-build the parameters file manually, see `deploy/main.bicepparam.template`.

### Alternative: Deploy Using the Official Documentation

If you encounter issues with the deployment scripts above, you can follow the original Azure Jumpstart LocalBox documentation directly:

1. **Getting Started** — [jumpstart.azure.com/azure_jumpstart_localbox/getting_started](https://jumpstart.azure.com/azure_jumpstart_localbox/getting_started)
2. **Bicep Deployment Guide** — [Deploy LocalBox with Azure Bicep](https://jumpstart.azure.com/azure_jumpstart_localbox/deployment_az)
3. **Connect to LocalBox** — [Post-deployment steps](https://jumpstart.azure.com/azure_jumpstart_localbox/cloud_deployment)

The official guide uses the same Bicep templates from the [microsoft/azure_arc](https://github.com/microsoft/azure_arc/tree/main/azure_jumpstart_localbox) GitHub repository. Once your LocalBox environment is operational, you can proceed with the exercises in this repo regardless of how you deployed.

## Repository Structure

```
deploy/                          # Deployment automation
  prerequisites.sh               # Validate environment and register providers
  deploy.sh                      # Deploy LocalBox infrastructure
  main.bicepparam.template       # Parameter template (copy & edit)

scripts/                         # Cost and lifecycle management
  estimate-cost.sh               # Estimate monthly Azure cost
  stop-environment.sh            # Deallocate VMs to pause billing
  start-environment.sh           # Restart deallocated VMs
  cleanup.sh                     # Destroy all resources

exercises/                       # Progressive learning path
  00-explore-architecture.md     # Understand the nested virtualization stack
  01-azure-portal-exploration.md # Navigate Azure Local in the portal
  02-networking-and-vms.md       # Logical networks, VM images, deploy VMs
  03-aks-on-azure-local.md       # Deploy and use AKS on Azure Local
  04-monitoring-observability.md # Azure Monitor and Insights
  05-security-and-governance.md  # Defender, Policy, RBAC
  06-challenge-operations.md     # Open challenge: hybrid operations
```

## Exercises Overview

| # | Exercise | Type | Duration |
|---|----------|------|----------|
| 0 | [Explore Architecture](exercises/00-explore-architecture.md) | Exploration | 30-45 min |
| 1 | [Azure Portal Exploration](exercises/01-azure-portal-exploration.md) | Guided | 30 min |
| 2 | [Networking & VM Management](exercises/02-networking-and-vms.md) | Challenge + Guide | 60-90 min |
| 3 | [AKS on Azure Local](exercises/03-aks-on-azure-local.md) | Challenge + Guide | 60-90 min |
| 4 | [Monitoring & Observability](exercises/04-monitoring-observability.md) | Semi-guided | 45-60 min |
| 5 | [Security & Governance](exercises/05-security-and-governance.md) | Semi-guided | 45-60 min |
| 6 | [Challenge: Hybrid Operations](exercises/06-challenge-operations.md) | Open Challenge | 60-90 min |

## Cost Management

The LocalBox VM is an **E32s_v6** (32 vCPUs, 256 GB RAM). Estimated costs:

- **Running 24/7**: ~$1,500-2,000/month (region-dependent)
- **Running 8h/day, weekdays only**: ~$400-550/month
- **With Spot pricing**: up to 60-90% savings (risk of eviction)

> ⚠️ **Always deallocate or delete when not in use!**

```bash
# Bash
./scripts/stop-environment.sh --resource-group myLocalBoxLab
./scripts/start-environment.sh --resource-group myLocalBoxLab
./scripts/cleanup.sh --resource-group myLocalBoxLab
```

```powershell
# PowerShell
.\scripts\stop-environment.ps1 -ResourceGroup myLocalBoxLab
.\scripts\start-environment.ps1 -ResourceGroup myLocalBoxLab
.\scripts\cleanup.ps1 -ResourceGroup myLocalBoxLab
```

## Prerequisites

- Azure subscription with **Owner** role
- Azure CLI 2.65.0+
- 32 ESv6-series vCPUs quota in your target region
- ~4-5 hours for initial deployment to complete

## Troubleshooting

The LocalBox deployment is a two-phase process: Phase 1 deploys Azure resources via Bicep (~30 min), and Phase 2 runs an automated PowerShell script inside the VM (~4-5 hours) that builds the nested Hyper-V cluster. Phase 2 is where most issues occur.

### Diagnosing Issues

Use the retry-setup script to check the health of the internal setup without needing to RDP into the VM:

```bash
# Bash
./scripts/retry-setup.sh --resource-group myLocalBoxLab

# PowerShell
.\scripts\retry-setup.ps1 -ResourceGroup myLocalBoxLab
```

This runs diagnostics remotely via `az vm run-command` and reports the status of each component: azcopy, storage pool, virtual drive, VHD files, Hyper-V VMs, and running processes.

### Common Issues

#### 1. azcopy not installed

**Symptom**: `AzL-node.vhdx: MISSING` in diagnostics, but the storage pool and V: drive are healthy.

**Cause**: The VM bootstrap was supposed to install azcopy, but the installation silently failed (network timing, package source issues). Without azcopy, the ~20 GB node VHD download never starts, and the setup script continues without error — leaving the cluster creation to fail later.

**Fix**: The retry-setup script detects this and installs azcopy automatically before re-launching the setup:

```bash
./scripts/retry-setup.sh --resource-group myLocalBoxLab --action retry

.\scripts\retry-setup.ps1 -ResourceGroup myLocalBoxLab -Action retry
```

#### 2. Storage pool timing issue after Hyper-V reboot

**Symptom**: `StoragePool: NOT FOUND` or `VDrive: NOT FOUND` in diagnostics.

**Cause**: The initial setup installs Hyper-V, which requires a VM reboot. After the reboot, the 8 data disks briefly report `CanPool = False` due to a timing race. If the logon script runs too quickly after reboot, the storage pool creation fails.

**Fix**: Run the retry script. On re-run the disks are usually ready, and the script creates the storage pool successfully:

```bash
./scripts/retry-setup.sh --resource-group myLocalBoxLab --action retry
```

#### 3. PowerShell window closed / setup script stopped

**Symptom**: You RDP into the VM and don't see the setup PowerShell window. The diagnostics show few or no Hyper-V VMs, and `PowerShell processes: 1 running` (only your session).

**Cause**: The setup script (`C:\LocalBox\LocalBoxLogonScript.ps1`) runs in a visible PowerShell window as a logon task. If the window is closed, the VM is restarted, or the RDP session drops at the wrong time, the script may stop mid-execution.

**Fix**: The retry script re-launches the logon script. It is designed to be idempotent — it skips steps that already completed:

```bash
./scripts/retry-setup.sh --resource-group myLocalBoxLab --action retry
```

#### 4. NSG rules blocking RDP (port 3389)

**Symptom**: You can't RDP into the LocalBox-Client VM. The VM is running and has a public IP, but the connection times out.

**Cause**: Some Azure subscriptions have policies that periodically remove NSG rules allowing inbound traffic on port 3389.

**Fix**: You don't need RDP for deployment or troubleshooting — all scripts use `az vm run-command` remotely. For exercises that require a desktop session, add Azure Bastion instead:

```bash
./scripts/add-bastion.sh --resource-group myLocalBoxLab

.\scripts\add-bastion.ps1 -ResourceGroup myLocalBoxLab
```

#### 5. VHD download incomplete or corrupted

**Symptom**: `AzL-node.vhdx` exists but is much smaller than expected (should be ~20 GB), or Hyper-V VMs fail to start.

**Cause**: The azcopy download was interrupted (network issue, VM restarted during download).

**Fix**: Delete the partial file and re-run the setup. Connect to the VM (via RDP or Bastion) and:

```powershell
# Inside the VM
Remove-Item C:\LocalBox\VHD\AzL-node.vhdx -Force
# Then re-run the setup script
& C:\LocalBox\LocalBoxLogonScript.ps1
```

Or use the retry-setup script, which will re-launch the logon script (it detects the missing VHD and re-downloads):

```bash
./scripts/retry-setup.sh --resource-group myLocalBoxLab --action retry
```

### Checking Logs Inside the VM

If you have RDP or Bastion access, the key log files inside the VM are:

| Log | Path | Contents |
|-----|------|----------|
| Main setup log | `C:\LocalBox\Logs\LocalBoxLogonScript.log` | Overall setup progress |
| Cluster creation log | `C:\LocalBox\Logs\New-LocalBoxCluster.log` | Azure Local cluster creation details |
| Bootstrap log | `C:\LocalBox\Logs\Bootstrap.log` | Initial VM configuration (Hyper-V install, disk setup) |

Tail the logon script log to monitor progress in real time:

```powershell
# Inside the VM
Get-Content C:\LocalBox\Logs\LocalBoxLogonScript.log -Tail 30 -Wait
```

## References

- [Jumpstart LocalBox Documentation](https://jumpstart.azure.com/azure_jumpstart_localbox/getting_started)
- [Azure Local Documentation](https://learn.microsoft.com/azure/azure-local/)
- [Azure Arc Overview](https://learn.microsoft.com/azure/azure-arc/overview)
- [AKS on Azure Local](https://learn.microsoft.com/azure/aks/aksarc/aks-overview)
