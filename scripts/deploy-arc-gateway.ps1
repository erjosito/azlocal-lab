#####################################################################
# deploy-arc-gateway.ps1 — Create or remove Azure Arc Gateway
#
# Creates an Azure Arc Gateway resource for the LocalBox lab and,
# optionally, configures the Arc agents on AzLHOST1 and AzLHOST2 to
# use it via the LocalBox-Client VM.
#####################################################################

param(
    [Parameter(Mandatory)][string]$ResourceGroup,
    [string]$Location,
    [string]$GatewayName = "LocalBox-ArcGateway",
    [Parameter(Mandatory)][string]$NestedAdminPassword,
    [switch]$Configure,
    [switch]$Remove
)

$ErrorActionPreference = "Stop"

$clientVmName = "LocalBox-Client"
$nestedNodes = @("AzLHOST1", "AzLHOST2")

function Invoke-AzCli {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$AllowFailure
    )

    $output = & az @Arguments --only-show-errors 2>&1
    $exitCode = $LASTEXITCODE

    if (-not $AllowFailure -and $exitCode -ne 0) {
        throw "Azure CLI command failed: az $($Arguments -join ' ')`n$output"
    }

    return [PSCustomObject]@{
        Output   = ($output | Out-String).Trim()
        ExitCode = $exitCode
    }
}

function Ensure-ArcGatewayExtension {
    $helpResult = Invoke-AzCli -Arguments @("arcgateway", "-h") -AllowFailure
    if ($helpResult.ExitCode -eq 0) {
        return
    }

    Write-Host "Installing Azure CLI arcgateway extension..." -ForegroundColor Yellow
    Invoke-AzCli -Arguments @("extension", "add", "-n", "arcgateway", "--allow-preview", "true", "--only-show-errors") | Out-Null
}

function Get-GatewayCliMode {
    $connectedMachineHelp = Invoke-AzCli -Arguments @("connectedmachine", "gateway", "-h") -AllowFailure
    if ($connectedMachineHelp.ExitCode -eq 0) {
        return "connectedmachine"
    }

    Ensure-ArcGatewayExtension
    return "arcgateway"
}

function Get-ResourceGroupLocation {
    param([string]$Name)

    $locationResult = Invoke-AzCli -Arguments @("group", "show", "--name", $Name, "--query", "location", "-o", "tsv")
    if ([string]::IsNullOrWhiteSpace($locationResult.Output)) {
        throw "Could not determine the location for resource group '$Name'."
    }

    return $locationResult.Output
}

function Get-SubscriptionId {
    $subscriptionResult = Invoke-AzCli -Arguments @("account", "show", "--query", "id", "-o", "tsv")
    return $subscriptionResult.Output
}

function Get-Gateway {
    param(
        [string]$Name,
        [string]$Rg,
        [string]$CliMode
    )

    $arguments = if ($CliMode -eq "connectedmachine") {
        @("connectedmachine", "gateway", "show", "--name", $Name, "--resource-group", $Rg, "-o", "json")
    } else {
        @("arcgateway", "show", "--name", $Name, "--resource-group", $Rg, "-o", "json")
    }

    $result = Invoke-AzCli -Arguments $arguments -AllowFailure
    if ($result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($result.Output)) {
        return $null
    }

    return $result.Output | ConvertFrom-Json
}

function New-Gateway {
    param(
        [string]$Name,
        [string]$Rg,
        [string]$Region,
        [string]$CliMode
    )

    $arguments = if ($CliMode -eq "connectedmachine") {
        @(
            "connectedmachine", "gateway", "create",
            "--name", $Name,
            "--resource-group", $Rg,
            "--location", $Region,
            "--gateway-type", "public",
            "--allowed-features", "*",
            "--output", "none"
        )
    } else {
        @(
            "arcgateway", "create",
            "--name", $Name,
            "--resource-group", $Rg,
            "--location", $Region,
            "--gateway-type", "public",
            "--allowed-features", "*",
            "--output", "none"
        )
    }

    Invoke-AzCli -Arguments $arguments | Out-Null
}

function Remove-Gateway {
    param(
        [string]$Name,
        [string]$Rg,
        [string]$CliMode
    )

    $arguments = if ($CliMode -eq "connectedmachine") {
        @("connectedmachine", "gateway", "delete", "--name", $Name, "--resource-group", $Rg, "--yes", "--output", "none")
    } else {
        @("arcgateway", "delete", "--name", $Name, "--resource-group", $Rg, "--yes", "--output", "none")
    }

    Invoke-AzCli -Arguments $arguments | Out-Null
}

