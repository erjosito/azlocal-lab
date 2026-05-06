#!/usr/bin/env bash
set -euo pipefail

#####################################################################
# start-environment.sh — Start a previously deallocated LocalBox VM
#
# After starting, prints connection details so you can RDP back in.
# The nested VMs (AzLHOST1, AzLHOST2, etc.) start automatically
# because they are configured to auto-start inside Hyper-V.
#####################################################################

RESOURCE_GROUP=""
VM_NAME="LocalBox-Client"

usage() {
    echo "Usage: $0 --resource-group <name>"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --resource-group|-g) RESOURCE_GROUP="$2"; shift 2;;
        *) usage;;
    esac
done

[[ -z "$RESOURCE_GROUP" ]] && usage

echo "============================================="
echo " Starting LocalBox Environment"
echo " Resource Group: $RESOURCE_GROUP"
echo "============================================="
echo ""

# Check VM exists
echo -n "Finding VM '$VM_NAME'... "
VM_ID=$(az vm show -g "$RESOURCE_GROUP" -n "$VM_NAME" --query "id" -o tsv 2>/dev/null || echo "")
if [[ -z "$VM_ID" ]]; then
    echo "NOT FOUND"
    echo "ERROR: VM '$VM_NAME' not found in resource group '$RESOURCE_GROUP'."
    exit 1
fi
echo "Found"

# Get current power state
POWER_STATE=$(az vm get-instance-view -g "$RESOURCE_GROUP" -n "$VM_NAME" \
    --query "instanceView.statuses[?starts_with(code,'PowerState/')].displayStatus" -o tsv)
echo "  Current state: $POWER_STATE"

if [[ "$POWER_STATE" == "VM running" ]]; then
    echo ""
    echo "VM is already running."
else
    echo ""
    echo "Starting VM (this may take a few minutes)..."
    az vm start -g "$RESOURCE_GROUP" -n "$VM_NAME"
    echo "VM started successfully."
fi

# Wait for VM to be ready, then ensure nested VMs are running
echo ""
echo "Retrieving connection details..."
sleep 5

# Start nested VMs if they are off (they may not auto-start after host deallocation)
echo ""
echo "Ensuring nested Hyper-V VMs are running..."
NESTED_RESULT=$(az vm run-command invoke -g "$RESOURCE_GROUP" -n "$VM_NAME" \
    --command-id RunPowerShellScript \
    --scripts "Get-VM | Where-Object { \$_.State -ne 'Running' } | ForEach-Object { Start-VM -Name \$_.Name; Write-Output \"Started: \$(\$_.Name)\" }; Get-VM | Select-Object Name, State | Out-String" \
    --query "value[0].message" -o tsv 2>/dev/null || echo "")
if [[ -n "$NESTED_RESULT" ]]; then
    echo "$NESTED_RESULT"
fi

# Start Azure Firewall if present in the resource group
FW_NAME=$(az network firewall list -g "$RESOURCE_GROUP" --query "[0].name" -o tsv 2>/dev/null || echo "")
if [[ -n "$FW_NAME" ]]; then
    echo ""
    echo "Reallocating Azure Firewall '$FW_NAME'..."
    # After deallocation ipConfigurations is empty, so look up PIP and subnet by name
    FW_PIP_NAME="${FW_NAME}-pip"
    FW_PIP_ID=$(az network public-ip show -g "$RESOURCE_GROUP" -n "$FW_PIP_NAME" --query "id" -o tsv 2>/dev/null || echo "")
    VNET_NAME=$(az network vnet list -g "$RESOURCE_GROUP" --query "[0].name" -o tsv 2>/dev/null || echo "")
    if [[ -n "$FW_PIP_ID" && -n "$VNET_NAME" ]]; then
        az network firewall ip-config create -g "$RESOURCE_GROUP" -f "$FW_NAME" \
            -n LocalBoxFirewallIpConfig \
            --public-ip-address "$FW_PIP_ID" \
            --vnet-name "$VNET_NAME" \
            --output none 2>/dev/null || true
        echo "  Azure Firewall reallocated."
    else
        echo "  (Firewall PIP or VNet not found, skipping reallocation)"
    fi
fi

PUBLIC_IP=$(az vm show -g "$RESOURCE_GROUP" -n "$VM_NAME" -d --query "publicIps" -o tsv 2>/dev/null || echo "N/A")
PRIVATE_IP=$(az vm show -g "$RESOURCE_GROUP" -n "$VM_NAME" -d --query "privateIps" -o tsv 2>/dev/null || echo "N/A")

echo ""
echo "============================================="
echo " Environment Running"
echo "============================================="
echo ""
echo "  Public IP:  $PUBLIC_IP"
echo "  Private IP: $PRIVATE_IP"
echo ""
echo "  Connect via RDP:"
echo "    mstsc /v:${PUBLIC_IP}"
echo ""
echo "  ⚠️  If the IP changed since last time, update your NSG rule"
echo "      to allow your current IP on port 3389."
echo ""
echo "  Nested VMs will auto-start within Hyper-V. Allow 10-15 minutes"
echo "  for the full nested stack to become operational."
echo ""
echo "  Default domain credentials: administrator@jumpstart.local"
echo "  (password is the same as your windowsAdminPassword)"
echo ""
echo "To stop when done: ./scripts/stop-environment.sh -g $RESOURCE_GROUP"
