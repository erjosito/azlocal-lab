#####################################################################
# check-upstream.ps1 — Check if local deployment artifacts match upstream
#
# Compares the locally cloned azure_arc commit with the latest commit
# that touches azure_jumpstart_localbox in the upstream repository.
# If they differ, offers to update the local clone.
#
# Usage:
#   .\scripts\check-upstream.ps1
#   .\scripts\check-upstream.ps1 -Update
#   .\scripts\check-upstream.ps1 -ShowChanges
#####################################################################

param(
    [switch]$Update,
    [switch]$ShowChanges,
    [string]$LocalClonePath = "azure_arc"
)

$ErrorActionPreference = "Stop"
$UpstreamRepo = "https://github.com/microsoft/azure_arc.git"
$UpstreamApiBase = "https://api.github.com/repos/microsoft/azure_arc"
$LocalBoxPath = "azure_jumpstart_localbox"
$MarkerFile = ".upstream-commit"

Write-Host "=============================================" -ForegroundColor Cyan
Write-Host " Upstream Sync Check"
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""

# ── Get latest upstream commit for LocalBox ──────────────────────
Write-Host "Checking latest upstream commit for $LocalBoxPath..."
try {
    $headers = @{ "Accept" = "application/vnd.github.v3+json" }
    $commits = Invoke-RestMethod -Uri "$UpstreamApiBase/commits?path=$LocalBoxPath&per_page=1" -Headers $headers
    $latestUpstream = $commits[0]
    $latestSha = $latestUpstream.sha
    $latestDate = $latestUpstream.commit.committer.date
    $latestMessage = ($latestUpstream.commit.message -split "`n")[0]

    Write-Host "  Latest upstream: $($latestSha.Substring(0,8)) ($latestDate)" -ForegroundColor Green
    Write-Host "  Message: $latestMessage"
} catch {
    Write-Host "  ERROR: Could not reach GitHub API." -ForegroundColor Red
    Write-Host "  $_"
    Write-Host ""
    Write-Host "Falling back to git ls-remote..."
    $remoteHead = git ls-remote $UpstreamRepo HEAD 2>$null
    if ($remoteHead) {
        Write-Host "  Remote HEAD: $($remoteHead.Substring(0,8))"
        Write-Host "  (Cannot determine LocalBox-specific commit without API access)"
    }
    exit 1
}

# ── Get local state ──────────────────────────────────────────────
Write-Host ""
$localSha = $null

if (Test-Path $MarkerFile) {
    $localSha = (Get-Content $MarkerFile -Raw).Trim()
    Write-Host "Local marker ($MarkerFile): $($localSha.Substring(0,8))"
}

if (Test-Path $LocalClonePath) {
    Push-Location $LocalClonePath
    $cloneSha = git rev-parse HEAD 2>$null
    Pop-Location
    if ($cloneSha) {
        Write-Host "Local clone HEAD: $($cloneSha.Substring(0,8))"
        if (-not $localSha) { $localSha = $cloneSha }
    }
} else {
    Write-Host "No local clone found at '$LocalClonePath'."
}

# ── Compare ──────────────────────────────────────────────────────
Write-Host ""
if (-not $localSha) {
    Write-Host "STATUS: No local artifacts found." -ForegroundColor Yellow
    Write-Host "  Run deploy.ps1 to clone the upstream repo, or use -Update to fetch now."
    $needsUpdate = $true
} elseif ($localSha -eq $latestSha) {
    Write-Host "STATUS: Up to date!" -ForegroundColor Green
    Write-Host "  Local and upstream both at $($latestSha.Substring(0,8))."
    $needsUpdate = $false
} else {
    Write-Host "STATUS: Out of date!" -ForegroundColor Yellow
    Write-Host "  Local:    $($localSha.Substring(0,8))"
    Write-Host "  Upstream: $($latestSha.Substring(0,8))"
    $needsUpdate = $true

    if ($ShowChanges) {
        Write-Host ""
        Write-Host "Changes since your version:" -ForegroundColor Cyan
        try {
            $comparison = Invoke-RestMethod -Uri "$UpstreamApiBase/compare/$($localSha.Substring(0,8))...$($latestSha.Substring(0,8))" -Headers $headers
            Write-Host "  Commits: $($comparison.total_commits)"
            foreach ($c in $comparison.commits) {
                $msg = ($c.commit.message -split "`n")[0]
                Write-Host "    $($c.sha.Substring(0,8)) $msg"
            }
            Write-Host ""
            Write-Host "  Files changed in $LocalBoxPath`:"
            foreach ($f in $comparison.files) {
                if ($f.filename -like "$LocalBoxPath*") {
                    Write-Host "    $($f.status): $($f.filename)"
                }
            }
        } catch {
            Write-Host "  Could not retrieve comparison: $_" -ForegroundColor Yellow
        }
    }
}

# ── Update if requested ──────────────────────────────────────────
if ($needsUpdate -and $Update) {
    Write-Host ""
    Write-Host "Updating local clone..." -ForegroundColor Cyan

    if (Test-Path $LocalClonePath) {
        Push-Location $LocalClonePath
        git fetch origin
        git checkout $latestSha
        Pop-Location
    } else {
        git clone --depth 50 $UpstreamRepo $LocalClonePath
        Push-Location $LocalClonePath
        git checkout $latestSha
        Pop-Location
    }

    # Save marker
    Set-Content -Path $MarkerFile -Value $latestSha -Encoding UTF8
    Write-Host ""
    Write-Host "Updated to $($latestSha.Substring(0,8))." -ForegroundColor Green
    Write-Host "Marker saved to $MarkerFile."

    # Check for key changes
    Write-Host ""
    Write-Host "Key artifact versions:" -ForegroundColor Cyan
    $clusterScript = Join-Path $LocalClonePath "$LocalBoxPath\artifacts\PowerShell\New-LocalBoxCluster.ps1"
    if (Test-Path $clusterScript) {
        $vhdLines = Get-Content $clusterScript | Select-String "AzLocal\d+" | ForEach-Object { $_.Matches.Value } | Select-Object -Unique
        if ($vhdLines) {
            Write-Host "  VHD image version: $($vhdLines -join ', ')"
        }
    }
} elseif ($needsUpdate -and -not $Update) {
    Write-Host ""
    Write-Host "To update, run:" -ForegroundColor Cyan
    Write-Host "  .\scripts\check-upstream.ps1 -Update"
    Write-Host ""
    Write-Host "To see what changed:" -ForegroundColor Cyan
    Write-Host "  .\scripts\check-upstream.ps1 -ShowChanges"
}
