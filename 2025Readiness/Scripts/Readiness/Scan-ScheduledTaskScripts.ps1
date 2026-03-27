<#
.SYNOPSIS
    Scans scheduled task scripts for patterns deprecated/removed in Windows Server 2025.
.DESCRIPTION
    Enumerates all scheduled tasks, extracts .ps1 script paths from ExecAction entries,
    reads each script file, and flags lines matching WS2025 deprecated/removed patterns.
    Compatible with Windows PowerShell 5.1 ISE on Server 2012 R2 through 2022.
.NOTES
    Run elevated. Read-only — no changes made.
#>
#Requires -Version 5.1

$patterns = @(
    @{ Name = 'PowerShell 2.0';       Regex = '-[Vv]ersion\s*2';                                                  Severity = 'FAIL'; Note = 'PS 2.0 engine removed in WS2025' }
    @{ Name = 'WMIC';                 Regex = '\bwmic(\.exe)?\b';                                                  Severity = 'FAIL'; Note = 'WMIC not installed by default in WS2025' }
    @{ Name = 'wuauclt detectnow';    Regex = 'wuauclt.*detectnow';                                                Severity = 'FAIL'; Note = 'wuauclt /detectnow removed in WS2025' }
    @{ Name = 'VBScript host';        Regex = '\b(wscript|cscript)(\.exe)?\b';                                     Severity = 'WARN'; Note = 'VBScript deprecated, removal pending' }
    @{ Name = 'VBScript file';        Regex = '\.(vbs|wsf)\b';                                                     Severity = 'WARN'; Note = 'VBScript deprecated, removal pending' }
    @{ Name = 'WinRM.vbs';            Regex = '\bwinrm\.vbs\b';                                                    Severity = 'WARN'; Note = 'WinRM.vbs deprecated' }
    @{ Name = 'scregedit.exe';        Regex = '\bscregedit(\.exe)?\b';                                             Severity = 'WARN'; Note = 'scregedit.exe deprecated' }
    @{ Name = 'IIS6 legacy scripts';  Regex = '\b(adsutil|iisapp|iisback|iiscnfg|iiscertdeploy|iisvdir|iisweb)(\.vbs)?\b'; Severity = 'WARN'; Note = 'IIS6 scripting tools removed' }
    @{ Name = 'Net.exe user/group';   Regex = '\bnet(\.exe)?\s+(user|localgroup|group)\b';                         Severity = 'INFO'; Note = 'Works but flag for modernization' }
    @{ Name = 'Invoke-Expression';    Regex = '\b(Invoke-Expression|iex)\s*[\(\$]';                                Severity = 'INFO'; Note = 'Review for encoded/obfuscated execution' }
)

$results = New-Object 'System.Collections.Generic.List[object]'
$scriptsSeen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

Write-Host "`nCollecting scheduled tasks..." -ForegroundColor Cyan

$allTasks = $null
try {
    $allTasks = @(Get-ScheduledTask -ErrorAction Stop)
    Write-Host ("  Found {0} scheduled tasks." -f $allTasks.Count) -ForegroundColor DarkGray
} catch {
    Write-Warning ("Get-ScheduledTask failed: {0}" -f $_.Exception.Message)
    exit 1
}

