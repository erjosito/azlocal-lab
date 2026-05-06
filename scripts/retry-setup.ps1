#####################################################################
# retry-setup.ps1 — Check and retry the LocalBox internal setup
#
# The LocalBox-Client VM runs an automated setup after deployment that
# takes 4-5 hours. If it fails (e.g., due to timing issues with storage
# pools or network connectivity), this script can:
#   1. Diagnose the current state
#   2. Re-launch the setup script inside the VM
#
# Common failure: AzL-node.vhdx download fails because the storage pool
# wasn't ready when the logon script first ran after Hyper-V reboot.
#####################################################################

param(
    [Parameter(Mandatory)][string]$ResourceGroup,
    [ValidateSet("status", "retry", "progress")][string]$Action = "status"
)

$ErrorActionPreference = "Stop"
$vmName = "LocalBox-Client"

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " LocalBox Setup Troubleshooting"
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""

# ── Check VM is running ───────────────────────────────────────────
Write-Host "Checking VM power state..."
$vmJson = az vm get-instance-view -g $ResourceGroup -n $vmName -o json 2>$null | ConvertFrom-Json
$vmState = ($vmJson.instanceView.statuses | Where-Object { $_.code -like "PowerState/*" }).displayStatus

if ($vmState -ne "VM running") {
    Write-Host "ERROR: VM is not running (state: $vmState)" -ForegroundColor Red
    Write-Host "Start it with: .\scripts\start-environment.ps1 -ResourceGroup $ResourceGroup"
    exit 1
}
Write-Host "  $(([char]0x2713)) VM is running" -ForegroundColor Green
Write-Host ""

# ── Run diagnostics inside the VM ─────────────────────────────────
Write-Host "Running diagnostics inside the VM (this takes ~30 seconds)..."
Write-Host ""

# Write diagnostic script to temp file (az vm run-command doesn't handle
# inline multi-line scripts with $ variables reliably on Windows)
$diagTempFile = Join-Path ([System.IO.Path]::GetTempPath()) "localbox-diag-$(Get-Random).ps1"
@'
$azcopyVer = try { azcopy --version 2>$null } catch { $null }
if ($azcopyVer) { Write-Output "azcopy: OK ($azcopyVer)" } else { Write-Output "azcopy: Not installed (OK for AzLocal2604+ images which ship VHDs pre-baked)" }

$pool = Get-StoragePool -FriendlyName AzLocalPool -ErrorAction SilentlyContinue
if ($pool) { Write-Output "StoragePool: $($pool.OperationalStatus) ($($pool.HealthStatus))" } else { Write-Output "StoragePool: NOT FOUND" }

if (Test-Path V:\) {
    $vUsed = [math]::Round((Get-PSDrive V).Used/1GB,1)
    Write-Output "VDrive: OK ($vUsed GB used)"
} else { Write-Output "VDrive: NOT FOUND" }

if (Test-Path C:\LocalBox\VHD\GUI.vhdx) {
    $guiSize = [math]::Round((Get-Item C:\LocalBox\VHD\GUI.vhdx).Length/1GB,1)
    Write-Output "GUI.vhdx: OK ($guiSize GB)"
} else { Write-Output "GUI.vhdx: MISSING" }

if (Test-Path C:\LocalBox\VHD\AzL-node.vhdx) {
    $azlSize = [math]::Round((Get-Item C:\LocalBox\VHD\AzL-node.vhdx).Length/1GB,1)
    Write-Output "AzL-node.vhdx: OK ($azlSize GB)"
} else { Write-Output "AzL-node.vhdx: MISSING" }

$vms = Get-VM -ErrorAction SilentlyContinue
if ($vms) {
    Write-Output "Hyper-V VMs: $(($vms | ForEach-Object { "$($_.Name):$($_.State)" }) -join ', ')"
} else { Write-Output "Hyper-V VMs: NONE" }

$ps = Get-Process powershell -ErrorAction SilentlyContinue
Write-Output "PowerShell processes: $($ps.Count) running"

$logFile = "C:\LocalBox\Logs\New-LocalBoxCluster.log"
if (Test-Path $logFile) {
    Write-Output "Cluster log: Last updated $(( Get-Item $logFile).LastWriteTime)"
} else { Write-Output "Cluster log: No log file" }

