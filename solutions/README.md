# Solution Scripts

> ⚠️ **Work in Progress** — These scripts are incomplete and have not been fully tested. They may contain errors, missing steps, or incorrect assumptions. Use at your own risk and expect to troubleshoot.

## Overview

Each script automates the solution for its corresponding exercise. They are intended as a reference for instructors or as a last-resort hint for participants who are stuck.

| Script | Exercise |
|--------|----------|
| `00-explore-architecture.ps1` | Explore the lab architecture (Azure + nested VMs) |
| `01-azure-portal-exploration.ps1` | Azure Portal and CLI exploration |
| `02-networking-and-vms.ps1` | Logical networks and VM deployment |
| `03-aks-on-azure-local.ps1` | AKS on Azure Local |
| `04-monitoring-observability.ps1` | Monitoring and observability |
| `05-security-and-governance.ps1` | Security and governance |
| `06-sql-managed-instance.ps1` | SQL Managed Instance |
| `07-sre-agent.ps1` | SRE Agent |
| `08-arc-gateway.ps1` | Arc Gateway |

## Usage

All scripts require the `-ResourceGroup` parameter:

```powershell
.\solutions\02-networking-and-vms.ps1 -ResourceGroup azlocal
```

The shared module `Common.AzureLocalLab.ps1` is loaded automatically by each script.

## Known Limitations

- Scripts depend on the specific Azure Local lab deployment from [Jumpstart LocalBox](https://jumpstart.azure.com/azure_jumpstart_localbox/getting_started).
- Some scripts require nested VM credentials (`-Password` or `-NestedAdminPassword` parameter).
- Run-command calls to the Azure VM are sequential and may take several minutes.
