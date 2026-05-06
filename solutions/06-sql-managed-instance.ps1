[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroup,

    [ValidateNotNullOrEmpty()]
    [string]$AksClusterName = 'localbox-aks',

    [ValidateNotNullOrEmpty()]
    [string]$NestedAdminPassword = 'Microsoft123!'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$DataExtensionName = 'arc-data-services'
$CustomLocationNamespace = 'arc'
$CustomLocationName = "$AksClusterName-arc"
$DataControllerName = 'localbox-dc'
$SqlManagedInstanceName = 'localbox-sqlmi'
$KubeNamespace = 'arc'
$SqlAdminUser = 'sqladmin'
$MinimumNodeCount = 3
$MinimumMemoryGi = 16
$ProxyProcess = $null
$ProxyPort = 47011
$ProxyKubeConfig = Join-Path $PSScriptRoot "$AksClusterName.kubeconfig"
$OriginalKubeConfig = $env:KUBECONFIG
$OriginalAzDataUser = $env:AZDATA_USERNAME
$OriginalAzDataPassword = $env:AZDATA_PASSWORD
$OriginalWorkspaceId = $env:WORKSPACE_ID
$OriginalWorkspaceSharedKey = $env:WORKSPACE_SHARED_KEY

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

function Invoke-KubectlJson {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,
        [switch]$AllowFailure
    )

    $result = Invoke-KubectlText -Arguments $Arguments -AllowFailure:$AllowFailure
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

function Ensure-Provider {
    param([Parameter(Mandatory)][string]$Namespace)

    $provider = Invoke-AzCliJson -Arguments @('provider', 'show', '--namespace', $Namespace, '-o', 'json')
    if ($provider.registrationState -eq 'Registered') {
        Write-Info "$Namespace is already registered." Green
        return
    }

    Write-Info "Registering provider $Namespace..." Yellow
    Invoke-AzCliText -Arguments @('provider', 'register', '--namespace', $Namespace, '-o', 'none') | Out-Null
}

function Get-ResourceGroup {
    param([string]$Name)

    $group = Invoke-AzCliJson -Arguments @('group', 'show', '--name', $Name, '-o', 'json') -AllowFailure
    if (-not $group) {
        throw "Resource group '$Name' was not found."
    }

    return $group
}

function Convert-KubernetesMemoryToGi {
    param([Parameter(Mandatory)][string]$MemoryValue)

    if ($MemoryValue -match '^(\d+)Ki$') {
        return [math]::Round(([double]$Matches[1] / 1MB), 2)
    }

    if ($MemoryValue -match '^(\d+)Mi$') {
        return [math]::Round(([double]$Matches[1] / 1024), 2)
    }

    if ($MemoryValue -match '^(\d+)Gi$') {
        return [double]$Matches[1]
    }

    return 0
}

function Start-ClusterProxy {
    param(
        [Parameter(Mandatory)][string]$ClusterName,
        [Parameter(Mandatory)][string]$Rg,
        [int]$Port = 47011
    )

    if (Test-Path $ProxyKubeConfig) {
        Remove-Item -Path $ProxyKubeConfig -Force
    }

    Write-Info 'Starting az connectedk8s proxy in the background so kubectl can reach the cluster through Azure Arc...' Yellow
    $process = Start-Process -FilePath 'az' -ArgumentList @('connectedk8s', 'proxy', '--name', $ClusterName, '--resource-group', $Rg, '--port', $Port, '--file', $ProxyKubeConfig, '--only-show-errors') -PassThru -WindowStyle Hidden
    $env:KUBECONFIG = $ProxyKubeConfig

    for ($attempt = 1; $attempt -le 24; $attempt++) {
        Start-Sleep -Seconds 5
        $probe = Invoke-KubectlText -Arguments @('get', 'nodes', '-o', 'name') -AllowFailure
        if ($probe.ExitCode -eq 0 -and $probe.Text) {
            Write-Info "Connected to cluster '$ClusterName' through the Arc proxy." Green
            return $process
        }

        Write-Info "Waiting for proxy readiness ($attempt/24)..." DarkGray
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

function Get-DefaultStorageClassName {
    $storageClasses = @(Invoke-KubectlJson -Arguments @('get', 'storageclass', '-o', 'json')).items
    if (-not $storageClasses -or $storageClasses.Count -eq 0) {
        throw 'No Kubernetes storage classes were found. Arc data services require persistent storage.'
    }

    $defaultClass = $storageClasses | Where-Object {
        $_.metadata.annotations.'storageclass.kubernetes.io/is-default-class' -eq 'true' -or
        $_.metadata.annotations.'storageclass.beta.kubernetes.io/is-default-class' -eq 'true'
    } | Select-Object -First 1

    if ($defaultClass) {
        return $defaultClass.metadata.name
    }

    return ($storageClasses | Select-Object -First 1).metadata.name
}

function Show-NodeCapacitySummary {
    param([object[]]$Nodes)

    $rows = foreach ($node in $Nodes) {
        [PSCustomObject]@{
            Name     = $node.metadata.name
            Cpu      = $node.status.capacity.cpu
            MemoryGi = Convert-KubernetesMemoryToGi -MemoryValue ([string]$node.status.capacity.memory)
        }
    }

    $rows | Format-Table -AutoSize | Out-String | Write-Host
}

function Ensure-WorkspaceContext {
    param([string]$Rg)

    $workspaces = @(Invoke-AzCliJson -Arguments @('monitor', 'log-analytics', 'workspace', 'list', '--resource-group', $Rg, '-o', 'json'))
    if (-not $workspaces -or $workspaces.Count -eq 0) {
        Write-Info 'No Log Analytics workspace was found. The script will continue, but log and metric auto-upload will be disabled.' Yellow
        return $null
    }

    $workspace = $workspaces | Where-Object { $_.name -like '*Workspace*' } | Select-Object -First 1
    if (-not $workspace) {
        $workspace = $workspaces | Select-Object -First 1
    }

    $sharedKeys = Invoke-AzCliJson -Arguments @('monitor', 'log-analytics', 'workspace', 'get-shared-keys', '--resource-group', $Rg, '--workspace-name', $workspace.name, '-o', 'json') -AllowFailure
    if ($sharedKeys -and $sharedKeys.primarySharedKey) {
        $env:WORKSPACE_ID = [string]$workspace.customerId
        $env:WORKSPACE_SHARED_KEY = [string]$sharedKeys.primarySharedKey
        Write-Info "Using Log Analytics workspace '$($workspace.name)' for auto-upload settings." Green
        return $workspace
    }

    Write-Info "Workspace '$($workspace.name)' was found, but shared keys were not available. Auto-upload will be disabled." Yellow
    return $null
}

function Get-OrCreateCustomLocation {
    param(
        [string]$Rg,
        [object]$Cluster,
        [object]$Extension
    )

    $existing = @(Invoke-AzCliJson -Arguments @('customlocation', 'list', '--resource-group', $Rg, '-o', 'json')) |
        Where-Object {
            $_.namespace -eq $CustomLocationNamespace -and $_.hostResourceId -eq $Cluster.id
        } |
        Select-Object -First 1

    if ($existing) {
        Write-Info "Reusing custom location '$($existing.name)'." Green
        return $existing
    }

    Write-Info "Creating custom location '$CustomLocationName' in namespace '$CustomLocationNamespace'..." Yellow
    Invoke-AzCliText -Arguments @(
        'customlocation', 'create',
        '--name', $CustomLocationName,
        '--resource-group', $Rg,
        '--location', $Cluster.location,
        '--namespace', $CustomLocationNamespace,
        '--host-resource-id', $Cluster.id,
        '--cluster-extension-ids', $Extension.id,
        '-o', 'none'
    ) | Out-Null

    for ($attempt = 1; $attempt -le 20; $attempt++) {
        $customLocation = Invoke-AzCliJson -Arguments @('customlocation', 'show', '--name', $CustomLocationName, '--resource-group', $Rg, '-o', 'json') -AllowFailure
        if ($customLocation -and $customLocation.provisioningState -eq 'Succeeded') {
            Write-Info "Custom location '$CustomLocationName' is ready." Green
            return $customLocation
        }

        Write-Info "Waiting for custom location provisioning ($attempt/20)..." DarkGray
        Start-Sleep -Seconds 15
    }

    throw 'Timed out while waiting for the custom location to become ready.'
}

function Wait-ForExtensionSucceeded {
    param([string]$Rg)

    for ($attempt = 1; $attempt -le 40; $attempt++) {
        $extension = Invoke-AzCliJson -Arguments @(
            'k8s-extension', 'show',
            '--name', $DataExtensionName,
            '--cluster-type', 'connectedClusters',
            '--cluster-name', $AksClusterName,
            '--resource-group', $Rg,
            '-o', 'json'
        ) -AllowFailure

        if ($extension -and $extension.provisioningState -eq 'Succeeded') {
            Write-Info 'Arc data services extension provisioning succeeded.' Green
            return $extension
        }

        Write-Info "Extension provisioning state: $($extension.provisioningState) (poll $attempt/40)" DarkGray
        Start-Sleep -Seconds 30
    }

    throw 'Timed out while waiting for the arc-data-services extension to reach Succeeded.'
}

function Get-ArmResourceByTypeAndName {
    param(
        [string]$Rg,
        [string]$ResourceType,
        [string]$Name
    )

    $resource = Invoke-AzCliJson -Arguments @('resource', 'show', '--resource-group', $Rg, '--resource-type', $ResourceType, '--name', $Name, '-o', 'json') -AllowFailure
    return $resource
}

function Wait-WithProgress {
    param(
        [Parameter(Mandatory)][string]$Activity,
        [Parameter(Mandatory)][int]$TotalMinutes,
        [Parameter(Mandatory)][scriptblock]$Probe,
        [int]$SleepSeconds = 30
    )

    $maxIterations = [math]::Ceiling(($TotalMinutes * 60) / $SleepSeconds)
    for ($iteration = 1; $iteration -le $maxIterations; $iteration++) {
        $result = & $Probe
        if ($result.Completed) {
            Write-Info $result.Message Green
            return
        }

        $percent = [int](($iteration / $maxIterations) * 100)
        Write-Progress -Activity $Activity -Status $result.Message -PercentComplete $percent
        Write-Info $result.Message DarkGray
        Start-Sleep -Seconds $SleepSeconds
    }

    throw "$Activity timed out."
}

try {
    Write-Banner 'Exercise 06 - SQL Managed Instance on Azure Local'

    Write-Step 'Validate prerequisites, Azure providers, Azure CLI extensions, and kubectl availability.' 'Arc data services span Azure Resource Manager and Kubernetes, so both planes must be ready before we deploy anything.'
    Ensure-AzLogin | Out-Null
    Get-ResourceGroup -Name $ResourceGroup | Out-Null
    if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
        throw 'kubectl is not installed or not on PATH.'
    }

    foreach ($provider in 'Microsoft.Kubernetes', 'Microsoft.KubernetesConfiguration', 'Microsoft.ExtendedLocation', 'Microsoft.AzureArcData') {
        Ensure-Provider -Namespace $provider
    }

    foreach ($extension in 'connectedk8s', 'k8s-extension', 'customlocation', 'arcdata') {
        Ensure-AzExtension -Name $extension
    }

    Write-Step 'Verify the Arc-enabled AKS cluster exists.' 'SQL Managed Instance enabled by Azure Arc is deployed onto the connected Kubernetes cluster, so the cluster must exist before any data-plane steps can work.'
    $cluster = Invoke-AzCliJson -Arguments @('connectedk8s', 'show', '--name', $AksClusterName, '--resource-group', $ResourceGroup, '-o', 'json') -AllowFailure
    if (-not $cluster) {
        throw "AKS Arc cluster '$AksClusterName' was not found in resource group '$ResourceGroup'."
    }
    Write-Info "Found cluster '$AksClusterName' in location '$($cluster.location)'." Green

    Write-Step 'Open an Azure Arc proxy to the cluster and validate node sizing.' 'One lesson from testing is that Arc data services fail late when the cluster is undersized, so we check capacity up front instead of waiting 20 minutes for Pending pods.'
    $ProxyProcess = Start-ClusterProxy -ClusterName $AksClusterName -Rg $ResourceGroup -Port $ProxyPort
    $nodeList = @(Invoke-KubectlJson -Arguments @('get', 'nodes', '-o', 'json')).items
    if ($nodeList.Count -lt $MinimumNodeCount) {
        throw "The cluster has $($nodeList.Count) nodes. This lab expects at least $MinimumNodeCount nodes."
    }

    Show-NodeCapacitySummary -Nodes $nodeList
    $undersizedNodes = @(
        $nodeList | Where-Object {
            (Convert-KubernetesMemoryToGi -MemoryValue ([string]$_.status.capacity.memory)) -lt $MinimumMemoryGi
        }
    )
    if ($undersizedNodes.Count -gt 0) {
        $names = $undersizedNodes | ForEach-Object { $_.metadata.name }
        throw "The following nodes have less than $MinimumMemoryGi GiB RAM: $($names -join ', ')."
    }
    Write-Info 'Cluster sizing check passed: 3+ nodes and each node has at least 16 GiB RAM.' Green

    Write-Step 'Discover storage and monitoring context dynamically.' 'Using the live cluster and resource group avoids hard-coding values that differ between lab runs.'
    $defaultStorageClass = Get-DefaultStorageClassName
    Write-Info "Default storage class selected for the lab: $defaultStorageClass" Green
    $workspace = Ensure-WorkspaceContext -Rg $ResourceGroup

    Write-Step 'Install the Arc data services extension on the AKS cluster if needed.' 'This extension teaches the cluster how to host Azure Arc data services and is the foundation for both the data controller and SQL MI.'
    $dataExtension = Invoke-AzCliJson -Arguments @(
        'k8s-extension', 'show',
        '--name', $DataExtensionName,
        '--extension-type', 'microsoft.arcdataservices',
        '--cluster-type', 'connectedClusters',
        '--cluster-name', $AksClusterName,
        '--resource-group', $ResourceGroup,
        '-o', 'json'
    ) -AllowFailure

    if (-not $dataExtension) {
        Invoke-AzCliText -Arguments @(
            'k8s-extension', 'create',
            '--name', $DataExtensionName,
            '--extension-type', 'microsoft.arcdataservices',
            '--cluster-type', 'connectedClusters',
            '--cluster-name', $AksClusterName,
            '--resource-group', $ResourceGroup,
            '--scope', 'cluster',
            '--release-namespace', $KubeNamespace,
            '--auto-upgrade-minor-version', 'false',
            '-o', 'none'
        ) | Out-Null
        Write-Info 'Arc data services extension creation submitted.' Green
    } else {
        Write-Info 'Arc data services extension already exists. Skipping creation.' Green
    }
    $dataExtension = Wait-ForExtensionSucceeded -Rg $ResourceGroup

    Write-Step 'Create or reuse the custom location for data services.' 'Azure uses a custom location as the placement address that maps ARM resources to this specific Arc-enabled Kubernetes cluster and namespace.'
    $customLocation = Get-OrCreateCustomLocation -Rg $ResourceGroup -Cluster $cluster -Extension $dataExtension

    Write-Step 'Create or reuse the Arc Data Controller.' 'The data controller is the control plane for Arc data services. Without it, Azure cannot manage SQL Managed Instance on the cluster.'
    $dataController = Get-ArmResourceByTypeAndName -Rg $ResourceGroup -ResourceType 'Microsoft.AzureArcData/dataControllers' -Name $DataControllerName
    if (-not $dataController) {
        $autoUploadLogs = if ($workspace) { 'true' } else { 'false' }
        $autoUploadMetrics = if ($workspace) { 'true' } else { 'false' }
        Invoke-AzCliText -Arguments @(
            'arcdata', 'dc', 'create',
            '--name', $DataControllerName,
            '--resource-group', $ResourceGroup,
            '--cluster-name', $AksClusterName,
            '--custom-location', $customLocation.name,
            '--connectivity-mode', 'direct',
            '--profile-name', 'azure-arc-aks-hci',
            '--k8s-namespace', $KubeNamespace,
            '--storage-class', $defaultStorageClass,
            '--auto-upload-metrics', $autoUploadMetrics,
            '--auto-upload-logs', $autoUploadLogs,
            '--no-wait',
            '-o', 'none'
        ) | Out-Null
        Write-Info 'Arc Data Controller deployment submitted.' Green
    } else {
        Write-Info 'Arc Data Controller resource already exists. The script will verify readiness instead of recreating it.' Green
    }

    Wait-WithProgress -Activity 'Waiting for Arc Data Controller' -TotalMinutes 15 -Probe {
        $dcText = Invoke-KubectlText -Arguments @('get', 'datacontrollers', '--namespace', $KubeNamespace, '--no-headers') -AllowFailure
        $podText = Invoke-KubectlText -Arguments @('get', 'pods', '--namespace', $KubeNamespace, '--no-headers') -AllowFailure
        $message = if ($podText.Text) { "Pods: $($podText.Text -replace "`r?`n", '; ')" } else { 'Pods are not visible yet.' }
        if ($dcText.ExitCode -eq 0 -and $dcText.Text -match 'Ready') {
            [PSCustomObject]@{ Completed = $true; Message = 'Arc Data Controller is Ready.' }
        } else {
            [PSCustomObject]@{ Completed = $false; Message = $message }
        }
    }

    Write-Step 'Create or reuse the SQL Managed Instance.' 'The SQL MI ARM resource drives Kubernetes resource creation through the data controller, so this is where the lab turns cluster capacity into a managed data service.'
    $sqlMi = Get-ArmResourceByTypeAndName -Rg $ResourceGroup -ResourceType 'Microsoft.AzureArcData/sqlManagedInstances' -Name $SqlManagedInstanceName
    if (-not $sqlMi) {
        $env:AZDATA_USERNAME = $SqlAdminUser
        $env:AZDATA_PASSWORD = $NestedAdminPassword
        Invoke-AzCliText -Arguments @(
            'sql', 'mi-arc', 'create',
            '--name', $SqlManagedInstanceName,
            '--resource-group', $ResourceGroup,
            '--custom-location', $customLocation.name,
            '--tier', 'GeneralPurpose',
            '--service-type', 'LoadBalancer',
            '--cores-request', '4',
            '--memory-request', '16Gi',
            '--storage-class-data', $defaultStorageClass,
            '--storage-class-logs', $defaultStorageClass,
            '--storage-class-backups', $defaultStorageClass,
            '--volume-size-data', '5Gi',
            '--volume-size-logs', '2Gi',
            '--volume-size-backups', '5Gi',
            '--license-type', 'LicenseIncluded',
            '--no-wait',
            '-o', 'none'
        ) | Out-Null
        Write-Info 'SQL Managed Instance deployment submitted.' Green
        Write-Info 'Lesson learned: use explicit CPU and memory requests so the lab fails early on capacity issues instead of creating mysterious Pending pods.' DarkCyan
    } else {
        Write-Info 'SQL Managed Instance resource already exists. The script will wait for readiness rather than recreate it.' Green
    }

    Write-Step 'Wait for the SQL Managed Instance to become ready and keep the operator informed.' 'This deployment commonly takes 20-30 minutes, so progress messages matter for both patience and troubleshooting.'
    Wait-WithProgress -Activity 'Waiting for SQL Managed Instance' -TotalMinutes 30 -Probe {
        $miText = Invoke-KubectlText -Arguments @('get', 'sqlmi', $SqlManagedInstanceName, '--namespace', $KubeNamespace, '--no-headers') -AllowFailure
        $podText = Invoke-KubectlText -Arguments @('get', 'pods', '--namespace', $KubeNamespace, '--no-headers') -AllowFailure
        $matchingPods = if ($podText.Text) { ($podText.Text -split [Environment]::NewLine | Where-Object { $_ -match $SqlManagedInstanceName }) -join '; ' } else { '' }
        $message = if ($matchingPods) { "SQL MI pods: $matchingPods" } else { 'SQL MI pods are still being created.' }
        if ($miText.ExitCode -eq 0 -and $miText.Text -match 'Ready') {
            [PSCustomObject]@{ Completed = $true; Message = 'SQL Managed Instance is Ready.' }
        } else {
            [PSCustomObject]@{ Completed = $false; Message = $message }
        }
    }

    Write-Step 'Show connection details.' 'A deployment is only useful if you know how to connect to it and validate that the SQL engine is actually serving requests.'
    $services = Invoke-KubectlText -Arguments @('get', 'svc', '--namespace', $KubeNamespace, '--no-headers') -AllowFailure
    if ($services.Text) {
        $connectionLines = $services.Text -split [Environment]::NewLine | Where-Object { $_ -match $SqlManagedInstanceName }
        if ($connectionLines) {
            Write-Info 'Relevant Kubernetes services:' Green
            $connectionLines | ForEach-Object { Write-Host $_ }
        }
    }

    $sqlMiResource = Get-ArmResourceByTypeAndName -Rg $ResourceGroup -ResourceType 'Microsoft.AzureArcData/sqlManagedInstances' -Name $SqlManagedInstanceName
    if ($sqlMiResource) {
        Write-Info "ARM resource id : $($sqlMiResource.id)" Green
    }
    Write-Info "SQL admin login : $SqlAdminUser" Green
    Write-Info 'SQL admin password uses the -NestedAdminPassword value in this lab script for simplicity.' DarkCyan
    Write-Info 'Lesson learned: custom locations should always be discovered dynamically and the azure-arc-aks-hci profile is the right template for AKS on Azure Local.' DarkCyan

    Write-Banner 'Exercise 06 completed'
    Write-Info 'Arc data controller and SQL Managed Instance workflow finished successfully.' Green
} catch {
    Write-Host ''
    Write-Host 'Exercise 06 failed.' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    throw
} finally {
    Stop-ClusterProxy -Process $ProxyProcess
    $env:AZDATA_USERNAME = $OriginalAzDataUser
    $env:AZDATA_PASSWORD = $OriginalAzDataPassword
    $env:WORKSPACE_ID = $OriginalWorkspaceId
    $env:WORKSPACE_SHARED_KEY = $OriginalWorkspaceSharedKey
}
