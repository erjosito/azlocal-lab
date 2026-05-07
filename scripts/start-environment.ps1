#####################################################################
# start-environment.ps1 - Start a previously deallocated LocalBox VM
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

# ── 1. Ensure Azure Firewall is allocated (must be up before VM for outbound connectivity) ──
$fwResource = (az resource list -g $ResourceGroup --resource-type "Microsoft.Network/azureFirewalls" -o json 2>$null | ConvertFrom-Json) | Select-Object -First 1
if ($fwResource) {
    $fwName = $fwResource.name
    $fwDetail = az resource show --ids $fwResource.id -o json 2>$null | ConvertFrom-Json
    $hasIp = $fwDetail.properties.ipConfigurations -and $fwDetail.properties.ipConfigurations.Count -gt 0
    if ($hasIp) {
        $fwIp = $fwDetail.properties.ipConfigurations[0].properties.privateIPAddress
        Write-Host "Azure Firewall '$fwName' already allocated (IP: $fwIp)" -ForegroundColor Green
    } else {
        Write-Host "Reallocating Azure Firewall '$fwName' (this takes ~5-10 minutes)..."
        $fwPipName = "$fwName-pip"
        $fwPipId = az network public-ip show -g $ResourceGroup -n $fwPipName --query "id" -o tsv 2>$null
        $vnetName = (az network vnet list -g $ResourceGroup -o json 2>$null | ConvertFrom-Json) | Select-Object -First 1 -ExpandProperty name
        if ($fwPipId -and $vnetName) {
            az network firewall ip-config create -g $ResourceGroup -f $fwName -n LocalBoxFirewallIpConfig --public-ip-address $fwPipId --vnet-name $vnetName --output none
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  Azure Firewall reallocated." -ForegroundColor Green
            } else {
                Write-Host "  Azure Firewall reallocation failed (exit code $LASTEXITCODE)." -ForegroundColor Red
            }
        } else {
            Write-Host "  (Firewall PIP or VNet not found, skipping reallocation)" -ForegroundColor Yellow
        }
    }
    Write-Host ""
}

# ── 2. Start the VM ──
Write-Host -NoNewline "Finding VM '$VmName'... "
$vmId = az vm show -g $ResourceGroup -n $VmName --query "id" -o tsv 2>$null
if (-not $vmId) {
    Write-Host "NOT FOUND" -ForegroundColor Red
    Write-Host "ERROR: VM '$VmName' not found in resource group '$ResourceGroup'."
    exit 1
}
Write-Host "Found" -ForegroundColor Green

$powerState = (az vm get-instance-view -g $ResourceGroup -n $VmName -o json 2>$null | ConvertFrom-Json).instanceView.statuses |
    Where-Object { $_.code -like 'PowerState/*' } | Select-Object -ExpandProperty displayStatus
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

# ── 3. Ensure nested Hyper-V VMs are running ──
Write-Host ""
Write-Host "Retrieving connection details..."
Start-Sleep -Seconds 5

Write-Host ""
Write-Host "Ensuring nested Hyper-V VMs are running..."
$nestedScript = 'Get-VM | Where-Object { $_.State -ne "Running" } | ForEach-Object { Start-VM -Name $_.Name; Write-Output "Started: $($_.Name)" }; Get-VM | Select-Object Name, State | Out-String'
$nestedRaw = az vm run-command invoke -g $ResourceGroup -n $VmName `
    --command-id RunPowerShellScript `
    --scripts $nestedScript `
    -o json 2>$null
# az on Windows may prefix output with CMD echo lines; extract JSON portion
$nestedJsonStr = ($nestedRaw | Out-String) -replace '(?s)^.*?(?=\{)', ''
$nestedResult = $null
if ($nestedJsonStr -match '^\{') {
    try { $nestedResult = ($nestedJsonStr | ConvertFrom-Json).value[0].message } catch {}
}
if ($nestedResult) {
    Write-Host $nestedResult
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
