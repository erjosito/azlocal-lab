# Useful Commands Reference

This page collects diagnostic and verification commands for the Azure Local lab environment. Use them to explore the infrastructure, troubleshoot issues, and understand how components interact.

## Azure Local Nodes (AzLHOST1, AzLHOST2)

Connect via RDP from LocalBox-Client or use PowerShell remoting:

```powershell
# From LocalBox-Client:
Enter-PSSession -ComputerName AzLHOST1 -Credential (Get-Credential jumpstart\Administrator)
```

### Cluster Health

```powershell
# List cluster nodes and their status
Get-ClusterNode

# Show cluster groups (roles) and their owner node
Get-ClusterGroup

# Health faults — quick summary of anything wrong
Get-HealthFault

# Detailed cluster validation (takes a few minutes)
Test-Cluster -Node AzLHOST1, AzLHOST2
```

### Azure Registration & Sync

After restarting the lab (or if the cluster shows "NotConnectedRecently" in the portal), trigger a manual sync:

```powershell
# Check current registration status
Get-AzureStackHCI

# Force a sync with Azure (updates billing, connectivity status, etc.)
Sync-AzureStackHCI
```

> **Tip**: The cluster syncs automatically every ~12 hours. If you restart the lab after a multi-day shutdown, it may show "Not connected" in the Azure portal until the next scheduled sync. Use `Sync-AzureStackHCI` to fix it immediately.

### Storage Spaces Direct

```powershell
# Storage pool overview
Get-StoragePool | ft FriendlyName, HealthStatus, OperationalStatus, Size

# Virtual disks (volumes) status
Get-VirtualDisk | ft FriendlyName, HealthStatus, OperationalStatus, Size

# Physical disks across all nodes
Get-PhysicalDisk | ft FriendlyName, OperationalStatus, HealthStatus, Size, MediaType

# Cluster Shared Volumes (CSVs)
Get-ClusterSharedVolume | ft Name, State, OwnerNode

# Any pending storage repair jobs
Get-StorageJob
```

### Networking

```powershell
# Virtual switches
Get-VMSwitch | ft Name, SwitchType, NetAdapterInterfaceDescription

# Physical and virtual network adapters
Get-NetAdapter | ft Name, Status, LinkSpeed, InterfaceDescription

# Management OS virtual NICs
Get-VMNetworkAdapter -ManagementOS | ft Name, IsManagementOs, SwitchName, IPAddresses

# IP configuration
Get-NetIPAddress -AddressFamily IPv4 | ft InterfaceAlias, IPAddress, PrefixLength
```

### Virtual Machines

```powershell
# VMs hosted on this node
Get-VM | ft Name, State, CPUUsage, MemoryAssigned, Uptime

# VMs across ALL cluster nodes (needed to find the Arc Resource Bridge)
Get-VM -ComputerName (Get-ClusterNode).Name | ft Name, State, ComputerName

# Clustered VM resources (includes the Arc Resource Bridge)
Get-ClusterResource | Where-Object ResourceType -eq "Virtual Machine" | ft Name, State, OwnerNode

# VM replication and migration status
Get-ClusterGroup | Where-Object GroupType -eq VirtualMachine | ft Name, State, OwnerNode
```

> **Note**: The Arc Resource Bridge shows up as a VM with a long MOC-generated hash name (e.g., `b9f8131d...-control-plane-0-...`). "aksarc" is just the distro label in the Azure portal — you won't find a VM literally named "aksarc".

### Azure Arc Agent

```powershell
# Arc Connected Machine agent status
azcmagent show

# Check Arc agent connectivity
azcmagent check
```

### Windows Admin Center (WAC)

WAC is installed on LocalBox-Client. Access it via browser at:
```
https://localhost
```

---

## VM-Router

The VM-Router runs RRAS (Routing and Remote Access) and provides routing between the internal lab subnets. Connect from AzLMGMT:

```powershell
Enter-PSSession -ComputerName Vm-Router -Credential (Get-Credential jumpstart\Administrator)
```

### Routing

