# Working Interactive Patching Automation - Tested and Fixed
# Handles interactive input parsing and domain authentication

[CmdletBinding()]
param(
    # 0 or less = run until everything is clear
    [int]$MaxCycles = 0,
    # default retry cadence
    [int]$RetryIntervalMinutes = 5,
    # how long to wait for a server to come back from reboot before moving on
    [int]$RebootWaitMinutes = 10,
    [switch]$AutoFixWinRM = $true,
    [switch]$ForceSystemInstall = $false,
    [switch]$CleanupTasks = $true,
    [switch]$MonitorSystemInstall = $true,
    [int]$SystemInstallTimeoutMinutes = 60,
    # Optional non-interactive inputs
    [string[]]$Servers,
    [string]$Username,
    [string]$Password,
    [string]$Domain,
    [switch]$UseLocalAccount,
    [switch]$RepairWindowsUpdate,
    [switch]$TestMode,
    [switch]$QuickTest
)

$script:StartTime = Get-Date
$script:Cycles = 0
$script:LogFile = "Working-Patching-Log_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logEntry = "[$timestamp] [$Level] $Message"
    
    $color = "White"
    if ($Level -eq "ERROR") { $color = "Red" }
    elseif ($Level -eq "WARN") { $color = "Yellow" }
    elseif ($Level -eq "SUCCESS") { $color = "Green" }
    elseif ($Level -eq "INFO") { $color = "Cyan" }
    
    Write-Host $logEntry -ForegroundColor $color
    $logEntry | Out-File -FilePath $script:LogFile -Append -Encoding UTF8
}

# Export connectivity results to CSV (always generated after reachability tests)
function Export-ConnectivityReport {
    param(
        [Parameter(Mandatory=$true)]
        [array]$Details
    )
    try {
        $file = "Working-Connectivity-Results_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
        if ($Details -and $Details.Count -gt 0) {
            $Details | Export-Csv -Path $file -NoTypeInformation -Encoding UTF8
            Write-Log "Connectivity report exported: $file" "SUCCESS"
        } else {
            # Create an empty CSV with headers for consistency
            [PSCustomObject]@{
                Server=''
                Reachable=$false
                RemoteComputerName=''
                Domain=''
                OS=''
                FreeSpaceGB=0
                Message='No data'
            } | Select-Object Server,Reachable,RemoteComputerName,Domain,OS,FreeSpaceGB,Message | Export-Csv -Path $file -NoTypeInformation -Encoding UTF8
            Write-Log "Connectivity report created (no data): $file" "WARN"
        }
        return $file
    } catch {
        Write-Log "Failed to write connectivity report: $($_.Exception.Message)" "ERROR"
        return $null
    }
}

# Export a simple targets CSV when user quits before connectivity
function Export-TargetsReport {
    param(
        [Parameter(Mandatory=$true)] [array]$Targets,
        [string]$Reason = 'Cancelled'
    )
    try {
        $file = "Working-Targets_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
        $Targets | ForEach-Object {
            [PSCustomObject]@{ Server = $_; Reason = $Reason }
        } | Export-Csv -Path $file -NoTypeInformation -Encoding UTF8
        Write-Log "Targets report exported: $file" "SUCCESS"
        return $file
    } catch {
        Write-Log "Failed to write targets report: $($_.Exception.Message)" "ERROR"
        return $null
    }
}

function Show-Banner {
    Clear-Host
    Write-Host ""
    Write-Host "================================================================" -ForegroundColor Cyan
    Write-Host "        WORKING INTERACTIVE PATCHING AUTOMATION                " -ForegroundColor Cyan  
    Write-Host "================================================================" -ForegroundColor Cyan
    Write-Host "  • Paste your server list or needs attention report          " -ForegroundColor Cyan
    Write-Host "  • Automatic parsing of hostnames, IPs, and server names     " -ForegroundColor Cyan
    Write-Host "  • Domain authentication with credential prompts             " -ForegroundColor Cyan
    Write-Host "  • Continuous remediation until ALL systems are clean        " -ForegroundColor Cyan
    Write-Host "================================================================" -ForegroundColor Cyan
    Write-Host ""
    
    if ($TestMode) {
        Write-Host "*** TEST MODE ENABLED - No actual changes will be made ***" -ForegroundColor Yellow -BackgroundColor Red
        Write-Host ""
    }
}

