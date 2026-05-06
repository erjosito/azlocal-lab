param(
    [Parameter(Mandatory)]
    [string]$ResourceGroup
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
            [pscustomobject]@{
                Name = $subnet.name
                Prefix = $subnet.addressPrefix
                NSG = if ($subnet.networkSecurityGroup) { ($subnet.networkSecurityGroup.id -split '/')[-1] } else { '-' }
                NatGateway = if ($subnet.natGateway) { ($subnet.natGateway.id -split '/')[-1] } else { '-' }
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
            [pscustomobject]@{
                Name = $nsg.name
                SecurityRules = @($nsg.securityRules).Count
            }
        }
        Show-TableFromObjects -InputObject $nsgRows -Property @('Name', 'SecurityRules')
        Write-Info 'The NSG controls which Azure-side traffic can reach LocalBox-Client, such as RDP or Bastion-related flows.'
    }

    if ($context.NatGateways) {
        Write-Host 'NAT gateways:' -ForegroundColor Green
        $natRows = foreach ($nat in @($context.NatGateways)) {
            [pscustomobject]@{
                Name = $nat.name
                PublicIPs = @($nat.publicIpAddresses).Count
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

    Write-Banner 'Architecture exploration completed'
}
catch {
    Write-Fail $_.Exception.Message
    exit 1
}