$logonLog = "C:\LocalBox\Logs\LocalBoxLogonScript.log"
if (Test-Path $logonLog) {
    Write-Output "Logon script log: Last updated $((Get-Item $logonLog).LastWriteTime)"
} else { Write-Output "Logon script log: No log file" }

Write-Output ""
$azlMissing = -not (Test-Path C:\LocalBox\VHD\AzL-node.vhdx)
$vmCount = if ($vms) { $vms.Count } else { 0 }
$psCount = if ($ps) { $ps.Count } else { 0 }

if ($azlMissing -and $psCount -le 2) {
    Write-Output "DIAGNOSIS: AzL-node.vhdx is missing. The download failed or was never started."
    Write-Output "ACTION: Run with -Action retry to re-launch the setup script."
} elseif ($azlMissing -and $psCount -gt 2) {
    Write-Output "DIAGNOSIS: AzL-node.vhdx is missing but setup appears to be running (downloading?)."
    Write-Output "ACTION: Wait and check again in 15-20 minutes."
} elseif ($vmCount -ge 3) {
    Write-Output "DIAGNOSIS: Setup appears to be progressing ($vmCount VMs exist)."
    Write-Output "ACTION: Wait for completion. Check Arc-enabled servers in the portal."
} elseif ($psCount -gt 2) {
    Write-Output "DIAGNOSIS: Setup script appears to be running ($psCount PowerShell processes)."
    Write-Output "ACTION: Wait for completion (4-5 hours total)."
} else {
    Write-Output "DIAGNOSIS: Setup may have completed or stalled. Check logs in the VM."
}
'@ | Set-Content $diagTempFile -Encoding UTF8

