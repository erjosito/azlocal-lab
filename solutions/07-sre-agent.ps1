[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroup
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$AksClusterName = 'localbox-aks'
$Namespace = 'sre-lab'
$AlertRuleName = 'AKS Pod Failures - localbox-aks'
$MonitoringExtensionName = 'azuremonitor-containers'
$ProxyProcess = $null
$ProxyPort = 47012
$ProxyKubeConfig = Join-Path $PSScriptRoot "$AksClusterName.sre.kubeconfig"
$OriginalKubeConfig = $env:KUBECONFIG

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
        [switch]$AllowFailure
    )

    $output = & az @Arguments --only-show-errors 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($output | Out-String).Trim()

    if (-not $AllowFailure -and $exitCode -ne 0) {
        throw "Azure CLI command failed: az $($Arguments -join ' ')`n$text"
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
        [switch]$AllowFailure
    )

    $result = Invoke-AzCliText -Arguments $Arguments -AllowFailure:$AllowFailure
    if ($result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($result.Text)) {
        return $null
    }

    return $result.Text | ConvertFrom-Json -Depth 100
}

function Invoke-KubectlText {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,
        [switch]$AllowFailure
    )

    $output = & kubectl @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($output | Out-String).Trim()

    if (-not $AllowFailure -and $exitCode -ne 0) {
        throw "kubectl $($Arguments -join ' ') failed.`n$text"
    }

    return [PSCustomObject]@{
        ExitCode = $exitCode
        Text     = $text
    }
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

function Ensure-AzLogin {
    $account = Invoke-AzCliJson -Arguments @('account', 'show', '-o', 'json') -AllowFailure
    if (-not $account) {
        throw 'Azure CLI is not logged in. Run az login first.'
    }

    return $account
}

function Ensure-AzExtension {
    param([Parameter(Mandatory)][string]$Name)

    $extension = Invoke-AzCliJson -Arguments @('extension', 'show', '--name', $Name, '-o', 'json') -AllowFailure
    if ($extension) {
        Write-Info "Azure CLI extension '$Name' is already installed." Green
        return
    }

    Write-Info "Installing Azure CLI extension '$Name'..." Yellow
    Invoke-AzCliText -Arguments @('extension', 'add', '--name', $Name, '--upgrade', '-o', 'none') | Out-Null
}

function Start-ClusterProxy {
    param([string]$ClusterName, [string]$Rg, [int]$Port)

    if (Test-Path $ProxyKubeConfig) {
        Remove-Item -Path $ProxyKubeConfig -Force
    }

    $env:KUBECONFIG = $ProxyKubeConfig
    $process = Start-Process -FilePath 'az' -ArgumentList @('connectedk8s', 'proxy', '--name', $ClusterName, '--resource-group', $Rg, '--port', $Port, '--file', $ProxyKubeConfig, '--only-show-errors') -PassThru -WindowStyle Hidden
    for ($attempt = 1; $attempt -le 24; $attempt++) {
        Start-Sleep -Seconds 5
        $probe = Invoke-KubectlText -Arguments @('get', 'nodes', '-o', 'name') -AllowFailure
        if ($probe.ExitCode -eq 0 -and $probe.Text) {
            Write-Info "Connected to '$ClusterName' through the Arc proxy." Green
            return $process
        }

        Write-Info "Waiting for Arc proxy readiness ($attempt/24)..." DarkGray
    }

    throw 'Timed out while waiting for az connectedk8s proxy to become ready.'
}

function Stop-ClusterProxy {
    param([System.Diagnostics.Process]$Process)

    if ($Process -and -not $Process.HasExited) {
        Stop-Process -Id $Process.Id -Force
    }

    if (Test-Path $ProxyKubeConfig) {
        Remove-Item -Path $ProxyKubeConfig -Force
    }

    $env:KUBECONFIG = $OriginalKubeConfig
}

