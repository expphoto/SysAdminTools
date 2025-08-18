<# 
.SYNOPSIS
  Paste your "Needs attention" blob. Script extracts server names, checks reachability,
  Windows Update state, pending reboot, and recent WU errors. Optionally reboots boxes
  that are "installed, waiting for reboot". Prompts for a user to run as.

.USAGE
  Run elevated:
    powershell.exe -ExecutionPolicy Bypass -File .\Check-UpdateState.ps1
  Paste the report text, press Enter on a blank line.
  You'll be prompted: "Run remoting as (DOMAIN\User)". Leave blank to use current creds.
  Add -AutoReboot to skip prompts and reboot all that need it.

.PARAMETERS
  -AutoReboot        Reboot all servers that report "reboot required" without prompting.
  -ForceInstallUpdates  Force install Windows updates on servers with available updates after checking for 3GB free disk space.
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
  [switch]$ForceInstallUpdates,
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
$runAs = Read-Host "Run remoting as (DOMAIN\\User) - leave blank to use current credentials"
if ($runAs) {
  try {
    Write-Host "Prompting for password for user: $runAs" -ForegroundColor Yellow
    $cred = Get-Credential -UserName $runAs -Message "Enter password for $runAs"
    
    # Verify we actually got credentials
    if (-not $cred -or -not $cred.Password) {
      Write-Host "GUI credential dialog not available. Prompting for password manually..." -ForegroundColor Yellow
      $securePassword = Read-Host "Enter password for $runAs" -AsSecureString
      if ($securePassword -and $securePassword.Length -gt 0) {
        $cred = New-Object System.Management.Automation.PSCredential($runAs, $securePassword)
        Write-Host "Credentials obtained successfully for: $($cred.UserName)" -ForegroundColor Green
      } else {
        Write-Warning "No password provided. Using current credentials instead."
        $cred = $null
      }
    } else {
      Write-Host "Credentials obtained successfully for: $($cred.UserName)" -ForegroundColor Green
    }
  } catch {
    Write-Host "Credential dialog failed. Trying manual password entry..." -ForegroundColor Yellow
    try {
      $securePassword = Read-Host "Enter password for $runAs" -AsSecureString
      if ($securePassword -and $securePassword.Length -gt 0) {
        $cred = New-Object System.Management.Automation.PSCredential($runAs, $securePassword)
        Write-Host "Credentials obtained successfully for: $($cred.UserName)" -ForegroundColor Green
      } else {
        Write-Warning "No password provided. Using current credentials instead."
        $cred = $null
      }
    } catch {
      Write-Warning "Credential prompt failed: $($_.Exception.Message). Using current credentials."
      $cred = $null
    }
  }
}

# Function to configure TrustedHosts if needed
function Set-TrustedHostsIfNeeded {
  param([string[]]$Servers)
  
  try {
    $currentTrustedHosts = Get-Item WSMan:\localhost\Client\TrustedHosts -ErrorAction SilentlyContinue
    $currentList = if ($currentTrustedHosts.Value) { $currentTrustedHosts.Value.Split(',').Trim() } else { @() }
    
    $serversToAdd = @()
    foreach ($server in $Servers) {
      if ($server -notin $currentList -and $currentList -notcontains '*') {
        $serversToAdd += $server
      }
    }
    
    if ($serversToAdd.Count -gt 0) {
      $response = Read-Host "Some servers may need to be added to TrustedHosts for WinRM authentication. Add them? (Y/N)"
      if ($response -match '^(y|yes)$') {
        $newTrustedHosts = if ($currentTrustedHosts.Value) { 
          $currentTrustedHosts.Value + ',' + ($serversToAdd -join ',')
        } else {
          $serversToAdd -join ','
        }
        Set-Item WSMan:\localhost\Client\TrustedHosts -Value $newTrustedHosts -Force
        Write-Host "Added servers to TrustedHosts: $($serversToAdd -join ', ')" -ForegroundColor Green
        Write-Host "Note: You may need to restart PowerShell for changes to take effect." -ForegroundColor Yellow
      }
    }
  } catch {
    Write-Warning "Could not configure TrustedHosts: $($_.Exception.Message)"
    Write-Host "Manual fix: Run as Administrator: Set-Item WSMan:\localhost\Client\TrustedHosts -Value '*' -Force" -ForegroundColor Yellow
  }
}

