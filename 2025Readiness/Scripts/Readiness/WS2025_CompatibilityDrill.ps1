<#
.SYNOPSIS
    Compatibility drill for Windows Server 2025 readiness findings.

.DESCRIPTION
    Reads the JSON output from WS2025_ProductionReadiness.ps1 and performs a
    temporary break-test drill that simulates selected WS2025 behavior changes.

    Supported command modes:
    - Plan: show what would be changed (no system changes)
    - Break: apply only changes backed by confirmed-use findings
    - BreakEverything / Go / ScreamTest: apply confirmed-use + config-only items
    - Revert / Undo / Restore: restore the latest saved drill state

    By default, high-risk auth policy changes (LmCompatibilityLevel=5) are NOT
    applied unless -IncludeAuthPolicy is supplied.

    This script is intentionally separate from readiness assessment logic.

.PARAMETER InputJson
    Path to WS2025 readiness JSON output.

.PARAMETER Command
    One of: Plan, Break, BreakEverything, Go, ScreamTest, Revert, Undo, Restore.

.PARAMETER StatePath
    Optional explicit path for drill state file.
    - Break modes: write state to this path
    - Revert mode: read state from this path

.PARAMETER IncludeAuthPolicy
    Allow local LmCompatibilityLevel changes as part of drill actions.
    This can impact authentication behavior immediately.

.PARAMETER Force
    Required to apply high-risk actions (currently: auth policy).

.EXAMPLE
    .\WS2025_CompatibilityDrill.ps1 C:\Reports\WS2025_ProductionReadiness_SERVER01.json Plan

.EXAMPLE
    .\WS2025_CompatibilityDrill.ps1 C:\Reports\WS2025_ProductionReadiness_SERVER01.json Break

.EXAMPLE
    .\WS2025_CompatibilityDrill.ps1 C:\Reports\WS2025_ProductionReadiness_SERVER01.json BreakEverything -IncludeAuthPolicy -Force

.EXAMPLE
    .\WS2025_CompatibilityDrill.ps1 C:\Reports\WS2025_ProductionReadiness_SERVER01.json Revert
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$InputJson,

    [Parameter(Mandatory = $true, Position = 1)]
    [string]$Command,

    [string]$StatePath,

    [switch]$IncludeAuthPolicy,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Info {
    param([string]$Text)
    Write-Host "[INFO] $Text" -ForegroundColor Cyan
}

function Write-Warn {
    param([string]$Text)
    Write-Host "[WARN] $Text" -ForegroundColor Yellow
}

function Write-Ok {
    param([string]$Text)
    Write-Host "[OK]   $Text" -ForegroundColor Green
}

function Write-Err {
    param([string]$Text)
    Write-Host "[ERR]  $Text" -ForegroundColor Red
}

function Test-IsAdministrator {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Normalize-Command {
    param([Parameter(Mandatory = $true)][string]$Raw)

    $value = $Raw.Trim().ToLowerInvariant()
    switch ($value) {
        'plan' { return [PSCustomObject]@{ Mode = 'Plan'; IncludeConfigOnly = $false } }
        'whatif' { return [PSCustomObject]@{ Mode = 'Plan'; IncludeConfigOnly = $false } }
        'dryrun' { return [PSCustomObject]@{ Mode = 'Plan'; IncludeConfigOnly = $false } }

        'break' { return [PSCustomObject]@{ Mode = 'Break'; IncludeConfigOnly = $false } }

        'go' { return [PSCustomObject]@{ Mode = 'Break'; IncludeConfigOnly = $true } }
        'breakall' { return [PSCustomObject]@{ Mode = 'Break'; IncludeConfigOnly = $true } }
        'breakeverything' { return [PSCustomObject]@{ Mode = 'Break'; IncludeConfigOnly = $true } }
        'screamtest' { return [PSCustomObject]@{ Mode = 'Break'; IncludeConfigOnly = $true } }

        'revert' { return [PSCustomObject]@{ Mode = 'Revert'; IncludeConfigOnly = $false } }
        'undo' { return [PSCustomObject]@{ Mode = 'Revert'; IncludeConfigOnly = $false } }
        'restore' { return [PSCustomObject]@{ Mode = 'Revert'; IncludeConfigOnly = $false } }

        default { throw "Unsupported command '$Raw'. Use Plan, Break, BreakEverything, Go, ScreamTest, Revert, Undo, or Restore." }
    }
}

function Read-Findings {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Input JSON not found: $Path"
    }

    $content = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($content)) {
        throw "Input JSON is empty: $Path"
    }

    $parsed = $content | ConvertFrom-Json -ErrorAction Stop

    if ($parsed -is [System.Array]) {
        return ,@($parsed)
    }

    return ,@($parsed)
}

