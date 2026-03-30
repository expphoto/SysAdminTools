<#
.SYNOPSIS
    Backup Health Monitor & Auto-Remediation (Duplicati / Duplicacy / Arq)
.DESCRIPTION
    Detects installed backup agents, checks last run status, parses errors,
    attempts auto-remediation, then exits:
        0  = All healthy (or auto-fix succeeded)
        2  = Error detected and could NOT be auto-fixed
.NOTES
    Compatible with Windows PowerShell 5.1+
    Adjust $MaxBackupAgeHours to match your backup SLA.
#>

$ErrorActionPreference = 'SilentlyContinue'

# ── Configuration ─────────────────────────────────────────────────────────────
$MaxBackupAgeHours = 24
$DuplicatiApiBase  = 'http://localhost:8200/api/v1'
$DuplicatiApiPass  = ''          # Set if Duplicati UI password is configured
$Script:HasError   = $false
$Script:FixFailed  = $false
$Script:Report     = New-Object System.Collections.Generic.List[string]

# ── Helpers ───────────────────────────────────────────────────────────────────
function Write-Log {
    param([string]$Msg, [string]$Level = 'INFO')
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line  = "[" + $stamp + "][" + $Level + "] " + $Msg
    $Script:Report.Add($line)
    $color = 'White'
    if ($Level -eq 'ERROR') { $color = 'Red'    }
    if ($Level -eq 'WARN')  { $color = 'Yellow' }
    if ($Level -eq 'OK')    { $color = 'Green'  }
    if ($Level -eq 'FIX')   { $color = 'Cyan'   }
    Write-Host $line -ForegroundColor $color
}

function Set-ErrorFlag { $Script:HasError = $true }
function Set-NoFix     { $Script:FixFailed = $true; $Script:HasError = $true }

function Test-BackupAge {
    param([datetime]$LastRun, [string]$Label)
    $age    = (Get-Date) - $LastRun
    $ageH   = [int]$age.TotalHours
    $lastStr = $LastRun.ToString('yyyy-MM-dd HH:mm')
    if ($age.TotalHours -gt $MaxBackupAgeHours) {
        Write-Log ($Label + " last backup: " + $lastStr + " (" + $ageH + "h ago) STALE threshold=" + $MaxBackupAgeHours + "h") 'WARN'
        Set-ErrorFlag
        return $false
    }
    Write-Log ($Label + " last backup: " + $lastStr + " (" + $ageH + "h ago)") 'OK'
    return $true
}

function Invoke-ServiceRestart {
    param([string]$Name)
    Write-Log ("Auto-fix: Restarting service '" + $Name + "' ...") 'FIX'
    try {
        Restart-Service -Name $Name -Force -ErrorAction Stop
        Start-Sleep -Seconds 6
        $s = Get-Service -Name $Name -ErrorAction Stop
        if ($s.Status -eq 'Running') {
            Write-Log ("Service '" + $Name + "' restarted successfully.") 'OK'
            return $true
        }
    } catch {
        Write-Log ("Restart exception: " + $_.Exception.Message) 'ERROR'
    }
    Write-Log ("Service '" + $Name + "' still not Running after restart.") 'ERROR'
    return $false
}

