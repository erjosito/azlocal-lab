#####################################################################
# deploy-firewall.ps1 - Deploy Azure Firewall for a LocalBox lab
#
# Creates a dedicated Azure Firewall subnet, public IP, firewall policy,
# diagnostics, and a default route so LocalBox-Subnet egress flows through
# Azure Firewall.
#
# Cost note: Azure Firewall Standard costs ~$30/day while running.
#
# Usage:
#   .\scripts\deploy-firewall.ps1 -ResourceGroup azlocal
#   .\scripts\deploy-firewall.ps1 -ResourceGroup azlocal -Location swedencentral
#####################################################################

param(
    [Parameter(Mandatory)][string]$ResourceGroup,
    [string]$Location,
    [string]$FirewallName = "LocalBox-Firewall"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$VnetName = "LocalBox-VNet"
$WorkloadSubnetName = "LocalBox-Subnet"
$FirewallSubnetName = "AzureFirewallSubnet"
$FirewallSubnetPrefix = "172.16.2.0/26"
$PublicIpName = "$FirewallName-pip"
$PolicyName = "$FirewallName-Policy"
$ApplicationRcgName = "LocalBox-App-RCG"
$NatRcgName = "LocalBox-NAT-RCG"
$NetworkRcgName = "LocalBox-Network-RCG"
$RouteTableName = "LocalBox-FW-RouteTable"
$DefaultRouteName = "DefaultToFirewall"
$DiagSettingName = "$FirewallName-Diagnostics"
$FallbackWorkspaceName = "LocalBox-FW-Workspace"

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host $Message -ForegroundColor Cyan
}

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " Deploy Azure Firewall for LocalBox"
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " Resource Group : $ResourceGroup"
Write-Host " Firewall Name  : $FirewallName"
Write-Host "============================================="

# -- Validate prerequisites --
$rgExists = az group exists -n $ResourceGroup -o tsv
if ($rgExists -ne "true") {
    throw "Resource group '$ResourceGroup' does not exist."
}

if ([string]::IsNullOrWhiteSpace($Location)) {
    $Location = az group show -n $ResourceGroup --query "location" -o tsv
}

Write-Host " Location       : $Location"
Write-Host " VNet           : $VnetName"
Write-Host " Firewall Policy: $PolicyName"

# -- Ensure VNet and subnets --
Write-Step "Checking LocalBox networking"
$vnetExists = az network vnet show -g $ResourceGroup -n $VnetName --query "id" -o tsv 2>$null
if (-not $vnetExists) {
    throw "VNet '$VnetName' was not found in resource group '$ResourceGroup'."
}

$firewallSubnetId = az network vnet subnet show -g $ResourceGroup --vnet-name $VnetName -n $FirewallSubnetName --query "id" -o tsv 2>$null
if (-not $firewallSubnetId) {
    Write-Host "Creating $FirewallSubnetName ($FirewallSubnetPrefix)..."
    az network vnet subnet create -g $ResourceGroup --vnet-name $VnetName `
        -n $FirewallSubnetName --address-prefixes $FirewallSubnetPrefix -o none
} else {
    Write-Host "$FirewallSubnetName already exists."
}

# -- Ensure public IP --
Write-Step "Ensuring firewall public IP"
$publicIpExists = az network public-ip show -g $ResourceGroup -n $PublicIpName --query "id" -o tsv 2>$null
if (-not $publicIpExists) {
    Write-Host "Creating public IP '$PublicIpName'..."
    az network public-ip create -g $ResourceGroup -n $PublicIpName -l $Location `
        --sku Standard --allocation-method Static -o none
} else {
    Write-Host "Public IP '$PublicIpName' already exists."
}

$firewallPublicIpAddress = az network public-ip show -g $ResourceGroup -n $PublicIpName --query "ipAddress" -o tsv

