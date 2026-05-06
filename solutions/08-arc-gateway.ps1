[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroup,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$NestedAdminPassword
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ConnectedNodes = @('AzLHOST1', 'AzLHOST2')
$ClientVmName = 'LocalBox-Client'
$MinimumAgentVersion = [version]'1.47.0'
$GatewayWarmupMinutes = 20
$RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$DeployGatewayScript = Join-Path $RepoRoot 'scripts\deploy-arc-gateway.ps1'

function Write-Banner {
    param([string]$Title)

    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor Cyan
    Write-Host " $Title" -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor Cyan
}

function Write-Step {
    param(
        [string]$What,
        [string]$Why
    )

    Write-Host ''
    Write-Host "WHAT: $What" -ForegroundColor Yellow
    Write-Host " WHY: $Why" -ForegroundColor DarkYellow
}

function Write-Info {
    param(
        [string]$Message,
        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )

    Write-Host $Message -ForegroundColor $Color
}

function Invoke-AzCliText {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,
        [switch]$AllowFailure,
        [switch]$SkipOnlyShowErrors
    )

    $fullArguments = @($Arguments)
    if (-not $SkipOnlyShowErrors) {
        $fullArguments += '--only-show-errors'
    }

    $output = & az @fullArguments 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($output | Out-String).Trim()

    if (-not $AllowFailure -and $exitCode -ne 0) {
        throw "Azure CLI command failed: az $($fullArguments -join ' ')`n$text"
    }

    return [PSCustomObject]@{
        ExitCode = $exitCode
        Text     = $text
    }
}

function Invoke-AzCliJson {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,
        [switch]$AllowFailure,
        [switch]$SkipOnlyShowErrors
    )

    $result = Invoke-AzCliText -Arguments $Arguments -AllowFailure:$AllowFailure -SkipOnlyShowErrors:$SkipOnlyShowErrors
    if ($result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($result.Text)) {
        return $null
    }

    return $result.Text | ConvertFrom-Json -Depth 100
}

function Ensure-AzLogin {
    $account = Invoke-AzCliJson -Arguments @('account', 'show', '-o', 'json') -AllowFailure
    if (-not $account) {
        throw 'Azure CLI is not logged in. Run az login first.'
    }

    return $account
}

function Invoke-WorkspaceQuery {
    param(
        [Parameter(Mandatory)][string]$WorkspaceId,
        [Parameter(Mandatory)][string]$Query
    )

    $result = Invoke-AzCliJson -Arguments @(
        'monitor', 'log-analytics', 'query',
        '--workspace', $WorkspaceId,
        '--analytics-query', $Query,
        '-o', 'json'
    )

    if (-not $result -or -not $result.tables -or $result.tables.Count -eq 0) {
        return @()
    }

    $table = $result.tables[0]
    if (-not $table.rows -or $table.rows.Count -eq 0) {
        return @()
    }

    $objects = foreach ($row in $table.rows) {
        $item = [ordered]@{}
        for ($i = 0; $i -lt $table.columns.Count; $i++) {
            $item[$table.columns[$i].name] = $row[$i]
        }
        [PSCustomObject]$item
    }

    return $objects
}

function Get-FqdnSnapshot {
    param(
        [Parameter(Mandatory)][string]$WorkspaceId,
        [Parameter(Mandatory)][string]$TimeRange
    )

    $query = @"
AZFWApplicationRule
| where TimeGenerated > ago($TimeRange)
| where isnotempty(Fqdn)
| summarize Hits=count() by Fqdn
| order by Hits desc
"@

    return @(Invoke-WorkspaceQuery -WorkspaceId $WorkspaceId -Query $query)
}

function Show-FqdnSnapshot {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][object[]]$Rows
    )

    Write-Info $Title Cyan
    if (-not $Rows -or $Rows.Count -eq 0) {
        Write-Info 'No firewall FQDN rows were returned for this window.' Yellow
        return
    }

    $Rows | Select-Object -First 20 | Format-Table -Property Fqdn, Hits -AutoSize | Out-String | Write-Host
}

function Invoke-RunCommandOnClient {
    param([Parameter(Mandatory)][string]$InlineScript)

    return Invoke-AzCliText -Arguments @(
        'vm', 'run-command', 'invoke',
        '--resource-group', $ResourceGroup,
        '--name', $ClientVmName,
        '--command-id', 'RunPowerShellScript',
        '--scripts', $InlineScript,
        '--query', 'value[0].message',
        '-o', 'tsv'
    )
}

