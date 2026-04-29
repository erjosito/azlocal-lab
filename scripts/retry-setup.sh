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
    echo "Usage: $0 --resource-group <name> [--action status|retry]"
    echo ""
    echo "Options:"
    echo "  --resource-group, -g   Resource group name (required)"
    echo "  --action, -a           Action: 'status' (default) or 'retry'"
    echo ""
    echo "Actions:"
    echo "  status   Check the current state of the internal setup"
    echo "  retry    Re-launch the logon script to retry the setup"
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

# ── Retry if requested ────────────────────────────────────────────
if [[ "$ACTION" == "retry" ]]; then
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
