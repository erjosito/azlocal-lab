# Update the route table to allow direct return traffic to the current client IP,
# bypassing the Azure Firewall for RDP/SSH connectivity.
#
# Usage: .\scripts\update-client-route.ps1 [-ResourceGroup azlocal2]

param(
    [string]$ResourceGroup = "azlocal2"
)

$ErrorActionPreference = "Stop"
$RouteTable = "LocalBox-FW-RouteTable"
$RouteName = "clientIP"
$NsgName = "LocalBox-NSG"

# Get current public IP
Write-Host "Detecting current public IP..."
$ClientIP = (Invoke-RestMethod -Uri "https://ifconfig.me" -TimeoutSec 10).Trim()

if (-not ($ClientIP -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$')) {
    Write-Error "Could not detect public IP (got: '$ClientIP')"
    exit 1
}

Write-Host "Current public IP: $ClientIP"

# Check if route already exists with this IP
$Existing = az network route-table route show -g $ResourceGroup --route-table-name $RouteTable -n $RouteName --query "addressPrefix" -o tsv 2>$null

if ($Existing -eq "$ClientIP/32") {
    Write-Host "Route already up to date ($ClientIP/32 -> Internet). Nothing to do."
    exit 0
}

if ($Existing) {
    Write-Host "Updating route: $Existing -> $ClientIP/32"
} else {
    Write-Host "Creating route: $ClientIP/32 -> Internet"
}

az network route-table route create `
    -g $ResourceGroup `
    --route-table-name $RouteTable `
    -n $RouteName `
    --address-prefix "$ClientIP/32" `
    --next-hop-type Internet `
    --output none

Write-Host "`u{2713} Route updated: $ClientIP/32 -> Internet (bypass firewall for return traffic)" -ForegroundColor Green

# Also update NSG rules
Write-Host ""
Write-Host "Updating NSG inbound rules for $ClientIP..."

az network nsg rule create -g $ResourceGroup --nsg-name $NsgName `
    -n "Allow-SSH-in" --priority 4000 `
    --source-address-prefixes $ClientIP `
    --destination-port-ranges 22 `
    --access Allow --protocol Tcp --direction Inbound `
    --output none 2>$null

az network nsg rule create -g $ResourceGroup --nsg-name $NsgName `
    -n "Allow-RDP-in" --priority 4001 `
    --source-address-prefixes $ClientIP `
    --destination-port-ranges 3389 `
    --access Allow --protocol Tcp --direction Inbound `
    --output none 2>$null

Write-Host "`u{2713} NSG rules updated for SSH and RDP from $ClientIP" -ForegroundColor Green
