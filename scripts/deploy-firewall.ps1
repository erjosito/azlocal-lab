#####################################################################
# deploy-firewall.ps1 — Deploy Azure Firewall for a LocalBox lab
#
# Creates a dedicated Azure Firewall subnet, public IP, firewall policy,
# diagnostics, and a default route so LocalBox-Subnet egress flows through
# Azure Firewall. After the UDR is applied, LocalBox-Client and anything
# behind Vm-Router reach Azure management endpoints and the Internet through
# the firewall.
#
# Cost note: Azure Firewall Standard is expensive for a lab environment.
# Expect roughly ~$30/day while it is running.
#
# Usage examples:
#   .\scripts\deploy-firewall.ps1 -ResourceGroup azlocal2
#   .\scripts\deploy-firewall.ps1 -ResourceGroup azlocal2 -Location swedencentral
#   .\scripts\deploy-firewall.ps1 -ResourceGroup azlocal2 -FirewallName LocalBox-Firewall
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
$FirewallIpConfigName = "LocalBoxFirewallIpConfig"
$RouteTableName = "LocalBox-FW-RouteTable"
$DefaultRouteName = "DefaultToFirewall"
$DiagSettingName = "$FirewallName-Diagnostics"
$FallbackWorkspaceName = "LocalBox-FW-Workspace"
$FirewallApiVersion = "2024-05-01"
$FirewallPolicyApiVersion = "2024-10-01"

function Invoke-AzText {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$AllowFailure
    )

    $output = & az @Arguments --only-show-errors 2>&1
    if ($LASTEXITCODE -ne 0) {
        if ($AllowFailure) {
            return $null
        }

        throw "az $($Arguments -join ' ') failed: $($output | Out-String)"
    }

    if ($null -eq $output) {
        return $null
    }

    return ($output | Out-String).Trim()
}

function Invoke-AzJson {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$AllowFailure
    )

    $text = Invoke-AzText -Arguments $Arguments -AllowFailure:$AllowFailure
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    return $text | ConvertFrom-Json -Depth 100
}

function Invoke-AzNoOutput {
    param([Parameter(Mandatory)][string[]]$Arguments)
    [void](Invoke-AzText -Arguments ($Arguments + @("--output", "none")))
}

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host $Message -ForegroundColor Cyan
}

function Wait-ForFirewallPrivateIp {
    param([int]$Attempts = 30, [int]$DelaySeconds = 10)

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $ip = Invoke-AzText -Arguments @(
            "resource", "show",
            "--ids", $script:FirewallId,
            "--api-version", $script:FirewallApiVersion,
            "--query", "properties.ipConfigurations[0].properties.privateIPAddress",
            "-o", "tsv"
        ) -AllowFailure

        if (-not [string]::IsNullOrWhiteSpace($ip)) {
            return $ip
        }

        Start-Sleep -Seconds $DelaySeconds
    }

    throw "Timed out waiting for Azure Firewall private IP."
}

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " Deploy Azure Firewall for LocalBox"
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " Resource Group : $ResourceGroup"
Write-Host " Firewall Name  : $FirewallName"
Write-Host "============================================="

$rgExists = Invoke-AzText -Arguments @("group", "exists", "-n", $ResourceGroup)
if ($rgExists -ne "true") {
    throw "Resource group '$ResourceGroup' does not exist."
}

$resourceGroupLocation = Invoke-AzText -Arguments @("group", "show", "-n", $ResourceGroup, "--query", "location", "-o", "tsv")
if ([string]::IsNullOrWhiteSpace($Location)) {
    $Location = $resourceGroupLocation
}

$subscriptionId = Invoke-AzText -Arguments @("account", "show", "--query", "id", "-o", "tsv")
$policyId = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Network/firewallPolicies/$PolicyName"
$applicationRcgUrl = "https://management.azure.com$policyId/ruleCollectionGroups/$ApplicationRcgName?api-version=$FirewallPolicyApiVersion"
$natRcgUrl = "https://management.azure.com$policyId/ruleCollectionGroups/$NatRcgName?api-version=$FirewallPolicyApiVersion"
$networkRcgUrl = "https://management.azure.com$policyId/ruleCollectionGroups/$NetworkRcgName?api-version=$FirewallPolicyApiVersion"
$FirewallId = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Network/azureFirewalls/$FirewallName"
$firewallUrl = "https://management.azure.com$FirewallId?api-version=$FirewallApiVersion"