function Test-IsAdmin {
    try {
        $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Wait-ForServerOnline {
    param(
        [Parameter(Mandatory=$true)][string]$Server,
        [Parameter(Mandatory=$true)]$Credential,
        [int]$TimeoutSeconds = 600,
        [int]$PollSeconds = 15
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        try {
            $ws = Test-WSMan -ComputerName $Server -Credential $Credential -Authentication Default -ErrorAction Stop
            if ($ws) { return $true }
        } catch {}
        Start-Sleep -Seconds $PollSeconds
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Repair-WinRMRemote {
    param(
        [Parameter(Mandatory=$true)][string]$Server,
        [Parameter(Mandatory=$true)]$Credential
    )
    Write-Log "Attempting WinRM remediation on $Server (via WMI/DCOM)" "WARN"
    $command = @'
powershell -NoProfile -ExecutionPolicy Bypass -Command "try { 
  Enable-PSRemoting -Force -SkipNetworkProfileCheck;
  winrm quickconfig -quiet;
  netsh advfirewall firewall set rule group='Windows Remote Management' new enable=yes | Out-Null;
  Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'LocalAccountTokenFilterPolicy' -Value 1 -Type DWord -Force;
  Start-Service -Name bits -ErrorAction SilentlyContinue;
  Start-Service -Name wuauserv -ErrorAction SilentlyContinue;
  Write-Host 'OK' 
} catch { Write-Host ('ERR:' + ($_.Exception.Message)) }"
'@
    try {
        $res = Invoke-WmiMethod -Class Win32_Process -Name Create -ComputerName $Server -Credential $Credential -ArgumentList $command -ErrorAction Stop
        if ($res.ReturnValue -eq 0) {
            Write-Log "WinRM remediation command launched (PID $($res.ProcessId))" "INFO"
            Start-Sleep -Seconds 10
            return $true
        } else {
            Write-Log "WMI process creation returned code $($res.ReturnValue)" "WARN"
        }
    } catch {
        Write-Log "WMI remediation failed: $($_.Exception.Message)" "ERROR"
    }
    return $false
}

function Get-ServersFromInput {
    Write-Host "SERVER INPUT:" -ForegroundColor Yellow
    Write-Host "You can paste any of the following:" -ForegroundColor White
    Write-Host "  • Server names (one per line or comma-separated)" -ForegroundColor Gray
    Write-Host "  • IP addresses (mixed with hostnames is fine)" -ForegroundColor Gray
    Write-Host "  • Complete needs attention report text" -ForegroundColor Gray
    Write-Host "  • Mixed format with extra text (script will parse automatically)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Paste your input below, then press ENTER on an empty line to finish:" -ForegroundColor Yellow
    Write-Host ""
    
    $inputLines = @()
    $lineCount = 0
    
    do {
        $lineCount++
        $prompt = "Line $lineCount"
        $line = Read-Host $prompt
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            $inputLines += $line
            Write-Host "  Added: $($line.Length) characters" -ForegroundColor Green
        }
    } while (-not [string]::IsNullOrWhiteSpace($line))
    
    if ($inputLines.Count -eq 0) {
        Write-Host "No input provided!" -ForegroundColor Red
        return @()
    }
    
    Write-Host ""
    Write-Host "Processing $($inputLines.Count) lines of input..." -ForegroundColor Cyan
    
    # Join all input and parse
    $allText = $inputLines -join " "
    
    # Find IP addresses
    $ipPattern = '\b(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\b'
    $ipMatches = [regex]::Matches($allText, $ipPattern) | ForEach-Object { $_.Value.ToLower().Trim() }
    
    # Find hostnames
    $hostPattern = '(?i)\b[a-z0-9](?:[a-z0-9\-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9\-]{0,61}[a-z0-9])?)*\b'
    $hostMatches = [regex]::Matches($allText, $hostPattern) | ForEach-Object { $_.Value.ToLower().Trim() }
    
    $allMatches = @()
    $allMatches += $ipMatches
    $allMatches += $hostMatches
    
    Write-Host "  Found $($ipMatches.Count) IP addresses" -ForegroundColor Gray
    Write-Host "  Found $($hostMatches.Count) potential hostnames" -ForegroundColor Gray
    
    # Filter results
    $excludeWords = @(
        'error', 'failed', 'success', 'ok', 'true', 'false', 'status', 'reboot', 'update', 'pending',
        'system', 'windows', 'microsoft', 'service', 'running', 'stopped', 'installed', 'available',
        'required', 'attention', 'needs', 'server', 'computer', 'machine', 'host', 'name', 'address',
        'the', 'and', 'for', 'are', 'with', 'this', 'that', 'have', 'been', 'will', 'from', 'they',
        'com', 'org', 'net', 'edu', 'gov', 'mil', 'int', 'www', 'http', 'https', 'ftp'
    )
    
    $filteredServers = $allMatches | Where-Object {
        $server = $_
        # Length check
        $server.Length -ge 3 -and $server.Length -le 253 -and
        # Not in exclude list
        $server -notin $excludeWords -and
        # Not just numbers unless its an IP
        ($server -match '\.' -or $server -notmatch '^\d+$') -and
        # Not common non-server patterns
        $server -notmatch '^(localhost|127\.0\.0\.1|0\.0\.0\.0|255\.255\.255\.255)$' -and
        # Has reasonable server name characteristics
        ($server -match '^(\d{1,3}\.){3}\d{1,3}$' -or $server -match '^[a-z0-9\-\.]+$')
    } | Select-Object -Unique | Sort-Object
    
    Write-Host ""
    if ($filteredServers.Count -gt 0) {
        Write-Host "Successfully extracted $($filteredServers.Count) unique servers:" -ForegroundColor Green
        $filteredServers | ForEach-Object { 
            Write-Host "   • $_" -ForegroundColor White 
        }
    } else {
        Write-Host "No valid server names or IP addresses found in the input" -ForegroundColor Red
        Write-Host "Please try again with clearer server identification" -ForegroundColor Yellow
    }
    
    return $filteredServers
}

function Get-DomainCredentials {
    Write-Host ""
    Write-Host "DOMAIN AUTHENTICATION:" -ForegroundColor Yellow
    Write-Host ""
    
    # Get domain/username
    $defaultDomain = $env:USERDOMAIN
    if ($defaultDomain -and $defaultDomain -ne $env:COMPUTERNAME) {
        $domainPrompt = "Domain (default: $defaultDomain)"
    } else {
        $domainPrompt = "Domain (e.g. CONTOSO)"
    }
    
    $domain = Read-Host $domainPrompt
    if ([string]::IsNullOrWhiteSpace($domain)) {
        $domain = $defaultDomain
    }
    
    # Get username
    $username = Read-Host "Username (without domain)"
    if ([string]::IsNullOrWhiteSpace($username)) {
        Write-Host "Username is required" -ForegroundColor Red
        return $null
    }
    
    # Construct full username
    $fullUsername = "$domain\$username"
    
    # Get password
    Write-Host ""
    Write-Host "Enter password for $fullUsername" -ForegroundColor Yellow
    $securePassword = Read-Host "Password" -AsSecureString
    
    if ($securePassword.Length -eq 0) {
        Write-Host "Password is required" -ForegroundColor Red
        return $null
    }
    
    # Create credential object
    try {
        $credential = New-Object System.Management.Automation.PSCredential($fullUsername, $securePassword)
        Write-Host "Credentials configured for: $fullUsername" -ForegroundColor Green
        return $credential
    } catch {
        Write-Host "Failed to create credential object: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}

# System analysis script
$SystemAnalysisScript = {
    $analysis = @{
        ComputerName = $env:COMPUTERNAME
        Status = 'Unknown'
        HealthScore = 100
        UpdatesTotal = 0
        PendingReboot = $false
        DiskSpaceGB = 0
        Issues = @()
        WindowsVersion = ""
    }
    
    try {
        # Get system info
        $os = Get-WmiObject Win32_OperatingSystem
        $analysis.WindowsVersion = $os.Caption
        
        # Check disk space
        $drive = Get-WmiObject Win32_LogicalDisk -Filter "DeviceID='C:'"
        $analysis.DiskSpaceGB = [math]::Round($drive.FreeSpace / 1GB, 2)
        if ($analysis.DiskSpaceGB -lt 5) {
            $analysis.Issues += "Low disk space: $($analysis.DiskSpaceGB) GB free"
            $analysis.HealthScore -= 25
        } elseif ($analysis.DiskSpaceGB -lt 10) {
            $analysis.Issues += "Moderate disk space: $($analysis.DiskSpaceGB) GB free"
            $analysis.HealthScore -= 10
        }
        
        # Check pending reboot
        $rebootPaths = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
        )
        
        foreach ($path in $rebootPaths) {
            if (Test-Path $path) {
                $analysis.PendingReboot = $true
                $analysis.Issues += "Pending reboot required"
                $analysis.HealthScore -= 20
                break
            }
        }
        
        # Check file operations
        $pfro = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue
        if ($pfro -and $pfro.PendingFileRenameOperations) {
            $analysis.PendingReboot = $true
            if ("Pending reboot required" -notin $analysis.Issues) {
                $analysis.Issues += "Pending reboot required"
                $analysis.HealthScore -= 20
            }
        }
        
        # Check Windows Updates
        try {
            $updateSession = New-Object -ComObject 'Microsoft.Update.Session'
            $updateSearcher = $updateSession.CreateUpdateSearcher()
            $searchResult = $updateSearcher.Search("IsInstalled=0 and Type='Software' and IsHidden=0")
            $analysis.UpdatesTotal = $searchResult.Updates.Count
            
            if ($analysis.UpdatesTotal -gt 0) {
                $analysis.Issues += "$($analysis.UpdatesTotal) Windows updates available"
                if ($analysis.UpdatesTotal -gt 10) {
                    $analysis.HealthScore -= 30
                } else {
                    $analysis.HealthScore -= 15
                }
            }
            
            # Cleanup COM objects
            [System.Runtime.Interopservices.Marshal]::ReleaseComObject($updateSearcher) | Out-Null
            [System.Runtime.Interopservices.Marshal]::ReleaseComObject($updateSession) | Out-Null
            
        } catch {
            $analysis.Issues += "Windows Update service error"
            $analysis.HealthScore -= 25
        }
        
        # Determine status
        if ($analysis.HealthScore -ge 95) { $analysis.Status = 'Excellent' }
        elseif ($analysis.HealthScore -ge 85) { $analysis.Status = 'VeryGood' }
        elseif ($analysis.HealthScore -ge 70) { $analysis.Status = 'Good' }
        elseif ($analysis.HealthScore -ge 50) { $analysis.Status = 'NeedsAttention' }
        elseif ($analysis.HealthScore -ge 30) { $analysis.Status = 'Poor' }
        else { $analysis.Status = 'Critical' }
        
    } catch {
        $analysis.Status = 'AnalysisError'
        $analysis.Issues += "System analysis failed"
        $analysis.HealthScore = 0
    }
    
    return [PSCustomObject]$analysis
}

# Disk cleanup script
$DiskCleanupScript = {
    $result = @{
        Success = $false
        Actions = @()
        FreeSpaceBefore = 0
        FreeSpaceAfter = 0
    }
    
    try {
        # Get initial space
        $drive = Get-WmiObject Win32_LogicalDisk -Filter "DeviceID='C:'"
        $result.FreeSpaceBefore = [math]::Round($drive.FreeSpace / 1GB, 2)
        $result.Actions += "Initial space: $($result.FreeSpaceBefore) GB"
        
        if ($result.FreeSpaceBefore -ge 10) {
            $result.Success = $true
            $result.Actions += "Sufficient space available - cleanup not needed"
            return $result
        }
        
        $result.Actions += "Starting comprehensive disk cleanup..."
        
        # Clean temp folders
        $cleanupPaths = @(
            "$env:TEMP",
            "$env:WINDIR\Temp", 
            "$env:WINDIR\SoftwareDistribution\Download",
            "$env:WINDIR\Logs",
            "$env:LOCALAPPDATA\Temp"
        )
        
        foreach ($path in $cleanupPaths) {
            try {
                if (Test-Path $path) {
                    $itemsBefore = (Get-ChildItem $path -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object).Count
                    Get-ChildItem $path -Recurse -Force -ErrorAction SilentlyContinue |
                        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
                        Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
                    $itemsAfter = (Get-ChildItem $path -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object).Count
                    $itemsRemoved = $itemsBefore - $itemsAfter
                    if ($itemsRemoved -gt 0) {
                        $result.Actions += "Cleaned $path - removed $itemsRemoved items"
                    }
                }
            } catch {
                $result.Actions += "Failed to clean $path"
            }
        }
        
        # Run DISM cleanup if available
        try {
            $result.Actions += "Running DISM component cleanup..."
            $dismProcess = Start-Process -FilePath "Dism.exe" -ArgumentList "/online", "/Cleanup-Image", "/StartComponentCleanup" -Wait -PassThru -WindowStyle Hidden
            if ($dismProcess.ExitCode -eq 0) {
                $result.Actions += "DISM cleanup completed successfully"
            } else {
                $result.Actions += "DISM cleanup completed with warnings"
            }
        } catch {
            $result.Actions += "DISM cleanup failed or not available"
        }
        
        # Check final space
        $drive = Get-WmiObject Win32_LogicalDisk -Filter "DeviceID='C:'"
        $result.FreeSpaceAfter = [math]::Round($drive.FreeSpace / 1GB, 2)
        $spaceRecovered = [math]::Round($result.FreeSpaceAfter - $result.FreeSpaceBefore, 2)
        $result.Actions += "Final space: $($result.FreeSpaceAfter) GB (recovered: $spaceRecovered GB)"
        
        $result.Success = $result.FreeSpaceAfter -gt $result.FreeSpaceBefore
        
    } catch {
        $result.Actions += "Critical cleanup error occurred"
    }
    
    return $result
}

# Windows Update installation script (runs on remote)
$InstallWindowsUpdatesScript = {
    $result = @{
        SearchedCount   = 0
        DownloadedCount = 0
        InstalledCount  = 0
        RebootRequired  = $false
        Messages        = @()
        Success         = $false
        PerUpdate       = @()
        Diagnostics     = @()
    }
    try {
        # Hint the modern Windows Update Orchestrator (USO) so that Settings UI reflects activity.
        try {
            foreach ($cmd in @('StartScan','StartDownload','StartInstall')) {
                Start-Process -FilePath 'usoclient.exe' -ArgumentList $cmd -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null
                Start-Sleep -Seconds 2
            }
            $result.Messages += 'USO triggered: StartScan/StartDownload/StartInstall'
        } catch {}

        # Basic service diagnostics
        try {
            $wu = Get-Service -Name wuauserv -ErrorAction Stop
            $bits = Get-Service -Name BITS -ErrorAction Stop
            $result.Diagnostics += "WU Service: $($wu.Status) | BITS: $($bits.Status)"
        } catch {
            $result.Diagnostics += "Service diagnostics failed: $($_.Exception.Message)"
        }

        $session   = New-Object -ComObject 'Microsoft.Update.Session'
        $searcher  = $session.CreateUpdateSearcher()
        $criteria  = "IsInstalled=0 and IsHidden=0"  # broader criteria; include drivers if applicable
        $search    = $searcher.Search($criteria)
        try { $result.Diagnostics += "ServerSelection: $($searcher.ServerSelection) | Online: $($searcher.Online)" } catch {}

        $result.SearchedCount = $search.Updates.Count
        if ($search.Updates.Count -eq 0) {
            $result.Messages += 'No updates available'
            $result.Success = $true
            return $result
        }

        $toInstall = New-Object -ComObject 'Microsoft.Update.UpdateColl'
        for ($i = 0; $i -lt $search.Updates.Count; $i++) {
            $upd = $search.Updates.Item($i)
            try { if (-not $upd.EulaAccepted) { $upd.AcceptEula() } } catch {}
            [void]$toInstall.Add($upd)
            try {
                $kb = if ($upd.KBArticleIDs) { ($upd.KBArticleIDs -join ',') } else { '' }
                $cats = @(); foreach($c in $upd.Categories){ $cats += $c.Name }
                $result.PerUpdate += "Queued: '" + $upd.Title + "' KB:" + $kb + " | Downloaded:" + $upd.IsDownloaded + " | Categories:" + ($cats -join ';')
            } catch {}
        }

        $downloader = $session.CreateUpdateDownloader()
        $downloader.Updates = $toInstall
        try { $downloader.Priority = 3 } catch {}
        $dlRes = $downloader.Download()
        try { $result.Diagnostics += "Download ResultCode: $($dlRes.ResultCode) | HResult: " + ('0x{0:X8}' -f [uint32]$dlRes.HResult) } catch {}
        $result.DownloadedCount = ($toInstall | Where-Object { $_.IsDownloaded }).Count

        $installer = $session.CreateUpdateInstaller()
        $installer.Updates = $toInstall
        try { $installer.ForceQuiet = $true } catch {}
        try { $installer.AllowSourcePrompts = $false } catch {}
        $instRes = $installer.Install()
        $result.InstalledCount = $instRes.UpdatesInstalled
        $result.RebootRequired = [bool]$instRes.RebootRequired
        $result.Messages += "Install ResultCode: $($instRes.ResultCode) | HResult: " + ('0x{0:X8}' -f [uint32]$instRes.HResult)
        # Interpret installer result: 2=Succeeded, 3=SucceededWithErrors, 4=Failed, 5=Aborted
        if ($instRes.ResultCode -eq 2) {
            $result.Success = $true
        } elseif ($instRes.ResultCode -eq 3) {
            $result.Success = $true
            $result.Messages += 'Succeeded with some errors'
        } else {
            $result.Success = $false
        }

        # Per-update outcomes (best-effort)
        for ($i = 0; $i -lt $toInstall.Count; $i++) {
            try {
                $upd = $toInstall.Item($i)
                $uRes = $instRes.GetUpdateResult($i)
                $result.PerUpdate += "Result: '" + $upd.Title + "' -> ResultCode: " + $uRes.ResultCode + ", HResult: " + ('0x{0:X8}' -f [uint32]$uRes.HResult) + ", IsDownloaded:" + $upd.IsDownloaded
            } catch {}
        }

        # Cleanup COM
        [System.Runtime.Interopservices.Marshal]::ReleaseComObject($installer)   | Out-Null
        [System.Runtime.Interopservices.Marshal]::ReleaseComObject($downloader)  | Out-Null
        [System.Runtime.Interopservices.Marshal]::ReleaseComObject($searcher)    | Out-Null
        [System.Runtime.Interopservices.Marshal]::ReleaseComObject($session)     | Out-Null

        # Best-effort: write an Application event so admins see activity in GUI tools
        try {
            $source = 'InteractivePatchingAutomation'
            if (-not [System.Diagnostics.EventLog]::SourceExists($source)) {
                New-EventLog -LogName Application -Source $source -ErrorAction SilentlyContinue | Out-Null
            }
            $msg = "Installed: $($result.InstalledCount) (of $($result.SearchedCount)) | RebootRequired: $($result.RebootRequired)"
            Write-EventLog -LogName Application -Source $source -EntryType Information -EventId 10000 -Message $msg -ErrorAction SilentlyContinue
        } catch {}
    } catch {
        $result.Messages += "Windows Update install error: $($_.Exception.Message)"
    }
    return $result
}

# Optional Windows Update component repair (runs on remote)
$RepairWUScript = {
    $out = @()
    try {
        $out += 'Stopping services: wuauserv, bits, cryptsvc'
        Stop-Service -Name wuauserv,bits,cryptsvc -ErrorAction SilentlyContinue -Force
        Start-Sleep -Seconds 3
        $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
        $sd = Join-Path $env:WINDIR 'SoftwareDistribution'
        $cr = Join-Path $env:WINDIR 'System32\catroot2'
        if (Test-Path $sd) { Rename-Item -Path $sd -NewName ("SoftwareDistribution.bak_" + $ts) -Force; $out += 'Renamed SoftwareDistribution' }
        if (Test-Path $cr) { Rename-Item -Path $cr -NewName ("catroot2.bak_" + $ts) -Force; $out += 'Renamed catroot2' }
        $out += 'Starting services: cryptsvc, bits, wuauserv'
        Start-Service -Name cryptsvc,bits,wuauserv -ErrorAction SilentlyContinue
        $out += 'RepairWU: Completed basic reset'
    } catch {
        $out += ('RepairWU error: ' + $_.Exception.Message)
    }
    return $out
}

# Main script execution
Show-Banner

try {
    # Phase 1: Get server list
    Write-Log "Starting Working Interactive Patching Automation" "SUCCESS"
    if ($null -ne $Servers -and $Servers.Count -gt 0) {
        $servers = $Servers | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() }
        Write-Host "Using servers from parameters: $($servers -join ', ')" -ForegroundColor Cyan
    } else {
        $servers = Get-ServersFromInput
    }
    
    if ($servers.Count -eq 0) {
        Write-Log "No servers to process - exiting" "ERROR"
        Read-Host "Press Enter to exit"
        exit 1
    }
    
    # Phase 2: Get credentials
    Write-Host ""
    $credential = $null
    $credentialMap = @{}
    if ($Username -and $Password) {
        if ($UseLocalAccount) {
            # Create per-server local credentials: <server>\<username>
            $sec = ConvertTo-SecureString -String $Password -AsPlainText -Force
            foreach ($s in $servers) {
                $u = "$s\$Username"
                $credentialMap[$s] = New-Object System.Management.Automation.PSCredential($u, $sec)
            }
            Write-Log "Using per-server local Administrator credentials (UseLocalAccount)" "INFO"
        } else {
            $fullUser = if ($Domain) { "$Domain\$Username" } else { $Username }
            $sec = ConvertTo-SecureString -String $Password -AsPlainText -Force
            $credential = New-Object System.Management.Automation.PSCredential($fullUser, $sec)
            Write-Log "Using provided credentials for all servers: $fullUser" "INFO"
        }
    } else {
        $credential = Get-DomainCredentials
        if (-not $credential) {
            Write-Log "Failed to obtain credentials - exiting" "ERROR"
            Read-Host "Press Enter to exit"
            exit 1
        }
    }
    
    # Phase 3: Configuration summary
    Write-Host ""
    Write-Host "PROCESSING CONFIGURATION:" -ForegroundColor Cyan
    Write-Host "  Servers to process: $($servers.Count)" -ForegroundColor White
    if ($credential) {
        Write-Host "  Authentication: $($credential.UserName)" -ForegroundColor White
    } else {
        Write-Host "  Authentication: per-server local account ($Username)" -ForegroundColor White
    }
    Write-Host "  Max cycles: $MaxCycles" -ForegroundColor White
    Write-Host "  Retry interval: $RetryIntervalMinutes minutes" -ForegroundColor White
    if ($TestMode) {
        Write-Host "  Test mode: YES (safe)" -ForegroundColor Yellow
    } else {
        Write-Host "  Test mode: NO (will make changes)" -ForegroundColor Red
    }
    Write-Host ""
    
    if (-not $QuickTest) {
        $confirm = Read-Host "Continue with processing? (Y/N)"
        if ($confirm -notmatch '^y|yes$') {
            Write-Log "Processing cancelled by user" "WARN"
            Export-TargetsReport -Targets $servers -Reason 'UserCancelledAtConfirmation' | Out-Null
            exit 0
        }
    }
    
    # Configure local WinRM TrustedHosts (optional, requires admin)
    if (Test-IsAdmin) {
        try {
            Set-Item WSMan:\localhost\Client\TrustedHosts -Value ($servers -join ',') -Force -Confirm:$false
            Write-Log "WinRM TrustedHosts configured" "SUCCESS"
        } catch {
            Write-Log "WinRM configuration warning: $($_.Exception.Message)" "WARN"
        }
    } else {
        Write-Log "Skipping TrustedHosts update (not elevated). Run PowerShell as Administrator to suppress this warning." "WARN"
    }
    
    # Phase 4: Connectivity testing
    Write-Log ""
    Write-Log "PHASE 1: Testing Connectivity" "INFO"
    $reachableServers = @()
    $reachabilityDetails = @()
    
    foreach ($server in $servers) {
        Write-Log "Testing $server..." "INFO"
        
        try {
            $credToUse = if ($credentialMap.ContainsKey($server)) { $credentialMap[$server] } else { $credential }
            $sessionParams = @{
                ComputerName = $server
                Credential = $credToUse
                ErrorAction = 'Stop'
            }
            
            $session = New-PSSession @sessionParams
            $remoteInfo = Invoke-Command -Session $session -ScriptBlock {
                @{
                    ComputerName = $env:COMPUTERNAME
                    Domain = $env:USERDOMAIN
                    OS = (Get-WmiObject Win32_OperatingSystem).Caption
                    FreeSpaceGB = [math]::Round((Get-WmiObject Win32_LogicalDisk -Filter "DeviceID='C:'").FreeSpace / 1GB, 2)
                }
            }
            Remove-PSSession $session
            
            $reachableServers += $server
            $reachabilityDetails += [PSCustomObject]@{
                Server = $server
                Reachable = $true
                RemoteComputerName = $remoteInfo.ComputerName
                Domain = $remoteInfo.Domain
                OS = $remoteInfo.OS
                FreeSpaceGB = $remoteInfo.FreeSpaceGB
                Message = 'OK'
            }
            Write-Log "SUCCESS: $server -> $($remoteInfo.ComputerName) | Domain: $($remoteInfo.Domain) | OS: $($remoteInfo.OS) | Free: $($remoteInfo.FreeSpaceGB) GB" "SUCCESS"
            
        } catch {
            $err = $_.Exception.Message
            Write-Log "FAILED: $server - $err" "ERROR"
            if ($AutoFixWinRM -and $err -match 'WinRM|Access is denied|cannot connect|The client cannot connect') {
                $credFix = if ($credentialMap.ContainsKey($server)) { $credentialMap[$server] } else { $credential }
                if (Repair-WinRMRemote -Server $server -Credential $credFix) {
                    Write-Log "Retrying WinRM connection after remediation..." "INFO"
                    Start-Sleep -Seconds 10
                    try {
                        $sessionParams.Credential = $credFix
                        $session = New-PSSession @sessionParams
                        $remoteInfo = Invoke-Command -Session $session -ScriptBlock {
                            @{
                                ComputerName = $env:COMPUTERNAME
                                Domain = $env:USERDOMAIN
                                OS = (Get-WmiObject Win32_OperatingSystem).Caption
                                FreeSpaceGB = [math]::Round((Get-WmiObject Win32_LogicalDisk -Filter "DeviceID='C:'").FreeSpace / 1GB, 2)
                            }
                        }
                        Remove-PSSession $session
                        $reachableServers += $server
                        $reachabilityDetails += [PSCustomObject]@{
                            Server = $server; Reachable=$true; RemoteComputerName=$remoteInfo.ComputerName; Domain=$remoteInfo.Domain; OS=$remoteInfo.OS; FreeSpaceGB=$remoteInfo.FreeSpaceGB; Message='OK (after remediation)'
                        }
                        Write-Log "SUCCESS: $server -> $($remoteInfo.ComputerName) | Domain: $($remoteInfo.Domain) | OS: $($remoteInfo.OS) | Free: $($remoteInfo.FreeSpaceGB) GB" "SUCCESS"
                        continue
                    } catch {
                        Write-Log "WinRM still failing after remediation: $($_.Exception.Message)" "ERROR"
                    }
                }
            }
            $reachabilityDetails += [PSCustomObject]@{
                Server = $server
                Reachable = $false
                RemoteComputerName = ''
                Domain = ''
                OS = ''
                FreeSpaceGB = 0
                Message = $err
            }
        }
    }
    
    if ($reachableServers.Count -eq 0) {
        Write-Log "No servers are reachable. Check connectivity, credentials, and network access." "ERROR"
        Read-Host "Press Enter to exit"
        exit 1
    }
    
    Write-Log "Phase 1 Complete: $($reachableServers.Count) of $($servers.Count) servers are reachable" "SUCCESS"
    Export-ConnectivityReport -Details $reachabilityDetails | Out-Null
    
    if ($QuickTest) {
        Write-Log "Quick connectivity test completed successfully!" "SUCCESS"
        Write-Host ""
        Write-Host "All systems are ready for full automation!" -ForegroundColor Green
        Read-Host "Press Enter to exit"
        exit 0
    }
    
    # Phase 5: Continuous remediation
    Write-Log ""
    Write-Log "PHASE 2: Continuous Remediation Loop" "INFO"
    
    $allResults = @()
    $serversNeedingWork = $reachableServers
    
    do {
        $script:Cycles++
        $cycleLabel = if ($MaxCycles -le 0) { "(no max)" } else { "of $MaxCycles" }
        Write-Log "Starting Remediation Cycle $script:Cycles $cycleLabel" "INFO"
        Write-Log "   Processing $($serversNeedingWork.Count) servers: $($serversNeedingWork -join ', ')" "INFO"
        
        $cycleResults = @()
        $stillNeedWork = @()
        $returnedEarlyThisCycle = $false
        
        foreach ($server in $serversNeedingWork) {
            Write-Log "Processing $server (Cycle $script:Cycles)..." "INFO"
            
            $remediation = @{
                Server = $server
                Success = $false
                Analysis = $null
                ActionsPerformed = @()
            }
            
            try {
                # Create session
                $credToUse = if ($credentialMap.ContainsKey($server)) { $credentialMap[$server] } else { $credential }
                $sessionParams = @{
                    ComputerName = $server
                    Credential = $credToUse
                    ErrorAction = 'Stop'
                }
                $session = New-PSSession @sessionParams
                
                # Run analysis
                $analysis = Invoke-Command -Session $session -ScriptBlock $SystemAnalysisScript
                $remediation.Analysis = $analysis
                
                Write-Log "  Analysis:" "INFO"
                Write-Log "     Status: $($analysis.Status) | Health: $($analysis.HealthScore)/100" "INFO"
                Write-Log "     OS: $($analysis.WindowsVersion)" "INFO"
                Write-Log "     Updates: $($analysis.UpdatesTotal) | Reboot: $($analysis.PendingReboot)" "INFO"
                Write-Log "     Disk: $($analysis.DiskSpaceGB) GB" "INFO"
                
                if ($analysis.Issues.Count -gt 0) {
                    Write-Log "     Issues: $($analysis.Issues -join '; ')" "WARN"
                }
                
                # Perform remediation when updates/reboot/disk need attention OR status indicates issues
                if ($analysis.UpdatesTotal -gt 0 -or $analysis.PendingReboot -or $analysis.DiskSpaceGB -lt 10 -or $analysis.Status -in @('Critical', 'Poor', 'NeedsAttention')) {
                    Write-Log "  $server requires remediation (Status: $($analysis.Status))" "WARN"
                    
                    # Disk cleanup if needed
                    if ($analysis.DiskSpaceGB -lt 10) {
                        Write-Log "     Performing disk cleanup..." "WARN"
                        
                        if ($TestMode) {
                            $remediation.ActionsPerformed += "TEST: Disk cleanup simulated"
                            Write-Log "     TEST MODE: Disk cleanup simulated" "SUCCESS"
                        } else {
                            $cleanupResult = Invoke-Command -Session $session -ScriptBlock $DiskCleanupScript
                            $remediation.ActionsPerformed += $cleanupResult.Actions
                            
                            if ($cleanupResult.Success) {
                                Write-Log "     Disk cleanup completed successfully" "SUCCESS"
                            } else {
                                Write-Log "     Disk cleanup completed with issues" "WARN"
                            }
                        }
                    }
                    
                    # Install updates if available
                    if ($analysis.UpdatesTotal -gt 0) {
                        $updateMessage = "Installing $($analysis.UpdatesTotal) Windows Updates..."
                        Write-Log "     $updateMessage" "WARN"

                        if ($TestMode) {
                            $testMessage = "TEST: $($analysis.UpdatesTotal) Windows Updates installation simulated"
                            $remediation.ActionsPerformed += $testMessage
                            Write-Log "     TEST MODE: Update installation simulated" "SUCCESS"
                        } else {
                            $installResult = $null
                            if (-not $ForceSystemInstall) {
                                $installResult = Invoke-Command -Session $session -ScriptBlock $InstallWindowsUpdatesScript
                            }
                            $remediation.ActionsPerformed += "Updates searched: $($installResult.SearchedCount), downloaded: $($installResult.DownloadedCount), installed: $($installResult.InstalledCount)"
                            if ($installResult.Diagnostics) { foreach($d in $installResult.Diagnostics){ Write-Log ("     DIAG: " + $d) "INFO" } }
                            if ($installResult.Messages) { foreach($m in $installResult.Messages){ Write-Log ("     MSG: " + $m) "INFO" } }
                            # Log installer result detail if present
                            if ($installResult.PSObject.Properties.Match('PerUpdate').Count -gt 0 -and $installResult.PerUpdate) {
                                foreach ($u in $installResult.PerUpdate) { Write-Log ("     " + $u) "INFO"; $remediation.ActionsPerformed += $u }
                            }
                            if ($installResult -and $installResult.Success) {
                                Write-Log "     Windows Updates installation completed (Installed: $($installResult.InstalledCount))" "SUCCESS"
                            } else {
                                Write-Log "     Windows Updates installation had issues" "WARN"
                                if ($RepairWindowsUpdate) {
                                    Write-Log "     Attempting Windows Update component repair..." "WARN"
                                    $repairOut = Invoke-Command -Session $session -ScriptBlock $RepairWUScript
                                    foreach($line in $repairOut){ Write-Log ("       " + $line) "INFO" }
                                    Write-Log "     Re-scanning and retrying install after repair..." "WARN"
                                    if (-not $ForceSystemInstall) {
                                        $installResult = Invoke-Command -Session $session -ScriptBlock $InstallWindowsUpdatesScript
                                    }
                                    if ($installResult.Messages) { foreach($m in $installResult.Messages){ Write-Log ("       MSG: " + $m) "INFO" } }
                                    if ($installResult.PerUpdate) { foreach($u in $installResult.PerUpdate){ Write-Log ("       " + $u) "INFO" } }
                                    if ($installResult -and $installResult.Success) {
                                        Write-Log "     Retry install completed (Installed: $($installResult.InstalledCount))" "SUCCESS"
                                    } else {
                                        Write-Log "     Retry install still had issues" "ERROR"
                                    }
                                }

                                if (-not $installResult.Success) {
                                    Write-Log "     Falling back to SYSTEM scheduled task for update install..." "WARN"
                                    try {
                                    $credToUse3 = if ($credentialMap.ContainsKey($server)) { $credentialMap[$server] } else { $credential }
                                    $sysResult = Invoke-Command -ComputerName $server -Credential $credToUse3 -ScriptBlock {
                                        $root = Join-Path $env:ProgramData 'InteractivePatching'
                                        New-Item -ItemType Directory -Path $root -Force | Out-Null
                                        $scriptPath = Join-Path $root 'Run-WUInstall.ps1'
                                        $outPath = Join-Path $root 'WU-Result.json'
                                        $hbPath = Join-Path $root 'WU-Heartbeat.txt'
                                        $script = @'
param($OutPath)
try {
  $result = @{ Messages=@(); Diagnostics=@(); PerUpdate=@(); SearchedCount=0; DownloadedCount=0; InstalledCount=0; RebootRequired=$false; Success=$false }
  $result.Messages += 'SYSTEM task starting'
  $hbPath = Join-Path $env:ProgramData 'InteractivePatching\WU-Heartbeat.txt'
  function Write-HB($m){ try { Add-Content -LiteralPath $hbPath -Value ("[{0}] {1}" -f (Get-Date), $m) -Encoding UTF8 } catch {} ; try { $src='InteractivePatchingAutomation'; if(-not [System.Diagnostics.EventLog]::SourceExists($src)){ New-EventLog -LogName Application -Source $src -ErrorAction SilentlyContinue | Out-Null }; Write-EventLog -LogName Application -Source $src -EntryType Information -EventId 10011 -Message $m -ErrorAction SilentlyContinue } catch {} }
  Write-HB 'SYSTEM task initialized'
  try {
    foreach($cmd in @('RefreshSettings','StartInteractiveScan','StartDownload','StartInstall')){ Start-Process -FilePath 'usoclient.exe' -ArgumentList $cmd -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null; Start-Sleep -Seconds 2 }
    $result.Messages += 'USO sequence triggered'
    Write-HB 'USO sequence triggered'
  } catch {}
  $session   = New-Object -ComObject "Microsoft.Update.Session"
  $searcher  = $session.CreateUpdateSearcher()
  Write-HB 'Scan started'
  $search    = $searcher.Search("IsInstalled=0 and IsHidden=0")
  $result.SearchedCount = $search.Updates.Count
  Write-HB ("Scan complete. Found {0} updates" -f $result.SearchedCount)
  if ($search.Updates.Count -gt 0) {
    $coll = New-Object -ComObject "Microsoft.Update.UpdateColl"
    for($i=0;$i -lt $search.Updates.Count;$i++){ $u=$search.Updates.Item($i); try{ if(-not $u.EulaAccepted){ $u.AcceptEula() } }catch{}; [void]$coll.Add($u) }
    $down = $session.CreateUpdateDownloader(); $down.Updates = $coll; Write-HB 'Download started'; $dres = $down.Download();
    $result.Diagnostics += ("Download RC: {0} HR: 0x{1:X8}" -f $dres.ResultCode, [uint32]$dres.HResult)
    $result.DownloadedCount = ($coll | ? { $_.IsDownloaded }).Count
    Write-HB ("Download finished. Downloaded {0} updates" -f $result.DownloadedCount)
    $inst = $session.CreateUpdateInstaller(); $inst.Updates = $coll; try { $inst.ForceQuiet=$true } catch {} ; try { $inst.AllowSourcePrompts=$false } catch {}
    Write-HB 'Install started'
    $ires = $inst.Install();
    $result.InstalledCount = $ires.UpdatesInstalled
    $result.RebootRequired = [bool]$ires.RebootRequired
    $result.Messages += ("Install RC: {0} HR: 0x{1:X8}" -f $ires.ResultCode, [uint32]$ires.HResult)
    $result.Success = ($ires.ResultCode -eq 2 -or $ires.ResultCode -eq 3)
    for($i=0;$i -lt $coll.Count;$i++){ try{ $u=$coll.Item($i); $ur=$ires.GetUpdateResult($i); $result.PerUpdate += ("Result: '"+$u.Title+"' RC:"+$ur.ResultCode+" HR: 0x"+([uint32]$ur.HResult).ToString('X8')) }catch{} }
    Write-HB ("Install finished. Installed {0} updates. RebootRequired={1}" -f $result.InstalledCount, $result.RebootRequired)
  } else { $result.Success=$true; $result.Messages += 'No updates available' }
} catch { $result.Messages += ('SYSTEM task error: ' + $_.Exception.Message) }
try { $result | ConvertTo-Json -Depth 5 | Out-File -FilePath $OutPath -Encoding UTF8 -Force } catch {}
'@
                                        Set-Content -LiteralPath $scriptPath -Value $script -Encoding UTF8 -Force
                                        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -OutPath `"$outPath`""
                                        $taskName = 'InteractivePatching_WUInstall'
                                        try { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue } catch {}
                                        $task = Register-ScheduledTask -TaskName $taskName -Action $action -RunLevel Highest -User 'SYSTEM' -Force
                                        Start-ScheduledTask -TaskName $taskName
                                        $deadline = (Get-Date).AddMinutes($using:SystemInstallTimeoutMinutes)
                                        do { Start-Sleep -Seconds 10 } while ((-not (Test-Path $outPath)) -and (Get-Date) -lt $deadline)
                                        $payload = if (Test-Path $outPath) { Get-Content -LiteralPath $outPath -Raw } else { '{"Messages":["Timeout waiting for SYSTEM task"],"Success":false}' }
                                        # Cleanup scheduled task and temp files
                                        try { if ($using:CleanupTasks) { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue } } catch {}
                                        try { if ($using:CleanupTasks) { Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue } } catch {}
                                        try { if ($using:CleanupTasks) { Remove-Item -LiteralPath $outPath -Force -ErrorAction SilentlyContinue } } catch {}
                                        try { if ($using:CleanupTasks) { Remove-Item -LiteralPath $hbPath -Force -ErrorAction SilentlyContinue } } catch {}
                                        $payload
                                    }
                                    } catch {
                                        $sysResult = $null
                                    }
                                    if (-not $sysResult) {
                                        # Session may have disconnected; wait and try a new session to read the output
                                        Write-Log "     Session dropped during SYSTEM task. Waiting for host and retrying fetch..." "WARN"
                                        if (Wait-ForServerOnline -Server $server -Credential $credToUse3 -TimeoutSeconds 900 -PollSeconds 15) {
                                            try {
                                                $sysResult = Invoke-Command -ComputerName $server -Credential $credToUse3 -ScriptBlock {
                                                    $outPath = Join-Path (Join-Path $env:ProgramData 'InteractivePatching') 'WU-Result.json'
                                                    if (Test-Path $outPath) { Get-Content -LiteralPath $outPath -Raw } else { '' }
                                                }
                                            } catch {
                                                Write-Log "     Failed to reconnect and fetch SYSTEM task output." "ERROR"
                                            }
                                        } else {
                                            Write-Log "     Host did not come back online in time to fetch SYSTEM output." "ERROR"
                                        }
                                    }
                                    if ($sysResult) {
                                        try { $sysObj = $sysResult | ConvertFrom-Json } catch { $sysObj = $null }
                                        if ($sysObj) {
                                            if ($sysObj.Diagnostics) { foreach($d in $sysObj.Diagnostics){ Write-Log ("       SYS DIAG: " + $d) "INFO" } }
                                            if ($sysObj.Messages) { foreach($m in $sysObj.Messages){ Write-Log ("       SYS MSG: " + $m) "INFO" } }
                                            if ($sysObj.PerUpdate) { foreach($u in $sysObj.PerUpdate){ Write-Log ("       SYS " + $u) "INFO" } }
                                            if ($sysObj.Success) {
                                                Write-Log "     SYSTEM fallback succeeded." "SUCCESS"
                                                $installResult.Success = $true
                                                $installResult.InstalledCount = $sysObj.InstalledCount
                                                if ($sysObj.RebootRequired -and -not $analysis.PendingReboot) { $analysis.PendingReboot = $true }
                                            } else {
                                                Write-Log "     SYSTEM fallback did not complete successfully." "ERROR"
                                            }
                                        } else {
                                            Write-Log "     SYSTEM fallback returned non-JSON output." "ERROR"
                                        }
                                    } else {
                                        Write-Log "     SYSTEM fallback produced no output." "ERROR"
                                    }
                            }
                            }
                            if ($installResult.RebootRequired -and -not $analysis.PendingReboot) {
                                # Mark for reboot in this cycle
                                $analysis.PendingReboot = $true
                                Write-Log "     Updates indicate reboot required" "WARN"
                            }

                            # Quick re-analysis in same session to reflect progress
                            try {
                                $analysis2 = Invoke-Command -Session $session -ScriptBlock $SystemAnalysisScript
                                Write-Log "     Post-install analysis: Updates=$($analysis2.UpdatesTotal) Reboot=$($analysis2.PendingReboot) Disk=$($analysis2.DiskSpaceGB)GB" "INFO"
                                $remediation.Analysis = $analysis2
                            } catch {}
                        }
                    }
                    
                    # Reboot if required
                    if ($analysis.PendingReboot) {
                        Write-Log "     System reboot required..." "WARN"
                        
                        if ($TestMode) {
                            $remediation.ActionsPerformed += "TEST: System reboot simulated"
                            Write-Log "     TEST MODE: Reboot simulated" "SUCCESS"
                        } else {
                            try {
                                $credToUse2 = if ($credentialMap.ContainsKey($server)) { $credentialMap[$server] } else { $credential }
                                $rebootParams = @{
                                    ComputerName = $server
                                    Credential = $credToUse2
                                    Force = $true
                                    ErrorAction = 'Stop'
                                }
                                Restart-Computer @rebootParams
                                $remediation.ActionsPerformed += "System reboot initiated"
                                Write-Log "     System reboot initiated successfully" "SUCCESS"

                                # Poll for the server to return to speed up next cycle
                                $waitSecs = [Math]::Max(120, $RebootWaitMinutes * 60)
                                Write-Log "     Waiting up to $([int]($waitSecs/60)) minutes for $server to come back online..." "INFO"
                                if (Wait-ForServerOnline -Server $server -Credential $credToUse2 -TimeoutSeconds $waitSecs -PollSeconds 15) {
                                    Write-Log "     $server is back online." "SUCCESS"
                                    $returnedEarlyThisCycle = $true
                                } else {
                                    Write-Log "     $server did not return within wait window; will check next cycle." "WARN"
                                }
                            } catch {
                                $errorMsg = $_.Exception.Message
                                Write-Log "     Reboot failed: $errorMsg" "ERROR"
                                $remediation.ActionsPerformed += "Reboot failed: $errorMsg"
                            }
                        }
                    }
                    
                    $remediation.Success = $true
                } else {
                    Write-Log "  $server is healthy (Status: $($analysis.Status)) - no remediation needed" "SUCCESS"
                    $remediation.Success = $true
                }
                
                Remove-PSSession $session
                
            } catch {
                $errorMsg = $_.Exception.Message
                Write-Log "  Processing failed for $server : $errorMsg" "ERROR"
                $remediation.ActionsPerformed += "Processing error: $errorMsg"
                Remove-PSSession $session -ErrorAction SilentlyContinue
            }
            
            $cycleResults += [PSCustomObject]$remediation
            
            # Determine if server needs another cycle (explicit health criteria)
            if ($remediation.Analysis -and (
                    $remediation.Analysis.UpdatesTotal -gt 0 -or 
                    $remediation.Analysis.PendingReboot -eq $true -or 
                    $remediation.Analysis.DiskSpaceGB -lt 10
                ) -and $remediation.Success) {
                $stillNeedWork += $server
                Write-Log "  $server will be retried in next cycle" "WARN"
            } elseif ($remediation.Analysis -and (
                $remediation.Analysis.UpdatesTotal -eq 0 -and -not $remediation.Analysis.PendingReboot -and $remediation.Analysis.DiskSpaceGB -ge 10)) {
                Write-Log "  $server remediation completed successfully!" "SUCCESS"
            }
        }
        
        $allResults += $cycleResults
        
        # Cycle Summary
        Write-Log ""
        Write-Log "Cycle $script:Cycles Summary:" "INFO"
        $statusGroups = $cycleResults | Where-Object { $_.Analysis } | Group-Object { $_.Analysis.Status }
        foreach ($group in $statusGroups) {
            Write-Log "   $($group.Name): $($group.Count) servers" "INFO"
        }
        Write-Log "   Servers still needing work: $($stillNeedWork.Count)" "INFO"
        
        # Check if we should continue
        if ($stillNeedWork.Count -gt 0 -and ( ($MaxCycles -le 0) -or ($script:Cycles -lt $MaxCycles) )) {
            Write-Log ""
            if ($returnedEarlyThisCycle -and -not $TestMode) {
                Write-Log "Some servers returned from reboot early; starting next cycle immediately." "INFO"
            } else {
                Write-Log "Waiting $RetryIntervalMinutes minutes before next cycle..." "INFO"
                Write-Log "   Next cycle will process: $($stillNeedWork -join ', ')" "INFO"
                if ($TestMode) {
                    Write-Log "   TEST MODE: Using 10-second delay instead of $RetryIntervalMinutes minutes" "INFO"
                    Start-Sleep -Seconds 10
                } else {
                    Start-Sleep -Seconds ($RetryIntervalMinutes * 60)
                }
            }
            $serversNeedingWork = $stillNeedWork
        } else {
            break
        }
        
    } while ($stillNeedWork.Count -gt 0 -and ( ($MaxCycles -le 0) -or ($script:Cycles -lt $MaxCycles) ))
    
    # Phase 6: Final reporting
    Write-Log ""
    Write-Log "PHASE 3: Final Report Generation" "INFO"
    
    $duration = [math]::Round(((Get-Date) - $script:StartTime).TotalMinutes, 1)
    $successful = ($allResults | Where-Object { $_.Success }).Count
    $failed = $allResults.Count - $successful
    
    # Generate CSV report
    $csvFile = "Working-Interactive-Results_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    try {
        $csvData = @()
        foreach ($result in $allResults) {
            $analysis = $result.Analysis
            $csvData += [PSCustomObject]@{
                Server = $result.Server
                Status = if($analysis) { $analysis.Status } else { "ConnectionFailed" }
                HealthScore = if($analysis) { $analysis.HealthScore } else { 0 }
                WindowsVersion = if($analysis) { $analysis.WindowsVersion } else { "" }
                UpdatesTotal = if($analysis) { $analysis.UpdatesTotal } else { 0 }
                DiskSpaceGB = if($analysis) { $analysis.DiskSpaceGB } else { 0 }
                PendingReboot = if($analysis) { $analysis.PendingReboot } else { $false }
                ProcessingSuccess = $result.Success
                ActionsPerformed = ($result.ActionsPerformed -join '; ')
                Issues = if($analysis) { ($analysis.Issues -join '; ') } else { "" }
            }
        }
        
        $csvData | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8
        Write-Log "CSV report exported: $csvFile" "SUCCESS"
    } catch {
        Write-Log "CSV export failed: $($_.Exception.Message)" "ERROR"
    }
    
    # Final summary display
    Write-Host ""
    Write-Host "================================================================" -ForegroundColor Green
    Write-Host "                   FINAL SUMMARY REPORT                        " -ForegroundColor Green
    Write-Host "================================================================" -ForegroundColor Green
    Write-Host ""
    
    Write-Log "PROCESSING STATISTICS:" "SUCCESS"
    Write-Log "   Total Servers Targeted: $($servers.Count)" "INFO"
    Write-Log "   Reachable Servers: $($reachableServers.Count)" "INFO"
    Write-Log "   Successfully Processed: $successful" "SUCCESS"
    if ($failed -gt 0) {
        Write-Log "   Processing Failures: $failed" "WARN"
    } else {
        Write-Log "   Processing Failures: $failed" "SUCCESS"
    }
    Write-Log "   Total Processing Cycles: $script:Cycles" "INFO"
    $lowDiskCount = ($allResults | Where-Object { $_.Analysis -and $_.Analysis.DiskSpaceGB -lt 10 }).Count
    if ($lowDiskCount -gt 0) { Write-Log "   Servers low on disk (<10 GB): $lowDiskCount" "WARN" }
    $cleanupCount = ($allResults | Where-Object { $_.ActionsPerformed -match 'Disk cleanup' }).Count
    if ($cleanupCount -gt 0) { Write-Log "   Servers cleaned (safe methods): $cleanupCount" "INFO" }
    Write-Log "   Total Processing Time: $duration minutes" "INFO"
    Write-Log "   Authenticated as: $($credential.UserName)" "INFO"
    
    # Final status distribution
    Write-Log ""
    Write-Log "FINAL STATUS DISTRIBUTION:" "SUCCESS"
    $finalStatus = @{}
    foreach ($result in $allResults) {
        if ($result.Analysis) {
            $status = $result.Analysis.Status
            if ($finalStatus.ContainsKey($status)) {
                $finalStatus[$status]++
            } else {
                $finalStatus[$status] = 1
            }
        } else {
            if ($finalStatus.ContainsKey("Failed")) {
                $finalStatus["Failed"]++
            } else {
                $finalStatus["Failed"] = 1
            }
        }
    }
    
    foreach ($status in ($finalStatus.Keys | Sort-Object)) {
        $count = $finalStatus[$status]
        $percentage = [math]::Round(($count / $reachableServers.Count) * 100, 1)
        Write-Log "   $status : $count servers ($percentage%)" "INFO"
    }
    
    # Servers still needing attention
    $needsAttention = $allResults | Where-Object { 
        $_.Analysis -and $_.Analysis.Status -notin @('Excellent', 'VeryGood', 'Good') 
    }
    
    if ($needsAttention.Count -gt 0) {
        Write-Log ""
        Write-Log "SERVERS STILL REQUIRING ATTENTION:" "WARN"
        foreach ($server in $needsAttention) {
            Write-Log "   $($server.Server): $($server.Analysis.Status) (Health: $($server.Analysis.HealthScore)/100)" "WARN"
            if ($server.Analysis.Issues.Count -gt 0) {
                Write-Log "      Issues: $($server.Analysis.Issues -join ', ')" "WARN"
            }
        }
        Write-Log ""
        Write-Log "RECOMMENDATION: Run the script again to continue remediation" "WARN"
        Write-Log "   or investigate remaining issues manually" "WARN"
    } else {
        Write-Log ""
        Write-Log "CONGRATULATIONS!" "SUCCESS"
        Write-Log "ALL REACHABLE SERVERS HAVE BEEN SUCCESSFULLY REMEDIATED!" "SUCCESS"
        Write-Log "Every server is now in Excellent, Very Good, or Good status" "SUCCESS"
    }
    
    Write-Log ""
    Write-Log "OUTPUT FILES GENERATED:" "SUCCESS"
    Write-Log "   Detailed Execution Log: $script:LogFile" "INFO"
    Write-Log "   Comprehensive CSV Report: $csvFile" "INFO"
    
    Write-Log ""
    Write-Log "Working Interactive Patching Automation completed successfully!" "SUCCESS"
    Write-Host ""
    
} catch {
    Write-Log "CRITICAL ERROR: $($_.Exception.Message)" "ERROR"
    Write-Log "Stack trace: $($_.ScriptStackTrace)" "ERROR"
    try {
        if ($allResults -and $allResults.Count -gt 0) {
            $csvFile = "Working-Interactive-Results_$(Get-Date -Format 'yyyyMMdd_HHmmss')_ERROR.csv"
            $csvData = @()
            foreach ($result in $allResults) {
                $analysis = $result.Analysis
                $csvData += [PSCustomObject]@{
                    Server = $result.Server
                    Status = if($analysis) { $analysis.Status } else { "ConnectionFailed" }
                    HealthScore = if($analysis) { $analysis.HealthScore } else { 0 }
                    WindowsVersion = if($analysis) { $analysis.WindowsVersion } else { "" }
                    UpdatesTotal = if($analysis) { $analysis.UpdatesTotal } else { 0 }
                    DiskSpaceGB = if($analysis) { $analysis.DiskSpaceGB } else { 0 }
                    PendingReboot = if($analysis) { $analysis.PendingReboot } else { $false }
                    ProcessingSuccess = $result.Success
                    ActionsPerformed = ($result.ActionsPerformed -join '; ')
                    Issues = if($analysis) { ($analysis.Issues -join '; ') } else { "" }
                }
            }
            $csvData | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8
            Write-Log "Partial CSV exported after error: $csvFile" "WARN"
        }
    } catch {
        Write-Log "Failed to export partial CSV after error: $($_.Exception.Message)" "ERROR"
    }
    
    Write-Host ""
    Write-Host "The script encountered a critical error. Please check the log file for details." -ForegroundColor Red
    Write-Host "Log file: $script:LogFile" -ForegroundColor Yellow
}

Write-Host "Press Enter to exit..." -ForegroundColor Gray
Read-Host