try {
    $resultJson = az vm run-command invoke -g $ResourceGroup -n $vmName `
        --command-id RunPowerShellScript `
        --scripts "@$diagTempFile" `
        -o json 2>$null | Out-String | ConvertFrom-Json

    $stdOut = $resultJson.value | Where-Object { $_.code -like "*StdOut*" } | Select-Object -ExpandProperty message
    $stdErr = $resultJson.value | Where-Object { $_.code -like "*StdErr*" } | Select-Object -ExpandProperty message

    if ($stdOut) {
        Write-Host $stdOut
    } elseif ($stdErr) {
        Write-Host "Script encountered errors:" -ForegroundColor Yellow
        Write-Host $stdErr
    } else {
        Write-Host "No output from diagnostics. The VM may still be starting up." -ForegroundColor Yellow
    }
} finally {
    Remove-Item $diagTempFile -ErrorAction SilentlyContinue
}
Write-Host ""

# ── Progress if requested ─────────────────────────────────────────
if ($Action -eq "progress") {
    Write-Host "--- Setup Progress ---" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Reading log files inside the VM..."
    Write-Host ""

    $progressFile = Join-Path ([System.IO.Path]::GetTempPath()) "localbox-progress-$(Get-Random).ps1"
    @'
# Known milestones in order of execution
$milestones = @(
    @{ Pattern = "Installing Hyper-V";              Label = "Phase 1: Hyper-V installation" }
    @{ Pattern = "Configuring Windows Defender";    Label = "Phase 1: Defender exclusions" }
    @{ Pattern = "Configuring storage";             Label = "Phase 2: Storage pool setup" }
    @{ Pattern = "Step 1/11.*Downloading";          Label = "Phase 2: Step  1/11 - Downloading VHDs (~20 GB)" }
    @{ Pattern = "Step 2/11.*Preparing";            Label = "Phase 2: Step  2/11 - Preparing virtualization host" }
    @{ Pattern = "Step 3/11.*Management VM";        Label = "Phase 2: Step  3/11 - Creating management VM (AzLMGMT)" }
    @{ Pattern = "Step 4/11.*node VMs";             Label = "Phase 2: Step  4/11 - Creating Azure Local node VMs" }
    @{ Pattern = "Step 5/11.*Starting VMs";         Label = "Phase 2: Step  5/11 - Starting VMs" }
    @{ Pattern = "Step 6/11.*networking";           Label = "Phase 2: Step  6/11 - Host networking and storage" }
    @{ Pattern = "Step 7/11.*router";               Label = "Phase 2: Step  7/11 - Building router VM" }
    @{ Pattern = "Step 8/11.*Domain Controller";    Label = "Phase 2: Step  8/11 - Building Domain Controller VM" }
    @{ Pattern = "Step 9/11.*cloud deployment";     Label = "Phase 2: Step  9/11 - Preparing cluster cloud deployment" }
    @{ Pattern = "Step 10/11.*Validate";            Label = "Phase 2: Step 10/11 - Validating cluster deployment" }
    @{ Pattern = "Step 11/11.*cluster deployment";  Label = "Phase 2: Step 11/11 - Running cluster deployment" }
    @{ Pattern = "Upgrading Local cluster";         Label = "Phase 2: Upgrading cluster" }
    @{ Pattern = "Successfully deployed";           Label = "COMPLETE: Infrastructure deployed" }
    @{ Pattern = "Running tests to verify";         Label = "Phase 3: Running verification tests" }
    @{ Pattern = "Creating deployment logs bundle"; Label = "Phase 3: Creating logs bundle" }
    @{ Pattern = "Removing Logon Task";             Label = "Phase 3: Cleanup - Removing logon task" }
    @{ Pattern = "Changing wallpaper";              Label = "Phase 3: Finalizing desktop" }
)

# Collect all log content
$allLogs = @()
$logFiles = @(
    "C:\LocalBox\Logs\Bootstrap.log",
    "C:\LocalBox\Logs\LocalBoxLogonScript.log",
    "C:\LocalBox\Logs\New-LocalBoxCluster.log"
)
foreach ($lf in $logFiles) {
    if (Test-Path $lf) { $allLogs += Get-Content $lf }
}

# Find which milestones have been reached
$lastReached = -1
$results = @()
for ($i = 0; $i -lt $milestones.Count; $i++) {
    $m = $milestones[$i]
    $found = $allLogs | Where-Object { $_ -match $m.Pattern } | Select-Object -Last 1
    if ($found) {
        $results += "[X] $($m.Label)"
        $lastReached = $i
    } else {
        $results += "[ ] $($m.Label)"
    }
}

# Output milestones
Write-Output "=== Milestone Checklist ==="
foreach ($r in $results) { Write-Output $r }

# Show what's currently happening
Write-Output ""
if ($lastReached -ge 0 -and $lastReached -lt ($milestones.Count - 1)) {
    $next = $milestones[$lastReached + 1]
    Write-Output "CURRENT: Likely working on '$($next.Label)' (or failed before reaching it)"
} elseif ($lastReached -eq ($milestones.Count - 1)) {
    Write-Output "STATUS: All milestones reached - setup appears complete!"
} else {
    Write-Output "STATUS: No milestones reached yet. Setup may not have started."
}

# Check for errors in the last 30 lines of the most recent log
Write-Output ""
Write-Output "=== Recent Log Activity ==="
$recentLog = $null
$recentLogName = $null
$latestWrite = [DateTime]::MinValue
foreach ($lf in $logFiles) {
    if (Test-Path $lf) {
        $item = Get-Item $lf
        if ($item.LastWriteTime -gt $latestWrite) {
            $latestWrite = $item.LastWriteTime
            $recentLog = $lf
            $recentLogName = $item.Name
        }
    }
}
if ($recentLog) {
    Write-Output "Most recent: $recentLogName (updated $latestWrite)"
    Write-Output "--- Last 20 lines ---"
    Get-Content $recentLog -Tail 20 | ForEach-Object { Write-Output $_ }
}

# Check for error patterns (filter out stack trace noise like CategoryInfo, FullyQualifiedErrorId)
Write-Output ""
Write-Output "=== Errors Found ==="
$errors = $allLogs | Where-Object {
    ($_ -match 'Write-Error|TerminatingError|Aborting|source VHDX not found') -and
    ($_ -notmatch 'ErrorAction|ErrorVariable|SilentlyContinue|CategoryInfo|FullyQualifiedErrorId|^\s*\+')
} | Select-Object -Last 10

# Known cosmetic errors that can be safely ignored
$cosmeticPatterns = @(
    @{ Pattern = "TerminatingError\(New-StoragePool\).*PhysicalDisks.*null or empty"; Label = "COSMETIC: StoragePool retries until disks appear (normal on first boot)" }
    @{ Pattern = "TerminatingError\(Get-ClusterResource\).*not found";               Label = "COSMETIC: Cluster resource queried before creation (timing)" }
    @{ Pattern = "TerminatingError\(Get-VM\).*Hyper-V.*not enabled";                 Label = "COSMETIC: Hyper-V queried before feature install completes" }
    @{ Pattern = "TerminatingError\(Resolve-DnsName\)";                              Label = "COSMETIC: DNS resolution fails during early network setup" }
    @{ Pattern = "WARNING.*Az\.Accounts.*already loaded";                            Label = "COSMETIC: PowerShell module version conflict (harmless)" }
)

if ($errors) {
    foreach ($e in $errors) {
        $isCosmetic = $false
        foreach ($cp in $cosmeticPatterns) {
            if ($e -match $cp.Pattern) {
                Write-Output "[OK] $($cp.Label)"
                $isCosmetic = $true
                break
            }
        }
        if (-not $isCosmetic) {
            Write-Output "[!!] $e"
        }
    }
} else {
    Write-Output "(none)"
}
'@ | Set-Content -Path $progressFile -Encoding UTF8

    try {
        $progressResult = az vm run-command invoke -g $ResourceGroup -n $vmName `
            --command-id RunPowerShellScript `
            --scripts "@$progressFile" `
            -o json 2>$null | Out-String | ConvertFrom-Json

        $stdOut = $progressResult.value | Where-Object { $_.code -like "*StdOut*" } | Select-Object -ExpandProperty message
        $stdErr = $progressResult.value | Where-Object { $_.code -like "*StdErr*" } | Select-Object -ExpandProperty message

        if ($stdOut) {
            $stdOut -split "`n" | ForEach-Object {
                $line = $_.Trim()
                if ($line -match '^\[X\]') {
                    Write-Host $line -ForegroundColor Green
                } elseif ($line -match '^\[ \]') {
                    Write-Host $line -ForegroundColor DarkGray
                } elseif ($line -match '^CURRENT:|^STATUS:') {
                    Write-Host $line -ForegroundColor Yellow
                } elseif ($line -match '^===') {
                    Write-Host $line -ForegroundColor Cyan
                } elseif ($line -match '^\[OK\]') {
                    Write-Host $line -ForegroundColor DarkGray
                } elseif ($line -match '^\[!!\]|Write-Error|TerminatingError|FAILED|Aborting|source VHDX not found') {
                    Write-Host $line -ForegroundColor Red
                } else {
                    Write-Host $line
                }
            }
        }
        if ($stdErr) {
            Write-Host ""
            Write-Host "Script warnings:" -ForegroundColor Yellow
            Write-Host $stdErr
        }
    } finally {
        Remove-Item $progressFile -ErrorAction SilentlyContinue
    }

    # ── Azure resource status checks ──────────────────────────────
    Write-Host ""
    Write-Host "=== Azure Resource Status ===" -ForegroundColor Cyan
    Write-Host ""

    # Arc-enabled servers
    $arcServers = az connectedmachine list -g $ResourceGroup --query "[].{name:name, status:status, agentVersion:agentVersion}" -o json 2>$null | ConvertFrom-Json
    if ($arcServers -and $arcServers.Count -gt 0) {
        Write-Host "Arc-enabled servers:" -ForegroundColor White
        foreach ($s in $arcServers) {
            $color = if ($s.status -eq "Connected") { "Green" } else { "Yellow" }
            Write-Host "  $($s.name): $($s.status) (agent v$($s.agentVersion))" -ForegroundColor $color
        }
    } else {
        Write-Host "Arc-enabled servers: None registered yet" -ForegroundColor DarkGray
    }

    # Azure Local cluster
    $cluster = az stack-hci cluster list -g $ResourceGroup --query "[0].{name:name, status:status}" -o json 2>$null | ConvertFrom-Json
    if ($cluster -and $cluster.name) {
        $color = switch ($cluster.status) {
            "ConnectedRecently" { "Green" }
            "DeploymentInProgress" { "Yellow" }
            default { "Red" }
        }
        Write-Host "Azure Local cluster: $($cluster.name) — $($cluster.status)" -ForegroundColor $color
    } else {
        Write-Host "Azure Local cluster: Not yet created" -ForegroundColor DarkGray
    }

    # Custom location
    $customLoc = az customlocation list -g $ResourceGroup --query "[0].{name:name, provisioningState:provisioningState}" -o json 2>$null | ConvertFrom-Json
    if ($customLoc -and $customLoc.name) {
        $color = if ($customLoc.provisioningState -eq "Succeeded") { "Green" } else { "Yellow" }
        Write-Host "Custom location: $($customLoc.name) — $($customLoc.provisioningState)" -ForegroundColor $color
    } else {
        Write-Host "Custom location: Not yet created" -ForegroundColor DarkGray
    }

    # Connected Kubernetes clusters (deployed via exercises, not part of base setup)
    $k8s = az connectedk8s list -g $ResourceGroup --query "[].{name:name, connectivityStatus:connectivityStatus}" -o json 2>$null | ConvertFrom-Json
    if ($k8s -and $k8s.Count -gt 0) {
        Write-Host "Connected Kubernetes:" -ForegroundColor White
        foreach ($c in $k8s) {
            $color = if ($c.connectivityStatus -eq "Connected") { "Green" } else { "Yellow" }
            Write-Host "  $($c.name): $($c.connectivityStatus)" -ForegroundColor $color
        }
    }

    # Arc Gateway (if deployed)
    $gw = az rest --method get --url "/subscriptions/{subscriptionId}/resourceGroups/$ResourceGroup/providers/Microsoft.HybridCompute/gateways?api-version=2024-03-31-preview" --query "value[0].{name:name, state:properties.gatewayType}" -o json 2>$null | ConvertFrom-Json
    if ($gw -and $gw.name) {
        Write-Host "Arc Gateway: $($gw.name) — deployed" -ForegroundColor Green
    }

    # Azure Firewall (if deployed)
    $fw = az network firewall list -g $ResourceGroup --query "[0].{name:name, provisioningState:provisioningState}" -o json 2>$null | ConvertFrom-Json
    if ($fw -and $fw.name) {
        $color = if ($fw.provisioningState -eq "Succeeded") { "Green" } else { "Yellow" }
        Write-Host "Azure Firewall: $($fw.name) — $($fw.provisioningState)" -ForegroundColor $color

        # Public IP and DNAT
        $fwPip = az network public-ip show -g $ResourceGroup -n "$($fw.name)-pip" --query "ipAddress" -o tsv 2>$null
        if ($fwPip) {
            Write-Host "  Public IP: $fwPip" -ForegroundColor White
        }
        $natRcg = az network firewall policy rule-collection-group show -g $ResourceGroup `
            --policy-name "$($fw.name)-Policy" -n "LocalBox-NAT-RCG" --query "id" -o tsv 2>$null
        if ($natRcg) {
            Write-Host "  DNAT rule (RDP): Configured" -ForegroundColor Green
        } else {
            Write-Host "  DNAT rule (RDP): Not configured" -ForegroundColor DarkGray
        }

        # Route table on workload subnet
        $subnetRt = az network vnet subnet show -g $ResourceGroup --vnet-name "LocalBox-VNet" `
            -n "LocalBox-Subnet" --query "routeTable.id" -o tsv 2>$null
        if ($subnetRt) {
            Write-Host "  Route table on LocalBox-Subnet: Yes (traffic via firewall)" -ForegroundColor Green
        } else {
            Write-Host "  Route table on LocalBox-Subnet: No (direct egress)" -ForegroundColor Yellow
        }
    }

    Write-Host ""
    exit 0
}

