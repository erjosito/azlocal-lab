[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroup
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Banner {
    param([string]$Title)

    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor Cyan
    Write-Host " $Title" -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor Cyan
}

function Write-Step {
    param(
        [string]$What,
        [string]$Why
    )

    Write-Host ''
    Write-Host "WHAT: $What" -ForegroundColor Yellow
    Write-Host " WHY: $Why" -ForegroundColor DarkYellow
}

function Write-Info {
    param(
        [string]$Message,
        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )

    Write-Host $Message -ForegroundColor $Color
}

function Invoke-AzCliText {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,
        [switch]$AllowFailure
    )

    $output = & az @Arguments --only-show-errors 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($output | Out-String).Trim()

    if (-not $AllowFailure -and $exitCode -ne 0) {
        throw "Azure CLI command failed: az $($Arguments -join ' ')`n$text"
    }

    return [PSCustomObject]@{
        ExitCode = $exitCode
        Text     = $text
    }
}

function Invoke-AzCliJson {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,
        [switch]$AllowFailure
    )

    $result = Invoke-AzCliText -Arguments $Arguments -AllowFailure:$AllowFailure
    if ($result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($result.Text)) {
        return $null
    }

    return $result.Text | ConvertFrom-Json -Depth 100
}

function Test-AzLogin {
    $account = Invoke-AzCliJson -Arguments @('account', 'show', '-o', 'json') -AllowFailure
    return $null -ne $account
}

function Get-ResourceGroup {
    param([string]$Name)

    $group = Invoke-AzCliJson -Arguments @('group', 'show', '--name', $Name, '-o', 'json') -AllowFailure
    if (-not $group) {
        throw "Resource group '$Name' was not found."
    }

    return $group
}

function Get-PolicyDefinition {
    param([string]$DisplayName)

    $definition = Invoke-AzCliJson -Arguments @(
        'policy', 'definition', 'list',
        '--query', "[?policyType=='BuiltIn' && displayName=='$DisplayName'] | [0]",
        '-o', 'json'
    )

    if (-not $definition) {
        throw "Could not find built-in policy definition '$DisplayName'."
    }

    return $definition
}

function Get-NestedPropertyValue {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string[]]$Path
    )

    $current = $Object
    foreach ($segment in $Path) {
        if ($null -eq $current) {
            return $null
        }

        $property = $current.PSObject.Properties[$segment]
        if (-not $property) {
            return $null
        }

        $current = $property.Value
    }

    return $current
}

function Show-Table {
    param([Parameter(Mandatory)][object[]]$Rows)

    if (-not $Rows -or $Rows.Count -eq 0) {
        Write-Info 'No rows to display.' DarkGray
        return
    }

    $Rows | Format-Table -AutoSize -Wrap | Out-String | Write-Host
}