# ── DUPLICATI ─────────────────────────────────────────────────────────────────
function Check-Duplicati {
    Write-Log '-------- Duplicati --------' 'INFO'

    $svc  = Get-Service  -Name 'Duplicati'  -ErrorAction SilentlyContinue
    $proc = Get-Process  -Name 'Duplicati' -ErrorAction SilentlyContinue

    if ((-not $svc) -and (-not $proc)) {
        Write-Log 'Duplicati: not detected - skipping.' 'INFO'
        return
    }

    # Service health
    if ($svc) {
        if ($svc.Status -ne 'Running') {
            Write-Log ("Duplicati service is '" + $svc.Status + "'.") 'WARN'
            if (-not (Invoke-ServiceRestart 'Duplicati')) { Set-NoFix }
        } else {
            Write-Log 'Duplicati service is Running.' 'OK'
        }
    }

    # REST API: job status
    $headers = @{ Accept = 'application/json' }
    if ($DuplicatiApiPass) {
        $encoded = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":" + $DuplicatiApiPass))
        $headers['Authorization'] = "Basic " + $encoded
    }

    try {
        $backups = Invoke-RestMethod -Uri ($DuplicatiApiBase + '/backups') `
                       -Headers $headers -TimeoutSec 8 -ErrorAction Stop

        if ((-not $backups) -or ($backups.Count -eq 0)) {
            Write-Log 'Duplicati: No backup jobs configured.' 'WARN'
            Set-ErrorFlag
            return
        }

        foreach ($entry in $backups) {
            $name = $entry.Backup.Name
            $id   = $entry.Backup.ID
            $meta = $entry.Metadata

            $lastDateRaw = $meta.LastBackupDate
            if ($lastDateRaw -and $lastDateRaw -ne '0001-01-01T00:00:00') {
                $lastDate = [datetime]::Parse($lastDateRaw)
                Test-BackupAge -LastRun $lastDate -Label ("Duplicati '" + $name + "'") | Out-Null
            } else {
                Write-Log ("Duplicati '" + $name + "': No backup date recorded.") 'WARN'
                Set-ErrorFlag
            }

            $lastErr = $meta.LastErrorMessage
            if ($lastErr) {
                Write-Log ("Duplicati '" + $name + "' last error: " + $lastErr) 'ERROR'
                Set-ErrorFlag
            }

            try {
                $prog = Invoke-RestMethod -Uri ($DuplicatiApiBase + '/backup/' + $id + '/progress') `
                            -Headers $headers -TimeoutSec 5 -ErrorAction Stop
                if ($prog.Phase -and
                    $prog.Phase -ne 'Backup_Complete' -and
                    $prog.Phase -ne 'Backup_WaitForTarget') {
                    Write-Log ("Duplicati '" + $name + "' phase: " + $prog.Phase) 'INFO'
                }
            } catch {}
        }
    } catch {
        Write-Log ("Duplicati REST API unreachable at " + $DuplicatiApiBase + ". Falling back to crash log.") 'WARN'

        $crashLog = Join-Path $env:LOCALAPPDATA 'Duplicati\crashlog.txt'
        if (Test-Path $crashLog) {
            $tail = Get-Content $crashLog -Tail 30
            $recent = $tail | Where-Object { $_ -match '\d{4}-\d{2}-\d{2}' } | Select-Object -Last 1
            if ($recent) {
                $m = [regex]::Match($recent, '\d{4}-\d{2}-\d{2}')
                if ($m.Success) {
                    $crashDate = [datetime]::Parse($m.Value)
                    if (((Get-Date) - $crashDate).TotalHours -lt 48) {
                        Write-Log ("Duplicati crash log (recent): " + $recent) 'ERROR'
                        Set-ErrorFlag
                    }
                }
            }
        }
    }

    # Windows Event Log errors
    try {
        $evts = Get-WinEvent -FilterHashtable @{
            LogName   = 'Application'
            Level     = 2
            StartTime = (Get-Date).AddHours(-24)
        } -MaxEvents 20 -ErrorAction Stop |
        Where-Object { $_.ProviderName -match 'Duplicati' }

        foreach ($evt in $evts) {
            $msg = $evt.Message
            if ($msg.Length -gt 250) { $msg = $msg.Substring(0, 250) }
            Write-Log ("Duplicati EventLog: " + $evt.TimeCreated.ToString('yyyy-MM-dd HH:mm') + " - " + $msg) 'ERROR'
            Set-ErrorFlag
        }
    } catch {}
}

