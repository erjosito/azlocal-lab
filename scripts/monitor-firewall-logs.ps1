#####################################################################
# monitor-firewall-logs.ps1 — Query Azure Firewall logs for LocalBox
#
# Uses az monitor log-analytics query against the resource-specific
# Azure Firewall tables in the Log Analytics workspace in the lab RG.
#
# Usage examples:
#   .\scripts\monitor-firewall-logs.ps1 -ResourceGroup azlocal
#   .\scripts\monitor-firewall-logs.ps1 -ResourceGroup azlocal -Action denied -TimeRange 4h
#   .\scripts\monitor-firewall-logs.ps1 -ResourceGroup azlocal -Action rules -TimeRange 1d
#   .\scripts\monitor-firewall-logs.ps1 -ResourceGroup azlocal -FixDiagnostics
#
# If no diagnostic settings exist (no logs flowing), the script warns
# and offers to create them automatically with -FixDiagnostics.
#####################################################################

param(
    [Parameter(Mandatory)][string]$ResourceGroup,
    [ValidatePattern('^[0-9]+[mhd]$')][string]$TimeRange = "1h",
    [ValidateSet("summary", "denied", "rules")][string]$Action = "summary",
    [switch]$FixDiagnostics
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

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

    try {
        return $text | ConvertFrom-Json -Depth 100
    }
    catch {
        # AzureDiagnostics can return columns with mixed casing (e.g. SourceIP and SourceIp)
        # which causes ConvertFrom-Json to fail. Fall back to -AsHashtable.
        return $text | ConvertFrom-Json -Depth 100 -AsHashtable
    }
}

function Invoke-WorkspaceQuery {
    param(
        [Parameter(Mandatory)][string]$WorkspaceId,
        [Parameter(Mandatory)][string]$Query
    )

    # Collapse multiline queries to single line — az CLI hangs on multiline --analytics-query
    $singleLine = ($Query -replace '\r?\n', ' ' -replace '\s+', ' ').Trim()

    $result = Invoke-AzJson -Arguments @(
        "monitor", "log-analytics", "query",
        "-w", $WorkspaceId,
        "--analytics-query", $singleLine,
        "-o", "json"
    ) -AllowFailure

    if (-not $result) {
        return @()
    }

    if ($result -is [array]) {
        return $result
    }

    return @($result)
}

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host $Title -ForegroundColor Cyan
    Write-Host ($Title.ToCharArray() | ForEach-Object { '-' } | Out-String).Trim()
}

function Write-ResultTable {
    param([object[]]$Rows)

    if (-not $Rows -or @($Rows).Count -eq 0) {
        Write-Host "  No results found." -ForegroundColor DarkGray
        return
    }

    # Remove the TableName property that az log-analytics query adds
    $cleaned = @($Rows) | ForEach-Object {
        if ($_ -is [hashtable]) {
            $h = $_.Clone()
            $h.Remove('TableName')
            [pscustomobject]$h
        } else {
            $_ | Select-Object -Property * -ExcludeProperty TableName
        }
    }
    $cleaned | Format-Table -AutoSize | Out-String | Write-Host
}

$workspaceList = Invoke-AzJson -Arguments @("monitor", "log-analytics", "workspace", "list", "-g", $ResourceGroup, "-o", "json")
$workspace = $workspaceList | Where-Object { $_.name -like "*Workspace*" } | Select-Object -First 1
if (-not $workspace) {
    $workspace = $workspaceList | Select-Object -First 1
}
if (-not $workspace) {
    throw "No Log Analytics workspace was found in resource group '$ResourceGroup'."
}

# Discover the firewall
$firewalls = @(Invoke-AzJson -Arguments @("network", "firewall", "list", "-g", $ResourceGroup, "-o", "json"))
if (-not $firewalls -or $firewalls.Count -eq 0) {
    throw "No Azure Firewall found in resource group '$ResourceGroup'."
}
$firewall = $firewalls[0]

