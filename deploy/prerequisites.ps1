#####################################################################
# prerequisites.ps1 — Validate and prepare environment for LocalBox
#####################################################################

param(
    [string]$Location = "swedencentral"
)

$RequiredVCPUs = 32

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " LocalBox Prerequisites Check"
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""

# ── 1. Azure CLI version ──────────────────────────────────────────
Write-Host -NoNewline "Checking Azure CLI version... "
try {
    $azVersion = (az version | ConvertFrom-Json).'azure-cli'
    $parts = $azVersion.Split('.')
    if ([int]$parts[0] -lt 2 -or ([int]$parts[0] -eq 2 -and [int]$parts[1] -lt 65)) {
        Write-Host "FAIL — Version $azVersion found, need 2.65.0+. Run: az upgrade" -ForegroundColor Red
        exit 1
    }
    Write-Host "OK (v$azVersion)" -ForegroundColor Green
} catch {
    Write-Host "FAIL — Azure CLI not found. Install from https://learn.microsoft.com/cli/azure/install-azure-cli" -ForegroundColor Red
    exit 1
}

# ── 2. Logged in ──────────────────────────────────────────────────
Write-Host -NoNewline "Checking Azure login... "
try {
    $account = az account show 2>$null | ConvertFrom-Json
    if (-not $account) { throw "Not logged in" }
    Write-Host "OK ($($account.name))" -ForegroundColor Green
} catch {
    Write-Host "FAIL — Not logged in. Run: az login" -ForegroundColor Red
    exit 1
}

# ── 3. Owner role ─────────────────────────────────────────────────
Write-Host -NoNewline "Checking subscription role... "
$upn = $account.user.name
$subscriptionId = $account.id
$ownerCount = (az role assignment list --assignee $upn --scope "/subscriptions/$subscriptionId" `
    --query "[?roleDefinitionName=='Owner'] | length(@)" -o tsv 2>$null)
if ([int]$ownerCount -gt 0) {
    Write-Host "OK (Owner)" -ForegroundColor Green
} else {
    Write-Host "WARN — Owner role not confirmed for $upn. Deployment may fail without Owner." -ForegroundColor Yellow
}

# ── 4. vCPU quota ─────────────────────────────────────────────────
Write-Host -NoNewline "Checking vCPU quota in $Location... "
$usageOutput = az vm list-usage --location $Location -o json 2>$null | ConvertFrom-Json
$esFamily = $usageOutput | Where-Object { $_.localName -match "Standard ESv[56] Family" } | Select-Object -First 1
if ($esFamily) {
    $available = $esFamily.limit - $esFamily.currentValue
    if ($available -ge $RequiredVCPUs) {
        Write-Host "OK ($available vCPUs available, need $RequiredVCPUs)" -ForegroundColor Green
    } else {
        Write-Host "FAIL — Only $available vCPUs available (need $RequiredVCPUs). Request quota increase." -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "WARN — Could not determine quota. Manually check: az vm list-usage --location $Location -o table" -ForegroundColor Yellow
}

# ── 5. Register resource providers ────────────────────────────────
Write-Host ""
Write-Host "Registering required resource providers..."
$providers = @(
    "Microsoft.HybridCompute",
    "Microsoft.GuestConfiguration",
    "Microsoft.HybridConnectivity",
    "Microsoft.AzureStackHCI",
    "Microsoft.Kubernetes",
    "Microsoft.KubernetesConfiguration",
    "Microsoft.ExtendedLocation",
    "Microsoft.ResourceConnector",
    "Microsoft.HybridContainerService",
    "Microsoft.Attestation",
    "Microsoft.Storage",
    "Microsoft.Insights",
    "Microsoft.KeyVault"
)

foreach ($provider in $providers) {
    $state = (az provider show --namespace $provider --query "registrationState" -o tsv 2>$null)
    if ($state -eq "Registered") {
        Write-Host "  ${provider}: Already registered" -ForegroundColor Green
    } else {
        Write-Host -NoNewline "  ${provider}: Registering... "
        az provider register --namespace $provider 2>$null | Out-Null
        Write-Host "Done" -ForegroundColor Green
    }
}

# ── 6. Bicep version ─────────────────────────────────────────────
Write-Host ""
Write-Host -NoNewline "Upgrading Bicep... "
az bicep upgrade 2>$null | Out-Null
$bicepVersion = az bicep version 2>$null
Write-Host "OK ($bicepVersion)" -ForegroundColor Green

# ── 7. HCI Resource Provider SPN ─────────────────────────────────
Write-Host ""
Write-Host -NoNewline "Retrieving Azure Local resource provider object ID... "
$spnId = az ad sp list --display-name "Microsoft.AzureStackHCI Resource Provider" --query "[0].id" -o tsv 2>$null
if ($spnId) {
    Write-Host "OK" -ForegroundColor Green
    Write-Host "  spnProviderId = $spnId"
} else {
    Write-Host "WARN — Could not retrieve. Register Microsoft.AzureStackHCI first." -ForegroundColor Yellow
}

# ── 8. Tenant ID ──────────────────────────────────────────────────
$tenantId = $account.tenantId
Write-Host "  tenantId      = $tenantId"

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " Prerequisites check complete!" -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Copy-Item deploy\main.bicepparam.template deploy\main.bicepparam"
Write-Host "  2. Edit deploy\main.bicepparam with the values above"
Write-Host "  3. Run: .\deploy\deploy.ps1 -ResourceGroup <name> -Location $Location"
