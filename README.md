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

## References

- [Jumpstart LocalBox Documentation](https://jumpstart.azure.com/azure_jumpstart_localbox/getting_started)
- [Azure Local Documentation](https://learn.microsoft.com/azure/azure-local/)
- [Azure Arc Overview](https://learn.microsoft.com/azure/azure-arc/overview)
- [AKS on Azure Local](https://learn.microsoft.com/azure/aks/aksarc/aks-overview)
