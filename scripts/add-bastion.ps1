#####################################################################
# add-bastion.ps1 — Add Azure Bastion to an existing LocalBox lab
#
# Deploys Azure Bastion so you can RDP into LocalBox-Client through
# the Azure Portal without needing a public IP NSG rule on port 3389.
# Useful when subscription policies remove inbound RDP rules.
#####################################################################

param(
    [Parameter(Mandatory)][string]$ResourceGroup,
    [string]$BastionName = "LocalBox-Bastion",
    [ValidateSet("Basic", "Standard")][string]$Sku = "Basic"
)

$ErrorActionPreference = "Stop"

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " Add Azure Bastion to LocalBox"
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " Resource Group : $ResourceGroup"
Write-Host " Bastion Name   : $BastionName"
Write-Host " SKU            : $Sku"
Write-Host "============================================="
Write-Host ""

# ── Find the VNet in the resource group ───────────────────────────
Write-Host "Looking for VNet in resource group '$ResourceGroup'..."
$vnetName = (az network vnet list -g $ResourceGroup -o json 2>$null | ConvertFrom-Json) | Select-Object -First 1 -ExpandProperty name

if ([string]::IsNullOrWhiteSpace($vnetName)) {
    Write-Host "ERROR: No VNet found in resource group '$ResourceGroup'." -ForegroundColor Red
    Write-Host "Is this the correct resource group for your LocalBox deployment?"
    exit 1
}
Write-Host "  Found VNet: $vnetName"

# ── Check if AzureBastionSubnet exists ────────────────────────────
Write-Host "Checking for AzureBastionSubnet..."
$bastionSubnet = az network vnet subnet show -g $ResourceGroup `
    --vnet-name $vnetName -n AzureBastionSubnet `
    --query "name" -o tsv 2>$null

if ([string]::IsNullOrWhiteSpace($bastionSubnet)) {
    Write-Host "  AzureBastionSubnet not found. Creating it..."

    # Get VNet address space
    $vnetPrefixes = az network vnet show -g $ResourceGroup -n $vnetName `
        --query "addressSpace.addressPrefixes" -o tsv
    Write-Host "  VNet address space: $vnetPrefixes"

    # Propose a /26 subnet that fits the LocalBox VNet (172.16.x.x)
    $bastionPrefix = "172.16.3.128/26"
    Write-Host ""
    Write-Host "  Azure Bastion requires a dedicated subnet named 'AzureBastionSubnet'"
    Write-Host "  with at least a /26 prefix. Proposed: $bastionPrefix"
    $subnetInput = Read-Host "  Use this prefix? [Y/n, or enter a custom /26 CIDR]"
    if ([string]::IsNullOrWhiteSpace($subnetInput)) { $subnetInput = "Y" }

    if ($subnetInput -match '^[Yy]$') {
        # Keep default
    } elseif ($subnetInput -match '/') {
        $bastionPrefix = $subnetInput
    }

    az network vnet subnet create `
        -g $ResourceGroup `
        --vnet-name $vnetName `
        -n AzureBastionSubnet `
        --address-prefixes $bastionPrefix `
        --output none

    Write-Host "  $(([char]0x2713)) AzureBastionSubnet created with prefix $bastionPrefix" -ForegroundColor Green
} else {
    Write-Host "  $(([char]0x2713)) AzureBastionSubnet already exists" -ForegroundColor Green
}

# ── Create public IP for Bastion ──────────────────────────────────
$bastionPip = "$BastionName-pip"
Write-Host ""
Write-Host "Creating public IP for Bastion..."
az network public-ip create `
    -g $ResourceGroup `
    -n $bastionPip `
    --sku Standard `
    --allocation-method Static `
    --output none
Write-Host "  $(([char]0x2713)) Public IP created: $bastionPip" -ForegroundColor Green

# ── Deploy Bastion ────────────────────────────────────────────────
Write-Host ""
Write-Host "Deploying Azure Bastion (this takes 5-10 minutes)..."
az network bastion create `
    -g $ResourceGroup `
    -n $BastionName `
    --public-ip-address $bastionPip `
    --vnet-name $vnetName `
    --sku $Sku `
    --output none

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " Azure Bastion Deployed Successfully!" -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  To connect to LocalBox-Client:"
Write-Host ""
Write-Host "  Option 1 - Azure Portal:"
Write-Host "    Go to the LocalBox-Client VM > Connect > Bastion"
Write-Host ""
if ($Sku -eq "Standard") {
    Write-Host "  Option 2 - Native client (Standard SKU):"
    Write-Host "    `$vmId = az vm show -g $ResourceGroup -n LocalBox-Client --query id -o tsv"
    Write-Host "    az network bastion rdp -g $ResourceGroup -n $BastionName --target-resource-id `$vmId"
    Write-Host ""
}
Write-Host "  Bastion provides RDP access without needing port 3389 open in NSG rules."
Write-Host ""
Write-Host "  Estimated additional cost: ~`$140/month (Basic) or ~`$350/month (Standard)"