```powershell
# View the full routing table
Get-NetRoute -AddressFamily IPv4 | ft DestinationPrefix, NextHop, InterfaceAlias, RouteMetric

# RRAS routing protocols
Get-RemoteAccessRoutingDomain

# Active interfaces
Get-NetAdapter | ft Name, Status, LinkSpeed, InterfaceDescription

# IP addresses on all interfaces
Get-NetIPAddress -AddressFamily IPv4 | ft InterfaceAlias, IPAddress, PrefixLength
```

### NAT & Forwarding

```powershell
# Check if IP forwarding is enabled
Get-NetIPInterface | Where-Object { $_.Forwarding -eq "Enabled" } | ft InterfaceAlias, AddressFamily, Forwarding

# NAT configuration (if using Windows NAT)
Get-NetNat
Get-NetNatStaticMapping
```

### DNS

```powershell
# DNS server forwarders
Get-DnsClientServerAddress -AddressFamily IPv4 | ft InterfaceAlias, ServerAddresses

# Test DNS resolution from the router
Resolve-DnsName www.microsoft.com
```

### Connectivity Tests

```powershell
# Test connectivity to Azure
Test-NetConnection -ComputerName management.azure.com -Port 443

# Test connectivity to cluster nodes
Test-NetConnection -ComputerName AzLHOST1 -Port 5985
Test-NetConnection -ComputerName AzLHOST2 -Port 5985

# Trace route to external destination
Test-NetConnection -ComputerName 8.8.8.8 -TraceRoute
```

---

## LocalBox-Client (Host VM)

The primary Azure VM hosting all nested infrastructure.

### Nested VMs Management

```powershell
# List all nested VMs and their state
Get-VM | ft Name, State, CPUUsage, MemoryAssigned, Uptime, Path

# Start/stop nested VMs
Start-VM -Name AzLHOST1
Stop-VM -Name AzLHOST1 -Force

# VM checkpoints (snapshots)
Get-VMCheckpoint | ft VMName, Name, CreationTime
```

### Hyper-V Networking

```powershell
# Virtual switches on the host
Get-VMSwitch | ft Name, SwitchType, NetAdapterInterfaceDescription

# All VM network adapters
Get-VMNetworkAdapter -All | ft VMName, Name, SwitchName, IPAddresses, MacAddress
```

### Logs

```powershell
# Deployment logs location
Get-ChildItem C:\LocalBox\Logs | ft Name, LastWriteTime, Length

# Tail a specific log
Get-Content C:\LocalBox\Logs\New-LocalBoxCluster.log -Tail 50

# Windows Event Log for Hyper-V
Get-WinEvent -LogName "Microsoft-Windows-Hyper-V-VMMS-Admin" -MaxEvents 20 | ft TimeCreated, Message
```

---

## Azure Firewall (from Azure CLI)

These commands run from your local machine (not inside the VMs). They query the Azure Firewall logs via Log Analytics.

> ℹ️ These commands use bash multiline strings. On Windows, run them from **WSL**, **Azure Cloud Shell**, or collapse each query onto a single line.

### Prerequisites

```bash
# Set variables (adjust if your resource group or workspace name differs)
rg="azlocal2"
logws_name="LocalBox-Workspace"
logws_id=$(az monitor log-analytics workspace show -n $logws_name -g $rg --query customerId -o tsv)
```

### Query Denied Traffic

```bash
# Network rules — denied traffic (last hour)
az monitor log-analytics query -w $logws_id --analytics-query "
AZFWNetworkRule
| where TimeGenerated > ago(1h)
| where Action == 'Deny'
| summarize Count=count() by DestinationPort, Protocol, DestinationIp
| order by Count desc
" -o table

# Application rules — denied traffic
az monitor log-analytics query -w $logws_id --analytics-query "
AZFWApplicationRule
| where TimeGenerated > ago(1h)
| where Action == 'Deny'
| summarize Count=count() by Fqdn, TargetUrl
| order by Count desc
" -o table
```

### Query Allowed Traffic

```bash
# HTTPS endpoints being accessed (application rules)
az monitor log-analytics query -w $logws_id --analytics-query "
AZFWApplicationRule
| where TimeGenerated > ago(1h)
| where Action == 'Allow'
| summarize Count=count() by Fqdn
| order by Count desc
" -o table

# Network rules — allowed traffic
az monitor log-analytics query -w $logws_id --analytics-query "
AZFWNetworkRule
| where TimeGenerated > ago(1h)
| where Action == 'Allow'
| summarize Count=count() by DestinationPort, Protocol, DestinationIp
| order by Count desc
" -o table
```