function Find-Rows {
    param(
        [Parameter(Mandatory = $true)][object[]]$Rows,
        [Parameter(Mandatory = $true)][string]$CheckRegex,
        [string[]]$Statuses
    )

    return @(
        $Rows | Where-Object {
            ([string]$_.Check -match $CheckRegex) -and (
                -not $Statuses -or $Statuses.Count -eq 0 -or ($Statuses -contains [string]$_.Status)
            )
        }
    )
}

function Get-RowEvidenceSummary {
    param([Parameter(Mandatory = $true)][object[]]$Rows)

    $lines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($row in ($Rows | Select-Object -First 4)) {
        $status = [string]$row.Status
        $check = [string]$row.Check
        $evidence = [string]$row.Evidence
        if ([string]::IsNullOrWhiteSpace($evidence)) {
            $evidence = [string]$row.Detail
        }
        $lines.Add(("$check ($status): $evidence"))
    }
    return ($lines -join ' | ')
}

function Get-RegistryValueState {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $exists = Test-Path -LiteralPath $Path
    $valueExists = $false
    $value = $null

    if ($exists) {
        try {
            $item = Get-ItemProperty -LiteralPath $Path -ErrorAction Stop
            if ($null -ne $item.PSObject.Properties[$Name]) {
                $valueExists = $true
                $value = $item.$Name
            }
        } catch {
        }
    }

    return [PSCustomObject]@{
        Path = $Path
        Name = $Name
        KeyExisted = $exists
        ValueExisted = $valueExists
        Value = $value
    }
}

function Invoke-ActionDisableSmb1 {
    if (-not (Get-Command -Name Get-SmbServerConfiguration -ErrorAction SilentlyContinue)) {
        throw 'SMB cmdlets not available on this host.'
    }

    $config = Get-SmbServerConfiguration -ErrorAction Stop
    $pre = [PSCustomObject]@{
        EnableSMB1Protocol = [bool]$config.EnableSMB1Protocol
    }

    if (-not $pre.EnableSMB1Protocol) {
        return [PSCustomObject]@{ Changed = $false; PreState = $pre; Note = 'SMB1 was already disabled.' }
    }

    Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force -Confirm:$false -ErrorAction Stop
    return [PSCustomObject]@{ Changed = $true; PreState = $pre; Note = 'SMB1 was disabled for drill.' }
}

function Invoke-RevertDisableSmb1 {
    param([Parameter(Mandatory = $true)][psobject]$PreState)

    if (-not (Get-Command -Name Set-SmbServerConfiguration -ErrorAction SilentlyContinue)) {
        throw 'SMB cmdlets not available on this host for revert.'
    }

    Set-SmbServerConfiguration -EnableSMB1Protocol ([bool]$PreState.EnableSMB1Protocol) -Force -Confirm:$false -ErrorAction Stop
}

