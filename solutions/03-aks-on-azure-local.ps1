param(
    [Parameter(Mandatory)]
    [string]$ResourceGroup,

    [string]$NestedAdminPassword = 'Microsoft123!'
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Common.AzureLocalLab.ps1"

$proxyProcess = $null
$kubeConfigPath = Join-Path $PSScriptRoot 'localbox-aks.kubeconfig'
$proxyOutLog = Join-Path $PSScriptRoot '03-aks-proxy.stdout.log'
$proxyErrLog = Join-Path $PSScriptRoot '03-aks-proxy.stderr.log'
$metallbConfigPath = Join-Path $PSScriptRoot '03-metallb-config.generated.yaml'
$nginxManifestPath = Join-Path $PSScriptRoot '03-nginx.generated.yaml'

function Get-LogicalNetwork {
    param(
        [string]$ResourceGroup,
        [string]$PreferredName,
        [string]$AddressPrefix
    )

    $logicalNetworks = @(Invoke-AzJson -Arguments @('stack-hci-vm', 'network', 'lnet', 'list', '--resource-group', $ResourceGroup))
    return $logicalNetworks | Where-Object {
        $_.name -eq $PreferredName -or
        (($_ | ConvertTo-Json -Depth 20) -match [regex]::Escape($AddressPrefix))
    } | Select-Object -First 1
}

function Invoke-KubectlText {
    param(
        [string[]]$Arguments,
        [switch]$AllowFailure
    )

    Assert-Command -Name 'kubectl' -InstallHint 'Install kubectl (for example with az aks install-cli) before running Exercise 03.'
    $output = & kubectl --kubeconfig $kubeConfigPath @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($output | ForEach-Object { "$_" }) -join "`n"

    if ($exitCode -ne 0) {
        if ($AllowFailure) {
            return $null
        }

        throw "kubectl $($Arguments -join ' ') failed.`n$text"
    }

    return $text.Trim()
}

try {
    Write-Banner 'Exercise 03 - AKS on Azure Local'
    Write-Step -What 'Preparing Azure Local, AKS Arc, and connected Kubernetes CLI extensions.' -Why 'AKS on Azure Local uses multiple Arc-aware APIs, so the script ensures the right CLI surface is present first.'
    Ensure-AzExtension -Name 'customlocation' | Out-Null
    Ensure-AzExtension -Name 'stack-hci-vm' | Out-Null
    Ensure-AzExtension -Name 'aksarc' | Out-Null
    Ensure-AzExtension -Name 'connectedk8s' | Out-Null

    $context = Get-AzureLocalContext -ResourceGroup $ResourceGroup
    if (-not $context.CustomLocation) {
        throw 'No custom location was found. AKS Arc needs a custom location that points at the Azure Local cluster.'
    }

    $aksNetworkName = 'aks-network'
    $aksClusterName = 'localbox-aks'
    $location = $context.Location
    $customLocationId = $context.CustomLocation.id

    Write-Step -What 'Checking whether the AKS logical network already exists.' -Why 'AKS nodes need a dedicated workload network that is separate from the VM network used in Exercise 02.'
    $aksNetwork = Get-LogicalNetwork -ResourceGroup $ResourceGroup -PreferredName $aksNetworkName -AddressPrefix '10.10.0.0/24'
    if (-not $aksNetwork) {
        Write-Info 'Creating AKS workload network 10.10.0.0/24 on VLAN 110.'
        $null = Invoke-AzJson -Arguments @(
            'stack-hci-vm', 'network', 'lnet', 'create',
            '--resource-group', $ResourceGroup,
            '--name', $aksNetworkName,
            '--location', $location,
            '--custom-location', $customLocationId,
            '--vm-switch-name', 'ConvergedSwitch(oob-hci)',
            '--address-prefixes', '10.10.0.0/24',
            '--gateway', '10.10.0.1',
            '--dns-servers', '192.168.1.254',
            '--ip-allocation-method', 'Static',
            '--ip-pool-type', 'vm',
            '--ip-pool-start', '10.10.0.10',
            '--ip-pool-end', '10.10.0.200',
            '--vlan', '110'
        )
        $aksNetwork = Get-LogicalNetwork -ResourceGroup $ResourceGroup -PreferredName $aksNetworkName -AddressPrefix '10.10.0.0/24'
        Write-Success "Logical network '$aksNetworkName' created."
    }
    else {
        Write-Success "Logical network '$($aksNetwork.name)' already exists and will be reused."
    }

    Write-Step -What 'Checking whether the AKS cluster already exists.' -Why 'AKS cluster creation is long running, so reruns should reuse a healthy cluster instead of rebuilding it.'
    $connectedCluster = Invoke-AzJson -Arguments @('connectedk8s', 'show', '--resource-group', $ResourceGroup, '--name', $aksClusterName) -AllowNotFound
    if (-not $connectedCluster) {
        Write-Info 'Creating AKS Arc cluster with a small lab-friendly footprint.'
        $null = Invoke-AzJson -Arguments @(
            'aksarc', 'create',
            '--resource-group', $ResourceGroup,
            '--name', $aksClusterName,
            '--location', $location,
            '--custom-location', $customLocationId,
            '--vnet-id', $aksNetwork.id,
            '--node-count', '2',
            '--control-plane-count', '1',
            '--node-vm-size', 'Standard_A4_v2',
            '--control-plane-vm-size', 'Standard_A4_v2',
            '--generate-ssh-keys'
        )
    }
    else {
        Write-Success "AKS cluster '$aksClusterName' already exists and will be reused."
    }

    Write-Step -What 'Waiting for the Arc-connected Kubernetes resource to become available.' -Why 'The connected resource is what Azure CLI and Azure Arc use for proxy access, extensions, and governance.'
    $connectedCluster = Wait-Until -Description 'AKS Arc connected cluster registration' -TimeoutSeconds 1800 -PollSeconds 20 -Condition {
        try {
            $cluster = Invoke-AzJson -Arguments @('connectedk8s', 'show', '--resource-group', $ResourceGroup, '--name', $aksClusterName) -AllowNotFound
            if ($cluster) { return $cluster }
        }
        catch {
            return $null
        }
    }
    Write-Success "Connected cluster '$aksClusterName' is visible in Azure."

    Write-Step -What 'Demonstrating nested host access with jumpstart\Administrator before proxy-based Kubernetes access.' -Why 'This reinforces that infrastructure administration still uses the local jumpstart domain even when the cluster is managed from Azure.'
    try {
        $hostnameResult = Invoke-NestedHostCommand -ResourceGroup $ResourceGroup -ComputerName 'AzLHOST1' -Password $NestedAdminPassword -ScriptText 'hostname'
        if ($hostnameResult) {
            Write-Success "Nested credential check succeeded against AzLHOST1: $($hostnameResult.Trim())"
        }
    }
    catch {
        Write-Warn "Nested credential verification was skipped: $($_.Exception.Message)"
    }

    Write-Step -What 'Starting az connectedk8s proxy.' -Why 'AKS on Azure Local is reached through Azure Arc, so kubectl traffic is tunneled without requiring direct routing from your machine to 10.10.0.0/24.'
    Remove-Item $kubeConfigPath, $proxyOutLog, $proxyErrLog -ErrorAction SilentlyContinue
    $azExecutable = (Get-Command az).Source
    $proxyProcess = Start-Process -FilePath $azExecutable -ArgumentList @('connectedk8s', 'proxy', '--name', $aksClusterName, '--resource-group', $ResourceGroup, '--file', $kubeConfigPath, '--port', '47011', '--only-show-errors') -PassThru -WindowStyle Hidden -RedirectStandardOutput $proxyOutLog -RedirectStandardError $proxyErrLog

    Wait-Until -Description 'kubeconfig generated by connectedk8s proxy' -TimeoutSeconds 180 -PollSeconds 5 -Condition {
        if (Test-Path $kubeConfigPath) { return $true }
    } | Out-Null

    Wait-Until -Description 'successful kubectl access through the Arc proxy' -TimeoutSeconds 240 -PollSeconds 10 -Condition {
        try {
            $nodes = Invoke-KubectlText -Arguments @('get', 'nodes') -AllowFailure
            if ($nodes) { return $nodes }
        }
        catch {
            return $null
        }
    } | Out-Null
    Write-Success 'kubectl can now reach the cluster through the Arc proxy.'

    Write-Step -What 'Installing MetalLB if it is not already present.' -Why 'On-prem Kubernetes does not get a cloud load balancer automatically, so MetalLB provides the LoadBalancer experience locally.'
    $metallbNamespace = Invoke-KubectlText -Arguments @('get', 'namespace', 'metallb-system', '-o', 'name') -AllowFailure
    if (-not $metallbNamespace) {
        $null = Invoke-KubectlText -Arguments @('apply', '-f', 'https://raw.githubusercontent.com/metallb/metallb/v0.14.9/config/manifests/metallb-native.yaml')
        $null = Invoke-KubectlText -Arguments @('wait', '--namespace', 'metallb-system', '--for=condition=ready', 'pod', '--selector=app=metallb', '--timeout=180s')
        Write-Success 'MetalLB was installed and its core pods are ready.'
    }
    else {
        Write-Success 'MetalLB is already installed.'
    }

    Write-Step -What 'Configuring MetalLB with an address pool from the AKS VLAN.' -Why 'LoadBalancer services need a pool of real IP addresses that belong to the AKS network segment.'
    @"
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: aks-pool
  namespace: metallb-system
spec:
  addresses:
  - 10.10.0.100-10.10.0.120
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: aks-l2
  namespace: metallb-system
spec: {}
"@ | Set-Content -Path $metallbConfigPath -Encoding UTF8
    $null = Invoke-KubectlText -Arguments @('apply', '-f', $metallbConfigPath)
    Write-Success 'MetalLB IP pool and advertisement are configured.'

    Write-Step -What 'Deploying a sample nginx application with a LoadBalancer service.' -Why 'This proves the full chain: Azure-managed AKS lifecycle, local networking, and on-prem load balancer functionality.'
    @"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx
spec:
  replicas: 2
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
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
  name: nginx
spec:
  selector:
    app: nginx
  type: LoadBalancer
  ports:
  - port: 80
    targetPort: 80
"@ | Set-Content -Path $nginxManifestPath -Encoding UTF8
    $null = Invoke-KubectlText -Arguments @('apply', '-f', $nginxManifestPath)
    Write-Success 'nginx deployment and service are applied.'

    Write-Step -What 'Waiting for the service to obtain an external IP from MetalLB.' -Why 'A LoadBalancer service is only useful once MetalLB has assigned and advertised a reachable address.'
    $externalIp = Wait-Until -Description 'MetalLB external IP assignment for nginx' -TimeoutSeconds 300 -PollSeconds 10 -Condition {
        $ip = Invoke-KubectlText -Arguments @('get', 'service', 'nginx', '-o', 'jsonpath={.status.loadBalancer.ingress[0].ip}') -AllowFailure
        if ($ip) { return $ip }
    }
    Write-Success "nginx received external IP $externalIp."

    Write-Step -What 'Verifying the app from inside LocalBox-Client.' -Why 'The LoadBalancer IP is on the nested AKS network, so the cleanest verification path is from inside the emulated datacenter.'
    $webResult = Invoke-LocalBoxCommand -ResourceGroup $ResourceGroup -ScriptText "(Invoke-WebRequest -UseBasicParsing -Uri 'http://$externalIp' -TimeoutSec 20).StatusCode"
    if ($webResult -match '200') {
        Write-Success "LocalBox-Client reached http://$externalIp successfully (HTTP 200)."
    }
    else {
        Write-Warn "The HTTP validation did not return 200. Output: $webResult"
    }

    Write-Step -What 'Showing cluster nodes and service state for final confirmation.' -Why 'Students should finish by correlating Azure success with Kubernetes objects running inside the cluster.'
    Write-Host (Invoke-KubectlText -Arguments @('get', 'nodes', '-o', 'wide')) -ForegroundColor Green
    Write-Host (Invoke-KubectlText -Arguments @('get', 'service', 'nginx', '-o', 'wide')) -ForegroundColor Green

    Write-Banner 'AKS on Azure Local automation completed'
}
catch {
    Write-Fail $_.Exception.Message
    exit 1
}
finally {
    if ($proxyProcess -and -not $proxyProcess.HasExited) {
        Stop-Process -Id $proxyProcess.Id -Force -ErrorAction SilentlyContinue
    }

    Remove-Item $metallbConfigPath, $nginxManifestPath -ErrorAction SilentlyContinue
}
