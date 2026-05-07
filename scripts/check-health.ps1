#####################################################################
# check-health.ps1 - Verify Azure Local lab environment health
#
# Checks the status of all key components:
#   - LocalBox-Client VM (running)
#   - Azure Arc-connected servers (connected)
#   - HCI cluster registration & health
#   - Arc Resource Bridge (running)
#   - Custom Location (available)
#   - Azure Firewall (if deployed)
#   - AKS Arc clusters (if any)
#   - Arc VMs (if any)
#
# Usage:
#   .\scripts\check-health.ps1 -ResourceGroup azlocal
#   .\scripts\check-health.ps1 -ResourceGroup azlocal -Detailed
#####################################################################

param(
    [Parameter(Mandatory)][string]$ResourceGroup,
    [switch]$Detailed
)

$ErrorActionPreference = "Stop"

# ── Counters ──────────────────────────────────────────────────────
$script:passCount = 0
$script:warnCount = 0
$script:failCount = 0

function Write-Check {
    param([string]$Name, [string]$Status, [string]$Detail = "")
    switch ($Status) {
        "pass" {
            Write-Host "  $([char]0x2713) $Name" -ForegroundColor Green
            $script:passCount++
        }
        "warn" {
            Write-Host "  ! $Name" -ForegroundColor Yellow
            $script:warnCount++
        }
        "fail" {
            Write-Host "  X $Name" -ForegroundColor Red
            $script:failCount++
        }
    }
    if ($Detail -and $Detailed) {
        Write-Host "      $Detail" -ForegroundColor DarkGray
    }
}

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " Azure Local Lab - Health Check"
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " Resource Group : $ResourceGroup"
Write-Host " Time           : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""

# ── 1. LocalBox-Client VM ─────────────────────────────────────────
Write-Host "[1/7] LocalBox-Client VM" -ForegroundColor White
$vmName = "LocalBox-Client"
$vmJson = az vm get-instance-view -g $ResourceGroup -n $vmName -o json 2>$null | ConvertFrom-Json
if (-not $vmJson) {
    Write-Check -Name "VM exists" -Status "fail" -Detail "Cannot find $vmName in resource group $ResourceGroup"
} else {
    $vmState = ($vmJson.instanceView.statuses | Where-Object { $_.code -like "PowerState/*" }).displayStatus
    if ($vmState -eq "VM running") {
        Write-Check -Name "VM running" -Status "pass" -Detail "Power state: $vmState"
    } elseif ($vmState -eq "VM deallocated") {
        Write-Check -Name "VM running" -Status "fail" -Detail "VM is stopped/deallocated. Run: .\scripts\start-environment.ps1 -ResourceGroup $ResourceGroup"
    } else {
        Write-Check -Name "VM running" -Status "warn" -Detail "Power state: $vmState"
    }
}
Write-Host ""

# ── 2. Arc-Connected Servers ──────────────────────────────────────
Write-Host "[2/7] Arc-Connected Servers" -ForegroundColor White
$arcServers = az connectedmachine list -g $ResourceGroup -o json 2>$null | ConvertFrom-Json
if (-not $arcServers -or $arcServers.Count -eq 0) {
    Write-Check -Name "Arc servers found" -Status "fail" -Detail "No Arc-connected machines in resource group"
} else {
    $connected = @($arcServers | Where-Object { $_.status -eq "Connected" })
    $disconnected = @($arcServers | Where-Object { $_.status -ne "Connected" })

    Write-Check -Name "Arc servers found: $($arcServers.Count)" -Status "pass"

    foreach ($srv in $arcServers) {
        $name = $srv.name
        $status = $srv.status
        $agentVersion = $srv.agentVersion
        if ($status -eq "Connected") {
            Write-Check -Name "$name - Connected (agent $agentVersion)" -Status "pass"
        } else {
            $lastSeen = if ($srv.lastStatusChange) { $srv.lastStatusChange } else { "unknown" }
            Write-Check -Name "$name - $status (last seen: $lastSeen)" -Status "fail" -Detail "Agent version: $agentVersion"
        }
    }

    if ($disconnected.Count -gt 0) {
        Write-Check -Name "$($disconnected.Count) server(s) disconnected" -Status "warn" -Detail "Check network/firewall connectivity"
    }
}
Write-Host ""

