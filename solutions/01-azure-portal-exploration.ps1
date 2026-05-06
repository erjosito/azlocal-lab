param(
    [Parameter(Mandatory)]
    [string]$ResourceGroup
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Common.AzureLocalLab.ps1"

try {
    Write-Banner 'Exercise 01 - Azure Portal Exploration'
    Write-Step -What 'Preparing Azure Local context and the CLI extensions used by Arc-aware commands.' -Why 'This script mirrors what a student would inspect in the Azure portal, but does it repeatably through Azure CLI.'
    Ensure-AzExtension -Name 'customlocation' | Out-Null
    Ensure-AzExtension -Name 'connectedmachine' | Out-Null
    $context = Get-AzureLocalContext -ResourceGroup $ResourceGroup
    $resourceGroupId = Invoke-AzTsv -Arguments @('group', 'show', '--name', $ResourceGroup, '--query', 'id')

    Write-Step -What 'Showing Arc Resource Bridge (appliance) details.' -Why 'The appliance is the translator between Azure Resource Manager and the local cluster control plane.'
    if ($context.ResourceBridge) {
        $bridge = Invoke-AzJson -Arguments @('resource', 'show', '--ids', $context.ResourceBridge.id)
        [pscustomobject]@{
            Name = $bridge.name
            Type = $bridge.type
            Location = $bridge.location
            ProvisioningState = if ($bridge.properties.PSObject.Properties['provisioningState']) { $bridge.properties.provisioningState } else { '-' }
            Status = if ($bridge.properties.PSObject.Properties['status']) { $bridge.properties.status } else { '-' }
            Distro = if ($bridge.properties.PSObject.Properties['distro']) { $bridge.properties.distro } else { '-' }
            KubernetesVersion = if ($bridge.properties.PSObject.Properties['kubernetesVersion']) { $bridge.properties.kubernetesVersion } else { '-' }
        } | Format-Table -AutoSize | Out-String | Write-Host
        Write-Info 'If this appliance is unavailable, Azure can still see existing resources, but new VM or AKS operations usually stop working.'
    }
    else {
        Write-Warn 'No Arc Resource Bridge appliance resource was found in this resource group.'
    }

    Write-Step -What 'Showing Custom Location details.' -Why 'Students need to understand how Azure knows where to land workloads on non-Azure infrastructure.'
    if ($context.CustomLocation) {
        $customLocation = Invoke-AzJson -Arguments @('resource', 'show', '--ids', $context.CustomLocation.id)
        [pscustomobject]@{
            Name = $customLocation.name
            Type = $customLocation.type
            Namespace = $customLocation.properties.namespace
            HostResourceId = $customLocation.properties.hostResourceId
            ProvisioningState = $customLocation.properties.provisioningState
        } | Format-Table -AutoSize | Out-String | Write-Host
        Write-Info 'The hostResourceId normally points to the Arc Resource Bridge. Together they turn the Azure Local cluster into a deployable Azure location.'
    }
    else {
        Write-Warn 'No custom location was found.'
    }

    Write-Step -What 'Listing Azure Policy assignments that apply at the resource group scope.' -Why 'Azure Arc is useful because governance follows the resources even when they are not running in Azure datacenters.'
    $policyAssignments = @(Invoke-AzJson -Arguments @('policy', 'assignment', 'list', '--resource-group', $ResourceGroup, '--filter', 'atScope()', '--expand', 'LatestDefinitionVersion,EffectiveDefinitionVersion'))
    if ($policyAssignments) {
        $policyRows = foreach ($assignment in $policyAssignments) {
            [pscustomobject]@{
                Name = $assignment.name
                DisplayName = $assignment.displayName
                Scope = $assignment.scope
                EnforcementMode = $assignment.enforcementMode
            }
        }
        Show-TableFromObjects -InputObject $policyRows -Property @('Name', 'DisplayName', 'EnforcementMode', 'Scope')
    }
    else {
        Write-Warn 'No policy assignments were returned at resource group scope.'
    }

    Write-Step -What 'Showing Azure Monitor / Log Analytics workspace details.' -Why 'This is where the lab stores telemetry for cluster, host, and AKS observability.'
    if ($context.Workspace) {
        $workspace = Invoke-AzJson -Arguments @('monitor', 'log-analytics', 'workspace', 'show', '-g', $ResourceGroup, '--workspace-name', $context.Workspace.name)
        [pscustomobject]@{
            Name = $workspace.name
            Location = $workspace.location
            CustomerId = $workspace.customerId
            RetentionInDays = $workspace.retentionInDays
            PublicNetworkAccessForIngestion = $workspace.publicNetworkAccessForIngestion
        } | Format-Table -AutoSize | Out-String | Write-Host
        Write-Info 'The workspace is the data lake for KQL queries, dashboards, and alerting.'
    }
    else {
        Write-Warn 'No Log Analytics workspace was found.'
    }

    Write-Step -What 'Explaining the dual identity model used in the lab.' -Why 'Azure Local blends cloud governance with local infrastructure administration, so students need both viewpoints.'
    Write-Host '• Azure RBAC controls who can see and manage Azure resources such as the cluster, custom location, Arc servers, and AKS resource objects.' -ForegroundColor Yellow
    Write-Host '• Local Active Directory (jumpstart.local) controls classic server access inside the nested environment, for example jumpstart\Administrator logging on to AzLHOST1 or AzLHOST2.' -ForegroundColor Yellow
    Write-Host '• In practice: Azure tells the platform WHAT to manage, while local AD still controls OS-level sign-in and many in-guest operations.' -ForegroundColor Yellow
    Write-Host '• That split is why hybrid operations often require both Azure permissions and local admin credentials.' -ForegroundColor Yellow

    Write-Step -What 'Listing Arc extensions installed on AzLHOST1 and AzLHOST2.' -Why 'Extensions are the mechanism Azure uses to project features like monitoring or guest configuration onto Arc-enabled machines.'
    $targetServers = @($context.ArcServers | Where-Object { $_.name -in @('AzLHOST1', 'AzLHOST2') })
    if (-not $targetServers) {
        $targetServers = @($context.ArcServers)
    }

    foreach ($server in $targetServers) {
        Write-Host "Extensions on $($server.name):" -ForegroundColor Green
        $extensions = @(Invoke-AzJson -Arguments @('connectedmachine', 'extension', 'list', '--machine-name', $server.name, '--resource-group', $ResourceGroup))
        if ($extensions) {
            $extensionRows = foreach ($extension in $extensions) {
                [pscustomobject]@{
                    Name = $extension.name
                    Type = $extension.properties.type
                    ProvisioningState = $extension.properties.provisioningState
                    Publisher = $extension.properties.publisher
                }
            }
            Show-TableFromObjects -InputObject $extensionRows -Property @('Name', 'Publisher', 'Type', 'ProvisioningState')
        }
        else {
            Write-Warn "No extensions were returned for $($server.name)."
        }
    }

    Write-Step -What 'Summarizing what a student would notice in the portal.' -Why 'The portal experience is about understanding relationships, not only about reading raw properties.'
    Write-Host '• Arc Resource Bridge + Custom Location = Azure can place workloads on the cluster.' -ForegroundColor Magenta
    Write-Host '• Arc-enabled servers = Azure governance and extensions applied to non-Azure machines.' -ForegroundColor Magenta
    Write-Host '• Policy assignments = the cloud compliance layer for hybrid infrastructure.' -ForegroundColor Magenta
    Write-Host '• Log Analytics workspace = the shared telemetry backend for monitoring and alerting.' -ForegroundColor Magenta

    Write-Banner 'Portal exploration completed'
}
catch {
    Write-Fail $_.Exception.Message
    exit 1
}