function Ensure-MonitoringExtension {
    param($Workspace)

    $extension = Invoke-AzCliJson -Arguments @(
        'k8s-extension', 'show',
        '--name', $MonitoringExtensionName,
        '--cluster-name', $AksClusterName,
        '--cluster-type', 'connectedClusters',
        '--resource-group', $ResourceGroup,
        '-o', 'json'
    ) -AllowFailure

    if (-not $extension) {
        Write-Info 'Container Insights extension is missing. Creating it because alerts need KubePodInventory data.' Yellow
        Invoke-AzCliText -Arguments @(
            'k8s-extension', 'create',
            '--name', $MonitoringExtensionName,
            '--cluster-name', $AksClusterName,
            '--cluster-type', 'connectedClusters',
            '--resource-group', $ResourceGroup,
            '--extension-type', 'Microsoft.AzureMonitor.Containers',
            '--configuration-settings',
            "logAnalyticsWorkspaceResourceID=$($Workspace.id)",
            'amalogs.useAADAuth=true',
            '-o', 'none'
        ) | Out-Null
    } else {
        Write-Info 'Container Insights extension already exists.' Green
    }

    for ($attempt = 1; $attempt -le 30; $attempt++) {
        $extension = Invoke-AzCliJson -Arguments @(
            'k8s-extension', 'show',
            '--name', $MonitoringExtensionName,
            '--cluster-name', $AksClusterName,
            '--cluster-type', 'connectedClusters',
            '--resource-group', $ResourceGroup,
            '-o', 'json'
        ) -AllowFailure

        if ($extension -and $extension.provisioningState -eq 'Succeeded') {
            Write-Info 'Container Insights extension is in Succeeded state.' Green
            return
        }

        Write-Info "Waiting for Container Insights extension provisioning ($attempt/30)..." DarkGray
        Start-Sleep -Seconds 20
    }

    throw 'Timed out while waiting for the azuremonitor-containers extension.'
}

function Ensure-Namespace {
    $manifest = @"
apiVersion: v1
kind: Namespace
metadata:
  name: $Namespace
"@
    $manifest | & kubectl apply -f - | Out-Null
}

function Apply-Manifest {
    param([Parameter(Mandatory)][string]$Yaml)

    $output = $Yaml | & kubectl apply -f - 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ($output | Out-String)
    }
}

function Remove-FailingPods {
    foreach ($pod in 'sre-fail-a', 'sre-fail-b') {
        Invoke-KubectlText -Arguments @('delete', 'pod', $pod, '--namespace', $Namespace, '--ignore-not-found=true') -AllowFailure | Out-Null
    }
}

