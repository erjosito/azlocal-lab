param(
    [Parameter(Mandatory)]
    [string]$ResourceGroup,

    [string]$NestedAdminPassword = 'Microsoft123!'
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Common.AzureLocalLab.ps1"

function Get-StackHciStoragePath {
    param([string]$ResourceGroup)

    $paths = @(Invoke-AzJson -Arguments @('stack-hci-vm', 'storagepath', 'list', '--resource-group', $ResourceGroup))
    if (-not $paths) {
        throw 'No Azure Local storage path resource was found. The cluster may not be ready for VM workloads yet.'
    }

    return $paths | Select-Object -First 1
}

function Get-LogicalNetwork {
    param(
        [string]$ResourceGroup,
        [string]$PreferredName,
        [string]$AddressPrefix
    )

    $logicalNetworks = @(Invoke-AzJson -Arguments @('stack-hci-vm', 'network', 'lnet', 'list', '--resource-group', $ResourceGroup))
    $match = $logicalNetworks | Where-Object {
        $_.name -eq $PreferredName -or
        (($_ | ConvertTo-Json -Depth 20) -match [regex]::Escape($AddressPrefix))
    } | Select-Object -First 1

    return $match
}

function Get-NetworkInterface {
    param(
        [string]$ResourceGroup,
        [string]$Name
    )

    return @(Invoke-AzJson -Arguments @('stack-hci-vm', 'network', 'nic', 'list', '--resource-group', $ResourceGroup)) |
        Where-Object { $_.name -eq $Name } |
        Select-Object -First 1
}

try {
    Write-Banner 'Exercise 02 - Networking and VMs'
    Write-Step -What 'Preparing Azure Local CLI extensions and dynamic context.' -Why 'VM deployment on Azure Local depends on stack-hci-vm resources plus the custom location that maps Azure to the cluster.'
    Ensure-AzExtension -Name 'customlocation' | Out-Null
    Ensure-AzExtension -Name 'stack-hci-vm' | Out-Null
    $context = Get-AzureLocalContext -ResourceGroup $ResourceGroup

    if (-not $context.CustomLocation) {
        throw 'No custom location was found. VM deployment on Azure Local requires a custom location.'
    }

    $location = $context.ClusterLocation
    $customLocationId = $context.CustomLocation.id
    $logicalNetworkName = 'vm-network-200'
    $imageName = 'win2022-marketplace'
    $vmName = 'azlocal-vm01'
    $computerName = 'AZLOCALVM01'
    $nicName = "$vmName-nic"
    $vmIpAddress = '192.168.200.20'
    $adminUserName = 'azurelocaladmin'

    Write-Step -What 'Checking whether the VM logical network already exists.' -Why 'Logical networks are the Azure Local equivalent of declaring a real VLAN-backed subnet that VMs can attach to.'
    $logicalNetwork = Get-LogicalNetwork -ResourceGroup $ResourceGroup -PreferredName $logicalNetworkName -AddressPrefix '192.168.200.0/24'
    if (-not $logicalNetwork) {
        Write-Info 'Creating logical network 192.168.200.0/24 on VLAN 200 with static IP allocation.'
        $null = Invoke-AzJson -Arguments @(
            'stack-hci-vm', 'network', 'lnet', 'create',
            '--resource-group', $ResourceGroup,
            '--name', $logicalNetworkName,
            '--location', $location,
            '--custom-location', $customLocationId,
            '--vm-switch-name', 'ConvergedSwitch(oob-hci)',
            '--address-prefixes', '192.168.200.0/24',
            '--gateway', '192.168.200.1',
            '--dns-servers', '192.168.1.254',
            '--ip-allocation-method', 'Static',
            '--ip-pool-type', 'vm',
            '--ip-pool-start', '192.168.200.10',
            '--ip-pool-end', '192.168.200.252',
            '--vlan', '200'
        )
        $logicalNetwork = Get-LogicalNetwork -ResourceGroup $ResourceGroup -PreferredName $logicalNetworkName -AddressPrefix '192.168.200.0/24'
        Write-Success "Logical network '$logicalNetworkName' created."
    }
    else {
        Write-Success "Logical network '$($logicalNetwork.name)' already exists, so the script will reuse it."
    }

    Write-Step -What 'Discovering a storage path for images and VM configuration files.' -Why 'Azure Local stores marketplace images and VM files on cluster storage, not in Azure managed disks.'
    $storagePath = Get-StackHciStoragePath -ResourceGroup $ResourceGroup
    Write-Success "Using storage path '$($storagePath.name)'."

    Write-Step -What 'Checking whether the Windows Server 2022 marketplace image is already present.' -Why 'Images are reusable cluster assets, so idempotent automation should create them once and reuse them for later VMs.'
    $image = @(Invoke-AzJson -Arguments @('stack-hci-vm', 'image', 'list', '--resource-group', $ResourceGroup)) |
        Where-Object { $_.name -eq $imageName } |
        Select-Object -First 1

    if (-not $image) {
        Write-Info 'Creating a marketplace-backed gallery image for Windows Server 2022 Datacenter.'
        $null = Invoke-AzJson -Arguments @(
            'stack-hci-vm', 'image', 'create',
            '--resource-group', $ResourceGroup,
            '--name', $imageName,
            '--location', $location,
            '--custom-location', $customLocationId,
            '--storage-path-id', $storagePath.id,
            '--os-type', 'Windows',
            '--publisher', 'MicrosoftWindowsServer',
            '--offer', 'WindowsServer',
            '--sku', '2022-datacenter',
            '--version', 'latest'
        )
        $image = @(Invoke-AzJson -Arguments @('stack-hci-vm', 'image', 'list', '--resource-group', $ResourceGroup)) |
            Where-Object { $_.name -eq $imageName } |
            Select-Object -First 1
        Write-Success "Image '$imageName' is now available for VM deployment."
    }
    else {
        Write-Success "Image '$imageName' already exists, so the script will reuse it."
    }

    Write-Step -What 'Checking the Azure Local NIC for the VM.' -Why 'On Azure Local the NIC is a first-class resource, which makes the logical network attachment explicit and reusable.'
    $nic = Get-NetworkInterface -ResourceGroup $ResourceGroup -Name $nicName
    if (-not $nic) {
        Write-Info "Creating NIC '$nicName' on logical network '$($logicalNetwork.name)' with IP $vmIpAddress."
        $null = Invoke-AzJson -Arguments @(
            'stack-hci-vm', 'network', 'nic', 'create',
            '--resource-group', $ResourceGroup,
            '--name', $nicName,
            '--location', $location,
            '--custom-location', $customLocationId,
            '--subnet-id', $logicalNetwork.id,
            '--ip-address', $vmIpAddress,
            '--dns-servers', '192.168.1.254'
        )
        $nic = Get-NetworkInterface -ResourceGroup $ResourceGroup -Name $nicName
        Write-Success "NIC '$nicName' created."
    }
    else {
        Write-Success "NIC '$nicName' already exists and will be reused."
    }

    Write-Step -What 'Checking whether the Azure Local VM already exists.' -Why 'VM creation is the expensive step, so the script must only create the guest once.'
    $vm = Invoke-AzJson -Arguments @('stack-hci-vm', 'show', '--resource-group', $ResourceGroup, '--name', $vmName) -AllowNotFound
    if (-not $vm) {
        Write-Info 'Creating the VM from the reusable gallery image and the explicit NIC resource.'
        $vm = Invoke-AzJson -Arguments @(
            'stack-hci-vm', 'create',
            '--resource-group', $ResourceGroup,
            '--name', $vmName,
            '--location', $location,
            '--custom-location', $customLocationId,
            '--computer-name', $computerName,
            '--admin-username', $adminUserName,
            '--admin-password', $NestedAdminPassword,
            '--authentication-type', 'password',
            '--image', $imageName,
            '--nics', $nic.id,
            '--storage-path-id', $storagePath.id,
            '--size', 'Default',
            '--enable-agent', 'true',
            '--enable-vm-config-agent', 'true'
        )
        Write-Success "VM '$vmName' created."
    }
    else {
        Write-Success "VM '$vmName' already exists, so the script will only report its current state."
    }

    Write-Step -What 'Displaying the final VM deployment summary.' -Why 'Students should clearly see the chain: logical network -> image -> NIC -> VM.'
    $vmSummary = Invoke-AzJson -Arguments @('stack-hci-vm', 'show', '--resource-group', $ResourceGroup, '--name', $vmName)
    [pscustomobject]@{
        Name = $vmSummary.name
        Id = $vmSummary.id
        ProvisioningState = $vmSummary.properties.provisioningState
        ComputerName = $vmSummary.properties.osProfile.computerName
        AdminUser = $adminUserName
        LogicalNetwork = $logicalNetwork.name
        RequestedIp = $vmIpAddress
    } | Format-Table -AutoSize | Out-String | Write-Host

    Write-Step -What 'Demonstrating nested host access with jumpstart\Administrator.' -Why 'A recurring lab lesson is that nested infrastructure uses local AD credentials, not Azure VM credentials, for host-level administration.'
    try {
        $hostnameResult = Invoke-NestedHostCommand -ResourceGroup $ResourceGroup -ComputerName 'AzLHOST1' -Password $NestedAdminPassword -ScriptText 'hostname'
        if ($hostnameResult) {
            Write-Success "Nested credential check succeeded against AzLHOST1: $($hostnameResult.Trim())"
        }
        else {
            Write-Warn 'Nested credential check returned no output, but the main Azure Local resources were created successfully.'
        }
    }
    catch {
        Write-Warn "Nested credential verification was not completed: $($_.Exception.Message)"
    }

    Write-Host 'Next exploration idea: RDP to LocalBox-Client, then use jumpstart\Administrator to inspect the new VM from the Azure Local hosts.' -ForegroundColor Magenta
    Write-Banner 'Networking and VM automation completed'
}
catch {
    Write-Fail $_.Exception.Message
    exit 1
}
