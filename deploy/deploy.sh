#!/usr/bin/env bash
set -euo pipefail

#####################################################################
# deploy.sh — Deploy LocalBox infrastructure via Azure Bicep
#
# This script deploys the Azure infrastructure (VM, networking, etc).
# After completion, the LocalBox-Client VM runs automated setup that
# takes 4-5 hours to finish configuring the nested Azure Local cluster.
#####################################################################

# Pinned commit for reproducibility — update periodically
JUMPSTART_REPO="https://github.com/microsoft/azure_arc.git"
JUMPSTART_COMMIT="main"  # Pin to a specific commit/tag for stability
JUMPSTART_DIR="azure_arc"
BICEP_PATH="azure_jumpstart_localbox/bicep"

RESOURCE_GROUP=""
LOCATION="swedencentral"
PARAMS_FILE="deploy/main.bicepparam"

usage() {
    echo "Usage: $0 --resource-group <name> [--location <region>] [--params <file>]"
    echo ""
    echo "Options:"
    echo "  --resource-group, -g   Resource group name (required)"
    echo "  --location, -l         Azure region (default: swedencentral)"
    echo "  --params, -p           Parameters file (default: deploy/main.bicepparam)"
    echo "  --commit, -c           Git commit/tag to pin (default: main)"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --resource-group|-g) RESOURCE_GROUP="$2"; shift 2;;
        --location|-l) LOCATION="$2"; shift 2;;
        --params|-p) PARAMS_FILE="$2"; shift 2;;
        --commit|-c) JUMPSTART_COMMIT="$2"; shift 2;;
        *) usage;;
    esac
done

[[ -z "$RESOURCE_GROUP" ]] && usage

echo "============================================="
echo " LocalBox Deployment"
echo "============================================="
echo " Resource Group : $RESOURCE_GROUP"
echo " Location       : $LOCATION"
echo " Parameters     : $PARAMS_FILE"
echo " Git ref        : $JUMPSTART_COMMIT"
echo "============================================="
echo ""

# ── Validate parameters file exists ──────────────────────────────
if [[ ! -f "$PARAMS_FILE" ]]; then
    echo "ERROR: Parameters file not found: $PARAMS_FILE"
    echo "Run: cp deploy/main.bicepparam.template deploy/main.bicepparam"
    echo "Then edit it with your values."
    exit 1
fi

# Check for placeholder values
if grep -q '<your-' "$PARAMS_FILE"; then
    echo "ERROR: Parameters file still contains placeholder values."
    echo "Edit $PARAMS_FILE and replace all <your-...> placeholders."
    exit 1
fi

# ── Clone Jumpstart repo ─────────────────────────────────────────
echo "Cloning Jumpstart repository..."
if [[ -d "$JUMPSTART_DIR" ]]; then
    echo "  Directory $JUMPSTART_DIR already exists, pulling latest..."
    cd "$JUMPSTART_DIR"
    git fetch origin
    git checkout "$JUMPSTART_COMMIT"
    cd ..
else
    git clone --depth 1 "$JUMPSTART_REPO" "$JUMPSTART_DIR"
    cd "$JUMPSTART_DIR"
    git checkout "$JUMPSTART_COMMIT"
    cd ..
fi

# Validate expected Bicep files exist
if [[ ! -f "$JUMPSTART_DIR/$BICEP_PATH/main.bicep" ]]; then
    echo "ERROR: Expected Bicep file not found at $JUMPSTART_DIR/$BICEP_PATH/main.bicep"
    echo "The Jumpstart repo structure may have changed."
    exit 1
fi

# ── Create resource group ─────────────────────────────────────────
echo ""
echo "Creating resource group '$RESOURCE_GROUP' in '$LOCATION'..."
az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none

# ── Deploy Bicep template ─────────────────────────────────────────
echo ""
echo "Deploying LocalBox infrastructure (this takes ~30 minutes)..."
echo "Starting at $(date '+%H:%M:%S')"
echo ""

# Copy params file next to main.bicep for the deployment
cp "$PARAMS_FILE" "$JUMPSTART_DIR/$BICEP_PATH/main.bicepparam"

az deployment group create \
    --resource-group "$RESOURCE_GROUP" \
    --template-file "$JUMPSTART_DIR/$BICEP_PATH/main.bicep" \
    --parameters "$JUMPSTART_DIR/$BICEP_PATH/main.bicepparam" \
    --verbose

echo ""
echo "============================================="
echo " Infrastructure Deployment Complete!"
echo "============================================="
echo ""
echo "IMPORTANT: This was Phase 1 only. The next steps are:"
echo ""
echo "  1. Connect to the LocalBox-Client VM via RDP or Bastion"
echo "     (You may need to add an NSG rule for port 3389 first)"
echo ""
echo "  2. A PowerShell script will run automatically inside the VM."
echo "     This takes approximately 4-5 HOURS to complete."
echo "     Do NOT close the PowerShell window."
echo ""
echo "  3. Once the script finishes, verify in Azure Portal that"
echo "     AzLHOST1 and AzLHOST2 appear as Arc-enabled servers."
echo ""
echo "  4. Start the exercises: exercises/00-explore-architecture.md"
echo ""
echo "To check your VM's public IP:"
echo "  az vm show -g $RESOURCE_GROUP -n LocalBox-Client -d --query publicIps -o tsv"
echo ""
echo "To monitor costs:"
echo "  ./scripts/estimate-cost.sh"
echo ""
echo "To stop and save money when not using:"
echo "  ./scripts/stop-environment.sh -g $RESOURCE_GROUP"