# ── Retry if requested ────────────────────────────────────────────
if ($Action -eq "retry") {
    Write-Host "--- Pre-flight checks ---" -ForegroundColor Cyan
    Write-Host ""

    # Check azcopy is installed (common cause of silent download failures)
    Write-Host "  Checking azcopy installation inside the VM..."
    $azcopyCheckFile = Join-Path ([System.IO.Path]::GetTempPath()) "localbox-azcopy-check-$(Get-Random).ps1"
    @'
if (Get-Command azcopy -ErrorAction SilentlyContinue) {
    Write-Output "INSTALLED: $(azcopy --version)"
} else {
    Write-Output "MISSING"
}
'@ | Set-Content -Path $azcopyCheckFile -Encoding UTF8

    $azcopyCheck = az vm run-command invoke -g $ResourceGroup -n $vmName `
        --command-id RunPowerShellScript `
        --scripts "@$azcopyCheckFile" `
        -o json 2>$null | Out-String | ConvertFrom-Json
    Remove-Item $azcopyCheckFile -ErrorAction SilentlyContinue
    $azcopyStatus = $azcopyCheck.value | Where-Object { $_.code -like "*StdOut*" } | Select-Object -ExpandProperty message

    if ($azcopyStatus -like "MISSING*") {
        Write-Host "  azcopy is NOT installed. Installing it now..." -ForegroundColor Yellow
        $installFile = Join-Path ([System.IO.Path]::GetTempPath()) "localbox-azcopy-install-$(Get-Random).ps1"
        @'
Invoke-WebRequest -Uri "https://aka.ms/downloadazcopy-v10-windows" -OutFile C:\Temp\azcopy.zip
Expand-Archive C:\Temp\azcopy.zip -DestinationPath C:\Temp\azcopy -Force
$exe = Get-ChildItem C:\Temp\azcopy -Recurse -Filter azcopy.exe | Select-Object -First 1
Copy-Item $exe.FullName C:\Windows\System32\azcopy.exe -Force
Write-Output "OK: $(azcopy --version)"
'@ | Set-Content -Path $installFile -Encoding UTF8

        $installResult = az vm run-command invoke -g $ResourceGroup -n $vmName `
            --command-id RunPowerShellScript `
            --scripts "@$installFile" `
            -o json 2>$null | Out-String | ConvertFrom-Json
        Remove-Item $installFile -ErrorAction SilentlyContinue
        $installOut = $installResult.value | Where-Object { $_.code -like "*StdOut*" } | Select-Object -ExpandProperty message
        if ($installOut -like "OK:*") {
            Write-Host "  $(([char]0x2713)) $installOut" -ForegroundColor Green
        } else {
            $installErr = $installResult.value | Where-Object { $_.code -like "*StdErr*" } | Select-Object -ExpandProperty message
            Write-Host "  ERROR: Failed to install azcopy." -ForegroundColor Red
            if ($installErr) { Write-Host "  $installErr" -ForegroundColor Red }
            Write-Host "  The setup script will fail without azcopy. Install it manually inside the VM."
            exit 1
        }
    } else {
        Write-Host "  $(([char]0x2713)) $($azcopyStatus.Trim())" -ForegroundColor Green
    }

    Write-Host ""
    Write-Host "--- Re-launching setup script ---" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "This will restart C:\LocalBox\LocalBoxLogonScript.ps1 inside the VM."
    Write-Host "The script is idempotent - it will skip steps already completed."
    Write-Host ""

    $confirm = Read-Host "Proceed? [Y/n]"
    if ([string]::IsNullOrWhiteSpace($confirm)) { $confirm = "Y" }
    if ($confirm -notmatch '^[Yy]') {
        Write-Host "Cancelled."
        exit 0
    }

    $retryJson = az vm run-command invoke -g $ResourceGroup -n $vmName `
        --command-id RunPowerShellScript `
        --scripts "Start-Process powershell -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File C:\LocalBox\LocalBoxLogonScript.ps1' -WindowStyle Normal; Write-Output 'Setup script re-launched successfully'" `
        -o json 2>$null | Out-String | ConvertFrom-Json

    $retryOutput = $retryJson.value | Where-Object { $_.code -like "*StdOut*" } | Select-Object -ExpandProperty message
    Write-Host $retryOutput -ForegroundColor Green
    Write-Host ""
    Write-Host "The setup will take 4-5 hours to complete."
    Write-Host "Re-run this script with -Action status to check progress."
}
