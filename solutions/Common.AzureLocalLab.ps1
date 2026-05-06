Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Banner {
    param([string]$Title)

    Write-Host ('=' * 72) -ForegroundColor Cyan
    Write-Host " $Title" -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor Cyan
    Write-Host ''
}

function Write-Step {
    param(
        [string]$What,
        [string]$Why
    )

    Write-Host "> $What" -ForegroundColor Cyan
    if ($Why) {
        Write-Host "  Why: $Why" -ForegroundColor DarkCyan
    }
}

function Write-Command {
    param(
        [Parameter(Mandatory)][string]$Command,
        [string]$Where = 'Local machine'
    )
    Write-Host "  [$Where] $Command" -ForegroundColor DarkYellow
}

function Write-Info {
    param([string]$Message)
    Write-Host "  $Message" -ForegroundColor Gray
}

function Write-Detail {
    param([string]$Message)
    Write-Host "    $Message" -ForegroundColor DarkGray
}

function Write-Success {
    param([string]$Message)
    Write-Host "  [OK] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "  [WARN] $Message" -ForegroundColor Yellow
}

function Write-Fail {
    param([string]$Message)
    Write-Host "  [ERROR] $Message" -ForegroundColor Red
}

function Assert-Command {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [string]$InstallHint
    )

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        if ($InstallHint) {
            throw "Required command '$Name' was not found. $InstallHint"
        }

        throw "Required command '$Name' was not found in PATH."
    }
}

function Invoke-AzRaw {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [switch]$AllowNotFound,
        [switch]$Silent
    )

    Assert-Command -Name 'az' -InstallHint 'Install Azure CLI and run az login first.'

    $commandText = "az $($Arguments -join ' ')"
    if (-not $Silent) {
        Write-Command -Command $commandText
    }
    $azArguments = @($Arguments)

    if ($azArguments -notcontains '--only-show-errors') {
        $azArguments += '--only-show-errors'
    }

    $output = & az @azArguments 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($output | ForEach-Object { "$_" }) -join "`n"

    if ($exitCode -ne 0) {
        if ($AllowNotFound -and $text -match 'ResourceNotFound|NotFound|could not be found|was not found|No registered resource provider found') {
            return $null
        }

        throw "Azure CLI command failed.`nCommand: $commandText`n$text"
    }

    return $text.Trim()
}

function Invoke-AzJson {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [switch]$AllowNotFound
    )

    $json = Invoke-AzRaw -Arguments ($Arguments + @('-o', 'json')) -AllowNotFound:$AllowNotFound
    if ([string]::IsNullOrWhiteSpace($json)) {
        return $null
    }

    return $json | ConvertFrom-Json -Depth 100
}

function Invoke-AzTsv {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [switch]$AllowNotFound
    )

    $text = Invoke-AzRaw -Arguments ($Arguments + @('-o', 'tsv')) -AllowNotFound:$AllowNotFound
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    return $text.Trim()
}

function Test-AzureContext {
    Assert-Command -Name 'az' -InstallHint 'Install Azure CLI and run az login first.'

    try {
        $account = Invoke-AzJson -Arguments @('account', 'show')
    }
    catch {
        throw 'Azure CLI is not authenticated. Run az login before using these solution scripts.'
    }

    if (-not $account) {
        throw 'Azure CLI did not return an active account. Run az login first.'
    }

    return $account
}

function Ensure-AzExtension {
    param([Parameter(Mandatory)][string]$Name)

    Write-Step -What "Checking Azure CLI extension '$Name'." -Why 'Azure Local and Arc scenarios rely on CLI extensions more than generic Azure commands do.'

    $extensionJson = & az extension show --name $Name --only-show-errors -o json 2>$null
    if ($LASTEXITCODE -eq 0 -and $extensionJson) {
        $extension = $extensionJson | ConvertFrom-Json
        Write-Success "Extension '$Name' is already installed (version $($extension.version))."
        return $extension
    }

    Write-Info "Installing extension '$Name' so the script can keep using Azure CLI end to end."
    $null = Invoke-AzRaw -Arguments @('extension', 'add', '--name', $Name, '--upgrade')
    $extension = Invoke-AzJson -Arguments @('extension', 'show', '--name', $Name)
    Write-Success "Extension '$Name' is ready (version $($extension.version))."
    return $extension
}

function Get-PreferredItem {
    param(
        [object[]]$Items,
        [string[]]$PreferredPatterns = @()
    )

    $materialized = @($Items | Where-Object { $_ })
    if (-not $materialized) {
        return $null
    }

    foreach ($pattern in $PreferredPatterns) {
        $match = $materialized | Where-Object { $_.name -match $pattern } | Select-Object -First 1
        if ($match) {
            return $match
        }
    }

    return $materialized | Select-Object -First 1
}

