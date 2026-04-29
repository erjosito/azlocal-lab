#####################################################################
# deploy.ps1 — Deploy LocalBox infrastructure via Azure Bicep
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

param(
    [Parameter(Mandatory)][string]$ResourceGroup,
    [string]$Location = "swedencentral",
    [string]$ParamsFile = "deploy\main.bicepparam",
    [string]$Commit = "main",
    [switch]$NoInteractive
)

$ErrorActionPreference = "Stop"
$JumpstartRepo = "https://github.com/microsoft/azure_arc.git"
$JumpstartDir = "azure_arc"
$BicepPath = "azure_jumpstart_localbox\bicep"

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " LocalBox Deployment"
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " Resource Group : $ResourceGroup"
Write-Host " Location       : $Location"
Write-Host " Git ref        : $Commit"
Write-Host "============================================="
Write-Host ""

# ── Helper functions ──────────────────────────────────────────────
function Prompt-WithDefault {
    param([string]$Message, [string]$Default)
    if ($Default) {
        $input = Read-Host "$Message [$Default]"
        if ([string]::IsNullOrWhiteSpace($input)) { return $Default }
        return $input
    } else {
        return Read-Host $Message
    }
}

function Prompt-YesNo {
    param([string]$Message, [string]$Default = "N")
    $input = Read-Host "$Message [$Default]"
    if ([string]::IsNullOrWhiteSpace($input)) { $input = $Default }
    if ($input -match '^[Yy]') { return "true" } else { return "false" }
}

function Prompt-SecurePassword {
    param([string]$Message)
    while ($true) {
        $secPass = Read-Host $Message -AsSecureString
        $password = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secPass))

        if ($password.Length -lt 12) {
            Write-Host "  Password must be at least 12 characters." -ForegroundColor Yellow
            continue
        }
        if ($password.Contains('$')) {
            Write-Host "  Password must NOT contain the `$ symbol (breaks logon scripts)." -ForegroundColor Yellow
            continue
        }
        if (-not ($password -cmatch '[A-Z]' -and $password -cmatch '[a-z]' -and $password -match '[0-9]')) {
            Write-Host "  Password must contain uppercase, lowercase, and a digit." -ForegroundColor Yellow
            continue
        }
        # Confirm
        $secConfirm = Read-Host "  Confirm password" -AsSecureString
        $confirm = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secConfirm))
        if ($password -ne $confirm) {
            Write-Host "  Passwords do not match. Try again." -ForegroundColor Yellow
            continue
        }
        return $password
    }
}

# ── Generate parameters interactively ─────────────────────────────
$needsGeneration = $true

if ((Test-Path $ParamsFile) -and -not ((Get-Content $ParamsFile -Raw) -match '<your-')) {
    Write-Host "Found existing parameters file: $ParamsFile"
    Write-Host "Using it as-is. Delete it to re-run interactive setup."
    Write-Host ""
    $needsGeneration = $false
}