function Invoke-ActionDisableLegacyTls {
    $base = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols'
    $protocols = @('TLS 1.0', 'TLS 1.1', 'SSL 3.0', 'SSL 2.0')
    $sides = @('Client', 'Server')

    $entries = New-Object 'System.Collections.Generic.List[object]'
    $changed = $false

    foreach ($protocol in $protocols) {
        foreach ($side in $sides) {
            $path = Join-Path -Path $base -ChildPath ("{0}\{1}" -f $protocol, $side)
            $enabledState = Get-RegistryValueState -Path $path -Name 'Enabled'
            $disabledState = Get-RegistryValueState -Path $path -Name 'DisabledByDefault'

            $entries.Add([PSCustomObject]@{
                Protocol = $protocol
                Side = $side
                Path = $path
                Enabled = $enabledState
                DisabledByDefault = $disabledState
            })

            $currentEnabled = if ($enabledState.ValueExisted) { [int]$enabledState.Value } else { $null }
            $currentDisabled = if ($disabledState.ValueExisted) { [int]$disabledState.Value } else { $null }
            if (-not $enabledState.KeyExisted -or $currentEnabled -ne 0 -or $currentDisabled -ne 1) {
                $changed = $true
            }

            if (-not (Test-Path -LiteralPath $path)) {
                New-Item -Path $path -Force | Out-Null
            }
            New-ItemProperty -Path $path -Name 'Enabled' -Value 0 -PropertyType DWord -Force | Out-Null
            New-ItemProperty -Path $path -Name 'DisabledByDefault' -Value 1 -PropertyType DWord -Force | Out-Null
        }
    }

    return [PSCustomObject]@{
        Changed = $changed
        PreState = @($entries)
        Note = 'Legacy protocol keys were set to disabled values for drill.'
    }
}