function Wait-ForGatewaySuccess {
    param([string]$ResourceId)

    Write-Host "Waiting for Arc Gateway provisioning to complete (this can take several minutes)..."
    Invoke-AzCli -Arguments @(
        "resource", "wait",
        "--ids", $ResourceId,
        "--custom", "properties.provisioningState=='Succeeded'",
        "--interval", "30",
        "--timeout", "1800",
        "--only-show-errors"
    ) | Out-Null
}

function Wait-ForGatewayDeletion {
    param([string]$ResourceId)

    Write-Host "Waiting for Arc Gateway deletion to complete..."
    Invoke-AzCli -Arguments @(
        "resource", "wait",
        "--ids", $ResourceId,
        "--deleted",
        "--interval", "15",
        "--timeout", "900",
        "--only-show-errors"
    ) | Out-Null
}

function Update-ArcGatewayAssociation {
    param(
        [string]$Rg,
        [string[]]$Nodes,
        [string]$GatewayResourceId,
        [bool]$Detach
    )

    Ensure-ArcGatewayExtension
    $subscriptionId = Get-SubscriptionId

    foreach ($node in $Nodes) {
        Write-Host "Updating Arc Gateway association for Azure resource '$node'..."

        $arguments = @(
            "arcgateway", "settings", "update",
            "--resource-group", $Rg,
            "--subscription", $subscriptionId,
            "--base-provider", "Microsoft.HybridCompute",
            "--base-resource-type", "machines",
            "--base-resource-name", $node,
            "--output", "none"
        )

        if ($Detach) {
            $arguments += @("--gateway-resource-id", "null")
        } else {
            $arguments += @("--gateway-resource-id", $GatewayResourceId)
        }

        Invoke-AzCli -Arguments $arguments | Out-Null
    }
}

function Invoke-ArcAgentConfiguration {
    param(
        [string]$Rg,
        [string]$ClientVm,
        [string[]]$Nodes,
        [string]$ConnectionType,
        [string]$GatewayResourceId,
        [string]$Password
    )

    $quotedNodes = ($Nodes | ForEach-Object { "'$_'" }) -join ", "
    $escapedPassword = $Password.Replace("'", "''")
    $escapedGatewayId = $GatewayResourceId.Replace("'", "''")

    $runCommandScript = @"
`$nodes = @($quotedNodes)
`$securePassword = ConvertTo-SecureString '$escapedPassword' -AsPlainText -Force
`$credential = [PSCredential]::new('Administrator', `$securePassword)
`$connectionType = '$ConnectionType'
`$gatewayResourceId = '$escapedGatewayId'