function Ensure-AgentVersion {
    $quotedNodes = ($ConnectedNodes | ForEach-Object { "'$_'" }) -join ', '
    $escapedPassword = $NestedAdminPassword.Replace("'", "''")

    $script = @"
`$nodes = @($quotedNodes)
`$securePassword = ConvertTo-SecureString '$escapedPassword' -AsPlainText -Force
`$credential = [PSCredential]::new('jumpstart\Administrator', `$securePassword)
`$minimumVersion = [version]'$MinimumAgentVersion'
`$downloadFolder = 'C:\Packages'
if (-not (Test-Path `$downloadFolder)) {
    New-Item -Path `$downloadFolder -ItemType Directory | Out-Null
}
`$installerPath = Join-Path `$downloadFolder 'AzureConnectedMachineAgent.msi'

foreach (`$node in `$nodes) {
    Write-Output "=== `$node ==="
    Invoke-Command -VMName `$node -Credential `$credential -ScriptBlock {
        param([version]`$MinimumVersion, [string]`$InstallerPath)

        `$currentVersionText = ((azcmagent version) -replace '.*\s+', '').Trim()
        `$currentVersion = [version]`$currentVersionText
        Write-Output "CurrentVersion=`$currentVersionText"
        if (`$currentVersion -lt `$MinimumVersion) {
            Write-Output 'UpgradeNeeded=True'
            Invoke-WebRequest -Uri 'https://aka.ms/AzureConnectedMachineAgent' -OutFile `$InstallerPath -UseBasicParsing
            Start-Process msiexec.exe -ArgumentList '/i', `$InstallerPath, '/qn', '/norestart' -Wait
            `$currentVersionText = ((azcmagent version) -replace '.*\s+', '').Trim()
            Write-Output "UpgradedVersion=`$currentVersionText"
        } else {
            Write-Output 'UpgradeNeeded=False'
        }
    } -ArgumentList `$minimumVersion, `$installerPath
}
"@

    $result = Invoke-RunCommandOnClient -InlineScript $script
    Write-Host $result.Text
    Write-Info 'Lesson learned: Arc Gateway requires azcmagent 1.47+; upgrading before gateway configuration avoids the confusing "unknown configuration property" failure.' DarkCyan
}

function Wait-WithProgress {
    param(
        [Parameter(Mandatory)][string]$Activity,
        [int]$Minutes = 20
    )

    $totalSeconds = $Minutes * 60
    for ($elapsed = 0; $elapsed -lt $totalSeconds; $elapsed += 30) {
        $percent = [int](($elapsed / $totalSeconds) * 100)
        $remaining = [int](($totalSeconds - $elapsed) / 60)
        Write-Progress -Activity $Activity -Status "~$remaining minute(s) remaining" -PercentComplete $percent
        Start-Sleep -Seconds 30
    }
    Write-Progress -Activity $Activity -Completed
}

function Show-AgentGatewayStatus {
    $quotedNodes = ($ConnectedNodes | ForEach-Object { "'$_'" }) -join ', '
    $escapedPassword = $NestedAdminPassword.Replace("'", "''")

    $script = @"
`$nodes = @($quotedNodes)
`$securePassword = ConvertTo-SecureString '$escapedPassword' -AsPlainText -Force
`$credential = [PSCredential]::new('jumpstart\Administrator', `$securePassword)

foreach (`$node in `$nodes) {
    Write-Output "=== `$node ==="
    Invoke-Command -VMName `$node -Credential `$credential -ScriptBlock {
        azcmagent show
    }
}
"@

    $result = Invoke-RunCommandOnClient -InlineScript $script
    Write-Host $result.Text
}

