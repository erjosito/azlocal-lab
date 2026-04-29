#####################################################################
# cleanup.ps1 — Delete all LocalBox resources
#
# WARNING: This permanently destroys all resources in the resource
# group. This action cannot be undone.
#####################################################################

param(
    [Parameter(Mandatory)][string]$ResourceGroup,
    [switch]$Yes
)

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " LocalBox Cleanup"
Write-Host " Resource Group: $ResourceGroup"
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""

# Check resource group exists
Write-Host -NoNewline "Checking resource group... "
$rgExists = az group exists -n $ResourceGroup 2>$null
if ($rgExists -ne "true") {
    Write-Host "NOT FOUND" -ForegroundColor Yellow
    Write-Host "Resource group '$ResourceGroup' does not exist. Nothing to clean up."
    exit 0
}

# Count resources
$resourceCount = az resource list -g $ResourceGroup --query "length(@)" -o tsv 2>$null
Write-Host "Found ($resourceCount resources)" -ForegroundColor Green

Write-Host ""
Write-Host "WARNING: This will PERMANENTLY DELETE all resources in '$ResourceGroup'." -ForegroundColor Red
Write-Host "   This includes VMs, disks, networks, Key Vaults, and all data."
Write-Host ""

if (-not $Yes) {
    $confirm = Read-Host "Type the resource group name to confirm"
    if ($confirm -ne $ResourceGroup) {
        Write-Host "Names don't match. Aborting." -ForegroundColor Yellow
        exit 1
    }
}

Write-Host ""
Write-Host "Deleting resource group '$ResourceGroup'..."
Write-Host "This may take 10-15 minutes."
Write-Host ""

az group delete --name $ResourceGroup --yes --no-wait

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " Cleanup Initiated" -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Resource group deletion is in progress (running in background)."
Write-Host "  Monitor status in Azure Portal or with:"
Write-Host "    az group exists -n $ResourceGroup"
Write-Host ""
Write-Host "  Also clean up the cloned repo if no longer needed:"
Write-Host "    Remove-Item -Recurse -Force azure_arc"