function Get-AzureLocalContext {
    param([Parameter(Mandatory)][string]$ResourceGroup)

    $account = Test-AzureContext
    $location = Invoke-AzTsv -Arguments @('group', 'show', '--name', $ResourceGroup, '--query', 'location')
    if (-not $location) {
        throw "Resource group '$ResourceGroup' was not found or is inaccessible."
    }

    $clusters = @(Invoke-AzJson -Arguments @('resource', 'list', '-g', $ResourceGroup, '--resource-type', 'Microsoft.AzureStackHCI/clusters'))
    $customLocations = @(Invoke-AzJson -Arguments @('customlocation', 'list', '-g', $ResourceGroup) -AllowNotFound)
    if (-not $customLocations) {
        $customLocations = @(Invoke-AzJson -Arguments @('resource', 'list', '-g', $ResourceGroup, '--resource-type', 'Microsoft.ExtendedLocation/customLocations'))
    }
    $resourceBridges = @(Invoke-AzJson -Arguments @('resource', 'list', '-g', $ResourceGroup, '--resource-type', 'Microsoft.ResourceConnector/appliances'))
    if (-not $resourceBridges) {
        $resourceBridges = @(Invoke-AzJson -Arguments @('resource', 'list', '-g', $ResourceGroup, '--resource-type', 'Microsoft.Appliance/appliances'))
    }
    $workspaces = @(Invoke-AzJson -Arguments @('monitor', 'log-analytics', 'workspace', 'list', '-g', $ResourceGroup))
    $arcServers = @(Invoke-AzJson -Arguments @('resource', 'list', '-g', $ResourceGroup, '--resource-type', 'Microsoft.HybridCompute/machines'))
    $vnets = @(Invoke-AzJson -Arguments @('network', 'vnet', 'list', '-g', $ResourceGroup))
    $nsgs = @(Invoke-AzJson -Arguments @('network', 'nsg', 'list', '-g', $ResourceGroup))
    $natGateways = @(Invoke-AzJson -Arguments @('network', 'nat', 'gateway', 'list', '-g', $ResourceGroup))

    [pscustomobject]@{
        Account = $account
        Location = $location
        Cluster = Get-PreferredItem -Items $clusters -PreferredPatterns @('localbox', 'cluster')
        CustomLocation = Get-PreferredItem -Items $customLocations -PreferredPatterns @('jumpstart-cl', 'jumpstart', '-cl$')
        ResourceBridge = Get-PreferredItem -Items $resourceBridges -PreferredPatterns @('resourcebridge', 'appliance', 'localbox')
        Workspace = Get-PreferredItem -Items $workspaces -PreferredPatterns @('LocalBox', 'Workspace')
        ArcServers = $arcServers
        VNet = Get-PreferredItem -Items $vnets -PreferredPatterns @('LocalBox', 'vnet')
        NetworkSecurityGroups = $nsgs
        NatGateways = $natGateways
    }
}

function Get-NestedAdminCredential {
    param([Parameter(Mandatory)][string]$Password)

    $securePassword = ConvertTo-SecureString $Password -AsPlainText -Force
    return [pscredential]::new('jumpstart\Administrator', $securePassword)
}

function Invoke-LocalBoxCommand {
    param(
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$ScriptText,
        [string]$VmName = 'LocalBox-Client'
    )

    $result = Invoke-AzJson -Arguments @(
        'vm', 'run-command', 'invoke',
        '-g', $ResourceGroup,
        '-n', $VmName,
        '--command-id', 'RunPowerShellScript',
        '--scripts', $ScriptText
    )

    if (-not $result) {
        return ''
    }

    $stdout = (($result.value | Where-Object { $_.code -like '*StdOut*' }).message -join "`n").Trim()
    $stderr = (($result.value | Where-Object { $_.code -like '*StdErr*' }).message -join "`n").Trim()

    if ($stderr) {
        Write-Warn $stderr
    }

    return $stdout
}

function Invoke-NestedHostCommand {
    param(
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)][string]$Password,
        [Parameter(Mandatory)][string]$ScriptText
    )

    $escapedPassword = $Password.Replace("'", "''")
    $nestedScript = @"
`$securePassword = ConvertTo-SecureString '$escapedPassword' -AsPlainText -Force
`$credential = [pscredential]::new('jumpstart\Administrator', `$securePassword)
Invoke-Command -ComputerName '$ComputerName' -Credential `$credential -ScriptBlock {
$ScriptText
}
"@

    return Invoke-LocalBoxCommand -ResourceGroup $ResourceGroup -ScriptText $nestedScript
}

function Wait-Until {
    param(
        [Parameter(Mandatory)][scriptblock]$Condition,
        [Parameter(Mandatory)][string]$Description,
        [int]$TimeoutSeconds = 900,
        [int]$PollSeconds = 15
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $result = & $Condition
        if ($result) {
            return $result
        }

        Start-Sleep -Seconds $PollSeconds
    } while ((Get-Date) -lt $deadline)

    throw "Timed out while waiting for: $Description"
}

function Show-TableFromObjects {
    param(
        [Parameter(Mandatory)][object[]]$InputObject,
        [string[]]$Property
    )

    if (-not $InputObject) {
        Write-Warn 'Nothing to display.'
        return
    }

    $InputObject | Format-Table -Property $Property -AutoSize | Out-String | Write-Host
}
