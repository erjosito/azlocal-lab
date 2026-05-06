param(
    [Parameter(Mandatory)]
    [string]$ResourceGroup,

    [string]$Password = 'ArcPassword123!!'
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Common.AzureLocalLab.ps1"

try {
    Write-Banner 'Exercise 00 - Explore Architecture'
    Write-Step -What 'Validating Azure CLI access and loading Azure Local context.' -Why 'This exploration script should discover the lab dynamically instead of hardcoding resource IDs.'
    Ensure-AzExtension -Name 'customlocation' | Out-Null
    $context = Get-AzureLocalContext -ResourceGroup $ResourceGroup
    Write-Success "Connected to subscription '$($context.Account.name)' in resource group '$ResourceGroup'."

    Write-Step -What 'Listing every resource in the lab resource group.' -Why 'Students should first see the full inventory before zooming into Azure Local-specific resources.'
    $allResources = @(Invoke-AzJson -Arguments @('resource', 'list', '-g', $ResourceGroup))
    Show-TableFromObjects -InputObject ($allResources | Sort-Object type, name | Select-Object name, type, location) -Property @('name', 'type', 'location')

    Write-Step -What 'Showing the Arc-enabled servers that represent the Azure Local hosts.' -Why 'AzLHOST1 and AzLHOST2 are not Azure VMs; they are on-premises style servers projected into Azure through Arc.'
    $arcServers = @($context.ArcServers | Where-Object { $_.name -in @('AzLHOST1', 'AzLHOST2') })
    if (-not $arcServers) {
        $arcServers = @($context.ArcServers)
    }
    Show-TableFromObjects -InputObject ($arcServers | Select-Object name, location, kind, id) -Property @('name', 'location', 'kind', 'id')
    foreach ($server in $arcServers) {
        Write-Info "$($server.name) is an Arc-enabled machine resource. It lets Azure apply policy, extensions, monitoring, and inventory to a server that runs outside the Azure datacenter."
    }

    Write-Step -What 'Showing the Azure Local cluster resource.' -Why 'The cluster resource is the Azure control-plane representation of the two-node Azure Local system.'
    if ($context.Cluster) {
        $clusterDetails = Invoke-AzJson -Arguments @('resource', 'show', '--ids', $context.Cluster.id)
        [pscustomobject]@{
            Name = $clusterDetails.name
            Type = $clusterDetails.type
            Location = $clusterDetails.location
            ProvisioningState = $clusterDetails.properties.provisioningState
            ConnectivityStatus = $clusterDetails.properties.connectivityStatus
        } | Format-Table -AutoSize | Out-String | Write-Host
        Write-Info 'This resource is where Azure surfaces cluster health, version, storage, and deployment history for the on-premises platform.'
    }
    else {
        Write-Warn 'No Microsoft.AzureStackHCI/cluster resource was found in this resource group.'
    }

    Write-Step -What 'Showing the Custom Location.' -Why 'The custom location is the placement target that lets Azure deploy VMs and AKS onto this specific Azure Local cluster.'
    if ($context.CustomLocation) {
        $customLocationDetails = Invoke-AzJson -Arguments @('resource', 'show', '--ids', $context.CustomLocation.id)
        [pscustomobject]@{
            Name = $customLocationDetails.name
            Namespace = $customLocationDetails.properties.namespace
            HostResourceId = $customLocationDetails.properties.hostResourceId
            ProvisioningState = $customLocationDetails.properties.provisioningState
        } | Format-Table -AutoSize | Out-String | Write-Host
        Write-Info 'Think of the custom location as the Azure-side address label for the Azure Local cluster.'
    }
    else {
        Write-Warn 'No custom location was found. Azure Local workload deployment usually depends on one.'
    }

    Write-Step -What 'Inspecting Azure networking around LocalBox.' -Why 'The Azure VNet, subnets, NSG, and NAT Gateway form the outer network shell that reaches the nested datacenter.'
    if ($context.VNet) {
        $vnetDetails = Invoke-AzJson -Arguments @('network', 'vnet', 'show', '-g', $ResourceGroup, '-n', $context.VNet.name)
        Write-Host 'Virtual network:' -ForegroundColor Green
        [pscustomobject]@{
            Name = $vnetDetails.name
            AddressSpace = ($vnetDetails.addressSpace.addressPrefixes -join ', ')
        } | Format-Table -AutoSize | Out-String | Write-Host

        Write-Host 'Subnets:' -ForegroundColor Green
        $subnetRows = foreach ($subnet in @($vnetDetails.subnets)) {
            $nsgName = '-'
            $natName = '-'
            if ($subnet.PSObject.Properties['networkSecurityGroup'] -and $subnet.networkSecurityGroup) {
                $nsgName = ($subnet.networkSecurityGroup.id -split '/')[-1]
            }
            if ($subnet.PSObject.Properties['natGateway'] -and $subnet.natGateway) {
                $natName = ($subnet.natGateway.id -split '/')[-1]
            }
            [pscustomobject]@{
                Name = $subnet.name
                Prefix = $subnet.addressPrefix
                NSG = $nsgName
                NatGateway = $natName
            }
        }
        Show-TableFromObjects -InputObject $subnetRows -Property @('Name', 'Prefix', 'NSG', 'NatGateway')
    }
    else {
        Write-Warn 'No Azure VNet was found in the resource group.'
    }

    if ($context.NetworkSecurityGroups) {
        Write-Host 'Network security groups:' -ForegroundColor Green
        $nsgRows = foreach ($nsg in @($context.NetworkSecurityGroups)) {
            $rulesCount = 0
            if ($nsg.PSObject.Properties['securityRules']) {
                $rulesCount = @($nsg.securityRules).Count
            }
            [pscustomobject]@{
                Name = $nsg.name
                SecurityRules = $rulesCount
            }
        }
        Show-TableFromObjects -InputObject $nsgRows -Property @('Name', 'SecurityRules')
        Write-Info 'The NSG controls which Azure-side traffic can reach LocalBox-Client, such as RDP or Bastion-related flows.'
    }

    if ($context.NatGateways) {
        Write-Host 'NAT gateways:' -ForegroundColor Green
        $natRows = foreach ($nat in @($context.NatGateways)) {
            $pipCount = 0
            if ($nat.PSObject.Properties['publicIpAddresses']) {
                $pipCount = @($nat.publicIpAddresses).Count
            }
            [pscustomobject]@{
                Name = $nat.name
                PublicIPs = $pipCount
            }
        }
        Show-TableFromObjects -InputObject $natRows -Property @('Name', 'PublicIPs')
        Write-Info 'The NAT Gateway gives outbound internet access to Azure subnets without exposing inbound endpoints.'
    }

    Write-Step -What 'Rendering a text-based architecture diagram.' -Why 'A compact ASCII view helps students connect Azure resources with the nested virtualization layers.'
    $diagram = @'
Azure
└─ Resource Group
   ├─ LocalBox-Client (Azure VM in Azure VNet)
   │  ├─ AzLHOST1  -> Arc-enabled server -> Azure Local node 1
   │  ├─ AzLHOST2  -> Arc-enabled server -> Azure Local node 2
   │  └─ AzLMGMT   -> Nested Hyper-V host
   │     ├─ JumpstartDC -> AD DS + DNS for jumpstart.local
   │     └─ Vm-Router   -> Routing + NAT between lab VLANs
   ├─ Azure Local cluster resource
   ├─ Custom Location (typically jumpstart-cl)
   ├─ Arc Resource Bridge appliance
   ├─ Azure VNet / subnets / NSG / NAT Gateway
   └─ Log Analytics workspace and monitoring resources

Nested networks
├─ Management network : 192.168.1.0/24
├─ VM network         : 192.168.200.0/24 (VLAN 200)
└─ AKS network        : 10.10.0.0/24    (VLAN 110)
'@
    Write-Host $diagram -ForegroundColor Magenta

    Write-Step -What 'Explaining what each major component does.' -Why 'Architecture only sticks when every box has a clear purpose.'
    Write-Host '• LocalBox-Client: the Azure VM that hosts the whole emulated datacenter.' -ForegroundColor Yellow
    Write-Host '• AzLHOST1 / AzLHOST2: the two Azure Local nodes that provide compute and storage.' -ForegroundColor Yellow
    Write-Host '• AzLMGMT: a nested management hypervisor that hosts infrastructure VMs.' -ForegroundColor Yellow
    Write-Host '• JumpstartDC: local Active Directory and DNS for the jumpstart.local domain.' -ForegroundColor Yellow
    Write-Host '• Vm-Router: gateway between management, VM, and AKS VLANs plus NAT to Azure/internet.' -ForegroundColor Yellow
    Write-Host '• Arc-enabled servers: Azure representations of the local hosts for governance and monitoring.' -ForegroundColor Yellow
    Write-Host '• Azure Local cluster resource: Azure-side management object for the HCI cluster.' -ForegroundColor Yellow
    Write-Host '• Custom Location: placement abstraction for deploying Azure resources onto the cluster.' -ForegroundColor Yellow
    Write-Host '• Arc Resource Bridge: translation layer between Azure Resource Manager and local infrastructure.' -ForegroundColor Yellow
    Write-Host '• Azure VNet / NSG / NAT Gateway: the cloud network shell around the lab environment.' -ForegroundColor Yellow

    # =============================================
    # NESTED EXPLORATION - Virtualization & Networking
    # =============================================

    Write-Step -What 'Exploring Hyper-V virtualization and networking on LocalBox-Client.' -Why 'This shows how the entire Azure Local lab is running as nested VMs inside a single Azure VM.'

    # Batch all LocalBox-Client queries into a single run-command to avoid conflicts
    $localBoxScript = @'
$sections = @()
$sections += "--- NESTED VMs ---"
$sections += (Get-VM | Format-Table Name, State, CPUUsage, @{N='MemoryGB';E={[math]::Round($_.MemoryAssigned/1GB,1)}}, Uptime -AutoSize | Out-String)
$sections += "--- VIRTUAL SWITCHES ---"
$sections += (Get-VMSwitch | Format-Table Name, SwitchType, NetAdapterInterfaceDescription -AutoSize | Out-String)
$sections += "--- HOST IP CONFIGURATION ---"
$sections += (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notlike "Loopback*" } | Sort-Object InterfaceAlias | Format-Table InterfaceAlias, IPAddress, PrefixLength -AutoSize | Out-String)
$sections += "--- HOST ROUTES (non-link-local) ---"
$sections += (Get-NetRoute -AddressFamily IPv4 | Where-Object { $_.DestinationPrefix -ne '255.255.255.255/32' -and $_.NextHop -ne '0.0.0.0' } | Sort-Object DestinationPrefix | Format-Table DestinationPrefix, NextHop, @{N='Interface';E={$_.InterfaceAlias}} -AutoSize | Out-String)
$sections -join "`n"
'@

    Write-Command -Command 'Get-VM; Get-VMSwitch; Get-NetIPAddress; Get-NetRoute' -Where 'LocalBox-Client'
    $localBoxOutput = Invoke-LocalBoxCommand -ResourceGroup $ResourceGroup -ScriptText $localBoxScript
    if ($localBoxOutput) { Write-Host $localBoxOutput } else { Write-Warn 'No output received from LocalBox-Client run-command.' }
    Write-Info 'AzLHOST1/2 are the Azure Local cluster nodes. AzLMGMT hosts infrastructure VMs (DC, Router).'
    Write-Info 'The virtual switches isolate traffic between management, VM, and storage VLANs.'

    Write-Step -What 'Exploring AzLHOST1 — Azure Local cluster node.' -Why 'The cluster nodes run Storage Spaces Direct and host workload VMs.'

    # Batch cluster queries into one nested command
    $clusterScript = @'
$sections = @()
$sections += "--- CLUSTER NODES ---"
$sections += (Get-ClusterNode | Format-Table Name, State -AutoSize | Out-String)
$sections += "--- CLUSTER NETWORKS ---"
$sections += (Get-ClusterNetwork | Format-Table Name, Address, AddressMask, Role -AutoSize | Out-String)
$sections += "--- STORAGE POOLS (non-primordial) ---"
$sections += (Get-StoragePool | Where-Object { $_.IsPrimordial -eq $false } | Format-Table FriendlyName, OperationalStatus, @{N='SizeGB';E={[math]::Round($_.Size/1GB)}} -AutoSize | Out-String)
$sections += "--- CLUSTER SHARED VOLUMES ---"
$sections += (Get-ClusterSharedVolume | Format-Table Name, State -AutoSize | Out-String)
$sections -join "`n"
'@

    Write-Command -Command 'Get-ClusterNode; Get-ClusterNetwork; Get-StoragePool; Get-ClusterSharedVolume' -Where 'AzLHOST1'
    $clusterOutput = Invoke-NestedHostCommand -ResourceGroup $ResourceGroup -ComputerName 'AzLHOST1' -Password $Password -ScriptText $clusterScript
    if ($clusterOutput) { Write-Host $clusterOutput } else { Write-Warn 'No output received from AzLHOST1.' }
    Write-Info 'Both nodes should be Up. Storage Spaces Direct pools local disks into shared resilient storage.'

    Write-Step -What 'Exploring AzLMGMT and Vm-Router — management infrastructure.' -Why 'AzLMGMT hosts the domain controller and router. The router interconnects all VLANs.'

    # Batch AzLMGMT + Vm-Router queries
    $mgmtScript = @'
$sections = @()
$sections += "--- VMs ON AzLMGMT ---"
$sections += (Get-VM | Format-Table Name, State -AutoSize | Out-String)
$sections += "--- Vm-Router IP ADDRESSES ---"
$innerCred = [pscredential]::new('jumpstart\Administrator', (ConvertTo-SecureString '{PASSWORD}' -AsPlainText -Force))
$routerIPs = Invoke-Command -ComputerName 'Vm-Router' -Credential $innerCred -ScriptBlock {
    Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notlike "Loopback*" -and $_.IPAddress -ne "127.0.0.1" } | Sort-Object InterfaceAlias | Format-Table InterfaceAlias, IPAddress, PrefixLength -AutoSize | Out-String
}
$sections += $routerIPs
$sections += "--- Vm-Router ROUTING TABLE ---"
$routerRoutes = Invoke-Command -ComputerName 'Vm-Router' -Credential $innerCred -ScriptBlock {
    Get-NetRoute -AddressFamily IPv4 | Where-Object { $_.DestinationPrefix -ne '255.255.255.255/32' -and $_.NextHop -ne '0.0.0.0' } | Sort-Object DestinationPrefix | Format-Table DestinationPrefix, NextHop, @{N='Interface';E={$_.InterfaceAlias}} -AutoSize | Out-String
}
$sections += $routerRoutes
$sections -join "`n"
'@ -replace '\{PASSWORD\}', $Password.Replace("'", "''")

    Write-Command -Command 'Get-VM (AzLMGMT); Get-NetIPAddress, Get-NetRoute (Vm-Router)' -Where 'AzLMGMT'
    $mgmtOutput = Invoke-NestedHostCommand -ResourceGroup $ResourceGroup -ComputerName 'AzLMGMT' -Password $Password -ScriptText $mgmtScript
    if ($mgmtOutput) { Write-Host $mgmtOutput } else { Write-Warn 'No output received from AzLMGMT.' }
    Write-Info 'The router has interfaces on management (192.168.1.x), VM (192.168.200.x), and AKS (10.10.0.x) VLANs.'
    Write-Info 'Its default route points to the Azure VNet gateway for internet access via Azure.'

    Write-Banner 'Architecture exploration completed'
}
catch {
    Write-Fail $_.Exception.Message
    exit 1
}
