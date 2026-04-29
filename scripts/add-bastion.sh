#!/usr/bin/env bash
set -euo pipefail

#####################################################################
# add-bastion.sh — Add Azure Bastion to an existing LocalBox lab
#
# Deploys Azure Bastion so you can RDP into LocalBox-Client through
# the Azure Portal without needing a public IP NSG rule on port 3389.
# Useful when subscription policies remove inbound RDP rules.
#####################################################################

RESOURCE_GROUP=""
BASTION_NAME="LocalBox-Bastion"
VNET_NAME=""
BASTION_SKU="Basic"

usage() {
    echo "Usage: $0 --resource-group <name> [--bastion-name <name>] [--sku Basic|Standard]"
    echo ""
    echo "Options:"
    echo "  --resource-group, -g   Resource group containing the LocalBox lab (required)"
    echo "  --bastion-name         Name for the Bastion resource (default: LocalBox-Bastion)"
    echo "  --sku                  Bastion SKU: Basic or Standard (default: Basic)"
    echo "                         Standard adds native client support (az network bastion rdp)"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --resource-group|-g) RESOURCE_GROUP="$2"; shift 2;;
        --bastion-name) BASTION_NAME="$2"; shift 2;;
        --sku) BASTION_SKU="$2"; shift 2;;
        *) usage;;
    esac
done

[[ -z "$RESOURCE_GROUP" ]] && usage

echo "============================================="
echo " Add Azure Bastion to LocalBox"
echo "============================================="
echo " Resource Group : $RESOURCE_GROUP"
echo " Bastion Name   : $BASTION_NAME"
echo " SKU            : $BASTION_SKU"
echo "============================================="
echo ""

# ── Find the VNet in the resource group ───────────────────────────
echo "Looking for VNet in resource group '$RESOURCE_GROUP'..."
VNET_NAME=$(az network vnet list -g "$RESOURCE_GROUP" --query "[0].name" -o tsv 2>/dev/null)

if [[ -z "$VNET_NAME" ]]; then
    echo "ERROR: No VNet found in resource group '$RESOURCE_GROUP'."
    echo "Is this the correct resource group for your LocalBox deployment?"
    exit 1
fi
echo "  Found VNet: $VNET_NAME"

# ── Check if AzureBastionSubnet exists ────────────────────────────
echo "Checking for AzureBastionSubnet..."
BASTION_SUBNET=$(az network vnet subnet show -g "$RESOURCE_GROUP" \
    --vnet-name "$VNET_NAME" -n AzureBastionSubnet \
    --query "name" -o tsv 2>/dev/null || echo "")

if [[ -z "$BASTION_SUBNET" ]]; then
    echo "  AzureBastionSubnet not found. Creating it..."

    # Get VNet address space to pick a non-overlapping /26
    VNET_PREFIXES=$(az network vnet show -g "$RESOURCE_GROUP" -n "$VNET_NAME" \
        --query "addressSpace.addressPrefixes" -o tsv)
    echo "  VNet address space: $VNET_PREFIXES"

    # Use a /26 within the VNet space — Azure Bastion requires at least /26
    # Try 10.16.3.128/26 (common in Jumpstart deployments) or prompt user
    BASTION_PREFIX="10.16.3.128/26"
    echo ""
    echo "  Azure Bastion requires a dedicated subnet named 'AzureBastionSubnet'"
    echo "  with at least a /26 prefix. Proposed: $BASTION_PREFIX"
    read -rp "  Use this prefix? [Y/n, or enter a custom /26 CIDR]: " SUBNET_INPUT
    SUBNET_INPUT="${SUBNET_INPUT:-Y}"

    if [[ "$SUBNET_INPUT" =~ ^[Yy]$ ]]; then
        BASTION_PREFIX="$BASTION_PREFIX"
    elif [[ "$SUBNET_INPUT" == *"/"* ]]; then
        BASTION_PREFIX="$SUBNET_INPUT"
    else
        echo "  Using default: $BASTION_PREFIX"
    fi

    az network vnet subnet create \
        -g "$RESOURCE_GROUP" \
        --vnet-name "$VNET_NAME" \
        -n AzureBastionSubnet \
        --address-prefixes "$BASTION_PREFIX" \
        --output none

    echo "  ✓ AzureBastionSubnet created with prefix $BASTION_PREFIX"
else
    echo "  ✓ AzureBastionSubnet already exists"
fi

# ── Create public IP for Bastion ──────────────────────────────────
BASTION_PIP="${BASTION_NAME}-pip"
echo ""
echo "Creating public IP for Bastion..."
az network public-ip create \
    -g "$RESOURCE_GROUP" \
    -n "$BASTION_PIP" \
    --sku Standard \
    --allocation-method Static \
    --output none
echo "  ✓ Public IP created: $BASTION_PIP"

# ── Deploy Bastion ────────────────────────────────────────────────
echo ""
echo "Deploying Azure Bastion (this takes 5-10 minutes)..."
az network bastion create \
    -g "$RESOURCE_GROUP" \
    -n "$BASTION_NAME" \
    --public-ip-address "$BASTION_PIP" \
    --vnet-name "$VNET_NAME" \
    --sku "$BASTION_SKU" \
    --output none

echo ""
echo "============================================="
echo " Azure Bastion Deployed Successfully!"
echo "============================================="
echo ""
echo "  To connect to LocalBox-Client:"
echo ""
echo "  Option 1 — Azure Portal:"
echo "    Go to the LocalBox-Client VM > Connect > Bastion"
echo ""
if [[ "$BASTION_SKU" == "Standard" ]]; then
    echo "  Option 2 — Native client (Standard SKU):"
    echo "    az network bastion rdp -g $RESOURCE_GROUP -n $BASTION_NAME --target-resource-id \\"
    echo "      \$(az vm show -g $RESOURCE_GROUP -n LocalBox-Client --query id -o tsv)"
    echo ""
fi
echo "  Bastion provides RDP access without needing port 3389 open in NSG rules."
echo ""
echo "  Estimated additional cost: ~\$140/month (Basic) or ~\$350/month (Standard)"
