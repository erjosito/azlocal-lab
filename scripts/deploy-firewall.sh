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
NAT_RCG_NAME="LocalBox-NAT-RCG"
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
FIREWALL_PUBLIC_IP=$(az_text network public-ip show -g "$RESOURCE_GROUP" -n "$PUBLIC_IP_NAME" --query ipAddress -o tsv 2>/dev/null || true)

step "Ensuring firewall policy"
POLICY_EXISTS=$(az_text network firewall policy show -g "$RESOURCE_GROUP" -n "$POLICY_NAME" --query id -o tsv 2>/dev/null || true)
if [[ -z "$POLICY_EXISTS" ]]; then
    echo "Creating firewall policy '$POLICY_NAME'..."
    az_text network firewall policy create \
        -g "$RESOURCE_GROUP" \
        -n "$POLICY_NAME" \
        -l "$LOCATION" \
        --threat-intel-mode Alert \
        --output none >/dev/null
else
    echo "Firewall policy '$POLICY_NAME' already exists."
fi

APP_RCG_EXISTS=$(az_text network firewall policy rule-collection-group show -g "$RESOURCE_GROUP" --policy-name "$POLICY_NAME" -n "$APPLICATION_RCG_NAME" --query id -o tsv 2>/dev/null || true)
if [[ -z "$APP_RCG_EXISTS" ]]; then
    echo "Creating application rule collection group '$APPLICATION_RCG_NAME'..."
    az_text network firewall policy rule-collection-group create \
        -g "$RESOURCE_GROUP" \
        --policy-name "$POLICY_NAME" \
        -n "$APPLICATION_RCG_NAME" \
        --priority 100 \
        --output none >/dev/null
    az_text network firewall policy rule-collection-group collection add-filter-collection \
        -g "$RESOURCE_GROUP" \
        --policy-name "$POLICY_NAME" \
        --rule-collection-group-name "$APPLICATION_RCG_NAME" \
        -n "AllowAll" \
        --collection-priority 100 \
        --action Allow \
        --rule-type ApplicationRule \
        --rule-name "permit-any" \
        --source-addresses "*" \
        --target-fqdns "*" \
        --protocols Http=80 Https=443 \
        --output none >/dev/null
else
    echo "Application rule collection group '$APPLICATION_RCG_NAME' already exists."
fi

NETWORK_RCG_EXISTS=$(az_text network firewall policy rule-collection-group show -g "$RESOURCE_GROUP" --policy-name "$POLICY_NAME" -n "$NETWORK_RCG_NAME" --query id -o tsv 2>/dev/null || true)
if [[ -z "$NETWORK_RCG_EXISTS" ]]; then
    echo "Creating network rule collection group '$NETWORK_RCG_NAME' with baseline rules..."
    az_text network firewall policy rule-collection-group create \
        -g "$RESOURCE_GROUP" \
        --policy-name "$POLICY_NAME" \
        -n "$NETWORK_RCG_NAME" \
        --priority 200 \
        --output none >/dev/null
    az_text network firewall policy rule-collection-group collection add-filter-collection \
        -g "$RESOURCE_GROUP" \
        --policy-name "$POLICY_NAME" \
        --rule-collection-group-name "$NETWORK_RCG_NAME" \
        -n "AllowDNS" \
        --collection-priority 200 \
        --action Allow \
        --rule-type NetworkRule \
        --rule-name "allow-dns" \
        --source-addresses "*" \
        --destination-addresses "*" \
        --destination-ports 53 \
        --ip-protocols UDP TCP \
        --output none >/dev/null
    az_text network firewall policy rule-collection-group collection add-filter-collection \
        -g "$RESOURCE_GROUP" \
        --policy-name "$POLICY_NAME" \
        --rule-collection-group-name "$NETWORK_RCG_NAME" \
        -n "AllowNTP" \
        --collection-priority 210 \
        --action Allow \
        --rule-type NetworkRule \
        --rule-name "allow-ntp" \
        --source-addresses "*" \
        --destination-addresses "*" \
        --destination-ports 123 \
        --ip-protocols UDP \
        --output none >/dev/null
    az_text network firewall policy rule-collection-group collection add-filter-collection \
        -g "$RESOURCE_GROUP" \
        --policy-name "$POLICY_NAME" \
        --rule-collection-group-name "$NETWORK_RCG_NAME" \
        -n "AllowSMBInternal" \
        --collection-priority 220 \
        --action Allow \
        --rule-type NetworkRule \
        --rule-name "allow-smb-internal" \
        --source-addresses 172.16.0.0/12 10.0.0.0/8 \
        --destination-addresses 10.0.0.0/8 \
        --destination-ports 445 \
        --ip-protocols TCP \
        --output none >/dev/null
    az_text network firewall policy rule-collection-group collection add-filter-collection \
        -g "$RESOURCE_GROUP" \
        --policy-name "$POLICY_NAME" \
        --rule-collection-group-name "$NETWORK_RCG_NAME" \
        -n "AllowQUICInternal" \
        --collection-priority 230 \
        --action Allow \
        --rule-type NetworkRule \
        --rule-name "allow-quic-internal" \
        --source-addresses 172.16.0.0/12 10.0.0.0/8 \
        --destination-addresses 10.0.0.0/8 \
        --destination-ports 443 \
        --ip-protocols UDP \
        --output none >/dev/null
else
    echo "Network rule collection group '$NETWORK_RCG_NAME' already exists."
