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
TENANT_ID=""
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

# Enterprise policy initiatives can disable shared key access on storage accounts,
# but the LocalBox cluster witness requires key-based authentication.
fix_storage_policy_conflicts() {
    local subscription_id=""
    local management_group_scope=""
    local resource_group_scope=""
    local detected_assignments=""
    local first_assignment=""
    local assignment_id=""
    local assignment_name=""
    local assignment_display=""
    local fallback_assignment_name="MCAPSGov-Deploy-Diag-LogA-Modify"
    local exemption_name="localbox-witness-shared-key"
    local exemption_display_name="LocalBox witness storage requires shared key for cluster validation"
    local witness_account=""

    echo ""
    echo "Checking for storage policy conflicts..."

    subscription_id=$(az account show --query id -o tsv 2>/dev/null || true)
    if [[ -z "$subscription_id" ]]; then
        echo "  Could not determine subscription ID. Skipping storage policy conflict fix."
        return 0
    fi

    if [[ -z "${TENANT_ID:-}" ]]; then
        TENANT_ID=$(az account show --query tenantId -o tsv 2>/dev/null || true)
    fi
    if [[ -z "$TENANT_ID" ]]; then
        echo "  Could not determine tenant ID. Skipping storage policy conflict fix."
        return 0
    fi

    management_group_scope="/providers/Microsoft.Management/managementGroups/$TENANT_ID"
    resource_group_scope="/subscriptions/$subscription_id/resourceGroups/$RESOURCE_GROUP"

    detected_assignments=$(az policy assignment list \
        --scope "$management_group_scope" \
        --query "[?(contains(displayName, 'Deploy') || contains(displayName, 'Modify') || contains(to_string(@), 'StorageAccountDisableLocalAuth'))].[id, name, displayName]" \
        -o tsv 2>/dev/null || true)

    if [[ -n "$detected_assignments" ]]; then
        echo "  Detected potentially conflicting policy assignments:"
        while IFS=$'\t' read -r _ detected_name detected_display; do
            [[ -z "$detected_name" ]] && continue
            echo "    - $detected_name ($detected_display)"
        done <<< "$detected_assignments"

        first_assignment=$(printf '%s\n' "$detected_assignments" | head -n 1)
        IFS=$'\t' read -r assignment_id assignment_name assignment_display <<< "$first_assignment"
    fi

    if [[ -z "$assignment_id" ]]; then
        assignment_id=$(az policy assignment show \
            --name "$fallback_assignment_name" \
            --scope "$management_group_scope" \
            --query id -o tsv 2>/dev/null || true)
        if [[ -n "$assignment_id" ]]; then
            assignment_name="$fallback_assignment_name"
            echo "  Falling back to known policy assignment: $assignment_name"
        fi
    fi

    if [[ -z "$assignment_id" ]]; then
        echo "  No conflicting policies detected."
        return 0
    fi

    echo "  Using policy assignment: $assignment_name"

    if az policy exemption show --name "$exemption_name" --scope "$resource_group_scope" --query name -o tsv >/dev/null 2>&1; then
        echo "  Policy exemption '$exemption_name' already exists."
    else
        if az policy exemption create \
            --name "$exemption_name" \
            --display-name "$exemption_display_name" \
            --policy-assignment "$assignment_id" \
            --exemption-category "Waiver" \
            --scope "$resource_group_scope" \
            --policy-definition-reference-ids "StorageAccountDisableLocalAuth" \
            --output none >/dev/null 2>&1; then
            echo "  Created policy exemption '$exemption_name'."
        else
            echo "  Could not create policy exemption automatically. Continuing without failing."
        fi
    fi

    witness_account=$(az storage account list -g "$RESOURCE_GROUP" --query "[?starts_with(name, 'localboxw')].name | [0]" -o tsv 2>/dev/null || true)
    if [[ -z "$witness_account" ]]; then
        witness_account=$(az storage account list -g "$RESOURCE_GROUP" --query "[0].name" -o tsv 2>/dev/null || true)
    fi

    if [[ -z "$witness_account" ]]; then
        echo "  No witness storage account found in resource group."
        return 0
    fi

    echo "  Updating witness storage account: $witness_account"
    az storage account update \
        -n "$witness_account" \
        -g "$RESOURCE_GROUP" \
        --allow-shared-key-access true \
        --output none >/dev/null
    echo "  Enabled shared key access."

    az storage account update \
        -n "$witness_account" \
        -g "$RESOURCE_GROUP" \
        --public-network-access Enabled \
        --output none >/dev/null
    echo "  Enabled public network access."
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
    echo ""
    echo "  Azure Bastion provides secure RDP/SSH access to VMs without"
    echo "  exposing public IPs. Without it, you'll need an NSG rule for RDP (port 3389)."
    DEPLOY_BASTION=$(prompt_yes_no "Deploy Azure Bastion? (adds ~\$140/month)" "N")
    echo ""
    echo "  Auto-deploy cluster: After the VM finishes its internal setup (~4-5h),"
    echo "  the script can automatically register and deploy the Azure Local cluster"
    echo "  resource in Azure (the 2-node HCI cluster). If disabled, you must do this"
    echo "  manually from the Azure Portal (useful if you want to learn that process)."
    AUTO_DEPLOY_CLUSTER=$(prompt_yes_no "Auto-deploy the Azure Local cluster resource?" "Y")
    echo ""
    echo "  Auto-upgrade cluster: If enabled, Azure will automatically apply solution"
    echo "  updates (OS patches + HCI feature updates) to the cluster when available."
    echo "  Disable this for lab environments to avoid unexpected reboots during exercises."
    AUTO_UPGRADE_CLUSTER=$(prompt_yes_no "Auto-upgrade the cluster resource?" "N")
    echo ""
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
    echo "  Tag governance enforces mandatory resource tags (e.g., CostCenter, Owner)"
    echo "  via Azure Policy. This is only needed for Microsoft-internal subscriptions"
    echo "  that require specific tag compliance. For personal/external tenants, say No."
    GOVERN_TAGS=$(prompt_yes_no "Enable resource tag governance?" "N")
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

fix_storage_policy_conflicts

echo ""
echo "============================================="
echo " Infrastructure Deployment Complete!"
echo "============================================="
echo ""

# Retrieve VM public IP
VM_IP=$(az vm show -g "$RESOURCE_GROUP" -n LocalBox-Client -d --query publicIps -o tsv 2>/dev/null || echo "")
ADMIN_USER_DISPLAY=$(grep -oP "(?<=windowsAdminUsername = ').*(?=')" "$PARAMS_FILE" 2>/dev/null || echo "arcdemo")

echo "IMPORTANT: This was Phase 1 only. The next steps are:"
echo ""
if [[ -n "$VM_IP" ]]; then
    echo "  LocalBox-Client public IP: $VM_IP"
    echo ""
    echo "  Connect via RDP (PowerShell):"
    echo "    mstsc /v:$VM_IP /u:$ADMIN_USER_DISPLAY"
    echo ""
    echo "  Or from a Linux terminal:"
    echo "    xfreerdp /v:$VM_IP /u:$ADMIN_USER_DISPLAY /dynamic-resolution"
    echo ""
else
    echo "  Could not retrieve VM public IP. Check with:"
    echo "    az vm show -g $RESOURCE_GROUP -n LocalBox-Client -d --query publicIps -o tsv"
    echo ""
fi
echo "  NOTE: If your subscription has policies that remove port 3389 NSG rules,"
echo "  consider using Azure Bastion instead (re-deploy with Bastion enabled)."
echo ""
echo "  1. A PowerShell script will run automatically inside the VM."
echo "     This takes approximately 4-5 HOURS to complete."
echo "     Do NOT close the PowerShell window."
echo ""
echo "  2. Once the script finishes, verify in Azure Portal that"
echo "     AzLHOST1 and AzLHOST2 appear as Arc-enabled servers."
echo ""
echo "  3. Start the exercises: exercises/00-explore-architecture.md"
echo ""
echo "To monitor costs:"
echo "  ./scripts/estimate-cost.sh"
echo ""
echo "To stop and save money when not using:"
echo "  ./scripts/stop-environment.sh -g $RESOURCE_GROUP"