$skippedTasks = 0
foreach ($task in $allTasks) {
    $taskLabel = '{0}{1}' -f $task.TaskPath, $task.TaskName

    $actions = $null
    try {
        $actions = @($task.Actions)
    } catch {
        $skippedTasks++
        continue
    }

    foreach ($action in $actions) {
        # Only MSFT_TaskExecAction has Execute/Arguments — skip COM handlers, email, show-message
        $actionType = $null
        try { $actionType = $action.CimClass.CimClassName } catch { }
        if ($null -eq $actionType) {
            try { $actionType = $action.GetType().Name } catch { }
        }
        if ($actionType -and $actionType -notmatch 'ExecAction') { continue }

        $exe = $null
        $arguments = ''
        try {
            $exe = [string]$action.Execute
            $arguments = [string]$action.Arguments
        } catch {
            continue
        }
        if ([string]::IsNullOrWhiteSpace($exe)) { continue }

        $exe = [Environment]::ExpandEnvironmentVariables($exe)
        $arguments = [Environment]::ExpandEnvironmentVariables($arguments)

        # Only care about PowerShell-hosted tasks
        if ($exe -notmatch '(?i)(powershell|pwsh)(\.exe)?$') { continue }

        # Extract .ps1 path(s) from arguments
        $scriptPaths = New-Object 'System.Collections.Generic.List[string]'

        # -File "path.ps1" or -File path.ps1
        if ($arguments -match '(?i)-(?:File|f)\s+"([^"]+\.ps1)"') {
            $scriptPaths.Add($Matches[1])
        } elseif ($arguments -match '(?i)-(?:File|f)\s+([^\s]+\.ps1)') {
            $scriptPaths.Add($Matches[1])
        }

        # Quoted .ps1 path anywhere in args
        $quotedMatches = [regex]::Matches($arguments, '"([^"]+\.ps1)"')
        foreach ($m in $quotedMatches) {
            $val = $m.Groups[1].Value
            if (-not $scriptPaths.Contains($val)) { $scriptPaths.Add($val) }
        }

        # Bare UNC or drive-letter .ps1 path
        $bareMatches = [regex]::Matches($arguments, '([A-Za-z]:\\[^\s"]+\.ps1|\\\\[^\s"]+\.ps1)')
        foreach ($m in $bareMatches) {
            $val = $m.Groups[1].Value
            if (-not $scriptPaths.Contains($val)) { $scriptPaths.Add($val) }
        }

        # Also check if Execute itself is a .ps1
        if ($exe -match '(?i)\.ps1$') {
            if (-not $scriptPaths.Contains($exe)) { $scriptPaths.Add($exe) }
        }

        if ($scriptPaths.Count -eq 0) { continue }

        foreach ($rawPath in $scriptPaths) {
            $scriptPath = [Environment]::ExpandEnvironmentVariables($rawPath)
            try {
                if (-not [System.IO.Path]::IsPathRooted($scriptPath)) {
                    $wd = [string]$action.WorkingDirectory
                    if (-not [string]::IsNullOrWhiteSpace($wd)) {
                        $scriptPath = [System.IO.Path]::Combine([Environment]::ExpandEnvironmentVariables($wd), $scriptPath)
                    }
                }
                $scriptPath = [System.IO.Path]::GetFullPath($scriptPath)
            } catch { }

            if (-not $scriptsSeen.Add($scriptPath)) { continue }

            if (-not (Test-Path -LiteralPath $scriptPath)) {
                $results.Add([PSCustomObject]@{
                    Task     = $taskLabel
                    Script   = $scriptPath
                    Line     = 'N/A'
                    Pattern  = 'FILE NOT FOUND'
                    Severity = 'WARN'
                    Match    = ''
                    Note     = 'Script path in task but missing on disk'
                })
                continue
            }

            Write-Host ("  Scanning: {0}" -f $scriptPath) -ForegroundColor DarkGray

            $lines = $null
            try {
                $lines = [System.IO.File]::ReadAllLines($scriptPath, [System.Text.Encoding]::UTF8)
            } catch {
                $results.Add([PSCustomObject]@{
                    Task     = $taskLabel
                    Script   = $scriptPath
                    Line     = 'N/A'
                    Pattern  = 'READ ERROR'
                    Severity = 'WARN'
                    Match    = $_.Exception.Message
                    Note     = 'Could not read file'
                })
                continue
            }

            $hitFound = $false
            for ($i = 0; $i -lt $lines.Count; $i++) {
                $lineText = $lines[$i]
                if ($lineText.TrimStart().StartsWith('#')) { continue }

                foreach ($p in $patterns) {
                    if ($lineText -match $p.Regex) {
                        $hitFound = $true
                        $results.Add([PSCustomObject]@{
                            Task     = $taskLabel
                            Script   = $scriptPath
                            Line     = ($i + 1)
                            Pattern  = $p.Name
                            Severity = $p.Severity
                            Match    = $lineText.Trim()
                            Note     = $p.Note
                        })
                    }
                }
            }

            if (-not $hitFound) {
                $results.Add([PSCustomObject]@{
                    Task     = $taskLabel
                    Script   = $scriptPath
                    Line     = 'N/A'
                    Pattern  = 'CLEAN'
                    Severity = 'PASS'
                    Match    = ''
                    Note     = 'No deprecated patterns found'
                })
            }
        }
    }
}

# ── Output ──────────────────────────────────────────────────────────────────

Write-Host ("`n{0}" -f ('=' * 70)) -ForegroundColor Cyan
Write-Host '  WS2025 SCHEDULED TASK SCRIPT SCAN RESULTS' -ForegroundColor Cyan
Write-Host ('{0}`n' -f ('=' * 70)) -ForegroundColor Cyan

if ($skippedTasks -gt 0) {
    Write-Host ("  Note: {0} task(s) skipped (COM handler / no exec action)`n" -f $skippedTasks) -ForegroundColor DarkGray
}

if ($results.Count -eq 0) {
    Write-Host '  No PowerShell script-based scheduled tasks found.' -ForegroundColor Green
} else {
    $grouped = $results | Group-Object Severity | Sort-Object {
        switch ($_.Name) { 'FAIL' {0} 'WARN' {1} 'INFO' {2} 'PASS' {3} default {4} }
    }

    foreach ($group in $grouped) {
        $color = switch ($group.Name) {
            'FAIL' { 'Red' } 'WARN' { 'Yellow' } 'INFO' { 'Cyan' } 'PASS' { 'Green' } default { 'Gray' }
        }
        Write-Host ("-- {0} ({1}) {2}" -f $group.Name, $group.Count, ('-' * 50)) -ForegroundColor $color
        foreach ($r in $group.Group) {
            Write-Host ("  Task   : {0}" -f $r.Task) -ForegroundColor $color
            Write-Host ("  Script : {0}" -f $r.Script)
            if ($r.Line -ne 'N/A') { Write-Host ("  Line   : {0}" -f $r.Line) }
            Write-Host ("  Pattern: {0} - {1}" -f $r.Pattern, $r.Note)
            if ($r.Match) { Write-Host ("  Match  : {0}" -f $r.Match) -ForegroundColor DarkGray }
            Write-Host ''
        }
    }
}

# Export CSV
$csvPath = '{0}\WS2025_TaskScriptScan_{1}.csv' -f $env:TEMP, (Get-Date -Format 'yyyyMMddHHmmss')
$results | Export-Csv -Path $csvPath -NoTypeInformation
Write-Host ("CSV saved: {0}" -f $csvPath) -ForegroundColor Cyan