Write-Host " Location       : $Location"
Write-Host " VNet           : $VnetName"
Write-Host " Firewall Policy: $PolicyName"

Write-Step "Checking LocalBox networking"
$vnet = Invoke-AzJson -Arguments @("network", "vnet", "show", "-g", $ResourceGroup, "-n", $VnetName, "-o", "json")
if (-not $vnet) {
    throw "VNet '$VnetName' was not found in resource group '$ResourceGroup'."
}

$workloadSubnetId = Invoke-AzText -Arguments @(
    "network", "vnet", "subnet", "show",
    "-g", $ResourceGroup,
    "--vnet-name", $VnetName,
    "-n", $WorkloadSubnetName,
    "--query", "id",
    "-o", "tsv"
) -AllowFailure
if (-not $workloadSubnetId) {
    throw "Subnet '$WorkloadSubnetName' was not found in VNet '$VnetName'."
}

$firewallSubnetId = Invoke-AzText -Arguments @(
    "network", "vnet", "subnet", "show",
    "-g", $ResourceGroup,
    "--vnet-name", $VnetName,
    "-n", $FirewallSubnetName,
    "--query", "id",
    "-o", "tsv"
) -AllowFailure

if (-not $firewallSubnetId) {
    Write-Host "Creating $FirewallSubnetName ($FirewallSubnetPrefix)..."
    Invoke-AzNoOutput -Arguments @(
        "network", "vnet", "subnet", "create",
        "-g", $ResourceGroup,
        "--vnet-name", $VnetName,
        "-n", $FirewallSubnetName,
        "--address-prefixes", $FirewallSubnetPrefix
    )

    $firewallSubnetId = Invoke-AzText -Arguments @(
        "network", "vnet", "subnet", "show",
        "-g", $ResourceGroup,
        "--vnet-name", $VnetName,
        "-n", $FirewallSubnetName,
        "--query", "id",
        "-o", "tsv"
    )
} else {
    Write-Host "$FirewallSubnetName already exists."
}

Write-Step "Ensuring firewall public IP"
$publicIpId = Invoke-AzText -Arguments @(
    "network", "public-ip", "show",
    "-g", $ResourceGroup,
    "-n", $PublicIpName,
    "--query", "id",
    "-o", "tsv"
) -AllowFailure

if (-not $publicIpId) {
    Write-Host "Creating public IP '$PublicIpName'..."
    Invoke-AzNoOutput -Arguments @(
        "network", "public-ip", "create",
        "-g", $ResourceGroup,
        "-n", $PublicIpName,
        "-l", $Location,
        "--sku", "Standard",
        "--allocation-method", "Static"
    )

    $publicIpId = Invoke-AzText -Arguments @(
        "network", "public-ip", "show",
        "-g", $ResourceGroup,
        "-n", $PublicIpName,
        "--query", "id",
        "-o", "tsv"
    )
} else {
    Write-Host "Public IP '$PublicIpName' already exists."
}

$firewallPublicIpAddress = Invoke-AzText -Arguments @(
    "network", "public-ip", "show",
    "-g", $ResourceGroup,
    "-n", $PublicIpName,
    "--query", "ipAddress",
    "-o", "tsv"
)

Write-Step "Ensuring firewall policy"
$policyExists = Invoke-AzText -Arguments @(
    "resource", "show",
    "--ids", $policyId,
    "--api-version", $FirewallPolicyApiVersion,
    "--query", "id",
    "-o", "tsv"
) -AllowFailure

if (-not $policyExists) {
    $policyBody = @{
        location   = $Location
        properties = @{
            threatIntelMode = "Alert"
        }
    } | ConvertTo-Json -Depth 10

    Invoke-AzNoOutput -Arguments @(
        "rest", "--method", "put",
        "--url", $policyId + "?api-version=$FirewallPolicyApiVersion",
        "--body", $policyBody
    )
} else {
    Write-Host "Firewall policy '$PolicyName' already exists."
}

