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
$vmState = az vm get-instance-view -g $ResourceGroup -n $vmName `
    --query "instanceView.statuses[?starts_with(code,'PowerState/')].displayStatus" -o tsv 2>$null

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

$diagScript = @'
$status = @{}

# Check storage pool
$pool = Get-StoragePool -FriendlyName AzLocalPool -ErrorAction SilentlyContinue
$status["StoragePool"] = if ($pool) { "$($pool.OperationalStatus) ($($pool.HealthStatus))" } else { "NOT FOUND" }

# Check V: drive
$status["VDrive"] = if (Test-Path V:\) { "OK ($(([math]::Round((Get-PSDrive V).Used/1GB,1)) GB used)" } else { "NOT FOUND" }

# Check VHD files
$status["GUI.vhdx"] = if (Test-Path C:\LocalBox\VHD\GUI.vhdx) { "OK ($(([math]::Round((Get-Item C:\LocalBox\VHD\GUI.vhdx).Length/1GB,1)) GB)" } else { "MISSING" }
$status["AzL-node.vhdx"] = if (Test-Path C:\LocalBox\VHD\AzL-node.vhdx) { "OK ($(([math]::Round((Get-Item C:\LocalBox\VHD\AzL-node.vhdx).Length/1GB,1)) GB)" } else { "MISSING" }

# Check Hyper-V VMs
$vms = Get-VM -ErrorAction SilentlyContinue
$status["Hyper-V VMs"] = if ($vms) { ($vms | ForEach-Object { "$($_.Name):$($_.State)" }) -join ", " } else { "NONE" }

# Check if setup is currently running
$ps = Get-Process powershell -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $PID }
$status["PowerShell processes"] = "$($ps.Count) running"

# Check last log entries
$logFile = "C:\LocalBox\Logs\New-LocalBoxCluster.log"
$lastLog = if (Test-Path $logFile) {
    $lastWrite = (Get-Item $logFile).LastWriteTime
    "Last updated: $lastWrite"
} else { "No log file" }
$status["Cluster log"] = $lastLog

# Check logon script log
$logonLog = "C:\LocalBox\Logs\LocalBoxLogonScript.log"
$logonStatus = if (Test-Path $logonLog) {
    $lastWrite = (Get-Item $logonLog).LastWriteTime
    "Last updated: $lastWrite"
} else { "No log file" }
$status["Logon script log"] = $logonStatus

# Output
foreach ($key in $status.Keys | Sort-Object) {
    Write-Output "${key}: $($status[$key])"
}

# Overall assessment
Write-Output ""
if ($status["AzL-node.vhdx"] -eq "MISSING") {
    Write-Output "DIAGNOSIS: AzL-node.vhdx is missing. The download failed or was never started."
    Write-Output "ACTION: Run retry to re-launch the setup script."
} elseif ($vms.Count -ge 3) {
    Write-Output "DIAGNOSIS: Setup appears to be progressing (VMs exist)."
    Write-Output "ACTION: Wait for completion. Check Arc-enabled servers in the portal."
} elseif ($ps.Count -gt 2) {
    Write-Output "DIAGNOSIS: Setup script appears to be running."
    Write-Output "ACTION: Wait for completion (4-5 hours total)."
} else {
    Write-Output "DIAGNOSIS: Setup may have completed or failed. Check logs in the VM."
}
'@

$result = az vm run-command invoke -g $ResourceGroup -n $vmName `
    --command-id RunPowerShellScript `
    --scripts $diagScript `
    --query "value[0].message" -o tsv 2>$null

Write-Host $result
Write-Host ""

# ── Retry if requested ────────────────────────────────────────────
if ($Action -eq "retry") {
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

    $retryResult = az vm run-command invoke -g $ResourceGroup -n $vmName `
        --command-id RunPowerShellScript `
        --scripts "Start-Process powershell -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File C:\LocalBox\LocalBoxLogonScript.ps1' -WindowStyle Normal; Write-Output 'Setup script re-launched successfully'" `
        --query "value[0].message" -o tsv 2>$null

    Write-Host $retryResult -ForegroundColor Green
    Write-Host ""
    Write-Host "The setup will take 4-5 hours to complete."
    Write-Host "Re-run this script with -Action status to check progress."
}
