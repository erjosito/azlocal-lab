#!/usr/bin/env bash
set -euo pipefail

#####################################################################
# estimate-cost.sh — Estimate monthly cost for LocalBox environment
#
# Queries the Azure Retail Prices API for the main resources used.
#####################################################################

LOCATION="${1:-swedencentral}"
CURRENCY="USD"
VM_SKU="Standard_E32s_v6"

echo "============================================="
echo " LocalBox Cost Estimate"
echo " Region: $LOCATION | Currency: $CURRENCY"
echo "============================================="
echo ""

fetch_price() {
    local filter="$1"
    local url="https://prices.azure.com/api/retail/prices?\$filter=${filter} and armRegionName eq '${LOCATION}' and currencyCode eq '${CURRENCY}'"
    local price
    price=$(curl -s "$url" | python3 -c "
import sys, json
data = json.load(sys.stdin)
items = data.get('Items', [])
# Prefer non-reservation, consumption prices
for item in items:
    if item.get('type') == 'Consumption' and 'Spot' not in item.get('skuName',''):
        print(f\"{item['retailPrice']:.4f}\")
        sys.exit(0)
if items:
    print(f\"{items[0]['retailPrice']:.4f}\")
else:
    print('0.0000')
" 2>/dev/null || echo "0.0000")
    echo "$price"
}

echo "Fetching prices from Azure Retail Prices API..."
echo ""

# ── VM compute cost ───────────────────────────────────────────────
echo -n "  VM ($VM_SKU, Linux)... "
VM_FILTER="armSkuName eq '${VM_SKU}' and serviceName eq 'Virtual Machines' and priceType eq 'Consumption' and contains(meterName, 'Spot') eq false and contains(skuName, 'Spot') eq false"
VM_HOURLY=$(fetch_price "$VM_FILTER")
VM_MONTHLY=$(python3 -c "print(f'{float(${VM_HOURLY}) * 730:.2f}')")
echo "\$${VM_HOURLY}/hr → \$${VM_MONTHLY}/month"

# ── VM Spot pricing ───────────────────────────────────────────────
echo -n "  VM ($VM_SKU, Spot)... "
SPOT_FILTER="armSkuName eq '${VM_SKU}' and serviceName eq 'Virtual Machines' and priceType eq 'Consumption' and contains(skuName, 'Spot') eq true"
SPOT_HOURLY=$(fetch_price "$SPOT_FILTER")
SPOT_MONTHLY=$(python3 -c "print(f'{float(${SPOT_HOURLY}) * 730:.2f}')")
echo "\$${SPOT_HOURLY}/hr → \$${SPOT_MONTHLY}/month"

# ── OS Disk (managed, Premium SSD) ───────────────────────────────
echo -n "  OS Disk (Premium SSD P30, 1 TiB)... "
DISK_FILTER="serviceName eq 'Storage' and contains(meterName, 'P30') and contains(productName, 'Premium SSD Managed Disks') and priceType eq 'Consumption'"
DISK_MONTHLY=$(fetch_price "$DISK_FILTER")
echo "\$${DISK_MONTHLY}/month"

# ── Log Analytics ─────────────────────────────────────────────────
echo -n "  Log Analytics (per GB ingested)... "
LA_FILTER="serviceName eq 'Log Analytics' and contains(meterName, 'Data Ingestion') and priceType eq 'Consumption'"
LA_PER_GB=$(fetch_price "$LA_FILTER")
echo "\$${LA_PER_GB}/GB"

# ── Public IP ─────────────────────────────────────────────────────
echo -n "  Public IP (Standard, static)... "
PIP_FILTER="serviceName eq 'Virtual Network' and contains(meterName, 'Static Public IP') and priceType eq 'Consumption'"
PIP_HOURLY=$(fetch_price "$PIP_FILTER")
PIP_MONTHLY=$(python3 -c "print(f'{float(${PIP_HOURLY}) * 730:.2f}')")
echo "\$${PIP_HOURLY}/hr → \$${PIP_MONTHLY}/month"

# ── NAT Gateway ───────────────────────────────────────────────────
echo -n "  NAT Gateway... "
NAT_FILTER="serviceName eq 'Virtual Network' and contains(meterName, 'NAT Gateway') and contains(meterName, 'Resource Hours') and priceType eq 'Consumption'"
NAT_HOURLY=$(fetch_price "$NAT_FILTER")
NAT_MONTHLY=$(python3 -c "print(f'{float(${NAT_HOURLY}) * 730:.2f}')")
echo "\$${NAT_HOURLY}/hr → \$${NAT_MONTHLY}/month"

echo ""
echo "============================================="
echo " Summary (estimated monthly costs)"
echo "============================================="
echo ""

TOTAL_24_7=$(python3 -c "print(f'{float(${VM_MONTHLY}) + float(${DISK_MONTHLY}) + float(${PIP_MONTHLY}) + float(${NAT_MONTHLY}):.2f}')")
TOTAL_8H=$(python3 -c "
vm_8h = float(${VM_HOURLY}) * 8 * 22  # 8h/day, 22 workdays
other = float(${DISK_MONTHLY}) + float(${PIP_MONTHLY}) + float(${NAT_MONTHLY})
print(f'{vm_8h + other:.2f}')
")
TOTAL_SPOT=$(python3 -c "print(f'{float(${SPOT_MONTHLY}) + float(${DISK_MONTHLY}) + float(${PIP_MONTHLY}) + float(${NAT_MONTHLY}):.2f}')")

printf "  %-35s %10s\n" "Running 24/7 (PAYG):" "\$${TOTAL_24_7}"
printf "  %-35s %10s\n" "Running 8h/day, weekdays only:" "\$${TOTAL_8H}"
printf "  %-35s %10s\n" "Running 24/7 (Spot pricing):" "\$${TOTAL_SPOT}"
echo ""
echo "  + Log Analytics ingestion: ~\$${LA_PER_GB}/GB (varies by volume)"
echo "  + Bandwidth egress: variable"
echo ""
echo "Note: These are RETAIL estimates. EA/MCA/CSP pricing may differ."
echo "      Disk and IP charges continue even when the VM is deallocated."
echo ""
echo "💡 Tip: Use ./scripts/stop-environment.sh when not using the lab!"