foreach (`$node in `$nodes) {
    Write-Output "=== Configuring `$node ==="

    Invoke-Command -VMName `$node -Credential `$credential -ScriptBlock {
        param(
            [string]`$ConnectionType,
            [string]`$GatewayResourceId
        )

        azcmagent config set connection.type `$ConnectionType | Out-Null

        if (`$ConnectionType -eq 'gateway') {
            azcmagent config set connection.gateway-resource-id `$GatewayResourceId | Out-Null
        }

        Restart-Service himds -Force
        Start-Sleep -Seconds 10
        azcmagent show
    } -ArgumentList `$connectionType, `$gatewayResourceId
}
"@

    Write-Host "Running remote configuration on '$ClientVm'..."
    $result = Invoke-AzCli -Arguments @(
        "vm", "run-command", "invoke",
        "--resource-group", $Rg,
        "--name", $ClientVm,
        "--command-id", "RunPowerShellScript",
        "--scripts", $runCommandScript,
        "--query", "value[0].message",
        "-o", "tsv"
    )

    if ($result.Output) {
        Write-Host ""
        Write-Host $result.Output
    }
}

function Show-ManualConfigurationInstructions {
    param(
        [string]$Rg,
        [string]$GatewayResourceId
    )

    Write-Host ""
    Write-Host "Manual configuration steps" -ForegroundColor Cyan
    Write-Host "-------------------------"
    Write-Host "1. Associate the Arc-enabled server resources with the gateway:"
    foreach ($node in $nestedNodes) {
        Write-Host "   az arcgateway settings update --resource-group $Rg --base-provider Microsoft.HybridCompute --base-resource-type machines --base-resource-name $node --gateway-resource-id $GatewayResourceId"
    }
    Write-Host ""
    Write-Host "2. On LocalBox-Client, run these commands on both nested nodes:"
    Write-Host "   azcmagent config set connection.type gateway"
    Write-Host "   azcmagent config set connection.gateway-resource-id $GatewayResourceId"
    Write-Host "   Restart-Service himds"
    Write-Host ""
    Write-Host "3. Verify on each node:"
    Write-Host "   azcmagent show"
    Write-Host "   azcmagent check"
}

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " Azure Arc Gateway for LocalBox"
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " Resource Group : $ResourceGroup"
Write-Host " Gateway Name   : $GatewayName"
Write-Host " Client VM      : $clientVmName"
Write-Host " Configure Now  : $Configure"
Write-Host " Remove         : $Remove"
Write-Host "============================================="
Write-Host ""

$rgExists = Invoke-AzCli -Arguments @("group", "exists", "--name", $ResourceGroup)
if ($rgExists.Output -ne "true") {
    throw "Resource group '$ResourceGroup' does not exist."
}

if (-not $Location) {
    $Location = Get-ResourceGroupLocation -Name $ResourceGroup
}

$gatewayCliMode = Get-GatewayCliMode
$gateway = Get-Gateway -Name $GatewayName -Rg $ResourceGroup -CliMode $gatewayCliMode

if ($Remove) {
    Write-Host "Switching Arc agents back to direct connectivity..." -ForegroundColor Yellow
    Update-ArcGatewayAssociation -Rg $ResourceGroup -Nodes $nestedNodes -GatewayResourceId "" -Detach $true
    Invoke-ArcAgentConfiguration -Rg $ResourceGroup -ClientVm $clientVmName -Nodes $nestedNodes -ConnectionType "direct" -GatewayResourceId "" -Password $NestedAdminPassword

    if ($gateway) {
        Write-Host "Deleting Arc Gateway '$GatewayName'..." -ForegroundColor Yellow
        Remove-Gateway -Name $GatewayName -Rg $ResourceGroup -CliMode $gatewayCliMode
        Wait-ForGatewayDeletion -ResourceId $gateway.id
        Write-Host "Arc Gateway deleted." -ForegroundColor Green
    } else {
        Write-Host "Arc Gateway '$GatewayName' was not found. Agent configuration was still reset to direct mode." -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "Validation commands:" -ForegroundColor Cyan
    Write-Host "  azcmagent show"
    Write-Host "  azcmagent check"
    exit 0
}

if (-not $gateway) {
    Write-Host "Creating Arc Gateway '$GatewayName' in '$Location'..."
    New-Gateway -Name $GatewayName -Rg $ResourceGroup -Region $Location -CliMode $gatewayCliMode
    $gateway = Get-Gateway -Name $GatewayName -Rg $ResourceGroup -CliMode $gatewayCliMode
    if (-not $gateway) {
        throw "Arc Gateway '$GatewayName' was created but could not be queried afterwards."
    }
} else {
    Write-Host "Arc Gateway '$GatewayName' already exists. Reusing it." -ForegroundColor Yellow
}

Wait-ForGatewaySuccess -ResourceId $gateway.id
$gateway = Get-Gateway -Name $GatewayName -Rg $ResourceGroup -CliMode $gatewayCliMode

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " Arc Gateway Ready" -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " Gateway Resource ID : $($gateway.id)"
if ($gateway.properties.gatewayEndpoint) {
    Write-Host " Gateway Endpoint    : $($gateway.properties.gatewayEndpoint)"
}
Write-Host " Location            : $Location"
Write-Host ""

if ($Configure) {
    Write-Host "Associating the Arc resources and configuring the agents to use the gateway..." -ForegroundColor Cyan
    Update-ArcGatewayAssociation -Rg $ResourceGroup -Nodes $nestedNodes -GatewayResourceId $gateway.id -Detach $false
    Invoke-ArcAgentConfiguration -Rg $ResourceGroup -ClientVm $clientVmName -Nodes $nestedNodes -ConnectionType "gateway" -GatewayResourceId $gateway.id -Password $NestedAdminPassword

    Write-Host ""
    Write-Host "Validation commands:" -ForegroundColor Cyan
    Write-Host "  az arcgateway show --name $GatewayName --resource-group $ResourceGroup"
    Write-Host "  azcmagent show"
    Write-Host "  azcmagent check"
} else {
    Show-ManualConfigurationInstructions -Rg $ResourceGroup -GatewayResourceId $gateway.id
}

Write-Host ""
Write-Host "Next step: wait 15-30 minutes and compare Azure Firewall logs before and after enabling the gateway." -ForegroundColor Cyan