try {
    Write-Banner 'Exercise 05 - Security and Governance'

    Write-Step 'Validate Azure context and target resource group.' 'Governance commands are scoped, so we first confirm we are authenticated and pointing at the right lab resource group.'
    if (-not (Test-AzLogin)) {
        throw 'Azure CLI is not logged in. Run az login first.'
    }

    $resourceGroupObject = Get-ResourceGroup -Name $ResourceGroup
    $resourceGroupId = [string]$resourceGroupObject.id
    Write-Info "Using resource group: $($resourceGroupObject.name)" Green
    Write-Info "Scope             : $resourceGroupId" Green

    Write-Step 'Show current policy assignments on the resource group.' 'Policy assignments tell us which governance controls are already inherited or explicitly applied before we change anything.'
    $assignments = @(Invoke-AzCliJson -Arguments @('policy', 'assignment', 'list', '--resource-group', $ResourceGroup, '-o', 'json'))
    if ($assignments.Count -eq 0) {
        Write-Info 'No policy assignments were found directly on this resource group.' Yellow
    } else {
        $assignmentTable = $assignments |
            Sort-Object displayName |
            Select-Object @{n='DisplayName';e={$_.displayName}}, @{n='EnforcementMode';e={$_.enforcementMode}}, @{n='Scope';e={$_.scope}}
        Show-Table -Rows $assignmentTable
    }

    Write-Step 'Assign a didactical built-in policy if our lab assignment is not already present.' 'Using a simple built-in policy keeps the exercise safe and repeatable while still demonstrating how Azure Policy extends to hybrid resources.'
    $policyDisplayName = 'Require a tag on resources'
    $policyDefinition = Get-PolicyDefinition -DisplayName $policyDisplayName
    $assignmentName = 'lab-require-environment-tag'
    $existingAssignment = $assignments | Where-Object { $_.name -eq $assignmentName } | Select-Object -First 1
    if ($existingAssignment) {
        Write-Info "Policy assignment '$assignmentName' already exists. Skipping creation to keep the script idempotent." Green
    } else {
        $paramsObject = @{ tagName = @{ value = 'environment' } }
        $paramsJson = $paramsObject | ConvertTo-Json -Depth 5 -Compress
        Invoke-AzCliText -Arguments @(
            'policy', 'assignment', 'create',
            '--name', $assignmentName,
            '--display-name', 'Lab - Require environment tag',
            '--policy', $policyDefinition.name,
            '--params', $paramsJson,
            '--scope', $resourceGroupId,
            '-o', 'json'
        ) | Out-Null
        Write-Info "Assigned built-in policy '$policyDisplayName' with tag parameter 'environment'." Green
        Write-Info 'Lesson learned: choosing a low-risk built-in policy makes demos safer than using deny-style policies that might block the lab unexpectedly.' DarkCyan
    }

    Write-Step 'Show Microsoft Defender for Cloud recommendations if they are available.' 'Defender gives security posture insight across Azure, Arc-enabled servers, Kubernetes, and Azure Local resources from one plane.'
    $assessments = @(Invoke-AzCliJson -Arguments @('security', 'assessment', 'list', '-o', 'json') -AllowFailure)
    if (-not $assessments -or $assessments.Count -eq 0) {
        Write-Info 'No Defender for Cloud assessments were returned. Defender may not be enabled in this subscription yet.' Yellow
    } else {
        $matchingAssessments = foreach ($assessment in $assessments) {
            $resourceId = Get-NestedPropertyValue -Object $assessment -Path @('resourceDetails', 'id')
            if (-not $resourceId) {
                $resourceId = Get-NestedPropertyValue -Object $assessment -Path @('resourceDetails', 'Id')
            }
            if (-not $resourceId) {
                $resourceId = Get-NestedPropertyValue -Object $assessment -Path @('id')
            }

            if ($resourceId -and $resourceId -like "*/resourceGroups/$ResourceGroup/*") {
                [PSCustomObject]@{
                    Recommendation = ([string](Get-NestedPropertyValue -Object $assessment -Path @('displayName')))
                    Status         = ([string](Get-NestedPropertyValue -Object $assessment -Path @('status', 'code')))
                    Resource       = [string]$resourceId
                }
            }
        }

        $matchingAssessments = @($matchingAssessments | Where-Object { $_ })
        if ($matchingAssessments.Count -eq 0) {
            Write-Info 'No Defender recommendations were found specifically for this resource group.' Yellow
        } else {
            Show-Table -Rows ($matchingAssessments | Sort-Object Recommendation)
        }
    }

    Write-Step 'Explain the Azure Local RBAC model.' 'Azure Local has two identity planes: Azure RBAC for the control plane, and local OS credentials for host or guest sign-in.'
    Write-Info 'Azure RBAC controls who can create, modify, and inspect Azure resources such as the Azure Local cluster, Arc servers, AKS, and policies.' Cyan
    Write-Info 'Local Windows / AD credentials still control who can log on to the underlying hosts, VMs, and operating systems.' Cyan
    Write-Info 'Lesson learned: Azure Contributor does NOT automatically grant RDP or host admin rights. Hybrid operations always have both a cloud control plane and a local data plane.' DarkCyan

    Write-Step 'Show role assignments on the resource group.' 'Role assignments reveal who can operate the lab from Azure and whether permissions are inherited from higher scopes.'
    $roleAssignments = @(Invoke-AzCliJson -Arguments @(
        'role', 'assignment', 'list',
        '--scope', $resourceGroupId,
        '--include-inherited',
        '--all',
        '--fill-principal-name', 'false',
        '-o', 'json'
    ))
    if ($roleAssignments.Count -eq 0) {
        Write-Info 'No role assignments were returned for this scope.' Yellow
    } else {
        $roleTable = $roleAssignments |
            Sort-Object roleDefinitionName, principalType |
            Select-Object @{n='Role';e={$_.roleDefinitionName}}, @{n='PrincipalType';e={$_.principalType}}, @{n='Principal';e={if ($_.principalName) { $_.principalName } else { $_.principalId }}}, @{n='Scope';e={$_.scope}}
        Show-Table -Rows $roleTable
    }

    Write-Step 'Demonstrate compliance summarization with az policy state summarize.' 'The summary shows whether the resource group is compliant right now, which is exactly how operators validate policy impact after an assignment.'
    $summaryText = Invoke-AzCliText -Arguments @('policy', 'state', 'summarize', '--resource-group', $ResourceGroup, '-o', 'json')
    Write-Info 'Compliance summary JSON:' Green
    Write-Host $summaryText.Text
    Write-Info 'Lesson learned: policy evaluation is not always instantaneous. After a new assignment, allow time for compliance scanning before expecting final results.' DarkCyan

    Write-Banner 'Exercise 05 completed'
    Write-Info 'Security and governance walkthrough finished successfully.' Green
} catch {
    Write-Host ''
    Write-Host 'Exercise 05 failed.' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    throw
}