# -- Ensure firewall policy --
Write-Step "Ensuring firewall policy"
$policyExists = az network firewall policy show -g $ResourceGroup -n $PolicyName --query "id" -o tsv 2>$null
if (-not $policyExists) {
    Write-Host "Creating firewall policy '$PolicyName'..."
    az network firewall policy create -g $ResourceGroup -n $PolicyName -l $Location `
        --threat-intel-mode Alert -o none
} else {
    Write-Host "Firewall policy '$PolicyName' already exists."
}

# -- Application rule collection group (allow all HTTP/S) --
$appRcgExists = az network firewall policy rule-collection-group show -g $ResourceGroup `
    --policy-name $PolicyName -n $ApplicationRcgName --query "id" -o tsv 2>$null
if (-not $appRcgExists) {
    Write-Host "Creating application rule collection group '$ApplicationRcgName'..."
    az network firewall policy rule-collection-group create -g $ResourceGroup `
        --policy-name $PolicyName -n $ApplicationRcgName --priority 100 -o none
    az network firewall policy rule-collection-group collection add-filter-collection `
        -g $ResourceGroup --policy-name $PolicyName --rule-collection-group-name $ApplicationRcgName `
        -n "AllowAll" --collection-priority 100 --action Allow --rule-type ApplicationRule `
        --rule-name "permit-any" --source-addresses "*" --target-fqdns "*" `
        --protocols Http=80 Https=443 -o none
} else {
    Write-Host "Application rule collection group '$ApplicationRcgName' already exists."
}

# -- Network rule collection group --
$networkRcgExists = az network firewall policy rule-collection-group show -g $ResourceGroup `
    --policy-name $PolicyName -n $NetworkRcgName --query "id" -o tsv 2>$null
if (-not $networkRcgExists) {
    Write-Host "Creating network rule collection group '$NetworkRcgName'..."
    az network firewall policy rule-collection-group create -g $ResourceGroup `
        --policy-name $PolicyName -n $NetworkRcgName --priority 200 -o none

    # DNS — Allow outbound DNS to Azure DNS and external resolvers
    Write-Host "  Adding DNS rules (UDP/TCP 53)..."
    az network firewall policy rule-collection-group collection add-filter-collection `
        -g $ResourceGroup --policy-name $PolicyName --rule-collection-group-name $NetworkRcgName `
        -n "AllowDNS" --collection-priority 200 --action Allow --rule-type NetworkRule `
        --rule-name "allow-dns-udp" --source-addresses "172.16.1.0/24" `
        --destination-addresses "*" --destination-ports 53 --ip-protocols UDP -o none
    az network firewall policy rule-collection-group collection rule add `
        -g $ResourceGroup --policy-name $PolicyName --rule-collection-group-name $NetworkRcgName `
        --collection-name "AllowDNS" --rule-type NetworkRule `
        -n "allow-dns-tcp" --source-addresses "172.16.1.0/24" `
        --destination-addresses "*" --destination-ports 53 --ip-protocols TCP -o none

    # NTP — Allow time sync
    Write-Host "  Adding NTP rule (UDP 123)..."
    az network firewall policy rule-collection-group collection add-filter-collection `
        -g $ResourceGroup --policy-name $PolicyName --rule-collection-group-name $NetworkRcgName `
        -n "AllowNTP" --collection-priority 210 --action Allow --rule-type NetworkRule `
        --rule-name "allow-ntp" --source-addresses "172.16.1.0/24" `
        --destination-addresses "*" --destination-ports 123 --ip-protocols UDP -o none

    # Azure services — Allow HTTPS to AzureCloud service tag (Arc, HCI, etc.)
    Write-Host "  Adding Azure service rules (TCP 443 to AzureCloud)..."
    az network firewall policy rule-collection-group collection add-filter-collection `
        -g $ResourceGroup --policy-name $PolicyName --rule-collection-group-name $NetworkRcgName `
        -n "AllowAzureServices" --collection-priority 220 --action Allow --rule-type NetworkRule `
        --rule-name "allow-azure-https" --source-addresses "172.16.1.0/24" `
        --destination-addresses "AzureCloud" --destination-ports 443 --ip-protocols TCP -o none
    az network firewall policy rule-collection-group collection rule add `
        -g $ResourceGroup --policy-name $PolicyName --rule-collection-group-name $NetworkRcgName `
        --collection-name "AllowAzureServices" --rule-type NetworkRule `
        -n "allow-azure-smb" --source-addresses "172.16.1.0/24" `
        --destination-addresses "AzureCloud" --destination-ports 445 --ip-protocols TCP -o none
    az network firewall policy rule-collection-group collection rule add `
        -g $ResourceGroup --policy-name $PolicyName --rule-collection-group-name $NetworkRcgName `
        --collection-name "AllowAzureServices" --rule-type NetworkRule `
        -n "allow-azure-quic" --source-addresses "172.16.1.0/24" `
        --destination-addresses "AzureCloud" --destination-ports 443 --ip-protocols UDP -o none

    # Azure Monitor — Allow HTTPS to AzureMonitor service tag
    Write-Host "  Adding Azure Monitor rule..."
    az network firewall policy rule-collection-group collection rule add `
        -g $ResourceGroup --policy-name $PolicyName --rule-collection-group-name $NetworkRcgName `
        --collection-name "AllowAzureServices" --rule-type NetworkRule `
        -n "allow-azure-monitor" --source-addresses "172.16.1.0/24" `
        --destination-addresses "AzureMonitor" --destination-ports 443 --ip-protocols TCP -o none
} else {
    Write-Host "Network rule collection group '$NetworkRcgName' already exists."
}

# -- DNAT rule for RDP access --
Write-Step "Ensuring DNAT rule for RDP access"
$clientPrivateIp = az vm show -g $ResourceGroup -n "LocalBox-Client" -d --query "privateIps" -o tsv 2>$null

if (-not $clientPrivateIp) {
    Write-Host "  WARNING: Could not find LocalBox-Client private IP. Skipping DNAT rule." -ForegroundColor Yellow
} else {
    Write-Host "  LocalBox-Client private IP: $clientPrivateIp"

    # Auto-detect caller's public IP for source restriction
    $myPublicIp = try { (Invoke-RestMethod -Uri "https://ifconfig.me/ip" -TimeoutSec 5).Trim() } catch { $null }
    if ($myPublicIp) {
        Write-Host "  Your public IP: $myPublicIp"
        $confirmIp = Read-Host "  Restrict DNAT source to $myPublicIp? [Y/n]"
        if ([string]::IsNullOrWhiteSpace($confirmIp) -or $confirmIp -match '^[Yy]') {
            $dnatSourceAddress = $myPublicIp
        } else {
            $dnatSourceAddress = "*"
            Write-Host "  Using '*' (any source). Consider restricting later for security." -ForegroundColor Yellow
        }
    } else {
        Write-Host "  Could not detect public IP. Using '*' (any source)." -ForegroundColor Yellow
        $dnatSourceAddress = "*"
    }

    $natRcgExists = az network firewall policy rule-collection-group show -g $ResourceGroup `
        --policy-name $PolicyName -n $NatRcgName --query "id" -o tsv 2>$null
    if (-not $natRcgExists) {
        Write-Host "  Creating NAT rule collection group '$NatRcgName' (RDP -> $clientPrivateIp, source: $dnatSourceAddress)..."
        az network firewall policy rule-collection-group create -g $ResourceGroup `
            --policy-name $PolicyName -n $NatRcgName --priority 150 -o none
        az network firewall policy rule-collection-group collection add-nat-collection `
            -g $ResourceGroup --policy-name $PolicyName --rule-collection-group-name $NatRcgName `
            -n "InboundRDP" --collection-priority 150 --action DNAT `
            --rule-name "RDP-to-LocalBox-Client" `
            --source-addresses $dnatSourceAddress `
            --destination-addresses $firewallPublicIpAddress `
            --destination-ports 3389 `
            --ip-protocols TCP `
            --translated-address $clientPrivateIp `
            --translated-port 3389 -o none
    } else {
        Write-Host "  NAT rule collection group '$NatRcgName' already exists."
    }
}

# -- Deploy Azure Firewall --
Write-Step "Ensuring Azure Firewall"
$firewallState = az network firewall show -g $ResourceGroup -n $FirewallName --query "provisioningState" -o tsv 2>$null
if (-not $firewallState) {
    Write-Host "Creating Azure Firewall '$FirewallName' (this takes 5-10 minutes)..."
    az network firewall create -g $ResourceGroup -n $FirewallName -l $Location `
        --policy $PolicyName --vnet-name $VnetName `
        --conf-name "LocalBoxFirewallIpConfig" --public-ip $PublicIpName -o none
} else {
    Write-Host "Azure Firewall '$FirewallName' already exists ($firewallState)."
}

# Ensure IP configuration is bound (az network firewall create sometimes creates without it)
Write-Host "Verifying IP configuration..."
$firewallPrivateIp = az network firewall show -g $ResourceGroup -n $FirewallName `
    --query 'ipConfigurations[0].privateIpAddress' -o tsv 2>$null
if (-not $firewallPrivateIp -or $firewallPrivateIp -eq "None") {
    Write-Host "  IP config not bound yet. Adding explicitly..."
    az network firewall ip-config create -g $ResourceGroup -f $FirewallName `
        -n "LocalBoxFirewallIpConfig" `
        --public-ip-address $PublicIpName --vnet-name $VnetName -o none
}

# Wait for firewall private IP
Write-Host "Waiting for firewall private IP..."
$firewallPrivateIp = $null
for ($attempt = 1; $attempt -le 30; $attempt++) {
    $firewallPrivateIp = az network firewall show -g $ResourceGroup -n $FirewallName `
        --query 'ipConfigurations[0].privateIpAddress' -o tsv 2>$null
    if ($firewallPrivateIp -and $firewallPrivateIp -ne "None") { break }
    Start-Sleep -Seconds 10
}
if (-not $firewallPrivateIp -or $firewallPrivateIp -eq "None") {
    throw "Timed out waiting for Azure Firewall private IP."
}
Write-Host "  Firewall private IP: $firewallPrivateIp"

# -- Log Analytics and diagnostics --
Write-Step "Ensuring Log Analytics workspace and diagnostics"
$workspaces = az monitor log-analytics workspace list -g $ResourceGroup -o json 2>$null | ConvertFrom-Json
$matchingWorkspace = $workspaces | Where-Object { $_.name -like "*Workspace*" } | Select-Object -First 1

if (-not $matchingWorkspace) {
    $matchingWorkspace = $workspaces | Select-Object -First 1
}
if (-not $matchingWorkspace) {
    Write-Host "No matching workspace found. Creating '$FallbackWorkspaceName'..."
    az monitor log-analytics workspace create -g $ResourceGroup -n $FallbackWorkspaceName -l $Location -o none --only-show-errors
    $matchingWorkspace = az monitor log-analytics workspace show -g $ResourceGroup -n $FallbackWorkspaceName -o json --only-show-errors | ConvertFrom-Json
} else {
    Write-Host "Using Log Analytics workspace '$($matchingWorkspace.name)'."
}

$firewallId = az network firewall show -g $ResourceGroup -n $FirewallName --query "id" -o tsv --only-show-errors

# Check if diagnostic settings already exist
$existingDiag = az monitor diagnostic-settings list --resource $firewallId -o json --only-show-errors 2>$null | ConvertFrom-Json
$diagExists = $false
if ($existingDiag -and $existingDiag.value) {
    $diagExists = ($existingDiag.value | Where-Object { $_.name -eq $DiagSettingName }).Count -gt 0
} elseif ($existingDiag -is [array]) {
    $diagExists = ($existingDiag | Where-Object { $_.name -eq $DiagSettingName }).Count -gt 0
}

if (-not $diagExists) {
    Write-Host "Creating diagnostic settings '$DiagSettingName' (all logs -> $($matchingWorkspace.name))..."
    $logsJson = '[{\"categoryGroup\":\"allLogs\",\"enabled\":true}]'
    $metricsJson = '[{\"category\":\"AllMetrics\",\"enabled\":true}]'
    az monitor diagnostic-settings create --resource $firewallId -n $DiagSettingName `
        --workspace $matchingWorkspace.id --export-to-resource-specific true `
        --logs $logsJson --metrics $metricsJson -o none --only-show-errors
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  WARNING: Failed to create diagnostic settings. Firewall logs may not flow." -ForegroundColor Yellow
    } else {
        Write-Host "  [OK] Diagnostic settings created. Logs will flow within 5-10 minutes."
    }
} else {
    Write-Host "Diagnostic settings '$DiagSettingName' already exist."
}

