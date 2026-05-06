#!/usr/bin/env bash
set -euo pipefail

#####################################################################
# stop-environment.sh — Deallocate LocalBox VM to save costs
#
# Deallocating stops compute billing but keeps disks and networking.
# Disk charges (~$120/mo) and IP charges continue while deallocated.
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
echo " Stopping LocalBox Environment"
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

if [[ "$POWER_STATE" == "VM deallocated" ]]; then
    echo ""
    echo "VM is already deallocated. No action needed."
    exit 0
fi

# Deallocate Azure Firewall first if present (saves ~$30/day)
FW_NAME=$(az resource list -g "$RESOURCE_GROUP" --resource-type "Microsoft.Network/azureFirewalls" --query "[0].name" -o tsv 2>/dev/null || echo "")
if [[ -n "$FW_NAME" ]]; then
    echo ""
    echo "Deallocating Azure Firewall '$FW_NAME' (saves ~\$30/day)..."
    az network firewall ip-config delete -g "$RESOURCE_GROUP" -f "$FW_NAME" -n LocalBoxFirewallIpConfig --output none 2>/dev/null || true
    echo "  Firewall deallocated (IP config removed)."
fi

# Deallocate
echo ""
echo "Deallocating VM (this may take a few minutes)..."
az vm deallocate -g "$RESOURCE_GROUP" -n "$VM_NAME" --no-wait false

echo ""
echo "============================================="
echo " Environment Stopped"
echo "============================================="
echo ""
echo "  ✅ Compute billing has stopped"
echo "  ⚠️  Disk and static IP charges continue (~\$5/day)"
echo "  ⚠️  Dynamic public IP will be released (new IP on restart)"
echo ""
echo "To restart: ./scripts/start-environment.sh -g $RESOURCE_GROUP"
echo "To destroy: ./scripts/cleanup.sh -g $RESOURCE_GROUP"