function Invoke-RevertDisableLegacyTls {
    param([Parameter(Mandatory = $true)][object[]]$PreState)

    foreach ($entry in $PreState) {
        $path = [string]$entry.Path
        $enabled = $entry.Enabled
        $disabled = $entry.DisabledByDefault

        if (-not $enabled.KeyExisted) {
            if (Test-Path -LiteralPath $path) {
                Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
            }
            continue
        }

        if (-not (Test-Path -LiteralPath $path)) {
            New-Item -Path $path -Force | Out-Null
        }

        if ($enabled.ValueExisted) {
            New-ItemProperty -Path $path -Name 'Enabled' -Value ([int]$enabled.Value) -PropertyType DWord -Force | Out-Null
        } else {
            Remove-ItemProperty -Path $path -Name 'Enabled' -ErrorAction SilentlyContinue
        }

        if ($disabled.ValueExisted) {
            New-ItemProperty -Path $path -Name 'DisabledByDefault' -Value ([int]$disabled.Value) -PropertyType DWord -Force | Out-Null
        } else {
            Remove-ItemProperty -Path $path -Name 'DisabledByDefault' -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-ActionEnforceLmCompatibility {
    $path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
    $before = Get-RegistryValueState -Path $path -Name 'LmCompatibilityLevel'
    $changed = -not ($before.ValueExisted -and ([int]$before.Value -eq 5))

    New-ItemProperty -Path $path -Name 'LmCompatibilityLevel' -Value 5 -PropertyType DWord -Force | Out-Null

    return [PSCustomObject]@{
        Changed = $changed
        PreState = $before
        Note = 'LmCompatibilityLevel set to 5 for drill.'
    }
}

function Invoke-RevertLmCompatibility {
    param([Parameter(Mandatory = $true)][psobject]$PreState)

    $path = [string]$PreState.Path
    if (-not $PreState.KeyExisted) {
        return
    }

    if (-not (Test-Path -LiteralPath $path)) {
        New-Item -Path $path -Force | Out-Null
    }

    if ($PreState.ValueExisted) {
        New-ItemProperty -Path $path -Name $PreState.Name -Value ([int]$PreState.Value) -PropertyType DWord -Force | Out-Null
    } else {
        Remove-ItemProperty -Path $path -Name $PreState.Name -ErrorAction SilentlyContinue
    }
}

function Build-ActionPlan {
    param(
        [Parameter(Mandatory = $true)][object[]]$Rows,
        [Parameter(Mandatory = $true)][bool]$IncludeConfigOnly
    )

    $plan = New-Object 'System.Collections.Generic.List[object]'
    $manual = New-Object 'System.Collections.Generic.List[object]'

    $smbUse = Find-Rows -Rows $Rows -CheckRegex '^SMBv1 upgrade impact$' -Statuses @('FAIL')
    $smbConfig = Find-Rows -Rows $Rows -CheckRegex '^SMBv1 server protocol$' -Statuses @('WARN', 'FAIL')
    if ($smbUse.Count -gt 0 -or ($IncludeConfigOnly -and $smbConfig.Count -gt 0)) {
        $triggerRows = if ($smbUse.Count -gt 0) { $smbUse } else { $smbConfig }
        $plan.Add([PSCustomObject]@{
            Id = 'DisableSmb1'
            Title = 'Disable SMBv1 protocol'
            Risk = 'Medium'
            RequiresForce = $false
            Why = Get-RowEvidenceSummary -Rows $triggerRows
        })
    }

    $tlsUse = Find-Rows -Rows $Rows -CheckRegex '^Observed legacy usage: (TLS 1\.0|TLS 1\.1|SSL 3\.0|SSL 2\.0)$' -Statuses @('FAIL')
    $tlsConfig = Find-Rows -Rows $Rows -CheckRegex '^Protocol configuration: (TLS 1\.0|TLS 1\.1|SSL 3\.0|SSL 2\.0)$' -Statuses @('WARN', 'FAIL')
    if ($tlsUse.Count -gt 0 -or ($IncludeConfigOnly -and $tlsConfig.Count -gt 0)) {
        $triggerRows = if ($tlsUse.Count -gt 0) { $tlsUse } else { $tlsConfig }
        $plan.Add([PSCustomObject]@{
            Id = 'DisableLegacyTls'
            Title = 'Disable legacy TLS/SSL protocol keys'
            Risk = 'Medium'
            RequiresForce = $false
            Why = Get-RowEvidenceSummary -Rows $triggerRows
        })
    }

    $ntlmv1 = Find-Rows -Rows $Rows -CheckRegex '^NTLMv1 observed$' -Statuses @('FAIL')
    $lmConfig = Find-Rows -Rows $Rows -CheckRegex '^LmCompatibilityLevel$' -Statuses @('INFO', 'FAIL', 'WARN')
    if ($ntlmv1.Count -gt 0 -or ($IncludeConfigOnly -and $lmConfig.Count -gt 0)) {
        $triggerRows = if ($ntlmv1.Count -gt 0) { $ntlmv1 } else { $lmConfig }
        $plan.Add([PSCustomObject]@{
            Id = 'EnforceLmCompatibility'
            Title = 'Set local LmCompatibilityLevel=5 (NTLMv2-only local policy)'
            Risk = 'High'
            RequiresForce = $true
            Why = Get-RowEvidenceSummary -Rows $triggerRows
        })
    }

    $ps2Risk = Find-Rows -Rows $Rows -CheckRegex '^PowerShell 2\.0 upgrade impact$' -Statuses @('WARN', 'FAIL')
    if ($ps2Risk.Count -gt 0) {
        $manual.Add([PSCustomObject]@{
            Item = 'PowerShell 2.0'
            Why = Get-RowEvidenceSummary -Rows $ps2Risk
            Note = 'Automatic disable/re-enable is intentionally not done here because feature-state rollback can require source media and reboot.'
        })
    }

    return [PSCustomObject]@{
        Actions = @($plan)
        ManualItems = @($manual)
    }
}

function Get-LatestStatePath {
    param([Parameter(Mandatory = $true)][string]$JsonPath)

    $dir = Split-Path -Path $JsonPath -Parent
    $latestPointer = Join-Path -Path $dir -ChildPath 'WS2025_ScreamTestState_latest.json'
    if (-not (Test-Path -LiteralPath $latestPointer)) {
        return $null
    }

    try {
        $pointer = Get-Content -LiteralPath $latestPointer -Raw | ConvertFrom-Json -ErrorAction Stop
        if ($pointer -and $pointer.StatePath -and (Test-Path -LiteralPath ([string]$pointer.StatePath))) {
            return [string]$pointer.StatePath
        }
    } catch {
        return $null
    }

    return $null
}

function Save-State {
    param(
        [Parameter(Mandatory = $true)][psobject]$State,
        [Parameter(Mandatory = $true)][string]$JsonPath,
        [Parameter(Mandatory = $true)][string]$TargetStatePath
    )

    $dir = Split-Path -Path $TargetStatePath -Parent
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }

    $State | ConvertTo-Json -Depth 10 | Set-Content -Path $TargetStatePath -Encoding UTF8

    $latestPointerPath = Join-Path -Path (Split-Path -Path $JsonPath -Parent) -ChildPath 'WS2025_ScreamTestState_latest.json'
    [PSCustomObject]@{ StatePath = $TargetStatePath; UpdatedAt = (Get-Date).ToString('o') } |
        ConvertTo-Json -Depth 5 |
        Set-Content -Path $latestPointerPath -Encoding UTF8
}

function Invoke-PlanOutput {
    param([Parameter(Mandatory = $true)][psobject]$Plan)

    Write-Host "`nCompatibility Drill Plan" -ForegroundColor Cyan
    if ($Plan.Actions.Count -eq 0) {
        Write-Ok 'No automated drill actions were selected from this report.'
    } else {
        foreach ($action in $Plan.Actions) {
            Write-Host (" - {0} [{1}]" -f $action.Title, $action.Risk) -ForegroundColor Yellow
            Write-Host ("   Trigger evidence: {0}" -f $action.Why) -ForegroundColor Yellow
            if ($action.RequiresForce) {
                Write-Host '   Note: requires -Force (and optional gate switches) to apply.' -ForegroundColor DarkYellow
            }
        }
    }

    if ($Plan.ManualItems.Count -gt 0) {
        Write-Host "`nManual Items (Not Auto-Drilled)" -ForegroundColor Cyan
        foreach ($item in $Plan.ManualItems) {
            Write-Host (" - {0}" -f $item.Item) -ForegroundColor DarkYellow
            Write-Host ("   Why: {0}" -f $item.Why) -ForegroundColor DarkYellow
            Write-Host ("   Note: {0}" -f $item.Note) -ForegroundColor DarkYellow
        }
    }
}

$normalized = Normalize-Command -Raw $Command
$mode = $normalized.Mode
$includeConfigOnly = [bool]$normalized.IncludeConfigOnly

$inputPath = (Resolve-Path -LiteralPath $InputJson -ErrorAction Stop).Path
$rows = Read-Findings -Path $inputPath

$hostName = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { [System.Net.Dns]::GetHostName() }

if ($mode -ne 'Plan' -and -not (Test-IsAdministrator)) {
    throw 'Break/Revert modes require an elevated PowerShell session.'
}

if ($mode -eq 'Plan') {
    $plan = Build-ActionPlan -Rows $rows -IncludeConfigOnly $includeConfigOnly
    Invoke-PlanOutput -Plan $plan
    Write-Info 'Plan mode only: no changes were made.'
    return
}

if ($mode -eq 'Break') {
    $plan = Build-ActionPlan -Rows $rows -IncludeConfigOnly $includeConfigOnly
    Invoke-PlanOutput -Plan $plan

    if ($plan.Actions.Count -eq 0) {
        Write-Info 'No actions to apply. Exiting.'
        return
    }

    $targetStatePath = $StatePath
    if ([string]::IsNullOrWhiteSpace($targetStatePath)) {
        $dir = Split-Path -Path $inputPath -Parent
        $targetStatePath = Join-Path -Path $dir -ChildPath ("WS2025_ScreamTestState_{0}_{1}.json" -f $hostName, (Get-Date -Format 'yyyyMMdd_HHmmss'))
    }

    $state = [ordered]@{
        Version = 1
        Computer = $hostName
        CreatedAt = (Get-Date).ToString('o')
        SourceJson = $inputPath
        IncludeConfigOnly = $includeConfigOnly
        IncludeAuthPolicy = [bool]$IncludeAuthPolicy
        AppliedActions = @()
        SkippedActions = @()
        ManualItems = $plan.ManualItems
    }

    foreach ($action in $plan.Actions) {
        if ($action.Id -eq 'EnforceLmCompatibility' -and -not $IncludeAuthPolicy) {
            $state.SkippedActions += [PSCustomObject]@{
                Id = $action.Id
                Title = $action.Title
                Reason = 'Skipped because -IncludeAuthPolicy was not supplied.'
            }
            Write-Warn ("Skipped {0}: -IncludeAuthPolicy not supplied." -f $action.Title)
            continue
        }

        if ($action.RequiresForce -and -not $Force) {
            $state.SkippedActions += [PSCustomObject]@{
                Id = $action.Id
                Title = $action.Title
                Reason = 'Skipped because -Force was not supplied for high-risk action.'
            }
            Write-Warn ("Skipped {0}: requires -Force." -f $action.Title)
            continue
        }

        try {
            $result = switch ($action.Id) {
                'DisableSmb1' { Invoke-ActionDisableSmb1 }
                'DisableLegacyTls' { Invoke-ActionDisableLegacyTls }
                'EnforceLmCompatibility' { Invoke-ActionEnforceLmCompatibility }
                default { throw "Unknown action id: $($action.Id)" }
            }

            $state.AppliedActions += [PSCustomObject]@{
                Id = $action.Id
                Title = $action.Title
                Risk = $action.Risk
                Changed = [bool]$result.Changed
                Note = [string]$result.Note
                PreState = $result.PreState
            }

            if ($result.Changed) {
                Write-Ok ("Applied: {0}" -f $action.Title)
            } else {
                Write-Info ("No-op: {0} ({1})" -f $action.Title, $result.Note)
            }
        } catch {
            $state.SkippedActions += [PSCustomObject]@{
                Id = $action.Id
                Title = $action.Title
                Reason = $_.Exception.Message
            }
            Write-Err ("Failed: {0} :: {1}" -f $action.Title, $_.Exception.Message)
        }
    }

    Save-State -State ([PSCustomObject]$state) -JsonPath $inputPath -TargetStatePath $targetStatePath
    Write-Ok ("State saved: {0}" -f $targetStatePath)
    Write-Info 'Run your app smoke tests now, then run this script with Revert/Undo/Restore.'
    return
}

if ($mode -eq 'Revert') {
    $stateToUse = $StatePath
    if ([string]::IsNullOrWhiteSpace($stateToUse)) {
        $stateToUse = Get-LatestStatePath -JsonPath $inputPath
    }

    if ([string]::IsNullOrWhiteSpace($stateToUse)) {
        throw 'No state file found. Supply -StatePath or run Break first.'
    }

    $resolvedStatePath = (Resolve-Path -LiteralPath $stateToUse -ErrorAction Stop).Path
    $state = Get-Content -LiteralPath $resolvedStatePath -Raw | ConvertFrom-Json -ErrorAction Stop

    if ([string]$state.Computer -and ([string]$state.Computer).ToUpperInvariant() -ne $hostName.ToUpperInvariant()) {
        throw "State file was created on '$($state.Computer)', current host is '$hostName'. Revert on the same server."
    }

    $applied = @($state.AppliedActions)
    if ($applied.Count -eq 0) {
        Write-Warn 'State file has no applied actions to revert.'
        return
    }

    Write-Host "`nReverting compatibility drill actions..." -ForegroundColor Cyan
    foreach ($action in ($applied | Select-Object -Reverse)) {
        if (-not [bool]$action.Changed) {
            Write-Info ("Skip revert (no-op originally): {0}" -f $action.Title)
            continue
        }

        try {
            switch ([string]$action.Id) {
                'DisableSmb1' { Invoke-RevertDisableSmb1 -PreState $action.PreState }
                'DisableLegacyTls' { Invoke-RevertDisableLegacyTls -PreState @($action.PreState) }
                'EnforceLmCompatibility' { Invoke-RevertLmCompatibility -PreState $action.PreState }
                default { throw "Unknown revert action id: $($action.Id)" }
            }
            Write-Ok ("Reverted: {0}" -f $action.Title)
        } catch {
            Write-Err ("Failed revert: {0} :: {1}" -f $action.Title, $_.Exception.Message)
        }
    }

    Write-Ok 'Revert sequence completed. Validate service health and app access.'
    return
}

