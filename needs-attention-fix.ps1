<# 
.SYNOPSIS
  Paste your “Needs attention” blob. Script extracts server names, checks reachability,
  Windows Update state, pending reboot, and recent WU errors. Optionally reboots boxes
  that are "installed, waiting for reboot". Prompts for a user to run as.

.USAGE
  Run elevated:
    powershell.exe -ExecutionPolicy Bypass -File .\Check-UpdateState.ps1
  Paste the report text, press Enter on a blank line.
  You’ll be prompted: "Run remoting as (DOMAIN\User)". Leave blank to use current creds.
  Add -AutoReboot to skip prompts and reboot all that need it.

.PARAMETERS
  -AutoReboot        Reboot all servers that report "reboot required" without prompting.
  -ThrottleLimit     Max concurrent remoting ops (default 24).
  -UseSSL            Use WinRM over HTTPS (5986).
  -Authentication    Auth mechanism (Default, Kerberos, Negotiate, CredSSP, Basic). Default: Negotiate.
  -SkipCACheck       Skip CA check when using HTTPS (self-signed lab certs).
  -SkipCNCheck       Skip CN check when using HTTPS.

.OUTPUT
  Console table + CSV at .\Update-Attention-Results_<timestamp>.csv
#>

[CmdletBinding(SupportsShouldProcess)]
param(
  [switch]$AutoReboot,
  [int]$ThrottleLimit = 24,
  [switch]$UseSSL,
  [ValidateSet('Default','Kerberos','Negotiate','CredSSP','Basic','NegotiateWithImplicitCredential')]
  [string]$Authentication = 'Negotiate',
  [switch]$SkipCACheck,
  [switch]$SkipCNCheck
)

function Read-PastedText {
  Write-Host "`nPaste your 'Needs attention' blob below. Press ENTER on an empty line to finish:`n" -ForegroundColor Cyan
  $lines = New-Object System.Collections.Generic.List[string]
  while ($true) {
    $line = Read-Host
    if ([string]::IsNullOrWhiteSpace($line)) { break }
    $lines.Add($line)
  }
  return ($lines -join "`n")
}

function Get-ServerNamesFromText {
  param([string]$Text)
  # Match typical hostnames or FQDNs: letters/digits/hyphen + optional dots
  $pattern = '(?im)\b[a-z0-9][a-z0-9-]{0,62}(?:\.[a-z0-9-]{1,63})*\b'
  $candidates = [regex]::Matches($Text, $pattern) | ForEach-Object { $_.Value.Trim() }
  # Heuristic: toss obvious non-host tokens
  $servers = $candidates | Where-Object {
    $_.Length -ge 2 -and $_ -notmatch '^(error|failed|status|reboot|update|pending|true|false)$'
  } | Select-Object -Unique
  return $servers
}

# --- Prompt for credential (optional) ---
$cred = $null
$runAs = Read-Host "Run remoting as (DOMAIN\User) — leave blank to use current credentials"
if ($runAs) {
  try {
    $cred = Get-Credential -UserName $runAs -Message "Enter password for $runAs"
  } catch {
    Write-Warning "Credential prompt canceled. Using current credentials."
  }
}

# Timeout options (PowerShell 5.1 wants milliseconds)
$sessionOptions = New-PSSessionOption -OperationTimeout 300000 -OpenTimeout 60000 -IdleTimeout 7200000

# Remote probe script (runs ON EACH SERVER)
$ProbeScript = {
  $ErrorActionPreference = 'Stop'
  $result = [ordered]@{
    ComputerName         = $env:COMPUTERNAME
    FQDN                 = $env:COMPUTERNAME
    Reachable            = $true
    PendingReboot        = $false
    UpdatesAvailable     = 0
    LastWUError          = $null
    LastWUErrorTime      = $null
    Status               = 'Unknown'
  }

  function Test-PendingReboot {
    try {
      $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
      )
      foreach ($p in $paths) {
        if (Test-Path $p) { return $true }
      }
      $pfro = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue
      if ($pfro -and $pfro.PendingFileRenameOperations) { return $true }
      return $false
    } catch { return $false }
  }

  function Get-WindowsUpdateSummary {
    $summary = [ordered]@{ CountAvailable = 0; LastError = $null; LastErrorTime = $null }
    try {
      $session  = New-Object -ComObject 'Microsoft.Update.Session'
      $searcher = $session.CreateUpdateSearcher()
      $search   = $searcher.Search('IsInstalled=0 and Type="Software" and IsHidden=0')
      $summary.CountAvailable = ($search.Updates | Measure-Object).Count

      $total = $searcher.GetTotalHistoryCount()
      if ($total -gt 0) {
        $hist = $searcher.QueryHistory(0, [Math]::Min($total, 50))
        $fail = $hist | Where-Object { $_.ResultCode -in 2,3 } | Select-Object -First 1
        if ($fail) {
          $summary.LastError = $fail.Title + ' (0x' + $fail.HResult.ToString('x8') + ')'
          $summary.LastErrorTime = $fail.Date
        }
      }
    } catch {
      if (-not $summary.LastError) { $summary.LastError = $_.Exception.Message }
    }
    return [pscustomobject]$summary
  }

  $pending = Test-PendingReboot
  $wu      = Get-WindowsUpdateSummary

  $result.PendingReboot    = [bool]$pending
  $result.UpdatesAvailable = [int]$wu.CountAvailable
  $result.LastWUError      = $wu.LastError
  $result.LastWUErrorTime  = $wu.LastErrorTime

  if ($pending -and $wu.CountAvailable -eq 0) {
    $result.Status = 'PendingReboot'
  } elseif ($wu.CountAvailable -gt 0) {
    $result.Status = 'UpdatesAvailable'
  } else {
    $result.Status = 'OK'
  }

  return [pscustomobject]$result
}

