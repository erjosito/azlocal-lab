#!/usr/bin/env bash
set -euo pipefail

#####################################################################
# retry-setup.sh — Check and retry the LocalBox internal setup
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

RESOURCE_GROUP=""
VM_NAME="LocalBox-Client"
ACTION="status"

usage() {
    echo "Usage: $0 --resource-group <name> [--action status|retry|progress]"
    echo ""
    echo "Options:"
    echo "  --resource-group, -g   Resource group name (required)"
    echo "  --action, -a           Action: 'status' (default), 'retry', or 'progress'"
    echo ""
    echo "Actions:"
    echo "  status     Check the current state of the internal setup"
    echo "  retry      Re-launch the logon script to retry the setup"
    echo "  progress   Show setup milestones and recent log activity"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --resource-group|-g) RESOURCE_GROUP="$2"; shift 2;;
        --action|-a) ACTION="$2"; shift 2;;
        *) usage;;
    esac
done

[[ -z "$RESOURCE_GROUP" ]] && usage

echo "============================================="
echo " LocalBox Setup Troubleshooting"
echo "============================================="
echo ""

# ── Check VM is running ───────────────────────────────────────────
echo "Checking VM power state..."
VM_STATE=$(az vm get-instance-view -g "$RESOURCE_GROUP" -n "$VM_NAME" \
    --query "instanceView.statuses[?starts_with(code,'PowerState/')].displayStatus" -o tsv 2>/dev/null)

if [[ "$VM_STATE" != "VM running" ]]; then
    echo "ERROR: VM is not running (state: $VM_STATE)"
    echo "Start it with: ./scripts/start-environment.sh -g $RESOURCE_GROUP"
    exit 1
fi
echo "  ✓ VM is running"
echo ""

# ── Run diagnostics inside the VM ─────────────────────────────────
echo "Running diagnostics inside the VM (this takes ~30 seconds)..."
echo ""

DIAG_SCRIPT='
$status = @{}

# Check azcopy
$azcopyVer = try { azcopy --version 2>$null } catch { $null }
$status["azcopy"] = if ($azcopyVer) { "OK ($azcopyVer)" } else { "MISSING - setup will fail without it" }

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
'

RESULT=$(az vm run-command invoke -g "$RESOURCE_GROUP" -n "$VM_NAME" \
    --command-id RunPowerShellScript \
    --scripts "$DIAG_SCRIPT" \
    --query "value[0].message" -o tsv 2>/dev/null)

echo "$RESULT"
echo ""

# ── Progress if requested ─────────────────────────────────────────
if [[ "$ACTION" == "progress" ]]; then
    echo "─── Setup Progress ────────────────────────────────────────────"
    echo ""
    echo "Reading log files inside the VM..."
    echo ""

    PROGRESS_SCRIPT='
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

$allLogs = @()
$logFiles = @(
    "C:\LocalBox\Logs\Bootstrap.log",
    "C:\LocalBox\Logs\LocalBoxLogonScript.log",
    "C:\LocalBox\Logs\New-LocalBoxCluster.log"
)
foreach ($lf in $logFiles) {
    if (Test-Path $lf) { $allLogs += Get-Content $lf }
}

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

Write-Output "=== Milestone Checklist ==="
foreach ($r in $results) { Write-Output $r }

Write-Output ""
if ($lastReached -ge 0 -and $lastReached -lt ($milestones.Count - 1)) {
    $next = $milestones[$lastReached + 1]
    Write-Output "CURRENT: Likely working on ''$($next.Label)'' (or failed before reaching it)"
} elseif ($lastReached -eq ($milestones.Count - 1)) {
    Write-Output "STATUS: All milestones reached - setup appears complete!"
} else {
    Write-Output "STATUS: No milestones reached yet. Setup may not have started."
}

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

Write-Output ""
Write-Output "=== Errors Found ==="
$errors = $allLogs | Where-Object { $_ -match "Write-Error|TerminatingError|Aborting|FAILED|Exception" -and $_ -notmatch "ErrorAction|ErrorVariable|SilentlyContinue" } | Select-Object -Last 10
if ($errors) {
    foreach ($e in $errors) { Write-Output $e }
} else {
    Write-Output "(none)"
}
'

    PROGRESS_RESULT=$(az vm run-command invoke -g "$RESOURCE_GROUP" -n "$VM_NAME" \
        --command-id RunPowerShellScript \
        --scripts "$PROGRESS_SCRIPT" \
        --query "value[0].message" -o tsv 2>/dev/null)

    echo "$PROGRESS_RESULT"
    echo ""
    exit 0
fi

# ── Retry if requested ────────────────────────────────────────────
if [[ "$ACTION" == "retry" ]]; then
    echo "─── Pre-flight checks ─────────────────────────────────────────"
    echo ""

    # Check azcopy is installed (common cause of silent download failures)
    echo "  Checking azcopy installation inside the VM..."
    AZCOPY_STATUS=$(az vm run-command invoke -g "$RESOURCE_GROUP" -n "$VM_NAME" \
        --command-id RunPowerShellScript \
        --scripts 'if (Get-Command azcopy -ErrorAction SilentlyContinue) { Write-Output "INSTALLED: $(azcopy --version)" } else { Write-Output "MISSING" }' \
        --query "value[0].message" -o tsv 2>/dev/null)

    if [[ "$AZCOPY_STATUS" == "MISSING"* ]]; then
        echo "  azcopy is NOT installed. Installing it now..."
        INSTALL_RESULT=$(az vm run-command invoke -g "$RESOURCE_GROUP" -n "$VM_NAME" \
            --command-id RunPowerShellScript \
            --scripts 'Invoke-WebRequest -Uri "https://aka.ms/downloadazcopy-v10-windows" -OutFile C:\Temp\azcopy.zip; Expand-Archive C:\Temp\azcopy.zip -DestinationPath C:\Temp\azcopy -Force; $exe = Get-ChildItem C:\Temp\azcopy -Recurse -Filter azcopy.exe | Select-Object -First 1; Copy-Item $exe.FullName C:\Windows\System32\azcopy.exe -Force; Write-Output "OK: $(azcopy --version)"' \
            --query "value[0].message" -o tsv 2>/dev/null)

        if [[ "$INSTALL_RESULT" == "OK:"* ]]; then
            echo "  ✓ $INSTALL_RESULT"
        else
            echo "  ERROR: Failed to install azcopy." >&2
            echo "  The setup script will fail without azcopy. Install it manually inside the VM."
            exit 1
        fi
    else
        echo "  ✓ $AZCOPY_STATUS"
    fi

    echo ""
    echo "─── Re-launching setup script ───────────────────────────────"
    echo ""
    echo "This will restart C:\\LocalBox\\LocalBoxLogonScript.ps1 inside the VM."
    echo "The script is idempotent — it will skip steps already completed."
    echo ""
    read -rp "Proceed? [Y/n]: " CONFIRM
    CONFIRM="${CONFIRM:-Y}"
    if [[ ! "$CONFIRM" =~ ^[Yy] ]]; then
        echo "Cancelled."
        exit 0
    fi

    RETRY_RESULT=$(az vm run-command invoke -g "$RESOURCE_GROUP" -n "$VM_NAME" \
        --command-id RunPowerShellScript \
        --scripts "Start-Process powershell -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File C:\LocalBox\LocalBoxLogonScript.ps1' -WindowStyle Normal; Write-Output 'Setup script re-launched successfully'" \
        --query "value[0].message" -o tsv 2>/dev/null)

    echo "$RETRY_RESULT"
    echo ""
    echo "The setup will take 4-5 hours to complete."
    echo "Re-run this script with --action status to check progress."
fi
