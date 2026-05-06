#!/usr/bin/env bash
set -euo pipefail

#####################################################################
# prerequisites.sh — Validate and prepare environment for LocalBox
#####################################################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

LOCATION="${1:-swedencentral}"
REQUIRED_VCPUS=32

echo "============================================="
echo " LocalBox Prerequisites Check"
echo "============================================="
echo ""

# ── 1. Azure CLI version ──────────────────────────────────────────
echo -n "Checking Azure CLI version... "
if ! command -v az &> /dev/null; then
    echo -e "${RED}FAIL${NC} — Azure CLI not found. Install from https://learn.microsoft.com/cli/azure/install-azure-cli"
    exit 1
fi
AZ_VERSION=$(az version --query '"azure-cli"' -o tsv)
MAJOR=$(echo "$AZ_VERSION" | cut -d. -f1)
MINOR=$(echo "$AZ_VERSION" | cut -d. -f2)
if [[ "$MAJOR" -lt 2 ]] || { [[ "$MAJOR" -eq 2 ]] && [[ "$MINOR" -lt 65 ]]; }; then
    echo -e "${RED}FAIL${NC} — Version $AZ_VERSION found, need 2.65.0+. Run: az upgrade"
    exit 1
fi
echo -e "${GREEN}OK${NC} (v$AZ_VERSION)"

# ── 2. Logged in ──────────────────────────────────────────────────
echo -n "Checking Azure login... "
if ! az account show &> /dev/null; then
    echo -e "${RED}FAIL${NC} — Not logged in. Run: az login"
    exit 1
fi
SUBSCRIPTION=$(az account show --query "name" -o tsv)
SUBSCRIPTION_ID=$(az account show --query "id" -o tsv)
echo -e "${GREEN}OK${NC} ($SUBSCRIPTION)"

# ── 3. Owner role ─────────────────────────────────────────────────
echo -n "Checking subscription role... "
UPN=$(az account show --query "user.name" -o tsv)
HAS_OWNER=$(az role assignment list --assignee "$UPN" --scope "/subscriptions/$SUBSCRIPTION_ID" \
    --query "[?roleDefinitionName=='Owner'] | length(@)" -o tsv 2>/dev/null || echo "0")
if [[ "$HAS_OWNER" -gt 0 ]]; then
    echo -e "${GREEN}OK${NC} (Owner)"
else
    echo -e "${YELLOW}WARN${NC} — Owner role not confirmed for $UPN. Deployment may fail without Owner."
fi

# ── 4. vCPU quota ─────────────────────────────────────────────────
echo -n "Checking vCPU quota in $LOCATION... "
# Try ESv6 first, fall back to ESv5
USAGE_LINE=$(az vm list-usage --location "$LOCATION" -o tsv 2>/dev/null \
    | grep -i "Standard ESv6 Family" || true)
if [[ -z "$USAGE_LINE" ]]; then
    USAGE_LINE=$(az vm list-usage --location "$LOCATION" -o tsv 2>/dev/null \
        | grep -i "Standard ESv5 Family" || true)
fi

if [[ -n "$USAGE_LINE" ]]; then
    CURRENT=$(echo "$USAGE_LINE" | awk '{print $1}')
    LIMIT=$(echo "$USAGE_LINE" | awk '{print $2}')
    AVAILABLE=$((LIMIT - CURRENT))
    if [[ "$AVAILABLE" -ge "$REQUIRED_VCPUS" ]]; then
        echo -e "${GREEN}OK${NC} ($AVAILABLE vCPUs available, need $REQUIRED_VCPUS)"
    else
        echo -e "${RED}FAIL${NC} — Only $AVAILABLE vCPUs available (need $REQUIRED_VCPUS). Request quota increase."
        exit 1
    fi
else
    echo -e "${YELLOW}WARN${NC} — Could not determine quota. Manually check: az vm list-usage --location $LOCATION -o table"
fi

# ── 5. Register resource providers ────────────────────────────────
echo ""
echo "Registering required resource providers..."
PROVIDERS=(
    "Microsoft.HybridCompute"
    "Microsoft.GuestConfiguration"
    "Microsoft.HybridConnectivity"
    "Microsoft.AzureStackHCI"
    "Microsoft.Kubernetes"
    "Microsoft.KubernetesConfiguration"
    "Microsoft.ExtendedLocation"
    "Microsoft.ResourceConnector"
    "Microsoft.HybridContainerService"
    "Microsoft.Attestation"
    "Microsoft.Storage"
    "Microsoft.Insights"
    "Microsoft.KeyVault"
)

for PROVIDER in "${PROVIDERS[@]}"; do
    STATE=$(az provider show --namespace "$PROVIDER" --query "registrationState" -o tsv 2>/dev/null || echo "NotRegistered")
    if [[ "$STATE" == "Registered" ]]; then
        echo -e "  $PROVIDER: ${GREEN}Already registered${NC}"
    else
        echo -n "  $PROVIDER: Registering... "
        az provider register --namespace "$PROVIDER" &>/dev/null || true
        echo -e "${GREEN}Done${NC}"
    fi
done

# ── 6. Bicep version ─────────────────────────────────────────────
echo ""
echo -n "Upgrading Bicep... "
az bicep upgrade &>/dev/null 2>&1 || az bicep install &>/dev/null 2>&1 || true
BICEP_VERSION=$(az bicep version 2>/dev/null | head -1 || echo "unknown")
echo -e "${GREEN}OK${NC} ($BICEP_VERSION)"

# ── 7. Python3 check ──────────────────────────────────────────────
echo ""
echo -n "Checking Python 3... "
if command -v python3 &> /dev/null; then
    PY_VERSION=$(python3 --version 2>&1)
    echo -e "${GREEN}OK${NC} ($PY_VERSION)"
else
    echo -e "${YELLOW}WARN${NC} — python3 not found. Some scripts (estimate-cost.sh) require it."
fi

# ── 8. HCI Resource Provider SPN ─────────────────────────────────
echo ""
echo -n "Retrieving Azure Local resource provider object ID... "
SPN_ID=$(az ad sp list --display-name "Microsoft.AzureStackHCI Resource Provider" \
    --query "[0].id" -o tsv 2>/dev/null || echo "")
if [[ -n "$SPN_ID" ]]; then
    echo -e "${GREEN}OK${NC}"
    echo "  spnProviderId = $SPN_ID"
else
    echo -e "${YELLOW}WARN${NC} — Could not retrieve. You may need to register Microsoft.AzureStackHCI first."
fi

# ── 9. Tenant ID ──────────────────────────────────────────────────
TENANT_ID=$(az account show --query "tenantId" -o tsv)
echo "  tenantId      = $TENANT_ID"

echo ""
echo "============================================="
echo -e " ${GREEN}Prerequisites check complete!${NC}"
echo "============================================="
echo ""
echo "Next steps:"
echo "  1. cp deploy/main.bicepparam.template deploy/main.bicepparam"
echo "  2. Edit deploy/main.bicepparam with the values above"
echo "  3. Run: ./deploy/deploy.sh --resource-group <name> --location $LOCATION"