# ── DUPLICACY ─────────────────────────────────────────────────────────────────
function Check-Duplicacy {
    Write-Log '-------- Duplicacy --------' 'INFO'

    $exeCandidates = @(
        'C:\Program Files\Duplicacy\duplicacy.exe'
        'C:\Program Files (x86)\Duplicacy\duplicacy.exe'
        (Join-Path $env:LOCALAPPDATA 'Duplicacy\duplicacy.exe')
    )
    $exe = $null
    foreach ($c in $exeCandidates) {
        if (Test-Path $c) { $exe = $c; break }
    }
    if (-not $exe) {
        $cmd = Get-Command duplicacy.exe -ErrorAction SilentlyContinue
        if ($cmd) { $exe = $cmd.Source }
    }

    $webSvcNames = @('DuplicacyWeb', 'Duplicacy Web', 'duplicacy-web')
    $webSvc = $null
    foreach ($n in $webSvcNames) {
        $s = Get-Service -Name $n -ErrorAction SilentlyContinue
        if ($s) { $webSvc = $s; break }
    }

    $proc = Get-Process -Name 'duplicacy*' -ErrorAction SilentlyContinue | Select-Object -First 1

    if ((-not $exe) -and (-not $webSvc) -and (-not $proc)) {
        Write-Log 'Duplicacy: not detected - skipping.' 'INFO'
        return
    }

    if ($webSvc) {
        if ($webSvc.Status -ne 'Running') {
            Write-Log ("Duplicacy Web service is '" + $webSvc.Status + "'.") 'WARN'
            if (-not (Invoke-ServiceRestart $webSvc.Name)) { Set-NoFix }
        } else {
            Write-Log 'Duplicacy Web service is Running.' 'OK'
        }
    }

    # Find .duplicacy/logs directories (limit depth to avoid long scans)
    $logDirs = @()
    $fixedDrives = Get-PSDrive -PSProvider FileSystem |
                   Where-Object { $_.Used -gt 0 } |
                   Select-Object -First 4

    foreach ($drive in $fixedDrives) {
        $found = Get-ChildItem -Path $drive.Root -Recurse -Depth 6 `
                     -Directory -Filter 'logs' -ErrorAction SilentlyContinue |
                 Where-Object { $_.Parent.Name -eq '.duplicacy' }
        $logDirs += $found
    }

    if ($logDirs.Count -eq 0) {
        Write-Log 'Duplicacy: No .duplicacy/logs directories found.' 'WARN'
        Set-ErrorFlag
        return
    }

    foreach ($logDir in $logDirs) {
        $repoRoot = $logDir.Parent.Parent.FullName
        Write-Log ("Duplicacy repo: " + $repoRoot) 'INFO'

        $logs = Get-ChildItem $logDir.FullName -Filter '*.log' -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 5

        if (-not $logs) {
            Write-Log ("Duplicacy (" + $repoRoot + "): No log files found.") 'WARN'
            Set-ErrorFlag
            continue
        }

        Test-BackupAge -LastRun $logs[0].LastWriteTime -Label ("Duplicacy (" + $repoRoot + ")") | Out-Null

        $errLines = @()
        foreach ($log in ($logs | Select-Object -First 3)) {
            $content = Get-Content $log.FullName -ErrorAction SilentlyContinue
            $errs = $content | Where-Object { $_ -match '(?i)\b(error|fail|panic|fatal|cannot)\b' } |
                    Select-Object -Last 5
            foreach ($e in $errs) {
                $errLines += ("[" + $log.Name + "] " + $e)
            }
        }

        if ($errLines.Count -gt 0) {
            Write-Log ("Duplicacy (" + $repoRoot + "): Errors in recent logs:") 'ERROR'
            $errLines | Select-Object -Last 10 | ForEach-Object { Write-Log ("  " + $_) 'ERROR' }
            Set-ErrorFlag

            $storageErr = $errLines | Where-Object {
                $_ -match '(?i)(storage|connect|timeout|unavailable|access denied)'
            }
            if ($storageErr) {
                Write-Log 'Duplicacy: Storage/connectivity error - cannot auto-fix. Check storage target.' 'ERROR'
                Set-NoFix
            }

            $corruptErr = $errLines | Where-Object { $_ -match '(?i)(corrupt|checksum|chunk)' }
            if ($corruptErr -and $exe) {
                Write-Log ("Duplicacy: Running 'check' on " + $repoRoot + " ...") 'FIX'
                Push-Location $repoRoot
                $checkOut = & $exe check 2>&1
                $checkExit = $LASTEXITCODE
                Pop-Location
                if ($checkExit -eq 0) {
                    Write-Log 'Duplicacy check passed.' 'OK'
                    $Script:HasError = $false
                } else {
                    $tail = ($checkOut | Select-Object -Last 5) -join ' | '
                    Write-Log ("Duplicacy check FAILED: " + $tail) 'ERROR'
                    Set-NoFix
                }
            }
        } else {
            Write-Log ("Duplicacy (" + $repoRoot + "): No errors in recent logs.") 'OK'
        }
    }
}

# ── ARQ ───────────────────────────────────────────────────────────────────────
function Check-Arq {
    Write-Log '-------- Arq Backup --------' 'INFO'

    $exeCandidates = @(
        'C:\Program Files\Arq\Arq.exe'
        'C:\Program Files (x86)\Arq\Arq.exe'
        'C:\Program Files\Arq Agent\ArqAgent.exe'
        'C:\Program Files (x86)\Arq Agent\ArqAgent.exe'
    )
    $exe = $null
    foreach ($c in $exeCandidates) {
        if (Test-Path $c) { $exe = $c; break }
    }

    $svc  = Get-Service -Name 'Arq*' -ErrorAction SilentlyContinue | Select-Object -First 1
    $proc = Get-Process -Name 'Arq*' -ErrorAction SilentlyContinue | Select-Object -First 1

    if ((-not $exe) -and (-not $svc) -and (-not $proc)) {
        Write-Log 'Arq: not detected - skipping.' 'INFO'
        return
    }

    if ($svc) {
        if ($svc.Status -ne 'Running') {
            Write-Log ("Arq service '" + $svc.Name + "' is '" + $svc.Status + "'.") 'WARN'
            if (-not (Invoke-ServiceRestart $svc.Name)) { Set-NoFix }
        } else {
            Write-Log ("Arq service '" + $svc.Name + "' is Running.") 'OK'
        }
    }

    $logDirCandidates = @(
        'C:\ProgramData\Arq\log'
        (Join-Path $env:APPDATA 'Arq\log')
        (Join-Path $env:LOCALAPPDATA 'Arq\log')
    )
    $logDir = $null
    foreach ($d in $logDirCandidates) {
        if (Test-Path $d) { $logDir = $d; break }
    }

    if (-not $logDir) {
        Write-Log 'Arq: Log directory not found.' 'WARN'
        Set-ErrorFlag
        return
    }

    $logs = Get-ChildItem $logDir -Filter '*.log' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 10

    if (-not $logs) {
        Write-Log ("Arq: No log files in " + $logDir) 'WARN'
        Set-ErrorFlag
        return
    }

    Test-BackupAge -LastRun $logs[0].LastWriteTime -Label 'Arq' | Out-Null

    $errLines = @()
    foreach ($log in ($logs | Select-Object -First 3)) {
        $content = Get-Content $log.FullName -ErrorAction SilentlyContinue
        $errs = $content | Where-Object {
            $_ -match '(?i)\b(error|fail|exception|abort|critical)\b'
        } | Select-Object -Last 5
        foreach ($e in $errs) {
            $errLines += ("[" + $log.Name + "] " + $e)
        }
    }

    if ($errLines.Count -gt 0) {
        Write-Log 'Arq: Errors in recent logs:' 'ERROR'
        $errLines | Select-Object -Last 10 | ForEach-Object { Write-Log ("  " + $_) 'ERROR' }
        Set-ErrorFlag

        if ($svc -and $svc.Status -eq 'Running') {
            Write-Log 'Arq: Restarting service to clear error state ...' 'FIX'
            if (Invoke-ServiceRestart $svc.Name) {
                Write-Log 'Arq: Service restarted. Verify next scheduled backup run.' 'OK'
            } else {
                Set-NoFix
            }
        } else {
            Write-Log 'Arq: No running service to restart - cannot auto-fix.' 'ERROR'
            Set-NoFix
        }
    } else {
        Write-Log 'Arq: No errors in recent logs.' 'OK'
    }

    try {
        $evts = Get-WinEvent -FilterHashtable @{
            LogName   = 'Application'
            Level     = 2
            StartTime = (Get-Date).AddHours(-24)
        } -MaxEvents 50 -ErrorAction Stop |
        Where-Object { $_.ProviderName -match 'Arq' }

        foreach ($evt in $evts) {
            $msg = $evt.Message
            if ($msg.Length -gt 250) { $msg = $msg.Substring(0, 250) }
            Write-Log ("Arq EventLog: " + $evt.TimeCreated.ToString('yyyy-MM-dd HH:mm') + " - " + $msg) 'ERROR'
            Set-ErrorFlag
        }
    } catch {}
}

# ── MAIN ──────────────────────────────────────────────────────────────────────
$sep = '=' * 60
Write-Log $sep 'INFO'
Write-Log ("Backup Health Check - " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) 'INFO'
Write-Log ("Stale threshold: " + $MaxBackupAgeHours + "h  Host: " + $env:COMPUTERNAME) 'INFO'
Write-Log $sep 'INFO'

Check-Duplicati
Check-Duplicacy
Check-Arq

Write-Log $sep 'INFO'
if ($Script:FixFailed) {
    Write-Log 'RESULT: ERRORS detected - auto-fix FAILED. Manual intervention required.' 'ERROR'
    exit 2
} elseif ($Script:HasError) {
    Write-Log 'RESULT: Issues detected - auto-fix APPLIED. Verify next backup cycle.' 'WARN'
    exit 0
} else {
    Write-Log 'RESULT: All backup agents healthy.' 'OK'
    exit 0
}