#####################################################################
# start-environment.ps1 — Start a previously deallocated LocalBox VM
#
# After starting, prints connection details so you can RDP back in.
# The nested VMs (AzLHOST1, AzLHOST2, etc.) start automatically
# because they are configured to auto-start inside Hyper-V.
#####################################################################

param(
    [Parameter(Mandatory)][string]$ResourceGroup
)

$VmName = "LocalBox-Client"

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " Starting LocalBox Environment"
Write-Host " Resource Group: $ResourceGroup"
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""

# Check VM exists
Write-Host -NoNewline "Finding VM '$VmName'... "
$vmId = az vm show -g $ResourceGroup -n $VmName --query "id" -o tsv 2>$null
if (-not $vmId) {
    Write-Host "NOT FOUND" -ForegroundColor Red
    Write-Host "ERROR: VM '$VmName' not found in resource group '$ResourceGroup'."
    exit 1
}
Write-Host "Found" -ForegroundColor Green

# Get current power state
$powerState = az vm get-instance-view -g $ResourceGroup -n $VmName `
    --query 'instanceView.statuses[?starts_with(code,`PowerState/`)].displayStatus' -o tsv
Write-Host "  Current state: $powerState"

if ($powerState -eq "VM running") {
    Write-Host ""
    Write-Host "VM is already running."
} else {
    Write-Host ""
    Write-Host "Starting VM (this may take a few minutes)..."
    az vm start -g $ResourceGroup -n $VmName
    Write-Host "VM started successfully." -ForegroundColor Green
}

# Wait for VM to be ready, then ensure nested VMs are running
Write-Host ""
Write-Host "Retrieving connection details..."
Start-Sleep -Seconds 5

# Start nested VMs if they are off (they may not auto-start after host deallocation)
Write-Host ""
Write-Host "Ensuring nested Hyper-V VMs are running..."
$nestedResult = az vm run-command invoke -g $ResourceGroup -n $VmName `
    --command-id RunPowerShellScript `
    --scripts "Get-VM | Where-Object { `$_.State -ne 'Running' } | ForEach-Object { Start-VM -Name `$_.Name; Write-Output `"Started: `$(`$_.Name)`" }; Get-VM | Select-Object Name, State | Out-String" `
    --query "value[0].message" -o tsv 2>$null
if ($nestedResult) {
    Write-Host $nestedResult
}

# Reallocate Azure Firewall if present in the resource group
$fwName = az network firewall list -g $ResourceGroup --query "[0].name" -o tsv 2>$null
if ($fwName) {
    Write-Host ""
    Write-Host "Reallocating Azure Firewall '$fwName'..."
    # After deallocation ipConfigurations is empty, so look up PIP and subnet by name
    $fwPipName = "$fwName-pip"
    $fwPipId = az network public-ip show -g $ResourceGroup -n $fwPipName --query "id" -o tsv 2>$null
    $vnetName = az network vnet list -g $ResourceGroup --query "[0].name" -o tsv 2>$null
    $fwSubnetId = if ($vnetName) {
        az network vnet subnet show -g $ResourceGroup --vnet-name $vnetName -n AzureFirewallSubnet --query "id" -o tsv 2>$null
    }
    if ($fwPipId -and $fwSubnetId) {
        az network firewall ip-config create -g $ResourceGroup -f $fwName -n LocalBoxFirewallIpConfig --public-ip-address $fwPipId --vnet-name $vnetName --output none 2>$null
        Write-Host "  Azure Firewall reallocated." -ForegroundColor Green
    } else {
        Write-Host "  (Firewall PIP or subnet not found, skipping reallocation)" -ForegroundColor Yellow
    }
}

$publicIp = az vm show -g $ResourceGroup -n $VmName -d --query "publicIps" -o tsv 2>$null
$privateIp = az vm show -g $ResourceGroup -n $VmName -d --query "privateIps" -o tsv 2>$null
if (-not $publicIp) { $publicIp = "N/A" }
if (-not $privateIp) { $privateIp = "N/A" }

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " Environment Running" -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Public IP:  $publicIp"
Write-Host "  Private IP: $privateIp"
Write-Host ""
Write-Host "  Connect via RDP:"
Write-Host "    mstsc /v:$publicIp"
Write-Host ""
Write-Host "  " -NoNewline; Write-Host "If the IP changed since last time, update your NSG rule" -ForegroundColor Yellow
Write-Host "      to allow your current IP on port 3389."
Write-Host ""
Write-Host "  Nested VMs will auto-start within Hyper-V. Allow 10-15 minutes"
Write-Host "  for the full nested stack to become operational."
Write-Host ""
Write-Host "  Default domain credentials: administrator@jumpstart.local"
Write-Host "  (password is the same as your windowsAdminPassword)"
Write-Host ""
Write-Host "To stop when done: .\scripts\stop-environment.ps1 -ResourceGroup $ResourceGroup"
