#!/usr/bin/env bash
set -euo pipefail

#####################################################################
# deploy-firewall.sh — Deploy Azure Firewall for a LocalBox lab
#
# Creates a dedicated Azure Firewall subnet, public IP, firewall policy,
# diagnostics, and a default route so LocalBox-Subnet egress flows through
# Azure Firewall. After the UDR is applied, LocalBox-Client and anything
# behind Vm-Router reach Azure management endpoints and the Internet through
# the firewall.
#
# Cost note: Azure Firewall Standard is expensive for a lab environment.
# Expect roughly ~$30/day while it is running.
#
# Usage examples:
#   ./scripts/deploy-firewall.sh --resource-group azlocal2
#   ./scripts/deploy-firewall.sh --resource-group azlocal2 --location swedencentral
#   ./scripts/deploy-firewall.sh --resource-group azlocal2 --firewall-name LocalBox-Firewall
#####################################################################

RESOURCE_GROUP=""
LOCATION=""
FIREWALL_NAME="LocalBox-Firewall"

VNET_NAME="LocalBox-VNet"
WORKLOAD_SUBNET_NAME="LocalBox-Subnet"
FIREWALL_SUBNET_NAME="AzureFirewallSubnet"
FIREWALL_SUBNET_PREFIX="172.16.2.0/26"
ROUTE_TABLE_NAME="LocalBox-FW-RouteTable"
DEFAULT_ROUTE_NAME="DefaultToFirewall"
FALLBACK_WORKSPACE_NAME="LocalBox-FW-Workspace"
FIREWALL_API_VERSION="2024-05-01"
FIREWALL_POLICY_API_VERSION="2024-10-01"

usage() {
    echo "Usage: $0 --resource-group <name> [--location <azure-region>] [--firewall-name <name>]"
    echo ""
    echo "Options:"
    echo "  --resource-group, -g   Resource group containing the LocalBox lab (required)"
    echo "  --location, -l         Azure region. Defaults to the resource group's location"
    echo "  --firewall-name        Firewall name (default: LocalBox-Firewall)"
    exit 1
}

az_text() {
    az "$@" --only-show-errors
}

az_text_allow_failure() {
    if az "$@" --only-show-errors 2>/dev/null; then
        return 0
    fi
    return 1
}

step() {
    echo ""
    echo "$1"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --resource-group|-g) RESOURCE_GROUP="$2"; shift 2 ;;
        --location|-l) LOCATION="$2"; shift 2 ;;
        --firewall-name) FIREWALL_NAME="$2"; shift 2 ;;
        *) usage ;;
    esac
done

[[ -z "$RESOURCE_GROUP" ]] && usage

PUBLIC_IP_NAME="${FIREWALL_NAME}-pip"
POLICY_NAME="${FIREWALL_NAME}-Policy"
APPLICATION_RCG_NAME="LocalBox-App-RCG"
NETWORK_RCG_NAME="LocalBox-Network-RCG"
FIREWALL_IP_CONFIG_NAME="LocalBoxFirewallIpConfig"
DIAG_SETTING_NAME="${FIREWALL_NAME}-Diagnostics"

RG_EXISTS=$(az_text group exists -n "$RESOURCE_GROUP")
if [[ "$RG_EXISTS" != "true" ]]; then
    echo "ERROR: Resource group '$RESOURCE_GROUP' does not exist."
    exit 1
fi

RG_LOCATION=$(az_text group show -n "$RESOURCE_GROUP" --query location -o tsv)
if [[ -z "$LOCATION" ]]; then
    LOCATION="$RG_LOCATION"
fi

SUBSCRIPTION_ID=$(az_text account show --query id -o tsv)
POLICY_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Network/firewallPolicies/${POLICY_NAME}"
FIREWALL_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Network/azureFirewalls/${FIREWALL_NAME}"
APPLICATION_RCG_URL="https://management.azure.com${POLICY_ID}/ruleCollectionGroups/${APPLICATION_RCG_NAME}?api-version=${FIREWALL_POLICY_API_VERSION}"
NETWORK_RCG_URL="https://management.azure.com${POLICY_ID}/ruleCollectionGroups/${NETWORK_RCG_NAME}?api-version=${FIREWALL_POLICY_API_VERSION}"
FIREWALL_URL="https://management.azure.com${FIREWALL_ID}?api-version=${FIREWALL_API_VERSION}"
ROUTE_TABLE_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Network/routeTables/${ROUTE_TABLE_NAME}"

cat <<EOF
=============================================
 Deploy Azure Firewall for LocalBox
=============================================
 Resource Group : ${RESOURCE_GROUP}
 Firewall Name  : ${FIREWALL_NAME}
 Location       : ${LOCATION}
=============================================
EOF

step "Checking LocalBox networking"
VNET_ID=$(az_text network vnet show -g "$RESOURCE_GROUP" -n "$VNET_NAME" --query id -o tsv 2>/dev/null || true)
if [[ -z "$VNET_ID" ]]; then
    echo "ERROR: VNet '$VNET_NAME' was not found in resource group '$RESOURCE_GROUP'."
    exit 1