# ── 3. HCI Cluster ───────────────────────────────────────────────
Write-Host "[3/7] Azure Stack HCI Cluster" -ForegroundColor White
$hciClusters = az resource list -g $ResourceGroup --resource-type "Microsoft.AzureStackHCI/clusters" -o json 2>$null | ConvertFrom-Json
if (-not $hciClusters -or $hciClusters.Count -eq 0) {
    Write-Check -Name "HCI cluster" -Status "fail" -Detail "No HCI cluster found in resource group"
} else {
    foreach ($cluster in $hciClusters) {
        $clusterName = $cluster.name
        # Get detailed cluster properties
        $clusterDetail = az resource show --ids $cluster.id -o json 2>$null | ConvertFrom-Json
        $clusterStatus = $clusterDetail.properties.status
        $connectivityStatus = $clusterDetail.properties.connectivityStatus

        if ($connectivityStatus -eq "Connected" -or $clusterStatus -eq "ConnectedRecently") {
            Write-Check -Name "$clusterName - Connected" -Status "pass" -Detail "Status: $clusterStatus"
        } elseif ($connectivityStatus -eq "PartiallyConnected") {
            Write-Check -Name "$clusterName - Partially connected" -Status "warn" -Detail "Status: $clusterStatus"
        } else {
            Write-Check -Name "$clusterName - $connectivityStatus" -Status "fail" -Detail "Status: $clusterStatus"
        }
    }
}
Write-Host ""

# ── 4. Arc Resource Bridge ────────────────────────────────────────
Write-Host "[4/7] Arc Resource Bridge" -ForegroundColor White
$bridges = az resource list -g $ResourceGroup --resource-type "Microsoft.ResourceConnector/appliances" -o json 2>$null | ConvertFrom-Json
if (-not $bridges -or $bridges.Count -eq 0) {
    Write-Check -Name "Resource Bridge" -Status "fail" -Detail "No Arc Resource Bridge found"
} else {
    foreach ($bridge in $bridges) {
        $bridgeDetail = az resource show --ids $bridge.id -o json 2>$null | ConvertFrom-Json
        $bridgeStatus = $bridgeDetail.properties.status
        $bridgeName = $bridge.name

        if ($bridgeStatus -eq "Running") {
            Write-Check -Name "$bridgeName - Running" -Status "pass"
        } elseif ($bridgeStatus -eq "WaitingForHeartbeat" -or $bridgeStatus -eq "Connecting") {
            Write-Check -Name "$bridgeName - $bridgeStatus" -Status "warn" -Detail "Bridge may be starting up or having connectivity issues"
        } else {
            Write-Check -Name "$bridgeName - $bridgeStatus" -Status "fail" -Detail "Bridge is not operational"
        }
    }
}
Write-Host ""

# ── 5. Custom Location ───────────────────────────────────────────
Write-Host "[5/7] Custom Location" -ForegroundColor White
$customLocs = az resource list -g $ResourceGroup --resource-type "Microsoft.ExtendedLocation/customLocations" -o json 2>$null | ConvertFrom-Json
if (-not $customLocs -or $customLocs.Count -eq 0) {
    Write-Check -Name "Custom Location" -Status "fail" -Detail "No custom location found"
} else {
    foreach ($loc in $customLocs) {
        $locDetail = az resource show --ids $loc.id -o json 2>$null | ConvertFrom-Json
        $provState = $locDetail.properties.provisioningState

        if ($provState -eq "Succeeded") {
            Write-Check -Name "$($loc.name) - Ready" -Status "pass" -Detail "Provisioning: $provState"
        } else {
            Write-Check -Name "$($loc.name) - $provState" -Status "warn"
        }
    }
}
Write-Host ""