# Check diagnostic settings
$diagSettings = Invoke-AzJson -Arguments @(
    "monitor", "diagnostic-settings", "list",
    "--resource", $firewall.id,
    "-o", "json"
) -AllowFailure
$hasDiagnostics = $false
if ($diagSettings) {
    if ($diagSettings -is [array]) {
        $hasDiagnostics = $diagSettings.Count -gt 0
    } elseif ($diagSettings.PSObject.Properties['value'] -and $diagSettings.value) {
        $hasDiagnostics = @($diagSettings.value).Count -gt 0
    } else {
        # Single object returned (not array, no .value) — treat as having settings
        $hasDiagnostics = $true
    }
}

if (-not $hasDiagnostics) {
    Write-Host ""
    Write-Host "WARNING: No diagnostic settings found for firewall '$($firewall.name)'." -ForegroundColor Yellow
    Write-Host "  Firewall logs are NOT being sent to the workspace." -ForegroundColor Yellow
    Write-Host "  Without diagnostic settings, this script cannot display any log data." -ForegroundColor Yellow
    Write-Host ""

    if ($FixDiagnostics) {
        Write-Host "Creating diagnostic settings to send all firewall logs to '$($workspace.name)'..." -ForegroundColor Green
        Invoke-AzText -Arguments @(
            "monitor", "diagnostic-settings", "create",
            "--name", "fw-to-workspace",
            "--resource", $firewall.id,
            "--workspace", $workspace.id,
            "--logs", '[{\"categoryGroup\":\"allLogs\",\"enabled\":true}]',
            "--metrics", '[{\"category\":\"AllMetrics\",\"enabled\":true}]',
            "-o", "json"
        )
        Write-Host "[OK] Diagnostic settings created. Logs will start flowing within 5-10 minutes." -ForegroundColor Green
        Write-Host "     Re-run this script after some time has passed to see results." -ForegroundColor Green
        return
    } else {
        Write-Host "  Run with -FixDiagnostics to auto-create the settings:" -ForegroundColor Yellow
        Write-Host "    .\scripts\monitor-firewall-logs.ps1 -ResourceGroup $ResourceGroup -FixDiagnostics" -ForegroundColor White
        Write-Host ""
        Write-Host "  Or create them manually:" -ForegroundColor Yellow
        Write-Host "    az monitor diagnostic-settings create --name fw-to-workspace ``" -ForegroundColor White
        Write-Host "      --resource $($firewall.id) ``" -ForegroundColor White
        Write-Host "      --workspace $($workspace.id) ``" -ForegroundColor White
        Write-Host "      --logs '[{""categoryGroup"":""allLogs"",""enabled"":true}]'" -ForegroundColor White
        Write-Host ""
        return
    }
}

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " Azure Firewall Log Monitor"
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " Resource Group : $ResourceGroup"
Write-Host " Firewall       : $($firewall.name)"
Write-Host " Workspace      : $($workspace.name)"
Write-Host " Time Range     : $TimeRange"
Write-Host " Action         : $Action"
Write-Host "============================================="

# Verify data is actually flowing before running queries
$countQuery = @"
AzureDiagnostics
| where TimeGenerated > ago($TimeRange)
| where Category in ('AZFWNetworkRule', 'AZFWApplicationRule')
| count
"@
$countResult = Invoke-WorkspaceQuery -WorkspaceId $workspace.customerId -Query $countQuery
$totalRows = 0
if ($countResult -and @($countResult).Count -gt 0) {
    $first = @($countResult)[0]
    if ($first -is [hashtable]) { $totalRows = [int]$first['Count'] }
    else { $totalRows = [int]$first.Count }
}

if ($totalRows -eq 0) {
    Write-Host ""
    Write-Host "No firewall log data found in the last $TimeRange." -ForegroundColor Yellow
    Write-Host "  Possible causes:" -ForegroundColor Yellow
    Write-Host "    - Diagnostic settings were recently created (allow 5-10 min for data to appear)" -ForegroundColor Yellow
    Write-Host "    - No traffic is flowing through the firewall" -ForegroundColor Yellow
    Write-Host "    - Try a wider time range: -TimeRange 24h or -TimeRange 7d" -ForegroundColor Yellow
    Write-Host ""

    # Try wider time range as a hint
    $widerQuery = "AzureDiagnostics | where TimeGenerated > ago(7d) | where Category in ('AZFWNetworkRule', 'AZFWApplicationRule') | count"
    $widerResult = Invoke-WorkspaceQuery -WorkspaceId $workspace.customerId -Query $widerQuery
    $widerCount = 0
    if ($widerResult -and @($widerResult).Count -gt 0) {
        $first = @($widerResult)[0]
        if ($first -is [hashtable]) { $widerCount = [int]$first['Count'] }
        else { $widerCount = [int]$first.Count }
    }
    if ($widerCount -gt 0) {
        Write-Host "  Hint: Found $widerCount records in the last 7 days. Try: -TimeRange 7d" -ForegroundColor Cyan
    } else {
        Write-Host "  No firewall log data found even in the last 7 days." -ForegroundColor Yellow
        Write-Host "  Diagnostics may not be configured correctly or the firewall has had no traffic." -ForegroundColor Yellow
    }
    return
}