try {
    Write-Banner 'Exercise 08 - Arc Gateway'

    Write-Step 'Validate Azure context, the helper script path, and the Log Analytics workspace.' 'This wrapper adds teaching and verification around the existing gateway deployment helper, so we first confirm the lab control-plane prerequisites.'
    Ensure-AzLogin | Out-Null
    if (-not (Test-Path $DeployGatewayScript)) {
        throw "The gateway deployment helper was not found at '$DeployGatewayScript'."
    }

    $workspaces = @(Invoke-AzCliJson -Arguments @('monitor', 'log-analytics', 'workspace', 'list', '--resource-group', $ResourceGroup, '-o', 'json'))
    if (-not $workspaces -or $workspaces.Count -eq 0) {
        throw 'No Log Analytics workspace was found in the resource group. Firewall log comparison requires one.'
    }
    $workspace = $workspaces | Where-Object { $_.name -like '*Workspace*' } | Select-Object -First 1
    if (-not $workspace) {
        $workspace = $workspaces | Select-Object -First 1
    }
    Write-Info "Using Log Analytics workspace '$($workspace.name)'." Green

    Write-Step 'Show the baseline firewall FQDN list before introducing Arc Gateway.' 'You cannot prove network simplification unless you capture the direct-connect state first.'
    $beforeFqdns = Get-FqdnSnapshot -WorkspaceId $workspace.customerId -TimeRange '4h'
    Show-FqdnSnapshot -Title 'Baseline FQDNs observed before Arc Gateway (top 20):' -Rows $beforeFqdns
    if (-not $beforeFqdns -or $beforeFqdns.Count -eq 0) {
        throw 'No firewall application rule logs were found. Make sure Azure Firewall is deployed and logs have had time to accumulate.'
    }

    Write-Step 'Upgrade the Arc agents first if they are below version 1.47.' 'A tested lesson from this lab is that Arc Gateway depends on newer agent capabilities, so proactive upgrade handling is safer than failing halfway through configuration.'
    Ensure-AgentVersion

    Write-Step 'Deploy Arc Gateway by calling the existing helper with -Configure.' 'The helper already knows how to create the gateway resource, associate it at ARM scope, set connection.type gateway locally, and restart himds.'
    & $DeployGatewayScript -ResourceGroup $ResourceGroup -NestedAdminPassword $NestedAdminPassword -Configure
    Write-Info 'The gateway helper completed.' Green
    Write-Info 'Lesson learned: the gateway-resource-id lives only in Azure Resource Manager. Locally, the important setting is connection.type gateway, followed by a himds restart.' DarkCyan

    Write-Step 'Wait for the environment to generate post-gateway traffic.' 'Arc Gateway usually needs additional time before the firewall logs clearly show the reduced FQDN footprint, so we intentionally allow a soak period.'
    Wait-WithProgress -Activity 'Waiting for Arc Gateway traffic to stabilize' -Minutes $GatewayWarmupMinutes

    Write-Step 'Capture the post-gateway firewall FQDN list.' 'Now we measure the new network pattern and compare it with the baseline to see whether traffic concentrates around the gateway endpoint.'
    $afterFqdns = Get-FqdnSnapshot -WorkspaceId $workspace.customerId -TimeRange '30m'
    Show-FqdnSnapshot -Title 'Post-gateway FQDNs observed after Arc Gateway (top 20):' -Rows $afterFqdns

    Write-Step 'Compare the two snapshots.' 'The business value of Arc Gateway is simpler egress policy, so we explicitly show what disappeared, what remained, and what is now centralized.'
    $beforeNames = @($beforeFqdns | ForEach-Object { [string]$_.Fqdn })
    $afterNames = @($afterFqdns | ForEach-Object { [string]$_.Fqdn })
    $comparison = Compare-Object -ReferenceObject $beforeNames -DifferenceObject $afterNames

    Write-Info "Distinct FQDNs before gateway : $($beforeNames.Count)" Green
    Write-Info "Distinct FQDNs after gateway  : $($afterNames.Count)" Green

    $removed = @($comparison | Where-Object { $_.SideIndicator -eq '<=' } | Select-Object -ExpandProperty InputObject)
    $new = @($comparison | Where-Object { $_.SideIndicator -eq '=>' } | Select-Object -ExpandProperty InputObject)

    Write-Info 'Direct-mode only destinations that disappeared from the latest window:' Cyan
    if ($removed.Count -gt 0) {
        $removed | Select-Object -First 15 | ForEach-Object { Write-Host " - $_" }
    } else {
        Write-Info 'No disappeared FQDNs were detected in the sampled windows.' Yellow
    }

    Write-Info 'New or concentrated destinations visible after gateway enablement:' Cyan
    if ($new.Count -gt 0) {
        $new | Select-Object -First 15 | ForEach-Object { Write-Host " - $_" }
    } else {
        Write-Info 'No new FQDNs were detected in the sampled windows.' Yellow
    }

    Write-Step 'Verify that the Arc-enabled servers are still connected and now operating in gateway mode.' 'Arc Gateway should simplify networking without breaking manageability, so both cloud-side status and local agent state matter.'
    $machineStatus = @(Invoke-AzCliJson -Arguments @('connectedmachine', 'list', '--resource-group', $ResourceGroup, '-o', 'json')) |
        Where-Object { $ConnectedNodes -contains $_.name } |
        Select-Object @{n='Name';e={$_.name}}, @{n='Status';e={$_.status}}, @{n='Location';e={$_.location}}
    $machineStatus | Format-Table -AutoSize | Out-String | Write-Host
    Show-AgentGatewayStatus

    Write-Info 'Key lessons reinforced by the verification output:' DarkCyan
    Write-Info ' - connection.type gateway is the local setting that matters on the host.' DarkCyan
    Write-Info ' - Restarting himds is required after the local config change.' DarkCyan
    Write-Info ' - The agent learns the actual gateway URL from the ARM association automatically.' DarkCyan
    Write-Info ' - Arc gateway CLI operations should use --only-show-errors to keep long waits readable.' DarkCyan

    Write-Banner 'Exercise 08 completed'
    Write-Info 'Arc Gateway deployment, comparison, and verification finished successfully.' Green
} catch {
    Write-Host ''
    Write-Host 'Exercise 08 failed.' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    throw
}
