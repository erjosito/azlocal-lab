#####################################################################
# monitor-firewall-logs.ps1 — Query Azure Firewall logs for LocalBox
#
# Uses az monitor log-analytics query against the resource-specific
# Azure Firewall tables in the Log Analytics workspace in the lab RG.
#
# Usage examples:
#   .\scripts\monitor-firewall-logs.ps1 -ResourceGroup azlocal2
#   .\scripts\monitor-firewall-logs.ps1 -ResourceGroup azlocal2 -Action denied -TimeRange 4h
#   .\scripts\monitor-firewall-logs.ps1 -ResourceGroup azlocal2 -Action rules -TimeRange 1d
#####################################################################

param(
    [Parameter(Mandatory)][string]$ResourceGroup,
    [ValidatePattern('^[0-9]+[mhd]$')][string]$TimeRange = "1h",
    [ValidateSet("summary", "denied", "rules")][string]$Action = "summary"
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
    throw "No Log Analytics workspace matching '*Workspace*' was found in resource group '$ResourceGroup'."
}

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " Azure Firewall Log Monitor"
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " Resource Group : $ResourceGroup"
Write-Host " Workspace      : $($workspace.name)"
Write-Host " Time Range     : $TimeRange"
Write-Host " Action         : $Action"
Write-Host "============================================="

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
)
| order by Category asc, Hits desc
"@

        $fqdnQuery = @"
AZFWApplicationRule
| where TimeGenerated > ago($TimeRange)
| where isnotempty(Fqdn)
| summarize Hits=count() by Fqdn
| top 10 by Hits desc
"@

        Write-Section "Allow/Deny Summary"
        Write-ResultTable (Invoke-WorkspaceQuery -WorkspaceId $workspace.customerId -Query $summaryQuery)

        Write-Section "Top 10 FQDNs"
        Write-ResultTable (Invoke-WorkspaceQuery -WorkspaceId $workspace.customerId -Query $fqdnQuery)
    }
    "denied" {
        $deniedQuery = @"
union isfuzzy=true
(
    AZFWApplicationRule
    | where TimeGenerated > ago($TimeRange)
    | where Action == "Deny"
    | extend Destination=Fqdn, Port=tostring(case(Protocol == "Http", 80, Protocol == "Https", 443, "n/a")), Protocol=tostring(Protocol)
    | summarize Hits=count() by Category="ApplicationRule", Destination, Port, Protocol
),
(
    AZFWNetworkRule
    | where TimeGenerated > ago($TimeRange)
    | where Action == "Deny"
    | extend Destination=tostring(DestinationIp), Port=tostring(DestinationPort), Protocol=tostring(Protocol)
    | summarize Hits=count() by Category="NetworkRule", Destination, Port, Protocol
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