if ($needsGeneration -and -not $NoInteractive) {
    Write-Host "--- Auto-detecting parameters from your Azure environment ---" -ForegroundColor Cyan
    Write-Host ""

    # Auto-retrieve: tenant ID
    Write-Host "  Retrieving tenant ID..."
    $tenantId = az account show --query tenantId -o tsv 2>$null
    if ([string]::IsNullOrWhiteSpace($tenantId)) {
        Write-Host "  ERROR: Could not retrieve tenant ID. Are you logged in? Run: az login" -ForegroundColor Red
        exit 1
    }
    Write-Host "  $(([char]0x2713)) Tenant ID: $tenantId" -ForegroundColor Green

    # Auto-retrieve: subscription
    $subscriptionName = az account show --query name -o tsv 2>$null
    $subscriptionId = az account show --query id -o tsv 2>$null
    Write-Host "  $(([char]0x2713)) Subscription: $subscriptionName ($subscriptionId)" -ForegroundColor Green

    # Auto-retrieve: spnProviderId
    Write-Host "  Retrieving AzureStackHCI Resource Provider service principal..."
    $spnProviderId = az ad sp list --display-name "Microsoft.AzureStackHCI Resource Provider" `
        --query "[0].id" -o tsv 2>$null
    if ([string]::IsNullOrWhiteSpace($spnProviderId)) {
        Write-Host "  Warning: Could not auto-detect spnProviderId." -ForegroundColor Yellow
        Write-Host "    This is the Object ID of the 'Microsoft.AzureStackHCI Resource Provider' SP."
        $spnProviderId = Prompt-WithDefault "  Enter spnProviderId manually" ""
        if ([string]::IsNullOrWhiteSpace($spnProviderId)) {
            Write-Host "  ERROR: spnProviderId is required." -ForegroundColor Red
            exit 1
        }
    } else {
        Write-Host "  $(([char]0x2713)) spnProviderId: $spnProviderId" -ForegroundColor Green
    }

    Write-Host ""
    Write-Host "--- Interactive configuration ---" -ForegroundColor Cyan
    Write-Host "Press Enter to accept defaults shown in [brackets]."
    Write-Host ""

    # Credentials
    $adminUser = Prompt-WithDefault "Windows admin username" "arcdemo"
    Write-Host ""
    Write-Host "Choose a password for the VM (min 12 chars, upper+lower+digit, no `$ symbol):"
    $adminPassword = Prompt-SecurePassword "  Windows admin password"
    Write-Host ""

    # VM options
    Write-Host "--- VM Configuration ---" -ForegroundColor Cyan
    $vmSize = Prompt-WithDefault "VM size" "Standard_E32s_v6"
    $useSpot = Prompt-YesNo "Enable Azure Spot pricing? (cheaper but risk of eviction)" "N"
    Write-Host ""

    # Deployment options
    Write-Host "--- Deployment Options ---" -ForegroundColor Cyan
    $deployBastion = Prompt-YesNo "Deploy Azure Bastion? (adds ~`$140/month)" "N"
    $autoDeployCluster = Prompt-YesNo "Auto-deploy the Azure Local cluster resource?" "Y"
    $autoUpgradeCluster = Prompt-YesNo "Auto-upgrade the cluster resource?" "N"
    $workspaceName = Prompt-WithDefault "Log Analytics workspace name" "LocalBox-Workspace"
    Write-Host ""

    # Azure Local region
    Write-Host "--- Azure Local Instance Region ---" -ForegroundColor Cyan
    Write-Host "  The Azure Local cluster registers in a separate region."
    Write-Host "  Valid: australiaeast, southcentralus, eastus, westeurope,"
    Write-Host "         southeastasia, canadacentral, japaneast, centralindia"
    $localInstanceLocation = Prompt-WithDefault "Azure Local instance location" "westeurope"
    Write-Host ""

    # Tags
    $governTags = Prompt-YesNo "Enable resource tag governance? (Microsoft-internal tenants only)" "N"
    Write-Host ""

    # ── Generate parameters file ─────────────────────────────────────
    Write-Host "--- Generating parameters file ---" -ForegroundColor Cyan
    $paramsContent = @"
using 'main.bicep'

// Auto-detected parameters
param tenantId = '$tenantId'
param spnProviderId = '$spnProviderId'

// Credentials
param windowsAdminUsername = '$adminUser'
param windowsAdminPassword = '$adminPassword'

// Deployment options
param logAnalyticsWorkspaceName = '$workspaceName'
param deployBastion = $deployBastion
param autoDeployClusterResource = $autoDeployCluster
param autoUpgradeClusterResource = $autoUpgradeCluster

// VM configuration
param vmSize = '$vmSize'
param enableAzureSpotPricing = $useSpot

// Azure Local instance region
param azureLocalInstanceLocation = '$localInstanceLocation'