# -- Route table --
Write-Step "Ensuring route table and subnet association"
$routeTableExists = az network route-table show -g $ResourceGroup -n $RouteTableName --query "id" -o tsv 2>$null
if (-not $routeTableExists) {
    Write-Host "Creating route table '$RouteTableName'..."
    az network route-table create -g $ResourceGroup -n $RouteTableName -l $Location -o none
} else {
    Write-Host "Route table '$RouteTableName' already exists."
}

az network route-table route create -g $ResourceGroup --route-table-name $RouteTableName `
    -n $DefaultRouteName --address-prefix "0.0.0.0/0" `
    --next-hop-type VirtualAppliance --next-hop-ip-address $firewallPrivateIp -o none 2>$null

# Associate route table with workload subnet
$currentRt = az network vnet subnet show -g $ResourceGroup --vnet-name $VnetName `
    -n $WorkloadSubnetName --query "routeTable.id" -o tsv 2>$null
if (-not $currentRt) {
    Write-Host "Associating route table with '$WorkloadSubnetName'..."
    az network vnet subnet update -g $ResourceGroup --vnet-name $VnetName `
        -n $WorkloadSubnetName --route-table $RouteTableName -o none
} else {
    Write-Host "Route table already associated with '$WorkloadSubnetName'."
}

# -- Summary --
Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " Azure Firewall Ready" -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " Firewall private IP : $firewallPrivateIp"
Write-Host " Firewall public IP  : $firewallPublicIpAddress"
Write-Host " Route table         : $RouteTableName"
Write-Host " Workspace           : $($matchingWorkspace.name)"
Write-Host ""
Write-Host "Traffic from $WorkloadSubnetName now uses Azure Firewall as its default egress path."
if ($clientPrivateIp) {
    Write-Host ""
    Write-Host "RDP access via DNAT:" -ForegroundColor Cyan
    Write-Host "  mstsc /v:$firewallPublicIpAddress"
    Write-Host "  (Firewall forwards port 3389 -> $clientPrivateIp)"
}
