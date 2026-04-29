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
    [ValidateSet("status", "retry")][string]$Action = "status"
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
if ($azcopyVer) { Write-Output "azcopy: OK ($azcopyVer)" } else { Write-Output "azcopy: MISSING - setup will fail without it" }

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