fi

WORKLOAD_SUBNET_ID=$(az_text network vnet subnet show -g "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" -n "$WORKLOAD_SUBNET_NAME" --query id -o tsv 2>/dev/null || true)
if [[ -z "$WORKLOAD_SUBNET_ID" ]]; then
    echo "ERROR: Subnet '$WORKLOAD_SUBNET_NAME' was not found in VNet '$VNET_NAME'."
    exit 1
fi

FIREWALL_SUBNET_ID=$(az_text network vnet subnet show -g "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" -n "$FIREWALL_SUBNET_NAME" --query id -o tsv 2>/dev/null || true)
if [[ -z "$FIREWALL_SUBNET_ID" ]]; then
    echo "Creating ${FIREWALL_SUBNET_NAME} (${FIREWALL_SUBNET_PREFIX})..."
    az_text network vnet subnet create \
        -g "$RESOURCE_GROUP" \
        --vnet-name "$VNET_NAME" \
        -n "$FIREWALL_SUBNET_NAME" \
        --address-prefixes "$FIREWALL_SUBNET_PREFIX" \
        --output none >/dev/null
    FIREWALL_SUBNET_ID=$(az_text network vnet subnet show -g "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" -n "$FIREWALL_SUBNET_NAME" --query id -o tsv)
else
    echo "${FIREWALL_SUBNET_NAME} already exists."
fi

step "Ensuring firewall public IP"
PUBLIC_IP_ID=$(az_text network public-ip show -g "$RESOURCE_GROUP" -n "$PUBLIC_IP_NAME" --query id -o tsv 2>/dev/null || true)
if [[ -z "$PUBLIC_IP_ID" ]]; then
    echo "Creating public IP '$PUBLIC_IP_NAME'..."
    az_text network public-ip create \
        -g "$RESOURCE_GROUP" \
        -n "$PUBLIC_IP_NAME" \
        -l "$LOCATION" \
        --sku Standard \
        --allocation-method Static \
        --output none >/dev/null
    PUBLIC_IP_ID=$(az_text network public-ip show -g "$RESOURCE_GROUP" -n "$PUBLIC_IP_NAME" --query id -o tsv)
else
    echo "Public IP '$PUBLIC_IP_NAME' already exists."
fi

step "Ensuring firewall policy"
if ! az_text_allow_failure resource show --ids "$POLICY_ID" --api-version "$FIREWALL_POLICY_API_VERSION" --query id -o tsv >/dev/null; then
    POLICY_BODY=$(cat <<EOF
{"location":"${LOCATION}","properties":{"threatIntelMode":"Alert"}}
EOF
)
    az_text rest --method put --url "${POLICY_ID}?api-version=${FIREWALL_POLICY_API_VERSION}" --body "$POLICY_BODY" --output none >/dev/null
else
    echo "Firewall policy '$POLICY_NAME' already exists."
fi

if ! az_text_allow_failure rest --method get --url "$APPLICATION_RCG_URL" >/dev/null; then
    echo "Creating application rule collection group '$APPLICATION_RCG_NAME'..."
    APP_RCG_BODY=$(cat <<EOF
{"properties":{"priority":100,"ruleCollections":[{"name":"AllowAll","priority":100,"ruleCollectionType":"FirewallPolicyFilterRuleCollection","action":{"type":"Allow"},"rules":[{"name":"permit-any","ruleType":"ApplicationRule","sourceAddresses":["*"],"targetFqdns":["*"],"protocols":[{"protocolType":"Http","port":80},{"protocolType":"Https","port":443}]}]}]}}
EOF
)
    az_text rest --method put --url "$APPLICATION_RCG_URL" --body "$APP_RCG_BODY" --output none >/dev/null
else
    echo "Application rule collection group '$APPLICATION_RCG_NAME' already exists."
fi

if ! az_text_allow_failure rest --method get --url "$NETWORK_RCG_URL" >/dev/null; then
    echo "Creating empty network rule collection group '$NETWORK_RCG_NAME'..."
    NETWORK_RCG_BODY=$(cat <<EOF
{"properties":{"priority":200,"ruleCollections":[{"name":"AllowRequired","priority":200,"ruleCollectionType":"FirewallPolicyFilterRuleCollection","action":{"type":"Allow"},"rules":[]}]}}
EOF
)
    az_text rest --method put --url "$NETWORK_RCG_URL" --body "$NETWORK_RCG_BODY" --output none >/dev/null
else
    echo "Network rule collection group '$NETWORK_RCG_NAME' already exists."
fi

step "Ensuring Azure Firewall"
FIREWALL_BODY=$(cat <<EOF
{"location":"${LOCATION}","properties":{"sku":{"name":"AZFW_VNet","tier":"Standard"},"threatIntelMode":"Alert","firewallPolicy":{"id":"${POLICY_ID}"},"ipConfigurations":[{"name":"${FIREWALL_IP_CONFIG_NAME}","properties":{"subnet":{"id":"${FIREWALL_SUBNET_ID}"},"publicIPAddress":{"id":"${PUBLIC_IP_ID}"}}}]}}
EOF
)
az_text rest --method put --url "$FIREWALL_URL" --body "$FIREWALL_BODY" --output none >/dev/null

