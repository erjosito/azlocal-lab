#!/bin/bash
# Update the route table to allow direct return traffic to the current client IP,
# bypassing the Azure Firewall for RDP/SSH connectivity.
#
# Usage: ./scripts/update-client-route.sh [resource-group]

set -euo pipefail

RG="${1:-azlocal2}"
ROUTE_TABLE="LocalBox-FW-RouteTable"
ROUTE_NAME="clientIP"

# Get current public IP
echo "Detecting current public IP..."
CLIENT_IP=$(curl -s https://ifconfig.me)

if [[ -z "$CLIENT_IP" || ! "$CLIENT_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: Could not detect public IP (got: '$CLIENT_IP')"
    exit 1
fi

echo "Current public IP: $CLIENT_IP"

# Check if route already exists with this IP
EXISTING=$(az network route-table route show -g "$RG" --route-table-name "$ROUTE_TABLE" -n "$ROUTE_NAME" --query "addressPrefix" -o tsv 2>/dev/null || echo "")

if [[ "$EXISTING" == "$CLIENT_IP/32" ]]; then
    echo "Route already up to date ($CLIENT_IP/32 → Internet). Nothing to do."
    exit 0
fi

if [[ -n "$EXISTING" ]]; then
    echo "Updating route: $EXISTING → $CLIENT_IP/32"
else
    echo "Creating route: $CLIENT_IP/32 → Internet"
fi

az network route-table route create \
    -g "$RG" \
    --route-table-name "$ROUTE_TABLE" \
    -n "$ROUTE_NAME" \
    --address-prefix "$CLIENT_IP/32" \
    --next-hop-type Internet \
    --output none

echo "✓ Route updated: $CLIENT_IP/32 → Internet (bypass firewall for return traffic)"

# Also update NSG rules if they exist
NSG_NAME="LocalBox-NSG"
echo ""
echo "Updating NSG inbound rules for $CLIENT_IP..."

az network nsg rule create -g "$RG" --nsg-name "$NSG_NAME" \
    -n "Allow-SSH-in" --priority 4000 \
    --source-address-prefixes "$CLIENT_IP" \
    --destination-port-ranges 22 \
    --access Allow --protocol Tcp --direction Inbound \
    --output none 2>/dev/null || true

az network nsg rule create -g "$RG" --nsg-name "$NSG_NAME" \
    -n "Allow-RDP-in" --priority 4001 \
    --source-address-prefixes "$CLIENT_IP" \
    --destination-port-ranges 3389 \
    --access Allow --protocol Tcp --direction Inbound \
    --output none 2>/dev/null || true

echo "✓ NSG rules updated for SSH and RDP from $CLIENT_IP"