# ── 6. Azure Firewall (optional) ─────────────────────────────────
Write-Host "[6/7] Azure Firewall (optional)" -ForegroundColor White
# Use az resource list (fast) instead of az network firewall list (very slow, fetches full rule sets)
$fwResources = az resource list -g $ResourceGroup --resource-type "Microsoft.Network/azureFirewalls" -o json 2>$null | ConvertFrom-Json
if (-not $fwResources -or $fwResources.Count -eq 0) {
    Write-Check -Name "Firewall" -Status "warn" -Detail "Not deployed (optional - use deploy-firewall.ps1 to add)"
} else {
    foreach ($fwRes in $fwResources) {
        $fwName = $fwRes.name
        $fwDetail = az resource show --ids $fwRes.id -o json 2>$null | ConvertFrom-Json
        $fwState = $fwDetail.properties.provisioningState
        $fwIpConfigs = $fwDetail.properties.ipConfigurations
        if ($fwState -eq "Succeeded" -and $fwIpConfigs -and $fwIpConfigs.Count -gt 0) {
            $fwIp = $fwIpConfigs[0].properties.privateIPAddress
            if ($fwIp) {
                Write-Check -Name "$fwName - Active (private IP: $fwIp)" -Status "pass"
            } else {
                Write-Check -Name "$fwName - Deallocated (no IP config)" -Status "warn" -Detail "Run start-environment.ps1 to reallocate"
            }

            # Check diagnostic settings
            $diagSettings = az monitor diagnostic-settings list --resource $fwRes.id -o json 2>$null | ConvertFrom-Json
            if ($diagSettings -and $diagSettings.Count -gt 0) {
                Write-Check -Name "  Diagnostic settings configured" -Status "pass"
            } else {
                Write-Check -Name "  Diagnostic settings missing" -Status "warn" -Detail "Logs not flowing. Run monitor-firewall-logs.ps1 -FixDiagnostics"
            }
        } elseif ($fwState -eq "Succeeded") {
            Write-Check -Name "$fwName - Deallocated (no IP config)" -Status "warn" -Detail "Run start-environment.ps1 to reallocate"
        } else {
            Write-Check -Name "$fwName - $fwState" -Status "fail"
        }
    }
}
Write-Host ""

# ── 7. AKS Arc Clusters & VMs (optional) ─────────────────────────
Write-Host "[7/7] Workloads (AKS, VMs)" -ForegroundColor White
$aksFound = $false
$vmsFound = $false

# AKS Arc (provisioned Kubernetes clusters)
$aksClusters = az resource list -g $ResourceGroup --resource-type "Microsoft.Kubernetes/connectedClusters" -o json 2>$null | ConvertFrom-Json
if ($aksClusters -and $aksClusters.Count -gt 0) {
    $aksFound = $true
    foreach ($aks in $aksClusters) {
        $aksDetail = az resource show --ids $aks.id -o json 2>$null | ConvertFrom-Json
        $aksConnectivity = $aksDetail.properties.connectivityStatus
        if ($aksConnectivity -eq "Connected") {
            Write-Check -Name "AKS: $($aks.name) - Connected" -Status "pass"
        } else {
            Write-Check -Name "AKS: $($aks.name) - $aksConnectivity" -Status "warn"
        }
    }
}

# Arc VMs
$arcVMs = az resource list -g $ResourceGroup --resource-type "Microsoft.AzureStackHCI/virtualMachineInstances" -o json 2>$null | ConvertFrom-Json
if ($arcVMs -and $arcVMs.Count -gt 0) {
    $vmsFound = $true
    Write-Check -Name "Arc VMs found: $($arcVMs.Count)" -Status "pass"
}

if (-not $aksFound -and -not $vmsFound) {
    Write-Check -Name "No AKS clusters or Arc VMs deployed" -Status "warn" -Detail "Deploy workloads via exercises 02 (VMs) and 03 (AKS)"
}
Write-Host ""

# ── Summary ───────────────────────────────────────────────────────
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " Summary"
Write-Host "=============================================" -ForegroundColor Cyan
$totalChecks = $script:passCount + $script:warnCount + $script:failCount
Write-Host "  Passed : $($script:passCount)/$totalChecks" -ForegroundColor Green
if ($script:warnCount -gt 0) {
    Write-Host "  Warnings: $($script:warnCount)" -ForegroundColor Yellow
}
if ($script:failCount -gt 0) {
    Write-Host "  Failed : $($script:failCount)" -ForegroundColor Red
}
Write-Host ""

if ($script:failCount -eq 0 -and $script:warnCount -eq 0) {
    Write-Host "  All systems healthy!" -ForegroundColor Green
} elseif ($script:failCount -eq 0) {
    Write-Host "  Environment operational (with warnings)." -ForegroundColor Yellow
} else {
    Write-Host "  Environment has issues. Review failed checks above." -ForegroundColor Red
}
Write-Host ""
