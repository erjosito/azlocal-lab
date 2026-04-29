#!/usr/bin/env bash
set -euo pipefail

#####################################################################
# deploy.sh — Deploy LocalBox infrastructure via Azure Bicep
#
# This script:
#   1. Auto-retrieves parameters from your Azure environment
#   2. Prompts interactively for values it cannot detect
#   3. Generates the Bicep parameters file
#   4. Deploys the infrastructure
#
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
INTERACTIVE=true

usage() {
    echo "Usage: $0 --resource-group <name> [--location <region>] [--params <file>] [--no-interactive]"
    echo ""
    echo "Options:"
    echo "  --resource-group, -g   Resource group name (required)"
    echo "  --location, -l         Azure region (default: swedencentral)"
    echo "  --params, -p           Pre-built parameters file (skips interactive prompts)"
    echo "  --commit, -c           Git commit/tag to pin (default: main)"
    echo "  --no-interactive       Fail if parameters file doesn't exist (for CI/CD)"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --resource-group|-g) RESOURCE_GROUP="$2"; shift 2;;
        --location|-l) LOCATION="$2"; shift 2;;
        --params|-p) PARAMS_FILE="$2"; INTERACTIVE=false; shift 2;;
        --commit|-c) JUMPSTART_COMMIT="$2"; shift 2;;
        --no-interactive) INTERACTIVE=false; shift;;
        *) usage;;
    esac
done

[[ -z "$RESOURCE_GROUP" ]] && usage

echo "============================================="
echo " LocalBox Deployment"
echo "============================================="
echo " Resource Group : $RESOURCE_GROUP"
echo " Location       : $LOCATION"
echo " Git ref        : $JUMPSTART_COMMIT"
echo "============================================="
echo ""

# ── Helper: prompt with default ───────────────────────────────────
prompt_with_default() {
    local prompt_text="$1"
    local default_value="$2"
    local user_input

    if [[ -n "$default_value" ]]; then
        read -rp "$prompt_text [$default_value]: " user_input
        echo "${user_input:-$default_value}"
    else
        read -rp "$prompt_text: " user_input
        echo "$user_input"
    fi
}

prompt_yes_no() {
    local prompt_text="$1"
    local default="$2"
    local user_input

    read -rp "$prompt_text [$default]: " user_input
    user_input="${user_input:-$default}"
    [[ "$user_input" =~ ^[Yy] ]] && echo "true" || echo "false"
}

