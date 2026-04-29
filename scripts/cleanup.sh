#!/usr/bin/env bash
set -euo pipefail

#####################################################################
# cleanup.sh — Delete all LocalBox resources
#
# WARNING: This permanently destroys all resources in the resource
# group. This action cannot be undone.
#####################################################################

RESOURCE_GROUP=""
FORCE=false

usage() {
    echo "Usage: $0 --resource-group <name> [--yes]"
    echo ""
    echo "Options:"
    echo "  --resource-group, -g   Resource group to delete (required)"
    echo "  --yes                  Skip confirmation prompt"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --resource-group|-g) RESOURCE_GROUP="$2"; shift 2;;
        --yes) FORCE=true; shift;;
        *) usage;;
    esac
done

[[ -z "$RESOURCE_GROUP" ]] && usage

echo "============================================="
echo " LocalBox Cleanup"
echo " Resource Group: $RESOURCE_GROUP"
echo "============================================="
echo ""

# Check resource group exists
echo -n "Checking resource group... "
RG_EXISTS=$(az group exists -n "$RESOURCE_GROUP" 2>/dev/null)
if [[ "$RG_EXISTS" != "true" ]]; then
    echo "NOT FOUND"
    echo "Resource group '$RESOURCE_GROUP' does not exist. Nothing to clean up."
    exit 0
fi

# Count resources
RESOURCE_COUNT=$(az resource list -g "$RESOURCE_GROUP" --query "length(@)" -o tsv 2>/dev/null || echo "0")
echo "Found ($RESOURCE_COUNT resources)"

echo ""
echo "⚠️  WARNING: This will PERMANENTLY DELETE all resources in '$RESOURCE_GROUP'."
echo "   This includes VMs, disks, networks, Key Vaults, and all data."
echo ""

if [[ "$FORCE" != true ]]; then
    read -rp "Type the resource group name to confirm: " CONFIRM
    if [[ "$CONFIRM" != "$RESOURCE_GROUP" ]]; then
        echo "Names don't match. Aborting."
        exit 1
    fi
fi

echo ""
echo "Deleting resource group '$RESOURCE_GROUP'..."
echo "This may take 10-15 minutes."
echo ""

az group delete --name "$RESOURCE_GROUP" --yes --no-wait

echo "============================================="
echo " Cleanup Initiated"
echo "============================================="
echo ""
echo "  Resource group deletion is in progress (running in background)."
echo "  Monitor status in Azure Portal or with:"
echo "    az group exists -n $RESOURCE_GROUP"
echo ""
echo "  Also clean up the cloned repo if no longer needed:"
echo "    rm -rf azure_arc"