fi

step "Ensuring DNAT rule for RDP access"
CLIENT_PRIVATE_IP=$(az_text vm show -g "$RESOURCE_GROUP" -n "LocalBox-Client" -d --query privateIps -o tsv 2>/dev/null || true)
if [[ -z "$CLIENT_PRIVATE_IP" ]]; then
    echo "WARNING: Could not find LocalBox-Client private IP. Skipping DNAT rule."
else
    echo "LocalBox-Client private IP: $CLIENT_PRIVATE_IP"
    NAT_RCG_EXISTS=$(az_text network firewall policy rule-collection-group show -g "$RESOURCE_GROUP" --policy-name "$POLICY_NAME" -n "$NAT_RCG_NAME" --query id -o tsv 2>/dev/null || true)
    if [[ -z "$NAT_RCG_EXISTS" ]]; then
        echo "Creating NAT rule collection group '$NAT_RCG_NAME'..."
        az_text network firewall policy rule-collection-group create \
            -g "$RESOURCE_GROUP" \
            --policy-name "$POLICY_NAME" \
            -n "$NAT_RCG_NAME" \
            --priority 150 \
            --output none >/dev/null
        az_text network firewall policy rule-collection-group collection add-nat-collection \
            -g "$RESOURCE_GROUP" \
            --policy-name "$POLICY_NAME" \
            --rule-collection-group-name "$NAT_RCG_NAME" \
            -n "InboundRDP" \
            --collection-priority 150 \
            --action DNAT \
            --rule-name "RDP-to-LocalBox-Client" \
            --source-addresses "*" \
            --destination-addresses "$FIREWALL_PUBLIC_IP" \
            --destination-ports 3389 \
            --ip-protocols TCP \
            --translated-address "$CLIENT_PRIVATE_IP" \
            --translated-port 3389 \
            --output none >/dev/null
    else
        echo "NAT rule collection group '$NAT_RCG_NAME' already exists."
    fi
fi

step "Ensuring Azure Firewall"
FIREWALL_STATE=$(az_text network firewall show -g "$RESOURCE_GROUP" -n "$FIREWALL_NAME" --query provisioningState -o tsv 2>/dev/null || true)
if [[ -z "$FIREWALL_STATE" ]]; then
    echo "Creating Azure Firewall '$FIREWALL_NAME' (this takes 5-10 minutes)..."
    az_text network firewall create \
        -g "$RESOURCE_GROUP" \
        -n "$FIREWALL_NAME" \
        -l "$LOCATION" \
        --policy "$POLICY_NAME" \
        --vnet-name "$VNET_NAME" \
        --conf-name "$FIREWALL_IP_CONFIG_NAME" \
        --public-ip "$PUBLIC_IP_NAME" \
        --output none >/dev/null
else
    echo "Azure Firewall '$FIREWALL_NAME' already exists ($FIREWALL_STATE)."
fi

echo "Verifying IP configuration..."
FIREWALL_PRIVATE_IP=$(az_text network firewall show -g "$RESOURCE_GROUP" -n "$FIREWALL_NAME" --query "ipConfigurations[0].privateIpAddress" -o tsv 2>/dev/null || true)
if [[ -z "$FIREWALL_PRIVATE_IP" || "$FIREWALL_PRIVATE_IP" == "None" ]]; then
    echo "  IP config not bound yet. Adding explicitly..."
    az_text network firewall ip-config create \
        -g "$RESOURCE_GROUP" \
        -f "$FIREWALL_NAME" \
        -n "$FIREWALL_IP_CONFIG_NAME" \
        --public-ip-address "$PUBLIC_IP_NAME" \
        --vnet-name "$VNET_NAME" \
        --output none >/dev/null
fi

echo "Waiting for firewall private IP..."
FIREWALL_PRIVATE_IP=""
for _ in $(seq 1 30); do
    FIREWALL_PRIVATE_IP=$(az_text network firewall show -g "$RESOURCE_GROUP" -n "$FIREWALL_NAME" --query "ipConfigurations[0].privateIpAddress" -o tsv 2>/dev/null || true)
    if [[ -n "$FIREWALL_PRIVATE_IP" && "$FIREWALL_PRIVATE_IP" != "None" ]]; then
        break
    fi
    sleep 10
done

if [[ -z "$FIREWALL_PRIVATE_IP" || "$FIREWALL_PRIVATE_IP" == "None" ]]; then
    echo "ERROR: Timed out waiting for Azure Firewall private IP."
    exit 1
fi
echo "  Firewall private IP: $FIREWALL_PRIVATE_IP"

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
FIREWALL_ID=$(az_text network firewall show -g "$RESOURCE_GROUP" -n "$FIREWALL_NAME" --query id -o tsv)
az_text monitor diagnostic-settings create \
    --resource "$FIREWALL_ID" \
    -n "$DIAG_SETTING_NAME" \
    --workspace "$WORKSPACE_ARM_ID" \
    --export-to-resource-specific true \
    --logs "$LOGS_JSON" \
    --output none >/dev/null 2>/dev/null || true

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
    --output none >/dev/null 2>/dev/null || true

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

if [[ -n "${CLIENT_PRIVATE_IP:-}" ]]; then
    cat <<EOF

RDP access via DNAT:
  mstsc /v:${FIREWALL_PUBLIC_IP}
  (Firewall forwards port 3389 -> ${CLIENT_PRIVATE_IP})
EOF
fi
