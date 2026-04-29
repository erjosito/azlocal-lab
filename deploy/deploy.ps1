#####################################################################
# deploy.ps1 — Deploy LocalBox infrastructure via Azure Bicep
#
# This script deploys the Azure infrastructure (VM, networking, etc).
# After completion, the LocalBox-Client VM runs automated setup that
# takes 4-5 hours to finish configuring the nested Azure Local cluster.
#####################################################################

param(
    [Parameter(Mandatory)][string]$ResourceGroup,
    [string]$Location = "swedencentral",
    [string]$ParamsFile = "deploy\main.bicepparam",
    [string]$Commit = "main"
)

$JumpstartRepo = "https://github.com/microsoft/azure_arc.git"
$JumpstartDir = "azure_arc"
$BicepPath = "azure_jumpstart_localbox\bicep"

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " LocalBox Deployment"
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " Resource Group : $ResourceGroup"
Write-Host " Location       : $Location"
Write-Host " Parameters     : $ParamsFile"
Write-Host " Git ref        : $Commit"
Write-Host "============================================="
Write-Host ""

# ── Validate parameters file exists ──────────────────────────────
if (-not (Test-Path $ParamsFile)) {
    Write-Host "ERROR: Parameters file not found: $ParamsFile" -ForegroundColor Red
    Write-Host "Run: Copy-Item deploy\main.bicepparam.template deploy\main.bicepparam"
    Write-Host "Then edit it with your values."
    exit 1
}

# Check for placeholder values
if ((Get-Content $ParamsFile -Raw) -match '<your-') {
    Write-Host "ERROR: Parameters file still contains placeholder values." -ForegroundColor Red
    Write-Host "Edit $ParamsFile and replace all <your-...> placeholders."
    exit 1
}

# ── Clone Jumpstart repo ─────────────────────────────────────────
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
Write-Host " Infrastructure Deployment Complete!"
Write-Host "=============================================" -ForegroundColor Green
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