FIREWALL_PRIVATE_IP=""
for _ in $(seq 1 30); do
    FIREWALL_PRIVATE_IP=$(az_text resource show --ids "$FIREWALL_ID" --api-version "$FIREWALL_API_VERSION" --query "properties.ipConfigurations[0].properties.privateIPAddress" -o tsv 2>/dev/null || true)
    [[ -n "$FIREWALL_PRIVATE_IP" ]] && break
    sleep 10
done

if [[ -z "$FIREWALL_PRIVATE_IP" ]]; then
    echo "ERROR: Timed out waiting for Azure Firewall private IP."
    exit 1
fi

FIREWALL_PUBLIC_IP=$(az_text network public-ip show -g "$RESOURCE_GROUP" -n "$PUBLIC_IP_NAME" --query ipAddress -o tsv)

step "Ensuring Log Analytics workspace and diagnostics"
WORKSPACE_INFO=$(az_text monitor log-analytics workspace list -g "$RESOURCE_GROUP" -o json | python3 -c 'import sys, json; items = json.load(sys.stdin); match = next((w for w in items if "Workspace" in w.get("name", "")), None); print("{}\t{}".format(match["name"], match["id"]) if match else "")')
if [[ -z "$WORKSPACE_INFO" ]]; then
    echo "No matching workspace found. Creating '$FALLBACK_WORKSPACE_NAME'..."
    az_text monitor log-analytics workspace create \
        -g "$RESOURCE_GROUP" \
        -n "$FALLBACK_WORKSPACE_NAME" \
        -l "$LOCATION" \
        --output none >/dev/null
    WORKSPACE_INFO=$(az_text monitor log-analytics workspace show -g "$RESOURCE_GROUP" -n "$FALLBACK_WORKSPACE_NAME" --query "join('\t',[name,id])" -o tsv)
else
    echo "Using existing Log Analytics workspace."
fi
IFS=$'\t' read -r WORKSPACE_NAME WORKSPACE_ARM_ID <<< "$WORKSPACE_INFO"

LOGS_JSON='[{"category":"AZFWApplicationRule","enabled":true,"retentionPolicy":{"enabled":false,"days":0}},{"category":"AZFWNetworkRule","enabled":true,"retentionPolicy":{"enabled":false,"days":0}},{"category":"AZFWDnsQuery","enabled":true,"retentionPolicy":{"enabled":false,"days":0}}]'
az_text monitor diagnostic-settings create \
    --resource "$FIREWALL_ID" \
    -n "$DIAG_SETTING_NAME" \
    --workspace "$WORKSPACE_ARM_ID" \
    --export-to-resource-specific true \
    --logs "$LOGS_JSON" \
    --output none >/dev/null

step "Ensuring route table and subnet association"
ROUTE_TABLE_EXISTS=$(az_text network route-table show -g "$RESOURCE_GROUP" -n "$ROUTE_TABLE_NAME" --query id -o tsv 2>/dev/null || true)
if [[ -z "$ROUTE_TABLE_EXISTS" ]]; then
    echo "Creating route table '$ROUTE_TABLE_NAME'..."
    az_text network route-table create -g "$RESOURCE_GROUP" -n "$ROUTE_TABLE_NAME" -l "$LOCATION" --output none >/dev/null
else
    echo "Route table '$ROUTE_TABLE_NAME' already exists."
fi

az_text network route-table route create \
    -g "$RESOURCE_GROUP" \
    --route-table-name "$ROUTE_TABLE_NAME" \
    -n "$DEFAULT_ROUTE_NAME" \
    --address-prefix 0.0.0.0/0 \
    --next-hop-type VirtualAppliance \
    --next-hop-ip-address "$FIREWALL_PRIVATE_IP" \
    --output none >/dev/null

CURRENT_ROUTE_TABLE_ID=$(az_text network vnet subnet show -g "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" -n "$WORKLOAD_SUBNET_NAME" --query routeTable.id -o tsv 2>/dev/null || true)
if [[ "$CURRENT_ROUTE_TABLE_ID" != "$ROUTE_TABLE_ID" ]]; then
    az_text network vnet subnet update \
        -g "$RESOURCE_GROUP" \
        --vnet-name "$VNET_NAME" \
        -n "$WORKLOAD_SUBNET_NAME" \
        --route-table "$ROUTE_TABLE_NAME" \
        --output none >/dev/null
fi

cat <<EOF

=============================================
 Azure Firewall Ready
=============================================
 Firewall private IP : ${FIREWALL_PRIVATE_IP}
 Firewall public IP  : ${FIREWALL_PUBLIC_IP}
 Route table         : ${ROUTE_TABLE_NAME}
 Workspace           : ${WORKSPACE_NAME}

Traffic from ${WORKLOAD_SUBNET_NAME} now uses Azure Firewall as its default egress path.
EOF