# --- Main flow ---
$text = Read-PastedText
$servers = Get-ServerNamesFromText -Text $text

if (-not $servers -or $servers.Count -eq 0) {
  Write-Warning 'No server names detected. (Check your paste or adjust the regex.)'
  return
}

Write-Host ('`nDiscovered ' + $servers.Count + ' server(s). Probing...') -ForegroundColor Yellow

$results = New-Object System.Collections.Generic.List[object]

foreach ($s in $servers) {
  Write-Host ('[INFO] Connecting to ' + $s + '...') -ForegroundColor Cyan

  $psParams = @{
    ComputerName   = $s
    SessionOption  = $sessionOptions
    ErrorAction    = 'Stop'
    Authentication = $Authentication
  }
  if ($UseSSL)     { $psParams.UseSSL = $true }
  if ($cred)       { $psParams.Credential = $cred }
  if ($SkipCACheck){ $psParams.SkipCACheck = $true }
  if ($SkipCNCheck){ $psParams.SkipCNCheck = $true }

  try {
    $sess = New-PSSession @psParams
  } catch {
    Write-Host ('[FAIL] ' + $s + ' - Unreachable (' + $_.Exception.Message + ')') -ForegroundColor Red
    $results.Add([pscustomobject]@{
      ComputerName     = $s
      FQDN             = $null
      Reachable        = $false
      PendingReboot    = $null
      UpdatesAvailable = $null
      LastWUError      = $_.Exception.Message
      LastWUErrorTime  = $null
      Status           = 'Unreachable'
    })
    continue
  }

  try {
    $r = Invoke-Command -Session $sess -ScriptBlock $ProbeScript -ErrorAction Stop
    $results.Add($r)
    Write-Host ('[OK]   ' + $s + ' - Status: ' + $r.Status) -ForegroundColor Green
  } catch {
    Write-Host ('[FAIL] ' + $s + ' - Error (' + $_.Exception.Message + ')') -ForegroundColor Red
    $results.Add([pscustomobject]@{
      ComputerName     = $s
      FQDN             = $null
      Reachable        = $true
      PendingReboot    = $null
      UpdatesAvailable = $null
      LastWUError      = $_.Exception.Message
      LastWUErrorTime  = $null
      Status           = 'Error'
    })
  } finally {
    Remove-PSSession -Session $sess -ErrorAction SilentlyContinue
  }
}


# Present summary
$results |
  Sort-Object Status, ComputerName |
  Format-Table ComputerName, Status, PendingReboot, UpdatesAvailable, LastWUError -AutoSize

# CSV log
$stamp = (Get-Date).ToString('yyyyMMdd_HHmmss')
$csv   = 'Update-Attention-Results_' + $stamp + '.csv'
$results | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
Write-Host ('`nSaved results to: ' + $csv + '`n') -ForegroundColor Green

# Reboot handling
$toReboot = $results | Where-Object { $_.Reachable -eq $true -and $_.Status -eq 'PendingReboot' }
if ($toReboot.Count -gt 0) {
  Write-Host ('Servers waiting on reboot: ' + $toReboot.Count) -ForegroundColor Yellow
  foreach ($row in $toReboot) {
    $target = $row.ComputerName
    $doReboot = $false
    if ($AutoReboot) {
      $doReboot = $true
    } else {
      $answer = Read-Host ('Reboot ' + $target + ' now? (Y/N)')
      if ($answer -match '^(y|yes)$') { $doReboot = $true }
    }

    if ($doReboot) {
      if ($PSCmdlet.ShouldProcess($target, 'Restart-Computer /t 5 /force')) {
        try {
          $restartParams = @{
            ComputerName = $target
            Force = $true
            ErrorAction = 'Stop'
          }
          if ($cred) { $restartParams.Credential = $cred }
          Restart-Computer @restartParams
          Write-Host ('  -> Reboot signaled: ' + $target) -ForegroundColor Green
        } catch {
          Write-Warning ('  -> Reboot failed: ' + $target + ' : ' + $_.Exception.Message)
        }
      }
    }
  }
} else {
  Write-Host 'No servers flagged as PendingReboot.' -ForegroundColor DarkGray
}

Write-Host '' -ForegroundColor Cyan
Write-Host 'Important Notes:' -ForegroundColor Cyan
Write-Host ' - Ensure WinRM is enabled on targets (Enable-PSRemoting -Force) and your admin creds are valid.' -ForegroundColor DarkGray
Write-Host ' - If using HTTPS with self-signed certs, -UseSSL -SkipCACheck -SkipCNCheck can help in labs.' -ForegroundColor DarkGray
Write-Host ' - Ports: 5985 (HTTP) and 5986 (HTTPS).' -ForegroundColor DarkGray

