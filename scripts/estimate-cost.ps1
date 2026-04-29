#####################################################################
# estimate-cost.ps1 — Estimate monthly cost for LocalBox environment
#
# Queries the Azure Retail Prices API for the main resources used.
#####################################################################

param(
    [string]$Location = "swedencentral",
    [string]$Currency = "USD",
    [string]$VmSku = "Standard_E32s_v6"
)

function Get-AzureRetailPrice {
    param([string]$Filter)
    $url = "https://prices.azure.com/api/retail/prices?`$filter=$Filter and armRegionName eq '$Location' and currencyCode eq '$Currency'"
    try {
        $response = Invoke-RestMethod -Uri $url -Method Get
        $items = $response.Items
        # Prefer consumption, non-spot prices
        $consumption = $items | Where-Object { $_.type -eq 'Consumption' -and $_.skuName -notmatch 'Spot' } | Select-Object -First 1
        if ($consumption) { return $consumption.retailPrice }
        if ($items.Count -gt 0) { return $items[0].retailPrice }
        return 0
    } catch {
        return 0
    }
}

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " LocalBox Cost Estimate"
Write-Host " Region: $Location | Currency: $Currency"
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Fetching prices from Azure Retail Prices API..."
Write-Host ""

# ── VM compute cost ───────────────────────────────────────────────
Write-Host -NoNewline "  VM ($VmSku, PAYG)... "
$vmHourly = Get-AzureRetailPrice "armSkuName eq '$VmSku' and serviceName eq 'Virtual Machines' and priceType eq 'Consumption' and contains(skuName, 'Spot') eq false"
$vmMonthly = [math]::Round($vmHourly * 730, 2)
Write-Host "`$$vmHourly/hr -> `$$vmMonthly/month"

# ── VM Spot pricing ───────────────────────────────────────────────
Write-Host -NoNewline "  VM ($VmSku, Spot)... "
$spotHourly = Get-AzureRetailPrice "armSkuName eq '$VmSku' and serviceName eq 'Virtual Machines' and priceType eq 'Consumption' and contains(skuName, 'Spot') eq true"
$spotMonthly = [math]::Round($spotHourly * 730, 2)
Write-Host "`$$spotHourly/hr -> `$$spotMonthly/month"

# ── OS Disk ───────────────────────────────────────────────────────
Write-Host -NoNewline "  OS Disk (Premium SSD P30, 1 TiB)... "
$diskMonthly = Get-AzureRetailPrice "serviceName eq 'Storage' and contains(meterName, 'P30') and contains(productName, 'Premium SSD Managed Disks') and priceType eq 'Consumption'"
Write-Host "`$$diskMonthly/month"

# ── Log Analytics ─────────────────────────────────────────────────
Write-Host -NoNewline "  Log Analytics (per GB ingested)... "
$laPerGb = Get-AzureRetailPrice "serviceName eq 'Log Analytics' and contains(meterName, 'Data Ingestion') and priceType eq 'Consumption'"
Write-Host "`$$laPerGb/GB"

# ── Public IP ─────────────────────────────────────────────────────
Write-Host -NoNewline "  Public IP (Standard, static)... "
$pipHourly = Get-AzureRetailPrice "serviceName eq 'Virtual Network' and contains(meterName, 'Static Public IP') and priceType eq 'Consumption'"
$pipMonthly = [math]::Round($pipHourly * 730, 2)
Write-Host "`$$pipHourly/hr -> `$$pipMonthly/month"

# ── NAT Gateway ───────────────────────────────────────────────────
Write-Host -NoNewline "  NAT Gateway... "
$natHourly = Get-AzureRetailPrice "serviceName eq 'Virtual Network' and contains(meterName, 'NAT Gateway') and contains(meterName, 'Resource Hours') and priceType eq 'Consumption'"
$natMonthly = [math]::Round($natHourly * 730, 2)
Write-Host "`$$natHourly/hr -> `$$natMonthly/month"

# ── Summary ───────────────────────────────────────────────────────
Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " Summary (estimated monthly costs)"
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""

$total247 = [math]::Round($vmMonthly + $diskMonthly + $pipMonthly + $natMonthly, 2)
$total8h = [math]::Round(($vmHourly * 8 * 22) + $diskMonthly + $pipMonthly + $natMonthly, 2)
$totalSpot = [math]::Round($spotMonthly + $diskMonthly + $pipMonthly + $natMonthly, 2)

Write-Host ("  {0,-35} {1,10}" -f "Running 24/7 (PAYG):", "`$$total247")
Write-Host ("  {0,-35} {1,10}" -f "Running 8h/day, weekdays only:", "`$$total8h")
Write-Host ("  {0,-35} {1,10}" -f "Running 24/7 (Spot pricing):", "`$$totalSpot")
Write-Host ""
Write-Host "  + Log Analytics ingestion: ~`$$laPerGb/GB (varies by volume)"
Write-Host "  + Bandwidth egress: variable"
Write-Host ""
Write-Host "Note: These are RETAIL estimates. EA/MCA/CSP pricing may differ."
Write-Host "      Disk and IP charges continue even when the VM is deallocated."
Write-Host ""
Write-Host "Tip: Use .\scripts\stop-environment.ps1 when not using the lab!" -ForegroundColor Yellow