$appRcgExists = Invoke-AzText -Arguments @("rest", "--method", "get", "--url", $applicationRcgUrl) -AllowFailure
if (-not $appRcgExists) {
    Write-Host "Creating application rule collection group '$ApplicationRcgName'..."
    $appRcgBody = @{
        properties = @{
            priority        = 100
            ruleCollections = @(
                @{
                    name               = "AllowAll"
                    priority           = 100
                    ruleCollectionType = "FirewallPolicyFilterRuleCollection"
                    action             = @{ type = "Allow" }
                    rules              = @(
                        @{
                            name            = "permit-any"
                            ruleType        = "ApplicationRule"
                            sourceAddresses = @("*")
                            targetFqdns     = @("*")
                            protocols       = @(
                                @{ protocolType = "Http";  port = 80 },
                                @{ protocolType = "Https"; port = 443 }
                            )
                        }
                    )
                }
            )
        }
    } | ConvertTo-Json -Depth 20

    Invoke-AzNoOutput -Arguments @("rest", "--method", "put", "--url", $applicationRcgUrl, "--body", $appRcgBody)
} else {
    Write-Host "Application rule collection group '$ApplicationRcgName' already exists."
}

$networkRcgExists = Invoke-AzText -Arguments @("rest", "--method", "get", "--url", $networkRcgUrl) -AllowFailure
if (-not $networkRcgExists) {
    Write-Host "Creating empty network rule collection group '$NetworkRcgName'..."
    $networkRcgBody = @{
        properties = @{
            priority        = 200
            ruleCollections = @(
                @{
                    name               = "AllowRequired"
                    priority           = 200
                    ruleCollectionType = "FirewallPolicyFilterRuleCollection"
                    action             = @{ type = "Allow" }
                    rules              = @()
                }
            )
        }
    } | ConvertTo-Json -Depth 20

    Invoke-AzNoOutput -Arguments @("rest", "--method", "put", "--url", $networkRcgUrl, "--body", $networkRcgBody)
} else {
    Write-Host "Network rule collection group '$NetworkRcgName' already exists."
}

Write-Step "Ensuring DNAT rule for RDP access"
$clientPrivateIp = Invoke-AzText -Arguments @(
    "vm", "show",
    "-g", $ResourceGroup,
    "-n", "LocalBox-Client",
    "--query", "privateIps",
    "-d",
    "-o", "tsv"
) -AllowFailure

if (-not $clientPrivateIp) {
    Write-Host "  WARNING: Could not find LocalBox-Client private IP. Skipping DNAT rule." -ForegroundColor Yellow
} else {
    Write-Host "  LocalBox-Client private IP: $clientPrivateIp"
    $natRcgExists = Invoke-AzText -Arguments @("rest", "--method", "get", "--url", $natRcgUrl) -AllowFailure
    if (-not $natRcgExists) {
        Write-Host "  Creating NAT rule collection group '$NatRcgName' (RDP → $clientPrivateIp)..."
        $natRcgBody = @{
            properties = @{
                priority        = 50
                ruleCollections = @(
                    @{
                        name               = "InboundRDP"
                        priority           = 100
                        ruleCollectionType = "FirewallPolicyNatRuleCollection"
                        action             = @{ type = "DNAT" }
                        rules              = @(
                            @{
                                name                = "RDP-to-LocalBox-Client"
                                ruleType            = "NatRule"
                                sourceAddresses     = @("*")
                                destinationAddresses = @($firewallPublicIpAddress)
                                destinationPorts    = @("3389")
                                ipProtocols         = @("TCP")
                                translatedAddress   = $clientPrivateIp
                                translatedPort      = "3389"
                            }
                        )
                    }
                )
            }
        } | ConvertTo-Json -Depth 20

        Invoke-AzNoOutput -Arguments @("rest", "--method", "put", "--url", $natRcgUrl, "--body", $natRcgBody)
    } else {
        Write-Host "  NAT rule collection group '$NatRcgName' already exists."
    }
}