prompt_password() {
    local prompt_text="$1"
    local password=""

    while true; do
        read -rsp "$prompt_text: " password
        echo ""
        if [[ ${#password} -lt 12 ]]; then
            echo "  Password must be at least 12 characters." >&2
            continue
        fi
        if [[ "$password" == *'$'* ]]; then
            echo "  Password must NOT contain the \$ symbol (breaks logon scripts)." >&2
            continue
        fi
        if ! [[ "$password" =~ [A-Z] && "$password" =~ [a-z] && "$password" =~ [0-9] ]]; then
            echo "  Password must contain uppercase, lowercase, and a digit." >&2
            continue
        fi
        # Confirm
        local confirm=""
        read -rsp "  Confirm password: " confirm
        echo ""
        if [[ "$password" != "$confirm" ]]; then
            echo "  Passwords do not match. Try again." >&2
            continue
        fi
        break
    done
    echo "$password"
}

# ── Generate parameters interactively ─────────────────────────────
if [[ -f "$PARAMS_FILE" ]] && ! grep -q '<your-' "$PARAMS_FILE"; then
    echo "Found existing parameters file: $PARAMS_FILE"
    echo "Using it as-is. Delete it to re-run interactive setup."
    echo ""
elif [[ "$INTERACTIVE" == "true" ]]; then
    echo "─── Auto-detecting parameters from your Azure environment ───"
    echo ""

    # Auto-retrieve: tenant ID
    echo "  Retrieving tenant ID..."
    TENANT_ID=$(az account show --query tenantId -o tsv 2>/dev/null) || true
    if [[ -z "$TENANT_ID" ]]; then
        echo "  ERROR: Could not retrieve tenant ID. Are you logged in? Run: az login" >&2
        exit 1
    fi
    echo "  ✓ Tenant ID: $TENANT_ID"

    # Auto-retrieve: subscription
    echo "  Retrieving subscription..."
    SUBSCRIPTION_NAME=$(az account show --query name -o tsv 2>/dev/null) || true
    SUBSCRIPTION_ID=$(az account show --query id -o tsv 2>/dev/null) || true
    echo "  ✓ Subscription: $SUBSCRIPTION_NAME ($SUBSCRIPTION_ID)"

    # Auto-retrieve: spnProviderId (Microsoft.AzureStackHCI Resource Provider)
    echo "  Retrieving AzureStackHCI Resource Provider service principal..."
    SPN_PROVIDER_ID=$(az ad sp list --display-name "Microsoft.AzureStackHCI Resource Provider" \
        --query "[0].id" -o tsv 2>/dev/null) || true
    if [[ -z "$SPN_PROVIDER_ID" ]]; then
        echo "  ⚠ Could not auto-detect spnProviderId."
        echo "    This is the Object ID of the 'Microsoft.AzureStackHCI Resource Provider' SP."
        SPN_PROVIDER_ID=$(prompt_with_default "  Enter spnProviderId manually" "")
        if [[ -z "$SPN_PROVIDER_ID" ]]; then
            echo "  ERROR: spnProviderId is required." >&2
            exit 1
        fi
    else
        echo "  ✓ spnProviderId: $SPN_PROVIDER_ID"
    fi

    echo ""
    echo "─── Interactive configuration ───────────────────────────────"
    echo "Press Enter to accept defaults shown in [brackets]."
    echo ""

    # Credentials
    ADMIN_USER=$(prompt_with_default "Windows admin username" "arcdemo")
    echo ""
    echo "Choose a password for the VM (min 12 chars, upper+lower+digit, no \$ symbol):"
    ADMIN_PASSWORD=$(prompt_password "  Windows admin password")
    echo ""

    # VM options
    echo "─── VM Configuration ────────────────────────────────────────"
    VM_SIZE=$(prompt_with_default "VM size" "Standard_E32s_v6")
    USE_SPOT=$(prompt_yes_no "Enable Azure Spot pricing? (cheaper but risk of eviction)" "N")
    echo ""

    # Deployment options
    echo "─── Deployment Options ──────────────────────────────────────"
    DEPLOY_BASTION=$(prompt_yes_no "Deploy Azure Bastion? (adds ~\$140/month)" "N")
    AUTO_DEPLOY_CLUSTER=$(prompt_yes_no "Auto-deploy the Azure Local cluster resource?" "Y")
    AUTO_UPGRADE_CLUSTER=$(prompt_yes_no "Auto-upgrade the cluster resource?" "N")
    WORKSPACE_NAME=$(prompt_with_default "Log Analytics workspace name" "LocalBox-Workspace")
    echo ""

    # Azure Local region
    echo "─── Azure Local Instance Region ─────────────────────────────"
    echo "  The Azure Local cluster registers in a separate region."
    echo "  Valid: australiaeast, southcentralus, eastus, westeurope,"
    echo "         southeastasia, canadacentral, japaneast, centralindia"
    LOCAL_INSTANCE_LOCATION=$(prompt_with_default "Azure Local instance location" "westeurope")
    echo ""

    # Tags
    GOVERN_TAGS=$(prompt_yes_no "Enable resource tag governance? (Microsoft-internal tenants only)" "N")
    echo ""

    # ── Generate parameters file ─────────────────────────────────────
    echo "─── Generating parameters file ──────────────────────────────"
    cat > "$PARAMS_FILE" <<EOF
using 'main.bicep'

// Auto-detected parameters
param tenantId = '$TENANT_ID'
param spnProviderId = '$SPN_PROVIDER_ID'

// Credentials
param windowsAdminUsername = '$ADMIN_USER'
param windowsAdminPassword = '$ADMIN_PASSWORD'

// Deployment options
param logAnalyticsWorkspaceName = '$WORKSPACE_NAME'
param deployBastion = $DEPLOY_BASTION
param autoDeployClusterResource = $AUTO_DEPLOY_CLUSTER
param autoUpgradeClusterResource = $AUTO_UPGRADE_CLUSTER

// VM configuration
param vmSize = '$VM_SIZE'
param enableAzureSpotPricing = $USE_SPOT

// Azure Local instance region
param azureLocalInstanceLocation = '$LOCAL_INSTANCE_LOCATION'

// Tags
param governResourceTags = $GOVERN_TAGS
EOF

    echo "  ✓ Parameters written to: $PARAMS_FILE"
    echo ""
    echo "─── Summary ─────────────────────────────────────────────────"
    echo "  Tenant:        $TENANT_ID"
    echo "  SPN Provider:  $SPN_PROVIDER_ID"
    echo "  Admin user:    $ADMIN_USER"
    echo "  VM size:       $VM_SIZE"
    echo "  Spot pricing:  $USE_SPOT"
    echo "  Bastion:       $DEPLOY_BASTION"
    echo "  Auto-deploy:   $AUTO_DEPLOY_CLUSTER"
    echo "  Instance loc:  $LOCAL_INSTANCE_LOCATION"
    echo ""

    # Confirm before proceeding
    read -rp "Proceed with deployment? [Y/n]: " CONFIRM
    CONFIRM="${CONFIRM:-Y}"
    if [[ ! "$CONFIRM" =~ ^[Yy] ]]; then
        echo "Deployment cancelled. Your parameters are saved in $PARAMS_FILE"
        echo "Re-run this script to deploy without re-entering values."
        exit 0
    fi
else
    # Non-interactive mode: params file must exist and be valid
    if [[ ! -f "$PARAMS_FILE" ]]; then
        echo "ERROR: Parameters file not found: $PARAMS_FILE"
        echo "Run without --no-interactive to generate it, or create it manually."
        exit 1
    fi
    if grep -q '<your-' "$PARAMS_FILE"; then
        echo "ERROR: Parameters file still contains placeholder values."
        exit 1
    fi
fi

# ── Clone Jumpstart repo ─────────────────────────────────────────
echo ""
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
