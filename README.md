# Azure Local Lab — Hands-On Learning Environment

This repository provides everything you need to deploy an emulated [Azure Local](https://learn.microsoft.com/azure/azure-local/whats-new) (formerly Azure Stack HCI) environment in Azure using [Jumpstart LocalBox](https://jumpstart.azure.com/azure_jumpstart_localbox/getting_started), along with progressive learning exercises to master the technology.

## What You'll Learn

- How Azure Local extends Azure into on-premises environments
- Nested virtualization architecture and cluster management
- Virtual machine lifecycle management through Azure Arc
- AKS (Azure Kubernetes Service) on Azure Local
- Monitoring, security, and governance for hybrid infrastructure
- Azure Policy for Arc-enabled resources
- Azure Arc Gateway for reducing Arc network footprint

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
  deploy-firewall.sh/.ps1        # Azure Firewall + UDR for enterprise networking
  monitor-firewall-logs.sh/.ps1  # Analyze firewall logs and discover rules
  deploy-arc-gateway.sh/.ps1     # Create/remove Arc Gateway for Arc agents

docs/                            # Architecture and operational docs
  firewall-rules.md              # Firewall rules inventory and architecture

exercises/                       # Progressive learning path
  00-explore-architecture.md     # Understand the nested virtualization stack
  01-azure-portal-exploration.md # Navigate Azure Local in the portal
  02-networking-and-vms.md       # Logical networks, VM images, deploy VMs
  03-aks-on-azure-local.md       # Deploy and use AKS on Azure Local
  04-monitoring-observability.md # Azure Monitor and Insights
  05-security-and-governance.md  # Defender, Policy, RBAC
  06-challenge-operations.md     # Open challenge: hybrid operations
  07-sql-managed-instance.md     # Arc-enabled SQL MI on Azure Local
  08-sre-agent.md                # Azure SRE Agent for hybrid incidents
  09-arc-gateway.md              # Arc Gateway and firewall log comparison
  sre-agent-knowledge/
    azure-local-operations.md    # Knowledge base for Exercise 8
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
| 7 | [SQL Managed Instance on Azure Local](exercises/07-sql-managed-instance.md) | Challenge + Guide | 60-90 min |
| 8 | [Azure SRE Agent for Azure Local Operations](exercises/08-sre-agent.md) | Challenge + Guide | 60-90 min |
| 9 | [Arc Gateway and Network Security](exercises/09-arc-gateway.md) | Guided + Analysis | 45-60 min |

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

> **Upstream reliability improvements (Apr 2026)**: [Commit c5b0554](https://github.com/microsoft/azure_arc/commit/c5b0554) added VHDX copy verification with retry, node VM post-creation checks, a missing scheduled task trigger for headless deployments, resource provider registration polling, and SYSTEM context handling. These fixes reduce the likelihood of silent failures in Phase 2. If you deployed before this date, some of the issues below may apply.

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

**Cause**: The VM bootstrap was supposed to install azcopy, but the installation silently failed (network timing, package source issues). Without azcopy, the ~20 GB node VHD download never starts, and the setup script continues without error — leaving the cluster creation to fail later. Tracked upstream: [microsoft/azure_arc#3401](https://github.com/microsoft/azure_arc/issues/3401).

**Fix**: The retry-setup script detects this and installs azcopy automatically before re-launching the setup:

```bash
./scripts/retry-setup.sh --resource-group myLocalBoxLab --action retry

.\scripts\retry-setup.ps1 -ResourceGroup myLocalBoxLab -Action retry
```

#### 2. VHD download fails — storage account disabled (upstream bug)

**Symptom**: `AzL-node.vhdx: MISSING` in diagnostics even though azcopy is installed. The progress report (`-Action progress`) shows Step 1/11 was reached but Step 3/11 was not.

**Cause**: The upstream storage account `azlocalvhds.blob.core.windows.net` used by the Jumpstart scripts returns **403 AccountIsDisabled**. This is an upstream issue tracked in [microsoft/azure_arc#3400](https://github.com/microsoft/azure_arc/issues/3400). The same VHD files are available on the older storage account `jumpstartprodsg.blob.core.windows.net`.

> **Note (May 2026)**: Upstream now ships `AzLocal2604.vhdx`. If the `azlocalvhds` storage account is still disabled, the workaround below applies — just replace `2604` in the URLs.

**Fix**: Patch the download URLs inside the VM and re-run the setup. Connect via RDP or Bastion and run:

```powershell
# Inside the VM — patch the cluster script
$script = Get-Content C:\LocalBox\New-LocalBoxCluster.ps1 -Raw
$script = $script.Replace(
    'https://azlocalvhds.blob.core.windows.net/images/AzLocal2604.vhdx',
    'https://jumpstartprodsg.blob.core.windows.net/jslocal/localbox/prod/AzLocal2604.vhdx')
$script = $script.Replace(
    'https://azlocalvhds.blob.core.windows.net/images/AzLocal2604.sha256',
    'https://jumpstartprodsg.blob.core.windows.net/jslocal/localbox/prod/AzLocal2604.sha256')
Set-Content C:\LocalBox\New-LocalBoxCluster.ps1 -Value $script -Encoding UTF8
```

Or remotely via `az vm run-command` (save the above as a `.ps1` file and run it with `--scripts @file.ps1`). Then re-launch the setup with the retry script.

#### 3. Storage pool timing issue after Hyper-V reboot

**Symptom**: `StoragePool: NOT FOUND` or `VDrive: NOT FOUND` in diagnostics.

**Cause**: The initial setup installs Hyper-V, which requires a VM reboot. After the reboot, the 8 data disks briefly report `CanPool = False` due to a timing race. If the logon script runs too quickly after reboot, the storage pool creation fails.

**Fix**: Run the retry script. On re-run the disks are usually ready, and the script creates the storage pool successfully:

```bash
./scripts/retry-setup.sh --resource-group myLocalBoxLab --action retry
```

#### 4. PowerShell window closed / setup script stopped

**Symptom**: You RDP into the VM and don't see the setup PowerShell window. The diagnostics show few or no Hyper-V VMs, and `PowerShell processes: 1 running` (only your session).

**Cause**: The setup script (`C:\LocalBox\LocalBoxLogonScript.ps1`) runs in a visible PowerShell window as a logon task. If the window is closed, the VM is restarted, or the RDP session drops at the wrong time, the script may stop mid-execution.

**Fix**: The retry script re-launches the logon script. It is designed to be idempotent — it skips steps that already completed:

```bash
./scripts/retry-setup.sh --resource-group myLocalBoxLab --action retry
```

#### 5. NSG rules blocking RDP (port 3389)

**Symptom**: You can't RDP into the LocalBox-Client VM. The VM is running and has a public IP, but the connection times out.

**Cause**: Some Azure subscriptions have policies that periodically remove NSG rules allowing inbound traffic on port 3389.

**Fix**: You don't need RDP for deployment or troubleshooting — all scripts use `az vm run-command` remotely. For exercises that require a desktop session, add Azure Bastion instead:

```bash
./scripts/add-bastion.sh --resource-group myLocalBoxLab

.\scripts\add-bastion.ps1 -ResourceGroup myLocalBoxLab
```

#### 6. VHD download incomplete or corrupted

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

#### 7. PowerShell module fails to load (corrupted Unicode character)

**Symptom**: Setup fails with `"The 'New-AzLocalNodeVM' command was found in the module 'Azure.Arc.Jumpstart.LocalBox', but the module could not be loaded"`, followed by `"No MAC address returned for AzLHOST1"`.

**Cause**: The `Azure.Arc.Jumpstart.LocalBox` PowerShell module v1.0.8 contains a corrupted Unicode character (garbled emoji appearing as `Γ?O`) at line 1828 of the `.psm1` file. This breaks the string parser, preventing the entire module from loading. Tracked upstream: [microsoft/azure_arc#3402](https://github.com/microsoft/azure_arc/issues/3402).

**Fix**: Patch the module file inside the VM and re-run:

```powershell
# Inside the VM — fix the corrupted character
$modulePath = "C:\Program Files\WindowsPowerShell\Modules\Azure.Arc.Jumpstart.LocalBox\1.0.8\Azure.Arc.Jumpstart.LocalBox.psm1"
$raw = [System.IO.File]::ReadAllText($modulePath)
$raw = $raw.Replace('Γ?O ', '')
[System.IO.File]::WriteAllText($modulePath, $raw, [System.Text.Encoding]::UTF8)

# Verify the fix
Import-Module Azure.Arc.Jumpstart.LocalBox -Force
Get-Command New-AzLocalNodeVM  # Should succeed
```

Then re-launch the setup with the retry script.

#### 8. ARM template generation fails (`ConvertTo-Json -AsArray`)

**Symptom**: The progress report shows Steps 1-9 complete but Step 10 (cluster validation) never starts. The cluster log ends with `A parameter cannot be found that matches parameter name 'AsArray'`.

**Cause**: The `Generate-ARM-Template.ps1` script uses `ConvertTo-Json -AsArray`, which is a PowerShell 7+ parameter. The LocalBox VM runs Windows PowerShell 5.1. Tracked upstream: [microsoft/azure_arc#3403](https://github.com/microsoft/azure_arc/issues/3403).

**Fix**: Patch the script inside the VM:

```powershell
# Inside the VM
$path = "C:\LocalBox\Generate-ARM-Template.ps1"
(Get-Content $path -Raw).Replace('ConvertTo-Json -AsArray', 'ConvertTo-Json') | Set-Content $path -Encoding UTF8
```

Then re-launch the setup with the retry script.

#### 9. Cluster validation fails — unsupported OS version (upstream bug, workaround available)

**Symptom**: Step 10 (cluster validation) fails with `"Unsupported Azure Stack HCI OS Version. The version of Azure Stack HCI OS currently installed on your system is not supported for new deployments."`.

**Cause**: The VHD image `AzLocal2601.vhdx` distributed by the Jumpstart upstream contains Azure Stack HCI 24H2 **build 26100.32230**. This build is Microsoft's own latest distributed image (recipe 12.2604 from the `Microsoft.AzureStackHCI/locations/osImages` API), yet the validation service rejects it — an internal inconsistency at Microsoft where their deployment pipeline ships a build that their validation pipeline rejects.

> **Update (May 2026)**: Upstream now ships `AzLocal2604.vhdx` ([commit 027b955](https://github.com/microsoft/azure_arc/commit/027b955)). This newer image may resolve the OS version issue. If it does not, the workaround below still applies — use `AzLocal2506.vhdx` as the replacement.

Tracked upstream: [microsoft/azure_arc#3411](https://github.com/microsoft/azure_arc/issues/3411).

**Workaround**: Replace the failing VHD with an older VHD from the same Jumpstart storage that uses build **26100.1742** (GA release track):

```powershell
# 1. Stop and remove the node VMs
Stop-VM -Name AzLHOST1,AzLHOST2 -Force
Remove-VM -Name AzLHOST1,AzLHOST2 -Force
Remove-Item V:\VMs\AzLHOST1*.vhdx, V:\VMs\AzLHOST2*.vhdx -Force
Remove-Item V:\VMs\AzL-node.vhdx -Force

# 2. Download the older (working) VHD — AzLocal2506 uses build 26100.1742
azcopy cp "https://jumpstartprodsg.blob.core.windows.net/jslocal/localbox/prod/AzLocal2506.vhdx" "V:\VMs\AzL-node.vhdx" --check-length=false

# 3. Recreate node VMs using the Jumpstart module
Import-Module Azure.Arc.Jumpstart.LocalBox -Force
$LocalBoxConfig = Import-PowerShellDataFile "C:\LocalBox\LocalBox-Config.psd1"
$localCred = New-Object PSCredential("Administrator", (ConvertTo-SecureString $LocalBoxConfig.SDNAdminPassword -AsPlainText -Force))
$domainCred = New-Object PSCredential(($LocalBoxConfig.SDNDomainFQDN.Split(".")[0] + "\Administrator"), (ConvertTo-SecureString $LocalBoxConfig.SDNAdminPassword -AsPlainText -Force))

foreach ($VM in $LocalBoxConfig.NodeHostConfig) {
    $mac = New-AzLocalNodeVM -Name $VM.Hostname -VHDXPath "V:\VMs\AzL-node.vhdx" -VMSwitch "InternalSwitch" -LocalBoxConfig $LocalBoxConfig
    Set-AzLocalNodeVhdx -HostName $VM.Hostname -IPAddress $VM.IP -VMMac $mac -LocalBoxConfig $LocalBoxConfig
    Start-VM -Name $VM.Hostname
}

# 4. Wait for VMs to boot, then configure networking
Test-AllVMsAvailable -LocalBoxConfig $LocalBoxConfig -Credential $localCred
Start-Sleep -Seconds 60
Set-DataDrives -LocalBoxConfig $LocalBoxConfig -Credential $localCred
Set-NICs -LocalBoxConfig $LocalBoxConfig -Credential $localCred

# 5. Run cloud deployment prep (domain join + Arc bootstrap)
Invoke-AzureEdgeBootstrap -LocalBoxConfig $LocalBoxConfig -localCred $localCred
Set-AzLocalDeployPrereqs -LocalBoxConfig $LocalBoxConfig -localCred $localCred -domainCred $domainCred
& "C:\LocalBox\Generate-ARM-Template.ps1"

# 6. Re-run validation (step 10) and deploy (step 11)
```

**Status**: Confirmed fixed — `AzLocal2506.vhdx` (build 26100.4349) passes all 16 validation steps (including OS version). After swapping the VHD, you may also need to fix NTP (see Bug #10 below) and storage account shared key access (see Bug #11 below). The newer `AzLocal2604.vhdx` should also work — to be confirmed.

**What does NOT fix the issue**:
- Windows Update on the 2601 image (updates to 26100.32690, still rejected)
- The evaluation center download is not publicly accessible

#### 10. Cluster validation fails — NTP time sync error

**Symptom**: Validation Step 7 (Software) fails with `"NTP Response not received on 'AZLHOST1' from 'VM IC Time Synchronization Provider': 'No such host is known. (0x80072AF9)'"`.

**Cause**: The cluster validator tests NTP by running `w32tm /stripchart /computer:"VM IC Time Synchronization Provider"`, which tries to resolve the provider name as a network hostname — it can't. In nested Hyper-V (VM-inside-VM), the VM Integration Components time synchronization provider is registered but the validator's test method fails because it treats the provider name as a DNS name.

**Fix**: Disable the VM IC time provider on both nodes and configure a real NTP server:

```powershell
# Inside LocalBox-Client, run on both nodes:
$pw = ConvertTo-SecureString "Microsoft123!" -AsPlainText -Force
$cred = New-Object PSCredential("Administrator", $pw)

foreach ($node in @("AzLHOST1","AzLHOST2")) {
    Invoke-Command -VMName $node -Credential $cred -ScriptBlock {
        # Disable VM IC Time Provider (causes validation failure in nested Hyper-V)
        Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\VMICTimeProvider" -Name "Enabled" -Value 0
        # Configure NTP to use time.windows.com
        w32tm /config /manualpeerlist:"time.windows.com,0x8" /syncfromflags:manual /reliable:yes /update
        Restart-Service w32time -Force
        Start-Sleep 5
        w32tm /resync /force
    }
}
```

Verify with `w32tm /stripchart /computer:time.windows.com /samples:1` — should show a valid time offset.

#### 11. Cluster validation fails — storage account shared key access disabled

**Symptom**: Validation Step 10 (Cluster Witness) fails with `"Key based authentication is not permitted on this storage account"` for the witness storage account.

**Cause**: Enterprise subscriptions often have Azure Policy (e.g., MCAPSGov "Deploy and Modify Policies") that automatically disables shared key access (`allowSharedKeyAccess=false`) on all storage accounts. The cluster witness requires key-based access to the storage account.

**Fix**: Create a policy exemption for the resource group and re-enable shared key access:

```bash
# Find the policy assignment that blocks shared key access
# (Look for "Deploy and Modify" policies at management group level)
az policy assignment list --scope "/providers/Microsoft.Management/managementGroups/<TENANT_ID>" \
  --query "[?contains(displayName,'Deploy')].{name:name, display:displayName}" -o table

# Create exemption (adjust assignment ID and scope)
az policy exemption create \
  --name "localbox-witness-shared-key" \
  --display-name "LocalBox witness storage requires shared key for cluster validation" \
  --policy-assignment "/providers/Microsoft.Management/managementGroups/<TENANT_ID>/providers/Microsoft.Authorization/policyAssignments/<ASSIGNMENT_NAME>" \
  --exemption-category "Waiver" \
  --scope "/subscriptions/<SUB_ID>/resourceGroups/<RG_NAME>" \
  --policy-definition-reference-ids "StorageAccountDisableLocalAuth"

# Now enable shared key access
az storage account update -n <WITNESS_ACCOUNT_NAME> -g <RG_NAME> --allow-shared-key-access true

# Also ensure public network access is enabled
az storage account update -n <WITNESS_ACCOUNT_NAME> -g <RG_NAME> --public-network-access Enabled
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