Write-Step "Ensuring Azure Firewall"
$firewallBody = @{
    location   = $Location
    properties = @{
        sku             = @{ name = "AZFW_VNet"; tier = "Standard" }
        threatIntelMode = "Alert"
        firewallPolicy  = @{ id = $policyId }
        ipConfigurations = @(
            @{
                name       = $FirewallIpConfigName
                properties = @{
                    subnet          = @{ id = $firewallSubnetId }
                    publicIPAddress = @{ id = $publicIpId }
                }
            }
        )
    }
} | ConvertTo-Json -Depth 20

Invoke-AzNoOutput -Arguments @("rest", "--method", "put", "--url", $firewallUrl, "--body", $firewallBody)

$firewallPrivateIp = Wait-ForFirewallPrivateIp

Write-Step "Ensuring Log Analytics workspace and diagnostics"
$workspace = Invoke-AzJson -Arguments @("monitor", "log-analytics", "workspace", "list", "-g", $ResourceGroup, "-o", "json")
$matchingWorkspace = $workspace | Where-Object { $_.name -like "*Workspace*" } | Select-Object -First 1

if (-not $matchingWorkspace) {
    Write-Host "No matching workspace found. Creating '$FallbackWorkspaceName'..."
    Invoke-AzNoOutput -Arguments @(
        "monitor", "log-analytics", "workspace", "create",
        "-g", $ResourceGroup,
        "-n", $FallbackWorkspaceName,
        "-l", $Location
    )

    $matchingWorkspace = Invoke-AzJson -Arguments @(
        "monitor", "log-analytics", "workspace", "show",
        "-g", $ResourceGroup,
        "-n", $FallbackWorkspaceName,
        "-o", "json"
    )
} else {
    Write-Host "Using Log Analytics workspace '$($matchingWorkspace.name)'."
}

$logs = @(
    @{ category = "AZFWApplicationRule"; enabled = $true; retentionPolicy = @{ enabled = $false; days = 0 } },
    @{ category = "AZFWNetworkRule"; enabled = $true; retentionPolicy = @{ enabled = $false; days = 0 } },
    @{ category = "AZFWDnsQuery"; enabled = $true; retentionPolicy = @{ enabled = $false; days = 0 } }
) | ConvertTo-Json -Depth 10 -Compress

Invoke-AzNoOutput -Arguments @(
    "monitor", "diagnostic-settings", "create",
    "--resource", $FirewallId,
    "-n", $DiagSettingName,
    "--workspace", $matchingWorkspace.id,
    "--export-to-resource-specific", "true",
    "--logs", $logs
)

Write-Step "Ensuring route table and subnet association"
$routeTableId = Invoke-AzText -Arguments @(
    "network", "route-table", "show",
    "-g", $ResourceGroup,
    "-n", $RouteTableName,
    "--query", "id",
    "-o", "tsv"
) -AllowFailure

if (-not $routeTableId) {
    Write-Host "Creating route table '$RouteTableName'..."
    Invoke-AzNoOutput -Arguments @(
        "network", "route-table", "create",
        "-g", $ResourceGroup,
        "-n", $RouteTableName,
        "-l", $Location
    )
} else {
    Write-Host "Route table '$RouteTableName' already exists."
}

Invoke-AzNoOutput -Arguments @(
    "network", "route-table", "route", "create",
    "-g", $ResourceGroup,
    "--route-table-name", $RouteTableName,
    "-n", $DefaultRouteName,
    "--address-prefix", "0.0.0.0/0",
    "--next-hop-type", "VirtualAppliance",
    "--next-hop-ip-address", $firewallPrivateIp
)

$currentRouteTableId = Invoke-AzText -Arguments @(
    "network", "vnet", "subnet", "show",
    "-g", $ResourceGroup,
    "--vnet-name", $VnetName,
    "-n", $WorkloadSubnetName,
    "--query", "routeTable.id",
    "-o", "tsv"
) -AllowFailure

if ($currentRouteTableId -ne ("/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Network/routeTables/$RouteTableName")) {
    Invoke-AzNoOutput -Arguments @(
        "network", "vnet", "subnet", "update",
        "-g", $ResourceGroup,
        "--vnet-name", $VnetName,
        "-n", $WorkloadSubnetName,
        "--route-table", $RouteTableName
    )
}

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
    Write-Host "  (Firewall forwards port 3389 → $clientPrivateIp)"
}