# Timeout options (PowerShell 5.1 wants milliseconds)
# Extended timeout for update operations (1 hour)
$updateSessionOptions = New-PSSessionOption -OperationTimeout 3600000 -OpenTimeout 60000 -IdleTimeout 7200000
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

  function Test-DiskSpace {
    try {
      $drive = Get-WmiObject -Class Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop
      $freeSpaceGB = $drive.FreeSpace / 1GB
      return $freeSpaceGB -ge 3
    } catch {
      # If we can't check disk space, assume it's OK to proceed
      return $true
    }
  }

  function Get-WindowsUpdateSummary {
    $summary = [ordered]@{ CountAvailable = 0; LastError = $null; LastErrorTime = $null }
    try {
      $session  = New-Object -ComObject 'Microsoft.Update.Session'
      $searcher = $session.CreateUpdateSearcher()
      $search   = $searcher.Search("IsInstalled=0 and Type='Software' and IsHidden=0")
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

Write-Host ("`nDiscovered " + $servers.Count + " server(s). Probing...") -ForegroundColor Yellow

# Configure TrustedHosts if needed for WinRM authentication
if (-not $UseSSL) {
  Set-TrustedHostsIfNeeded -Servers $servers
}

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
    $errorMsg = $_.Exception.Message
    
    # If we get a WinRM authentication error, provide helpful guidance
    if ($errorMsg -match "WinRM client cannot process the request" -or $errorMsg -match "TrustedHosts") {
      Write-Host ("[FAIL] " + $s + " - WinRM Authentication Error") -ForegroundColor Red
      Write-Host "  Suggestion: Try one of these options:" -ForegroundColor Yellow
      Write-Host "  1. Run with -UseSSL parameter for HTTPS transport" -ForegroundColor Yellow
      Write-Host "  2. Add server to TrustedHosts: Set-Item WSMan:\localhost\Client\TrustedHosts -Value '$s' -Force" -ForegroundColor Yellow
      Write-Host "  3. Use domain credentials with -Authentication Kerberos" -ForegroundColor Yellow
    } else {
      Write-Host ("[FAIL] " + $s + " - Unreachable (" + $errorMsg + ")") -ForegroundColor Red
    }
    
    $results.Add([pscustomobject]@{
      ComputerName     = $s
      FQDN             = $null
      Reachable        = $false
      PendingReboot    = $null
      UpdatesAvailable = $null
      LastWUError      = $errorMsg
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

# Force install updates handling
if ($ForceInstallUpdates) {
  $toUpdate = $results | Where-Object { $_.Reachable -eq $true -and $_.Status -eq 'UpdatesAvailable' }
  # Handle both array and single object cases
  $toUpdateCount = if ($toUpdate -is [array]) { $toUpdate.Count } else { if ($toUpdate) { 1 } else { 0 } }
  if ($toUpdateCount -gt 0) {
    Write-Host ('Servers with available updates: ' + $toUpdateCount) -ForegroundColor Yellow
    foreach ($row in $toUpdate) {
      $target = $row.ComputerName
      # When ForceInstallUpdates is used, we install updates automatically without prompting
      $doUpdate = $true

      if ($doUpdate) {
        if ($PSCmdlet.ShouldProcess($target, 'Install Windows Updates')) {
          try {
            # Check disk space before installing updates
            $diskCheckScript = {
              try {
                $drive = Get-WmiObject -Class Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop
                $freeSpaceGB = $drive.FreeSpace / 1GB
                return $freeSpaceGB -ge 3
              } catch {
                # If we can't check disk space, assume it's OK to proceed
                return $true
              }
            }
            
            $hasSpace = Invoke-Command -ComputerName $target -ScriptBlock $diskCheckScript -ErrorAction Stop
            if (-not $hasSpace) {
              Write-Warning ('  -> Insufficient disk space on ' + $target + ' (minimum 3GB required)')
              continue
            }
            
            # Install updates
            $updateScript = {
              $ErrorActionPreference = 'Stop'
              try {
                # Check if PSWindowsUpdate module is available as an alternative approach
                if (Get-Module -ListAvailable -Name PSWindowsUpdate) {
                  Write-Output "PSWindowsUpdate module found, using it for more reliable update installation"
                  try {
                    # Import the module
                    Import-Module PSWindowsUpdate -Force -ErrorAction Stop
                    
                    # Install updates using PSWindowsUpdate
                    Write-Output "Installing updates on $env:COMPUTERNAME using PSWindowsUpdate..."
                    $updateResult = Install-WindowsUpdate -AcceptAll -AutoReboot:$AutoReboot -Verbose
                    
                    if ($updateResult) {
                      Write-Output "Successfully installed updates on $env:COMPUTERNAME using PSWindowsUpdate"
                      Write-Output "Update details:"
                      $updateResult | ForEach-Object { Write-Output "  - $($_.Title)" }
                    } else {
                      Write-Output "No updates were installed on $env:COMPUTERNAME"
                    }
                  } catch {
                    Write-Warning "PSWindowsUpdate failed: $($_.Exception.Message)"
                    Write-Output "Falling back to COM-based update installation..."
                    # Continue with the original COM-based approach below
                  }
                }
                
                # Fallback to COM-based approach if PSWindowsUpdate is not available or fails
                if (!(Get-Module -Name PSWindowsUpdate -ErrorAction SilentlyContinue) -or $updateResult -eq $null) {
                  Write-Output "Starting Windows Update installation on $env:COMPUTERNAME"
                  Write-Output "Note: Windows Update GUI may not show progress when run remotely"
                  Write-Output "Note: Check Windows Update history or Task Manager on the target machine to verify installation"
                  $session = New-Object -ComObject 'Microsoft.Update.Session'
                  $searcher = $session.CreateUpdateSearcher()
                  
                  # Improve COM object reliability
                  $searcher.ServerSelection = 1  # ssWindowsUpdate
                  $searcher.ServiceID = "7971f918-a847-4430-9279-4a52d1efe18d"  # Windows Update service
                  
                  $search = $searcher.Search("IsInstalled=0 and Type='Software' and IsHidden=0")
                  
                  if ($search.Updates.Count -eq 0) {
                    Write-Output "No updates found on $env:COMPUTERNAME"
                    # Cleanup COM objects
                    try { [System.Runtime.Interopservices.Marshal]::ReleaseComObject($searcher) | Out-Null } catch { }
                    try { [System.Runtime.Interopservices.Marshal]::ReleaseComObject($session) | Out-Null } catch { }
                    return
                  }
                  
                  Write-Output ("Found " + $search.Updates.Count + " updates on $env:COMPUTERNAME")
                  Write-Output "Update titles:"
                  foreach ($update in $search.Updates) {
                    Write-Output "  - $($update.Title)"
                  }
                  
                  $updatesToDownload = New-Object -ComObject 'Microsoft.Update.UpdateColl'
                  foreach ($update in $search.Updates) {
                    $updatesToDownload.Add($update) | Out-Null
                  }
                  
                  if ($updatesToDownload.Count -eq 0) {
                    Write-Output "No updates to download on $env:COMPUTERNAME"
                    # Cleanup COM objects
                    try { [System.Runtime.Interopservices.Marshal]::ReleaseComObject($updatesToDownload) | Out-Null } catch { }
                    try { [System.Runtime.Interopservices.Marshal]::ReleaseComObject($searcher) | Out-Null } catch { }
                    try { [System.Runtime.Interopservices.Marshal]::ReleaseComObject($session) | Out-Null } catch { }
                    return
                  }
                  
                  Write-Output "Downloading updates on $env:COMPUTERNAME..."
                  $downloader = $session.CreateUpdateDownloader()
                  $downloader.Updates = $updatesToDownload
                  $downloader.Priority = 3  # dpHigh
                  $downloadResult = $downloader.Download()
                  
                  if ($downloadResult.ResultCode -ne 2) {
                    Write-Error "Failed to download updates on $env:COMPUTERNAME (ResultCode: $($downloadResult.ResultCode))"
                    # Cleanup COM objects
                    try { [System.Runtime.Interopservices.Marshal]::ReleaseComObject($downloader) | Out-Null } catch { }
                    try { [System.Runtime.Interopservices.Marshal]::ReleaseComObject($updatesToDownload) | Out-Null } catch { }
                    try { [System.Runtime.Interopservices.Marshal]::ReleaseComObject($searcher) | Out-Null } catch { }
                    try { [System.Runtime.Interopservices.Marshal]::ReleaseComObject($session) | Out-Null } catch { }
                    return
                  }
                  
                  Write-Output "Installing updates on $env:COMPUTERNAME..."
                  Write-Output "Note: This may take several minutes. Please be patient."
                  $installer = $session.CreateUpdateInstaller()
                  $installer.Updates = $updatesToDownload
                  
                  # Try to show progress, though it may not appear in GUI when run remotely
                  $installer.ForceQuiet = $false
                  $installer.AllowSourcePrompts = $false
                  
                  $installResult = $installer.Install()
                  
                  # Cleanup COM objects
                  try { [System.Runtime.Interopservices.Marshal]::ReleaseComObject($installer) | Out-Null } catch { }
                  try { [System.Runtime.Interopservices.Marshal]::ReleaseComObject($downloader) | Out-Null } catch { }
                  try { [System.Runtime.Interopservices.Marshal]::ReleaseComObject($updatesToDownload) | Out-Null } catch { }
                  try { [System.Runtime.Interopservices.Marshal]::ReleaseComObject($searcher) | Out-Null } catch { }
                  try { [System.Runtime.Interopservices.Marshal]::ReleaseComObject($session) | Out-Null } catch { }
                  
                  if ($installResult.ResultCode -ne 2) {
                    Write-Error "Failed to install updates on $env:COMPUTERNAME (ResultCode: $($installResult.ResultCode))"
                    return
                  }
                  
                  Write-Output ("Successfully installed " + $installResult.Updates.Count + " updates on $env:COMPUTERNAME")
                  Write-Output "Verification steps:"
                  Write-Output "  1. Check Windows Update history on the target machine"
                  Write-Output "  2. Look for wuauclt.exe or TrustedInstaller.exe in Task Manager"
                  Write-Output "  3. Check Windows Update log: Get-WindowsUpdateLog"
                }
              } catch {
                Write-Error "Exception during update installation: $($_.Exception.Message)"
                throw $_
              }
            }
            
            $updateParams = @{
              ComputerName = $target
              ScriptBlock = $updateScript
              ErrorAction = 'Stop'
              SessionOption = $updateSessionOptions
            }
            if ($cred) { $updateParams.Credential = $cred }
            
            Invoke-Command @updateParams
            Write-Host ('  -> Updates installed successfully on: ' + $target) -ForegroundColor Green
            
            # Check if reboot is needed after updates
            $rebootCheckScript = ${function:Test-PendingReboot}
            
            $needsReboot = Invoke-Command -ComputerName $target -ScriptBlock $rebootCheckScript -ErrorAction Stop
            if ($needsReboot -and $AutoReboot) {
              Write-Host ('  -> Reboot needed after updates on: ' + $target) -ForegroundColor Yellow
              try {
                $restartParams = @{
                  ComputerName = $target
                  Force = $true
                  ErrorAction = 'Stop'
                }
                if ($cred) { $restartParams.Credential = $cred }
                Restart-Computer @restartParams
                Write-Host ('  -> Reboot signaled after updates on: ' + $target) -ForegroundColor Green
              } catch {
                Write-Warning ('  -> Failed to reboot after updates on: ' + $target + ' : ' + $_.Exception.Message)
              }
            } elseif ($needsReboot) {
              Write-Host ('  -> Reboot needed after updates on: ' + $target + ' (use -AutoReboot to auto-reboot)') -ForegroundColor Yellow
            }
          } catch {
            Write-Warning ('  -> Failed to install updates on: ' + $target + ' : ' + $_.Exception.Message)
          }
        }
      }
    }
  } else {
    Write-Host 'No servers with available updates.' -ForegroundColor DarkGray
  }
}

Write-Host "" -ForegroundColor Cyan
Write-Host "Important Notes:" -ForegroundColor Cyan
Write-Host " - Ensure WinRM is enabled on targets (Enable-PSRemoting -Force) and your admin creds are valid." -ForegroundColor DarkGray
Write-Host " - If using HTTPS with self-signed certs, -UseSSL -SkipCACheck -SkipCNCheck can help in labs." -ForegroundColor DarkGray
Write-Host " - For WinRM auth issues: Use -UseSSL or add servers to TrustedHosts or use domain auth." -ForegroundColor DarkGray
Write-Host " - Ports: 5985 (HTTP) and 5986 (HTTPS)." -ForegroundColor DarkGray
Write-Host " - When using -ForceInstallUpdates: Windows Update GUI may not show progress when run remotely." -ForegroundColor DarkGray
Write-Host " - Check Task Manager (wuauclt.exe/TrustedInstaller.exe) or Windows Update history to verify installation." -ForegroundColor DarkGray