switch ($Action) {
    "summary" {
        $summaryQuery = @"
AzureDiagnostics
| where TimeGenerated > ago($TimeRange)
| where Category in ('AZFWNetworkRule', 'AZFWApplicationRule')
| extend RuleCategory = iif(Category == 'AZFWApplicationRule', 'Application', 'Network')
| summarize Hits=count() by RuleCategory, Action_s
| order by RuleCategory asc, Hits desc
"@

        $fqdnQuery = @"
AzureDiagnostics
| where TimeGenerated > ago($TimeRange)
| where Category == 'AZFWApplicationRule'
| where isnotempty(Fqdn_s)
| summarize Hits=count() by Fqdn_s, Action_s
| top 15 by Hits desc
"@

        $sourceQuery = @"
AzureDiagnostics
| where TimeGenerated > ago($TimeRange)
| where Category in ('AZFWNetworkRule', 'AZFWApplicationRule')
| where isnotempty(SourceIP)
| summarize Hits=count() by SourceIP, Action_s
| order by Hits desc
| take 15
"@

        Write-Section "Allow/Deny Summary"
        Write-ResultTable (Invoke-WorkspaceQuery -WorkspaceId $workspace.customerId -Query $summaryQuery)

        Write-Section "Top FQDNs (Application Rules)"
        Write-ResultTable (Invoke-WorkspaceQuery -WorkspaceId $workspace.customerId -Query $fqdnQuery)

        Write-Section "Top Source IPs"
        Write-ResultTable (Invoke-WorkspaceQuery -WorkspaceId $workspace.customerId -Query $sourceQuery)
    }
    "denied" {
        $deniedQuery = @"
AzureDiagnostics
| where TimeGenerated > ago($TimeRange)
| where Category in ('AZFWNetworkRule', 'AZFWApplicationRule')
| where Action_s == 'Deny'
| extend RuleCategory = iif(Category == 'AZFWApplicationRule', 'Application', 'Network')
| extend Destination = coalesce(Fqdn_s, DestinationIp_s)
| extend Port = tostring(toint(DestinationPort_d))
| extend Proto = Protocol_s
| where isnotempty(Destination)
| summarize Hits=count() by RuleCategory, SourceIP, Destination, Port, Proto
| order by Hits desc
| take 30
"@

        Write-Section "Denied Traffic"
        Write-ResultTable (Invoke-WorkspaceQuery -WorkspaceId $workspace.customerId -Query $deniedQuery)
    }
    "rules" {
        $rulesQuery = @"
AzureDiagnostics
| where TimeGenerated > ago($TimeRange)
| where Category in ('AZFWNetworkRule', 'AZFWApplicationRule')
| where Action_s == 'Deny'
| extend RuleType = iif(Category == 'AZFWApplicationRule', 'Application', 'Network')
| extend Destination = coalesce(Fqdn_s, DestinationIp_s)
| extend Port = tostring(toint(DestinationPort_d))
| extend Proto = Protocol_s
| where isnotempty(Destination)
| summarize Hits=count() by RuleType, Destination, Port, Proto
| extend SuggestedRule = case(
    RuleType == 'Application', strcat('App rule: allow ', Proto, ' to ', Destination),
    strcat('Net rule: allow ', Proto, ' to ', Destination, ':', Port))
| order by Hits desc
| take 30
"@

        Write-Section "Suggested Rules From Denied Traffic"
        Write-ResultTable (Invoke-WorkspaceQuery -WorkspaceId $workspace.customerId -Query $rulesQuery)
    }
}