### DNS Queries

```bash
# DNS queries going through the firewall
az monitor log-analytics query -w $logws_id --analytics-query "
AZFWDnsQuery
| where TimeGenerated > ago(1h)
| summarize Count=count() by QueryName
| order by Count desc
| take 20
" -o table
```

> **Tip**: You can also use the `scripts/monitor-firewall-logs.sh` script for a quick overview.

---

## Azure CLI — Cluster Management

Manage the Azure Local cluster from your local machine via Azure CLI.

### Cluster Status

```bash
# Cluster overview
az stack-hci cluster show -g <resource-group> -n localboxcluster \
    --query "{status:status, provisioningState:provisioningState}" -o json

# Arc-connected machines
az connectedmachine list -g <resource-group> -o table

# Extensions installed on Arc machines
az connectedmachine extension list -g <resource-group> --machine-name AzLHOST1 -o table
```

### Run Commands Remotely (via Azure VM agent)

```bash
# Run a PowerShell command on LocalBox-Client
az vm run-command invoke -g <resource-group> -n LocalBox-Client \
    --command-id RunPowerShellScript \
    --scripts "Get-VM | Format-Table Name, State"

# Check cluster health remotely
az vm run-command invoke -g <resource-group> -n LocalBox-Client \
    --command-id RunPowerShellScript \
    --scripts "Invoke-Command -ComputerName AzLHOST1 -ScriptBlock { Get-HealthFault }"
```

### Resource Costs

```bash
# Check what's running (and costing money)
az vm list -g <resource-group> -d --query "[].{name:name, state:powerState, size:hardwareProfile.vmSize}" -o table

# Deallocate to save costs
az vm deallocate -g <resource-group> -n LocalBox-Client --no-wait
```

---

## JumpstartDC (Domain Controller)

The domain controller for `jumpstart.local`. Connect from AzLMGMT:

```powershell
Enter-PSSession -ComputerName JumpstartDC -Credential (Get-Credential jumpstart\Administrator)
```

### Active Directory

```powershell
# List domain computers
Get-ADComputer -Filter * | ft Name, DNSHostName, Enabled

# List domain users
Get-ADUser -Filter * | ft Name, SamAccountName, Enabled

# Check AD replication (if multi-DC)
repadmin /replsummary
```

### DNS Server

```powershell
# DNS zones hosted
Get-DnsServerZone | ft ZoneName, ZoneType, IsReverseLookupZone

# DNS records in jumpstart.local
Get-DnsServerResourceRecord -ZoneName "jumpstart.local" | ft HostName, RecordType, RecordData

# DNS forwarders
Get-DnsServerForwarder
```

---

## Quick Health Check (All-in-One)

Run this from LocalBox-Client to get a quick overview of the entire lab:

```powershell
Write-Host "=== Nested VMs ===" -ForegroundColor Cyan
Get-VM | ft Name, State, CPUUsage, MemoryAssigned

Write-Host "=== Cluster Nodes ===" -ForegroundColor Cyan
Invoke-Command -ComputerName AzLHOST1 -ScriptBlock { Get-ClusterNode } -Credential $cred

Write-Host "=== Health Faults ===" -ForegroundColor Cyan
Invoke-Command -ComputerName AzLHOST1 -ScriptBlock { Get-HealthFault } -Credential $cred

Write-Host "=== Storage ===" -ForegroundColor Cyan
Invoke-Command -ComputerName AzLHOST1 -ScriptBlock {
    Get-VirtualDisk | ft FriendlyName, HealthStatus, OperationalStatus
} -Credential $cred

Write-Host "=== Cluster Shared Volumes ===" -ForegroundColor Cyan
Invoke-Command -ComputerName AzLHOST1 -ScriptBlock {
    Get-ClusterSharedVolume | ft Name, State, OwnerNode
} -Credential $cred
```

> **Note**: Set `$cred = Get-Credential jumpstart\Administrator` first (use the password you chose during deployment).
