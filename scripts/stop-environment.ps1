#####################################################################
# stop-environment.ps1 — Deallocate LocalBox VM to save costs
#
# Deallocating stops compute billing but keeps disks and networking.
# Disk charges (~$120/mo) and IP charges continue while deallocated.
#####################################################################

param(
    [Parameter(Mandatory)][string]$ResourceGroup
)

$VmName = "LocalBox-Client"

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " Stopping LocalBox Environment"
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

if ($powerState -eq "VM deallocated") {
    Write-Host ""
    Write-Host "VM is already deallocated. No action needed."
    exit 0
}

# Deallocate Azure Firewall first if present (saves ~$30/day)
$fwName = az network firewall list -g $ResourceGroup --query '[0].name' -o tsv 2>$null
if ($fwName) {
    Write-Host ""
    Write-Host "Deallocating Azure Firewall '$fwName' (saves ~`$30/day)..."
    az network firewall update -g $ResourceGroup -n $fwName --set "ipConfigurations=[]" 2>$null
    Write-Host "  Firewall deallocated." -ForegroundColor Green
}

# Deallocate
Write-Host ""
Write-Host "Deallocating VM (this may take a few minutes)..."
az vm deallocate -g $ResourceGroup -n $VmName

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " Environment Stopped" -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  " -NoNewline; Write-Host "Compute billing has stopped" -ForegroundColor Green
Write-Host "  " -NoNewline; Write-Host "Disk and static IP charges continue (~`$5/day)" -ForegroundColor Yellow
Write-Host "  " -NoNewline; Write-Host "Dynamic public IP will be released (new IP on restart)" -ForegroundColor Yellow
Write-Host ""
Write-Host "To restart: .\scripts\start-environment.ps1 -ResourceGroup $ResourceGroup"
Write-Host "To destroy: .\scripts\cleanup.ps1 -ResourceGroup $ResourceGroup"
