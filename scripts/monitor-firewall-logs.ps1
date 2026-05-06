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

    return $text | ConvertFrom-Json -Depth 100
}

function Invoke-WorkspaceQuery {
    param(
        [Parameter(Mandatory)][string]$WorkspaceId,
        [Parameter(Mandatory)][string]$Query
    )

    $result = Invoke-AzJson -Arguments @(
        "monitor", "log-analytics", "query",
        "-w", $WorkspaceId,
        "--analytics-query", $Query,
        "-o", "json"
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
        [pscustomobject]$item
    }

    return $objects
}

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host $Title -ForegroundColor Cyan
    Write-Host ($Title.ToCharArray() | ForEach-Object { '-' } | Out-String).Trim()
}

function Write-ResultTable {
    param([Parameter(Mandatory)][object[]]$Rows)

    if (-not $Rows -or $Rows.Count -eq 0) {
        Write-Host "No results found."
        return
    }

    $Rows | Format-Table -AutoSize -Wrap
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
if ($diagSettings -and $diagSettings.value) {
    $hasDiagnostics = $diagSettings.value.Count -gt 0
} elseif ($diagSettings -is [array]) {
    $hasDiagnostics = $diagSettings.Count -gt 0
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
union isfuzzy=true AZFWNetworkRule, AZFWApplicationRule, AzureDiagnostics
| where TimeGenerated > ago($TimeRange)
| count
"@
$countResult = Invoke-WorkspaceQuery -WorkspaceId $workspace.customerId -Query $countQuery
$totalRows = if ($countResult -and $countResult.Count -gt 0) { [int]$countResult[0].Count } else { 0 }

if ($totalRows -eq 0) {
    Write-Host ""
    Write-Host "No firewall log data found in the last $TimeRange." -ForegroundColor Yellow
    Write-Host "  Possible causes:" -ForegroundColor Yellow
    Write-Host "    - Diagnostic settings were recently created (allow 5-10 min for data to appear)" -ForegroundColor Yellow
    Write-Host "    - No traffic is flowing through the firewall" -ForegroundColor Yellow
    Write-Host "    - Try a wider time range: -TimeRange 24h or -TimeRange 7d" -ForegroundColor Yellow
    Write-Host ""

    # Try wider time range as a hint
    $widerQuery = "union isfuzzy=true AZFWNetworkRule, AZFWApplicationRule, AzureDiagnostics | where TimeGenerated > ago(7d) | count"
    $widerResult = Invoke-WorkspaceQuery -WorkspaceId $workspace.customerId -Query $widerQuery
    $widerCount = if ($widerResult -and $widerResult.Count -gt 0) { [int]$widerResult[0].Count } else { 0 }
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
union isfuzzy=true
(
    AZFWApplicationRule
    | where TimeGenerated > ago($TimeRange)
    | summarize Hits=count() by Category="ApplicationRule", Action
),
(
    AZFWNetworkRule
    | where TimeGenerated > ago($TimeRange)
    | summarize Hits=count() by Category="NetworkRule", Action
),
(
    AzureDiagnostics
    | where TimeGenerated > ago($TimeRange)
    | where Category == "AzureFirewallApplicationRule"
    | summarize Hits=count() by Category="ApplicationRule(legacy)", Action=extract("Action: (\\w+)", 1, msg_s)
),
(
    AzureDiagnostics
    | where TimeGenerated > ago($TimeRange)
    | where Category == "AzureFirewallNetworkRule"
    | summarize Hits=count() by Category="NetworkRule(legacy)", Action=extract("Action: (\\w+)", 1, msg_s)
)
| where isnotempty(Action)
| order by Category asc, Hits desc
"@

        $fqdnQuery = @"
union isfuzzy=true
(
    AZFWApplicationRule
    | where TimeGenerated > ago($TimeRange)
    | where isnotempty(Fqdn)
    | summarize Hits=count() by Fqdn
),
(
    AzureDiagnostics
    | where TimeGenerated > ago($TimeRange)
    | where Category == "AzureFirewallApplicationRule"
    | extend Fqdn=extract("to (\\S+):", 1, msg_s)
    | where isnotempty(Fqdn)
    | summarize Hits=count() by Fqdn
)
| summarize Hits=sum(Hits) by Fqdn
| top 10 by Hits desc
"@

        $sourceQuery = @"
union isfuzzy=true
(
    AZFWNetworkRule
    | where TimeGenerated > ago($TimeRange)
    | summarize Hits=count() by SourceIp, Action
),
(
    AZFWApplicationRule
    | where TimeGenerated > ago($TimeRange)
    | summarize Hits=count() by SourceIp, Action
)
| summarize Hits=sum(Hits) by SourceIp, Action
| order by Hits desc
| take 15
"@

        Write-Section "Allow/Deny Summary"
        Write-ResultTable (Invoke-WorkspaceQuery -WorkspaceId $workspace.customerId -Query $summaryQuery)

        Write-Section "Top 10 FQDNs"
        Write-ResultTable (Invoke-WorkspaceQuery -WorkspaceId $workspace.customerId -Query $fqdnQuery)

        Write-Section "Top Source IPs"
        Write-ResultTable (Invoke-WorkspaceQuery -WorkspaceId $workspace.customerId -Query $sourceQuery)
    }
    "denied" {
        $deniedQuery = @"
union isfuzzy=true
(
    AZFWApplicationRule
    | where TimeGenerated > ago($TimeRange)
    | where Action == "Deny"
    | extend Destination=Fqdn, Port=tostring(case(Protocol == "Http", 80, Protocol == "Https", 443, "n/a")), Protocol=tostring(Protocol)
    | summarize Hits=count() by Category="ApplicationRule", SourceIp, Destination, Port, Protocol
),
(
    AZFWNetworkRule
    | where TimeGenerated > ago($TimeRange)
    | where Action == "Deny"
    | extend Destination=tostring(DestinationIp), Port=tostring(DestinationPort), Protocol=tostring(Protocol)
    | summarize Hits=count() by Category="NetworkRule", SourceIp, Destination, Port, Protocol
),
(
    AzureDiagnostics
    | where TimeGenerated > ago($TimeRange)
    | where Category == "AzureFirewallApplicationRule"
    | where msg_s contains "Deny"
    | extend Destination=extract("to (\\S+):", 1, msg_s), Port=extract(":(\\d+)", 1, msg_s), Protocol="Http/s", SourceIp=extract("from (\\S+):", 1, msg_s)
    | summarize Hits=count() by Category="ApplicationRule(legacy)", SourceIp, Destination, Port, Protocol
),
(
    AzureDiagnostics
    | where TimeGenerated > ago($TimeRange)
    | where Category == "AzureFirewallNetworkRule"
    | where msg_s contains "Deny"
    | extend Destination=extract("to (\\S+):", 1, msg_s), Port=extract(":(\\d+)", 1, msg_s), Protocol=extract("(TCP|UDP|ICMP)", 1, msg_s), SourceIp=extract("from (\\S+):", 1, msg_s)
    | summarize Hits=count() by Category="NetworkRule(legacy)", SourceIp, Destination, Port, Protocol
)
| order by Hits desc
"@

        Write-Section "Denied Traffic"
        Write-ResultTable (Invoke-WorkspaceQuery -WorkspaceId $workspace.customerId -Query $deniedQuery)
    }
    "rules" {
        $rulesQuery = @"
union isfuzzy=true
(
    AZFWApplicationRule
    | where TimeGenerated > ago($TimeRange)
    | where Action == "Deny"
    | where isnotempty(Fqdn)
    | summarize Hits=count() by RuleType="ApplicationRule", Destination=Fqdn, Ports="80,443", Protocols="Http,Https"
    | extend SuggestedRule=strcat("Application rule: permit ", Destination, " on Http:80,Https:443")
),
(
    AZFWNetworkRule
    | where TimeGenerated > ago($TimeRange)
    | where Action == "Deny"
    | extend Port=tostring(DestinationPort), Destination=tostring(DestinationIp), Protocols=tostring(Protocol)
    | extend RuleType=iff(toint(DestinationPort) in (80, 443, 8443), "ApplicationRule", "NetworkRule")
    | summarize Hits=count() by RuleType, Destination, Ports=Port, Protocols
    | extend SuggestedRule=case(
        RuleType == "ApplicationRule", strcat("Application rule candidate: map ", Destination, ":", Ports, " to the required FQDN and add it to AllowRequired."),
        strcat("Network rule candidate: permit ", Protocols, " to ", Destination, ":", Ports)
    )
)
| order by Hits desc
"@

        Write-Section "Suggested Rules From Denied Traffic"
        Write-ResultTable (Invoke-WorkspaceQuery -WorkspaceId $workspace.customerId -Query $rulesQuery)
    }
}