function Get-AlertsByCondition {
    param(
        [string]$SubscriptionId,
        [string]$Rg,
        [string]$Condition,
        [string]$AlertRuleId
    )

    $url = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.AlertsManagement/alerts?api-version=2019-05-05-preview&`$filter=targetResourceGroup eq '$Rg' and monitorCondition eq '$Condition'"
    $response = Invoke-AzCliJson -Arguments @('rest', '--method', 'get', '--url', $url, '-o', 'json') -AllowFailure
    if (-not $response -or -not $response.value) {
        return @()
    }

    return @($response.value | Where-Object {
        $essentials = $_.properties.essentials
        $essentials.alertRule -eq $AlertRuleId -or $essentials.alertRule -like "*$AlertRuleName*"
    })
}

try {
    Write-Banner 'Exercise 07 - Azure SRE Agent'

    Write-Step 'Validate Azure, the AKS Arc cluster, and Log Analytics prerequisites.' 'This exercise is mostly portal-based, but alerting depends on cluster telemetry and a workspace that can store Kubernetes logs.'
    $account = Ensure-AzLogin
    $cluster = Invoke-AzCliJson -Arguments @('connectedk8s', 'show', '--name', $AksClusterName, '--resource-group', $ResourceGroup, '-o', 'json') -AllowFailure
    if (-not $cluster) {
        throw "AKS Arc cluster '$AksClusterName' was not found in resource group '$ResourceGroup'."
    }

    $workspaces = @(Invoke-AzCliJson -Arguments @('monitor', 'log-analytics', 'workspace', 'list', '--resource-group', $ResourceGroup, '-o', 'json'))
    if (-not $workspaces -or $workspaces.Count -eq 0) {
        throw 'No Log Analytics workspace was found in the resource group. Container Insights data is required for the alert rule.'
    }
    $workspace = $workspaces | Where-Object { $_.name -like '*Workspace*' } | Select-Object -First 1
    if (-not $workspace) {
        $workspace = $workspaces | Select-Object -First 1
    }
    Write-Info "Using workspace '$($workspace.name)' for alert queries." Green

    Write-Step 'Ensure the required Azure CLI extensions exist.' 'Using Azure CLI keeps the automation close to the Azure control plane and avoids unnecessary PowerShell cmdlet dependencies.'
    foreach ($extension in 'connectedk8s', 'k8s-extension', 'scheduled-query') {
        Ensure-AzExtension -Name $extension
    }

    Write-Step 'Ensure Container Insights is enabled and healthy.' 'A key lesson from testing is that SRE alerts are useless if KubePodInventory data never reaches Log Analytics.'
    Ensure-MonitoringExtension -Workspace $workspace
    $ProxyProcess = Start-ClusterProxy -ClusterName $AksClusterName -Rg $ResourceGroup -Port $ProxyPort
    $amaPods = Invoke-KubectlText -Arguments @('get', 'pods', '--namespace', 'kube-system', '--no-headers') -AllowFailure
    if ($amaPods.Text -notmatch 'ama-logs') {
        Write-Info 'ama-logs pods were not visible immediately. The script will keep checking workspace data before creating the alert.' Yellow
    }

    for ($attempt = 1; $attempt -le 24; $attempt++) {
        $rows = Invoke-WorkspaceQuery -WorkspaceId $workspace.customerId -Query 'KubePodInventory | where TimeGenerated > ago(30m) | summarize Count=count(), ClusterNames=make_set(ClusterName, 10)'
        if ($rows.Count -gt 0 -and [int]$rows[0].Count -gt 0) {
            Write-Info 'KubePodInventory data is flowing to Log Analytics.' Green
            break
        }

        if ($attempt -eq 24) {
            throw 'KubePodInventory is still empty after waiting. Fix Container Insights before relying on SRE alerting.'
        }

        Write-Info "Waiting for Kubernetes telemetry to arrive in Log Analytics ($attempt/24)..." DarkGray
        Start-Sleep -Seconds 15
    }

    Write-Step 'Create a small healthy workload that the portal-based SRE Agent can reason about.' 'A known-good service gives the incident narrative context: one workload is healthy while another is intentionally broken.'
    Ensure-Namespace
    Apply-Manifest -Yaml @"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: localbox-store
  namespace: $Namespace
spec:
  replicas: 2
  selector:
    matchLabels:
      app: localbox-store
  template:
    metadata:
      labels:
        app: localbox-store
    spec:
      containers:
      - name: nginx
        image: nginx
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: localbox-store
  namespace: $Namespace
spec:
  selector:
    app: localbox-store
  ports:
  - port: 80
    targetPort: 80
  type: ClusterIP
"@
    Write-Info 'Healthy workload applied.' Green

    Write-Step 'Deploy failing pods that will generate alertable evidence.' 'Using failing standalone pods, rather than only a deployment in CrashLoopBackOff, aligns with the chosen KQL that looks for pods outside Running and Succeeded states.'
    Remove-FailingPods
    Apply-Manifest -Yaml @"
apiVersion: v1
kind: Pod
metadata:
  name: sre-fail-a
  namespace: $Namespace
spec:
  restartPolicy: Never
  containers:
  - name: fail
    image: nginx
    command: ['/bin/sh', '-c', 'exit 1']
---
apiVersion: v1
kind: Pod
metadata:
  name: sre-fail-b
  namespace: $Namespace
spec:
  restartPolicy: Never
  containers:
  - name: fail
    image: nginx
    command: ['/bin/sh', '-c', 'exit 1']
"@
    Write-Info 'Failing pods created.' Green
    Invoke-KubectlText -Arguments @('get', 'pods', '--namespace', $Namespace, '-o', 'wide') | ForEach-Object { Write-Host $_.Text }

    Write-Step 'Create or update a scheduled query alert rule with auto-mitigation enabled.' 'The lab lesson here is critical: ALWAYS set --auto-mitigate true so the SRE Agent does not keep chasing stale incidents.'
    $query = @"
KubePodInventory
| where ClusterName == '$AksClusterName'
| where PodStatus != 'Running' and PodStatus != 'Succeeded'
| where Namespace !in ('kube-system','arc','azure-arc')
| summarize FailedPods=dcount(PodUid) by bin(TimeGenerated, 5m)
| where FailedPods > 0
"@

    $workspaceScope = [string]$workspace.id
    $existingRule = Invoke-AzCliJson -Arguments @('monitor', 'scheduled-query', 'show', '--resource-group', $ResourceGroup, '--name', $AlertRuleName, '-o', 'json') -AllowFailure
    if ($existingRule) {
        Invoke-AzCliText -Arguments @(
            'monitor', 'scheduled-query', 'update',
            '--resource-group', $ResourceGroup,
            '--name', $AlertRuleName,
            '--condition', "count 'PodFailureQuery' > 0",
            '--condition-query', "PodFailureQuery=$query",
            '--evaluation-frequency', '5m',
            '--window-size', '5m',
            '--severity', '2',
            '--auto-mitigate', 'true',
            '--description', 'Lab alert for failed pods on localbox-aks',
            '--skip-query-validation', 'true',
            '-o', 'none'
        ) | Out-Null
        Write-Info 'Existing scheduled query alert updated.' Green
    } else {
        Invoke-AzCliText -Arguments @(
            'monitor', 'scheduled-query', 'create',
            '--resource-group', $ResourceGroup,
            '--name', $AlertRuleName,
            '--location', $workspace.location,
            '--scopes', $workspaceScope,
            '--condition', "count 'PodFailureQuery' > 0",
            '--condition-query', "PodFailureQuery=$query",
            '--evaluation-frequency', '5m',
            '--window-size', '5m',
            '--severity', '2',
            '--auto-mitigate', 'true',
            '--description', 'Lab alert for failed pods on localbox-aks',
            '--skip-query-validation', 'true',
            '-o', 'none'
        ) | Out-Null
        Write-Info 'Scheduled query alert created.' Green
    }

    $alertRule = Invoke-AzCliJson -Arguments @('monitor', 'scheduled-query', 'show', '--resource-group', $ResourceGroup, '--name', $AlertRuleName, '-o', 'json')
    Write-Info "Alert rule id: $($alertRule.id)" Green
    Write-Info 'Lesson learned: the alert scope uses the Log Analytics workspace because the KQL query runs over workspace telemetry even though the incident is about the AKS Arc cluster.' DarkCyan

    Write-Step 'Wait for the alert to fire and show the resulting incident evidence.' 'This proves the portal-based SRE Agent will have a real Azure Monitor signal to react to.'
    for ($attempt = 1; $attempt -le 20; $attempt++) {
        $alerts = Get-AlertsByCondition -SubscriptionId $account.id -Rg $ResourceGroup -Condition 'Fired' -AlertRuleId $alertRule.id
        if ($alerts.Count -gt 0) {
            Write-Info 'The alert has fired. Matching alert instances:' Green
            $alerts | ForEach-Object {
                $essentials = $_.properties.essentials
                [PSCustomObject]@{
                    Name       = $essentials.alertRule
                    Severity   = $essentials.severity
                    State      = $essentials.alertState
                    Condition  = $essentials.monitorCondition
                    StartedUtc = $essentials.startDateTime
                }
            } | Format-Table -AutoSize | Out-String | Write-Host
            break
        }

        if ($attempt -eq 20) {
            throw 'The alert did not fire in the expected time window. Check whether the workspace is receiving KubePodInventory data and whether the rule was created successfully.'
        }

        Write-Info "Waiting for the alert to fire ($attempt/20). Scheduled query rules typically need 10-15 minutes." DarkGray
        Start-Sleep -Seconds 30
    }

    Write-Step 'Clean up the failing pods and verify the alert auto-resolves.' 'This demonstrates why auto-mitigation matters for the SRE Agent: the incident should close itself after the underlying signal disappears.'
    Remove-FailingPods
    Write-Info 'Failing pods removed.' Green

    for ($attempt = 1; $attempt -le 20; $attempt++) {
        $resolvedAlerts = Get-AlertsByCondition -SubscriptionId $account.id -Rg $ResourceGroup -Condition 'Resolved' -AlertRuleId $alertRule.id
        if ($resolvedAlerts.Count -gt 0) {
            Write-Info 'The alert auto-resolved successfully.' Green
            $resolvedAlerts | ForEach-Object {
                $essentials = $_.properties.essentials
                [PSCustomObject]@{
                    Name         = $essentials.alertRule
                    State        = $essentials.alertState
                    Condition    = $essentials.monitorCondition
                    LastModified = $essentials.lastModifiedDateTime
                }
            } | Format-Table -AutoSize | Out-String | Write-Host
            break
        }

        if ($attempt -eq 20) {
            throw 'The alert did not auto-resolve in time. Re-check that the alert rule has autoMitigate=true.'
        }

        Write-Info "Waiting for auto-resolution ($attempt/20)..." DarkGray
        Start-Sleep -Seconds 30
    }

    Write-Step 'Explain how the SRE Agent uses subagents and how to continue in the portal.' 'The script can create signals and evidence, but the actual SRE Agent experience lives in sre.azure.com where custom agents, knowledge, and response plans are configured.'
    Write-Info 'Suggested subagents:' Cyan
    Write-Info ' - kubernetes_expert: pod failures, scheduling, node pressure, and namespace issues.' Cyan
    Write-Info ' - infrastructure_expert: Azure Local, Arc connectivity, storage, and host health.' Cyan
    Write-Info ' - database_expert: Arc data services, data controller, and SQL MI issues.' Cyan
    Write-Info 'How to use them at sre.azure.com:' Cyan
    Write-Info ' 1. Create a custom SRE Agent and add your Azure subscription as a data source.' Cyan
    Write-Info ' 2. Upload exercises\sre-agent-knowledge\azure-local-operations.md as knowledge.' Cyan
    Write-Info ' 3. Create response plans that match this alert rule or the target resource group.' Cyan
    Write-Info ' 4. Verify the agent routes pod incidents to the Kubernetes-focused subagent.' Cyan
    Write-Info 'Lesson learned: stale alerts confuse automated investigations, so keeping auto-mitigation enabled is operationally important, not just a cosmetic setting.' DarkCyan

    Write-Banner 'Exercise 07 completed'
    Write-Info 'The Azure-side prerequisites for the portal-based SRE Agent exercise are now in place.' Green
} catch {
    Write-Host ''
    Write-Host 'Exercise 07 failed.' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    throw
} finally {
    try { Remove-FailingPods } catch { }
    Stop-ClusterProxy -Process $ProxyProcess
}