// Tags
param governResourceTags = $governTags
"@
    # Ensure deploy directory exists
    $paramsDir = Split-Path $ParamsFile -Parent
    if ($paramsDir -and -not (Test-Path $paramsDir)) {
        New-Item -ItemType Directory -Path $paramsDir -Force | Out-Null
    }
    Set-Content -Path $ParamsFile -Value $paramsContent -Encoding UTF8
    Write-Host "  $(([char]0x2713)) Parameters written to: $ParamsFile" -ForegroundColor Green
    Write-Host ""

    Write-Host "--- Summary ---" -ForegroundColor Cyan
    Write-Host "  Tenant:        $tenantId"
    Write-Host "  SPN Provider:  $spnProviderId"
    Write-Host "  Admin user:    $adminUser"
    Write-Host "  VM size:       $vmSize"
    Write-Host "  Spot pricing:  $useSpot"
    Write-Host "  Bastion:       $deployBastion"
    Write-Host "  Auto-deploy:   $autoDeployCluster"
    Write-Host "  Instance loc:  $localInstanceLocation"
    Write-Host ""

    # Confirm before proceeding
    $confirm = Read-Host "Proceed with deployment? [Y/n]"
    if ([string]::IsNullOrWhiteSpace($confirm)) { $confirm = "Y" }
    if ($confirm -notmatch '^[Yy]') {
        Write-Host "Deployment cancelled. Your parameters are saved in $ParamsFile"
        Write-Host "Re-run this script to deploy without re-entering values."
        exit 0
    }
}
elseif ($needsGeneration) {
    # Non-interactive mode
    if (-not (Test-Path $ParamsFile)) {
        Write-Host "ERROR: Parameters file not found: $ParamsFile" -ForegroundColor Red
        Write-Host "Run without -NoInteractive to generate it, or create it manually."
        exit 1
    }
    if ((Get-Content $ParamsFile -Raw) -match '<your-') {
        Write-Host "ERROR: Parameters file still contains placeholder values." -ForegroundColor Red
        exit 1
    }
}

# ── Clone Jumpstart repo ─────────────────────────────────────────
Write-Host ""
Write-Host "Cloning Jumpstart repository..."
if (Test-Path $JumpstartDir) {
    Write-Host "  Directory $JumpstartDir already exists, pulling latest..."
    Push-Location $JumpstartDir
    git fetch origin
    git checkout $Commit
    Pop-Location
} else {
    git clone --depth 1 $JumpstartRepo $JumpstartDir
    Push-Location $JumpstartDir
    git checkout $Commit
    Pop-Location
}

# Validate expected Bicep files exist
$bicepFile = Join-Path $JumpstartDir $BicepPath "main.bicep"
if (-not (Test-Path $bicepFile)) {
    Write-Host "ERROR: Expected Bicep file not found at $bicepFile" -ForegroundColor Red
    Write-Host "The Jumpstart repo structure may have changed."
    exit 1
}

# ── Create resource group ─────────────────────────────────────────
Write-Host ""
Write-Host "Creating resource group '$ResourceGroup' in '$Location'..."
az group create --name $ResourceGroup --location $Location --output none

# ── Deploy Bicep template ─────────────────────────────────────────
Write-Host ""
Write-Host "Deploying LocalBox infrastructure (this takes ~30 minutes)..."
Write-Host "Starting at $(Get-Date -Format 'HH:mm:ss')"
Write-Host ""

# Copy params file next to main.bicep for the deployment
$destParams = Join-Path $JumpstartDir $BicepPath "main.bicepparam"
Copy-Item $ParamsFile $destParams -Force

az deployment group create `
    --resource-group $ResourceGroup `
    --template-file $bicepFile `
    --parameters $destParams `
    --verbose

if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Deployment failed. Check the output above for details." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " Infrastructure Deployment Complete!" -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "IMPORTANT: This was Phase 1 only. The next steps are:"
Write-Host ""
Write-Host "  1. Connect to the LocalBox-Client VM via RDP or Bastion"
Write-Host "     (You may need to add an NSG rule for port 3389 first)"
Write-Host ""
Write-Host "  2. A PowerShell script will run automatically inside the VM."
Write-Host "     This takes approximately 4-5 HOURS to complete."
Write-Host "     Do NOT close the PowerShell window."
Write-Host ""
Write-Host "  3. Once the script finishes, verify in Azure Portal that"
Write-Host "     AzLHOST1 and AzLHOST2 appear as Arc-enabled servers."
Write-Host ""
Write-Host "  4. Start the exercises: exercises\00-explore-architecture.md"
Write-Host ""
Write-Host "To check your VM's public IP:"
Write-Host "  az vm show -g $ResourceGroup -n LocalBox-Client -d --query publicIps -o tsv"
Write-Host ""
Write-Host "To monitor costs:"
Write-Host "  .\scripts\estimate-cost.ps1"
Write-Host ""
Write-Host "To stop and save money when not using:"
Write-Host "  .\scripts\stop-environment.ps1 -ResourceGroup $ResourceGroup"
