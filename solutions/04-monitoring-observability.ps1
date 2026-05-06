param(
    [Parameter(Mandatory)]
    [string]$ResourceGroup
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Common.AzureLocalLab.ps1"

$dcrRuleFilePath = Join-Path $PSScriptRoot '04-container-insights-dcr.generated.json'

try {
    Write-Banner 'Exercise 04 - Monitoring and Observability'
    Write-Step -What 'Preparing Azure Monitor, Arc Kubernetes, and query-related CLI extensions.' -Why 'Exercise 04 touches Azure Monitor, Container Insights, DCRs, Log Analytics, and alert rules, so several Azure CLI extensions are involved.'
    Ensure-AzExtension -Name 'connectedk8s' | Out-Null
    Ensure-AzExtension -Name 'k8s-extension' | Out-Null
    Ensure-AzExtension -Name 'monitor-control-service' | Out-Null
    Ensure-AzExtension -Name 'scheduled-query' | Out-Null
    Ensure-AzExtension -Name 'log-analytics' | Out-Null

    $context = Get-AzureLocalContext -ResourceGroup $ResourceGroup
    $workspace = $context.Workspace
    if (-not $workspace) {
        throw 'No Log Analytics workspace was found. Monitoring exercises depend on a workspace such as LocalBox-Workspace.'
    }

    $aksClusterName = 'localbox-aks'
    $location = $context.Location
    $connectedCluster = Invoke-AzJson -Arguments @('connectedk8s', 'show', '--resource-group', $ResourceGroup, '--name', $aksClusterName) -AllowNotFound
    if (-not $connectedCluster) {
        throw "Arc-connected Kubernetes cluster '$aksClusterName' was not found. Run Exercise 03 first."
    }

    $workspaceDetails = Invoke-AzJson -Arguments @('monitor', 'log-analytics', 'workspace', 'show', '-g', $ResourceGroup, '--workspace-name', $workspace.name)
    $workspaceId = $workspaceDetails.id
    $workspaceCustomerId = $workspaceDetails.customerId
    $resourceGroupId = Invoke-AzTsv -Arguments @('group', 'show', '--name', $ResourceGroup, '--query', 'id')
    $dcrName = 'localbox-aks-ci-dcr'
    $associationName = 'localbox-aks-ci-association'
    $alertName = 'localbox-aks-node-cpu-alert'

    Write-Step -What 'Checking whether Container Insights is already enabled on the Arc-enabled AKS cluster.' -Why 'Container Insights is delivered as an Arc extension, so the script should reuse an existing healthy extension when possible.'
    $monitorExtension = Invoke-AzJson -Arguments @(
        'k8s-extension', 'show',
        '--resource-group', $ResourceGroup,
        '--cluster-name', $aksClusterName,
        '--cluster-type', 'connectedClusters',
        '--name', 'azuremonitor-containers'
    ) -AllowNotFound

    if (-not $monitorExtension) {
        Write-Info 'Creating the azuremonitor-containers extension and pointing it at the lab Log Analytics workspace.'
        $monitorExtension = Invoke-AzJson -Arguments @(
            'k8s-extension', 'create',
            '--resource-group', $ResourceGroup,
            '--cluster-name', $aksClusterName,
            '--cluster-type', 'connectedClusters',
            '--name', 'azuremonitor-containers',
            '--extension-type', 'Microsoft.AzureMonitor.Containers',
            '--configuration-settings', "amalogs.useAADAuth=true", "logAnalyticsWorkspaceResourceID=$workspaceId"
        )
        Write-Success 'Container Insights extension created.'
    }
    else {
        Write-Success "Container Insights extension already exists with provisioning state '$($monitorExtension.provisioningState)'."
    }

    Write-Step -What 'Inspecting DCR associations on the Arc-enabled AKS cluster.' -Why 'With modern Azure Monitor, the DCR is the contract that says what data is collected and where it goes.'
    $dcrAssociations = @(Invoke-AzJson -Arguments @('monitor', 'data-collection', 'rule', 'association', 'list', '--resource', $connectedCluster.id))
    if ($dcrAssociations) {
        $associationRows = foreach ($association in $dcrAssociations) {
            [pscustomobject]@{
                Name = $association.name
                RuleId = $association.properties.dataCollectionRuleId
            }
        }
        Show-TableFromObjects -InputObject $associationRows -Property @('Name', 'RuleId')
    }
    else {
        Write-Warn 'No DCR association was found, so the script will create a simple Container Insights DCR and associate it manually.'

        $dcrPayload = @{
            location = $location
            kind = 'Linux'
            properties = @{
                dataSources = @{
                    extensions = @(
                        @{
                            name = 'ContainerInsightsExtension'
                            extensionName = 'ContainerInsights'
                            streams = @('Microsoft-ContainerInsights-Group-Default')
                        }
                    )
                }
                destinations = @{
                    logAnalytics = @(
                        @{
                            name = 'ciWorkspace'
                            workspaceResourceId = $workspaceId
                        }
                    )
                }
                dataFlows = @(
                    @{
                        streams = @('Microsoft-ContainerInsights-Group-Default')
                        destinations = @('ciWorkspace')
                    }
                )
            }
        } | ConvertTo-Json -Depth 10

        Set-Content -Path $dcrRuleFilePath -Value $dcrPayload -Encoding UTF8
        $dcr = Invoke-AzJson -Arguments @(
            'monitor', 'data-collection', 'rule', 'create',
            '--resource-group', $ResourceGroup,
            '--location', $location,
            '--name', $dcrName,
            '--rule-file', $dcrRuleFilePath
        )
        Write-Success "Created DCR '$($dcr.name)'."

        $null = Invoke-AzJson -Arguments @(
            'monitor', 'data-collection', 'rule', 'association', 'create',
            '--name', $associationName,
            '--rule-id', $dcr.id,
            '--resource', $connectedCluster.id
        )
        Write-Success 'Associated the DCR to the Arc-enabled AKS cluster.'
        $dcrAssociations = @(Invoke-AzJson -Arguments @('monitor', 'data-collection', 'rule', 'association', 'list', '--resource', $connectedCluster.id))
    }

    Write-Step -What 'Showing sample KQL queries for students to run in Log Analytics.' -Why 'Monitoring becomes useful when students can turn telemetry into operational questions and answers.'
    $nodePerformanceQuery = @'
// Node performance (CPU and memory)
Perf
| where TimeGenerated > ago(1h)
| where (ObjectName == "Processor" and CounterName == "% Processor Time" and InstanceName == "_Total")
   or (ObjectName == "Memory" and CounterName == "% Committed Bytes In Use")
| summarize AvgValue = avg(CounterValue) by bin(TimeGenerated, 5m), Computer, CounterName
| render timechart
'@
    $podHealthQuery = @'
// Pod health
KubePodInventory
| where TimeGenerated > ago(1h)
| summarize Pods = count() by Namespace, PodStatus
| order by Namespace asc, Pods desc
'@
    $eventLogsQuery = @'
// Kubernetes events
KubeEvents
| where TimeGenerated > ago(1h)
| project TimeGenerated, Namespace, Name, Reason, Message, Type
| order by TimeGenerated desc
'@

    Write-Host $nodePerformanceQuery -ForegroundColor Magenta
    Write-Host $podHealthQuery -ForegroundColor Magenta
    Write-Host $eventLogsQuery -ForegroundColor Magenta

    Write-Step -What 'Creating a sample scheduled-query alert for high node CPU.' -Why 'A log-backed alert demonstrates how KQL moves from exploration into proactive operations.'
    $existingAlert = @(Invoke-AzJson -Arguments @('resource', 'list', '-g', $ResourceGroup, '--resource-type', 'Microsoft.Insights/scheduledQueryRules')) |
        Where-Object { $_.name -eq $alertName } |
        Select-Object -First 1

    if (-not $existingAlert) {
        $cpuAlertQuery = "Perf | where TimeGenerated > ago(15m) | where ObjectName == 'Processor' and CounterName == '% Processor Time' and InstanceName == '_Total' | summarize AvgCPU = avg(CounterValue) by bin(TimeGenerated, 5m), Computer, _ResourceId | where AvgCPU > 80"
        $condition = "count 'CpuHot' > 0 resource id _ResourceId at least 1 violations out of 1 aggregated points"
        $null = Invoke-AzJson -Arguments @(
            'monitor', 'scheduled-query', 'create',
            '--resource-group', $ResourceGroup,
            '--name', $alertName,
            '--location', $location,
            '--scopes', $resourceGroupId,
            '--target-resource-type', 'Microsoft.Resources/subscriptions/resourceGroups',
            '--window-size', '15m',
            '--evaluation-frequency', '5m',
            '--severity', '2',
            '--description', 'Sample lab alert: node CPU over 80 percent based on Log Analytics data.',
            '--condition', $condition,
            '--condition-query', "CpuHot=$cpuAlertQuery",
            '--skip-query-validation', 'true'
        )
        Write-Success "Alert rule '$alertName' created."
    }
    else {
        Write-Success "Alert rule '$alertName' already exists."
    }

    Write-Step -What 'Explaining the monitoring pipeline end to end.' -Why 'Students should leave with a mental model, not just a set of created resources.'
    Write-Host '1. The Arc-enabled AKS cluster runs the Azure Monitor container extension.' -ForegroundColor Yellow
    Write-Host '2. The extension collects container, pod, node, and event telemetry.' -ForegroundColor Yellow
    Write-Host '3. A Data Collection Rule decides which streams are sent to the workspace.' -ForegroundColor Yellow
    Write-Host '4. Log Analytics stores the telemetry and exposes it through KQL.' -ForegroundColor Yellow
    Write-Host '5. Scheduled-query or metric alerts evaluate the data and turn it into proactive signals.' -ForegroundColor Yellow

    Write-Step -What 'Running a quick sample query to verify the workspace is reachable.' -Why 'Even if data needs time to arrive, the query path itself should work immediately.'
    $tablesQuery = 'search * | summarize Count=count() by $table | top 10 by Count desc'
    $queryResult = Invoke-AzJson -Arguments @('monitor', 'log-analytics', 'query', '--workspace', $workspaceCustomerId, '--analytics-query', $tablesQuery, '--timespan', 'P1D')
    if ($queryResult.tables) {
        Write-Success 'Log Analytics query path is working. Data freshness still depends on agent ingestion delay.'
    }

    Write-Banner 'Monitoring and observability automation completed'
}
catch {
    Write-Fail $_.Exception.Message
    exit 1
}
finally {
    Remove-Item $dcrRuleFilePath -ErrorAction SilentlyContinue
}
