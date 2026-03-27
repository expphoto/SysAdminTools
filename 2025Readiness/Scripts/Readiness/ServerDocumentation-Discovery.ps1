<#
.SYNOPSIS
    Automated server documentation and workload discovery tool.

.DESCRIPTION
    Read-only reconnaissance script that discovers what a Windows Server is actually
    used for by analyzing active workloads, network patterns, and usage evidence.

    Designed to be:
    - Fast (30-60 second runtime)
    - Safe (read-only, no changes)
    - Thorough (analyzes roles, apps, network, file activity)
    - Actionable (generates test plans and documentation)

.PARAMETER DaysBack
    Number of days of historical data to analyze. Default is 14 days.
    Valid range: 1-90 days.

.PARAMETER OutputDirectory
    Directory for output reports. Defaults to script directory.

.PARAMETER IncludeFileActivity
    Include file system activity analysis (may add 10-15 seconds).

.PARAMETER IncludeNetworkDetails
    Include detailed network connection analysis.

.EXAMPLE
    .\ServerDocumentation-Discovery.ps1

.EXAMPLE
    .\ServerDocumentation-Discovery.ps1 -DaysBack 30 -IncludeFileActivity

.EXAMPLE
    .\ServerDocumentation-Discovery.ps1 -OutputDirectory C:\Reports
#>

[CmdletBinding()]
param(
    [ValidateRange(1, 90)]
    [int]$DaysBack = 14,

    [string]$OutputDirectory = '',

    [switch]$IncludeFileActivity,

    [switch]$IncludeNetworkDetails
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Resolve OutputDirectory - use current directory if not specified
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    if ($PSScriptRoot) {
        $OutputDirectory = $PSScriptRoot
    } else {
        try {
            $OutputDirectory = (Get-Location).Path
        } catch {
            if ($env:TEMP) {
                $OutputDirectory = $env:TEMP
            } else {
                $OutputDirectory = 'C:\Temp'
            }
        }
    }
}

$script:StartTime = Get-Date
$script:Hostname = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { [System.Net.Dns]::GetHostName() }
$script:Timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$script:WindowStart = (Get-Date).AddDays(-$DaysBack)

# Data collectors
$script:ServerProfile = @{
    Hostname = $script:Hostname
    CollectedAt = $script:StartTime.ToString('o')
    DaysAnalyzed = $DaysBack
}
$script:ActiveWorkloads = New-Object 'System.Collections.Generic.List[object]'
$script:Applications = New-Object 'System.Collections.Generic.List[object]'
$script:NetworkActivity = @{}
$script:CriticalityScore = 0

function Write-Progress-Status {
    param(
        [string]$Activity,
        [string]$Status,
        [int]$PercentComplete
    )
    Write-Progress -Activity "Server Documentation Discovery" -Status $Status -PercentComplete $PercentComplete
    Write-Verbose "$Activity - $Status"
}

function Get-SafeWmiObject {
    param(
        [string]$Class,
        [string]$Filter = $null
    )

    try {
        if ($Filter) {
            return Get-CimInstance -ClassName $Class -Filter $Filter -ErrorAction Stop
        } else {
            return Get-CimInstance -ClassName $Class -ErrorAction Stop
        }
    } catch {
        Write-Verbose "Could not query $Class : $($_.Exception.Message)"
        return $null
    }
}

function Get-SafeEventLog {
    param(
        [hashtable]$Filter,
        [int]$MaxEvents = 500
    )

    try {
        return @(Get-WinEvent -FilterHashtable $Filter -MaxEvents $MaxEvents -ErrorAction Stop)
    } catch {
        Write-Verbose "Could not query event log: $($_.Exception.Message)"
        return @()
    }
}

function Invoke-ServerBaseline {
    Write-Progress-Status "Baseline" "Gathering OS and hardware info..." 10

    $os = Get-SafeWmiObject -Class Win32_OperatingSystem
    $cs = Get-SafeWmiObject -Class Win32_ComputerSystem

    if ($os) {
        $script:ServerProfile.OS = $os.Caption
        $script:ServerProfile.OSVersion = $os.Version
        $script:ServerProfile.BuildNumber = $os.BuildNumber
        $script:ServerProfile.InstallDate = $os.InstallDate
        $script:ServerProfile.LastBoot = $os.LastBootUpTime
        $script:ServerProfile.Uptime = ((Get-Date) - $os.LastBootUpTime).Days
        $script:ServerProfile.MemoryGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)
    }

    if ($cs) {
        $script:ServerProfile.Manufacturer = $cs.Manufacturer
        $script:ServerProfile.Model = $cs.Model
        $script:ServerProfile.Domain = $cs.Domain
        $script:ServerProfile.DomainRole = switch ($cs.DomainRole) {
            0 { 'Standalone Workstation' }
            1 { 'Member Workstation' }
            2 { 'Standalone Server' }
            3 { 'Member Server' }
            4 { 'Backup Domain Controller' }
            5 { 'Primary Domain Controller' }
            default { 'Unknown' }
        }
        $script:ServerProfile.ProcessorCount = $cs.NumberOfProcessors
        $script:ServerProfile.LogicalProcessors = $cs.NumberOfLogicalProcessors
    }

    # Network config
    try {
        $adapters = Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter "IPEnabled=True" -ErrorAction Stop
        $script:ServerProfile.IPAddresses = ($adapters | ForEach-Object { $_.IPAddress } | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' }) -join ', '
    } catch {
        $script:ServerProfile.IPAddresses = 'Unknown'
    }
}

function Invoke-RoleDiscovery {
    Write-Progress-Status "Roles" "Discovering installed roles and features..." 20

    $installedRoles = New-Object 'System.Collections.Generic.List[object]'

    # Try ServerManager first (preferred)
    if (Get-Command -Name Get-WindowsFeature -ErrorAction SilentlyContinue) {
        try {
            $features = @(Get-WindowsFeature | Where-Object { $_.Installed })
            foreach ($feature in $features) {
                if (-not $feature) { continue }
                # Only track major roles, not sub-features
                $depth = if ($feature.PSObject.Properties['Depth']) { $feature.Depth } else { 0 }
                $featureType = if ($feature.PSObject.Properties['FeatureType']) { $feature.FeatureType } else { 'Unknown' }

                if ($depth -le 1 -or $featureType -eq 'Role') {
                    $name = if ($feature.Name) { $feature.Name } else { 'Unknown' }
                    $displayName = if ($feature.DisplayName) { $feature.DisplayName } else { $name }

                    $installedRoles.Add([PSCustomObject]@{
                        Name = $name
                        DisplayName = $displayName
                        Type = $featureType
                    })
                }
            }
        } catch {
            Write-Verbose "Get-WindowsFeature failed: $($_.Exception.Message)"
        }
    }

    $script:ServerProfile.InstalledRoles = $installedRoles
    $script:ServerProfile.RoleCount = $installedRoles.Count
}

function Invoke-ServiceAnalysis {
    Write-Progress-Status "Services" "Analyzing active services..." 30

    $services = @(Get-Service | Where-Object { $_.Status -eq 'Running' })
    $serviceData = New-Object 'System.Collections.Generic.List[object]'

    # Key service patterns that indicate server purpose
    $servicePatterns = @{
        'DomainController' = @('NTDS', 'DNS', 'Netlogon', 'KDC')
        'FileServer' = @('LanmanServer', 'SRV')
        'WebServer' = @('W3SVC', 'WAS')
        'SQLServer' = @('MSSQLSERVER', 'SQLAgent', 'SQLSERVERAGENT')
        'Exchange' = @('MSExchangeServiceHost', 'MSExchangeTransport')
        'DHCP' = @('DHCPServer')
        'Hyper-V' = @('vmms', 'vmcompute')
        'PrintServer' = @('Spooler')
        'RemoteDesktop' = @('TermService', 'SessionEnv')
    }

    $detectedRoles = New-Object 'System.Collections.Generic.List[string]'

    foreach ($service in $services) {
        foreach ($role in $servicePatterns.Keys) {
            if ($servicePatterns[$role] -contains $service.Name) {
                if ($detectedRoles -notcontains $role) {
                    $detectedRoles.Add($role)
                }
            }
        }

        # Collect service details
        $serviceData.Add([PSCustomObject]@{
            Name = $service.Name
            DisplayName = $service.DisplayName
            Status = $service.Status
            StartType = $service.StartType
        })
    }

    $script:ServerProfile.RunningServices = $serviceData.Count
    $script:ServerProfile.DetectedRoles = $detectedRoles
    $script:ServerProfile.PrimaryRole = if ($detectedRoles.Count -gt 0) { $detectedRoles[0] } else { 'Unknown' }
}

function Invoke-ProcessAnalysis {
    Write-Progress-Status "Processes" "Analyzing running processes..." 35

    $processes = Get-Process |
        Where-Object { $_.WorkingSet64 -gt 10MB } |
        Sort-Object WorkingSet64 -Descending |
        Select-Object -First 20

    $processData = New-Object 'System.Collections.Generic.List[object]'

    foreach ($proc in $processes) {
        # Some processes may not have accessible TotalProcessorTime (system processes, access denied)
        $cpuSeconds = 0
        if ($proc.TotalProcessorTime) {
            try {
                $cpuSeconds = [math]::Round($proc.TotalProcessorTime.TotalSeconds, 2)
            } catch {
                $cpuSeconds = 0
            }
        }

        $processData.Add([PSCustomObject]@{
            Name = $proc.Name
            Id = $proc.Id
            WorkingSetMB = [math]::Round($proc.WorkingSet64 / 1MB, 2)
            CPUSeconds = $cpuSeconds
            StartTime = if ($proc.StartTime) { $proc.StartTime.ToString('yyyy-MM-dd HH:mm') } else { 'Unknown' }
        })
    }

    $script:ServerProfile.TopProcesses = $processData
}

function Invoke-NetworkAnalysis {
    Write-Progress-Status "Network" "Analyzing network connections..." 40

    $connections = @()
    $listeningPorts = New-Object 'System.Collections.Generic.List[object]'

    # Try Get-NetTCPConnection first (Server 2012 R2+)
    if (Get-Command -Name Get-NetTCPConnection -ErrorAction SilentlyContinue) {
        try {
            $tcpConns = Get-NetTCPConnection -State Established, Listen -ErrorAction Stop

            # Count unique remote addresses (inbound connections indicator)
            $remoteAddresses = $tcpConns |
                Where-Object { $_.State -eq 'Established' -and $_.RemoteAddress -ne '127.0.0.1' -and $_.RemoteAddress -ne '::1' } |
                Select-Object -ExpandProperty RemoteAddress -Unique

            $script:NetworkActivity.ActiveConnections = @($tcpConns | Where-Object { $_.State -eq 'Established' }).Count
            $script:NetworkActivity.UniqueRemoteHosts = @($remoteAddresses).Count

    # Listening ports
    $listeningPorts = New-Object 'System.Collections.Generic.List[object]'
    $portConnectionCounts = @{}

    # Try Get-NetTCPConnection first (Server 2012 R2+)
    if (Get-Command -Name Get-NetTCPConnection -ErrorAction SilentlyContinue) {
        try {
            $tcpConns = Get-NetTCPConnection -State Established, Listen -ErrorAction Stop

            # Count unique remote addresses (inbound connections indicator)
            $remoteAddresses = $tcpConns |
                Where-Object { $_.State -eq 'Established' -and $_.RemoteAddress -ne '127.0.0.1' -and $_.RemoteAddress -ne '::1' } |
                Select-Object -ExpandProperty RemoteAddress -Unique

            # Count connections per port
            foreach ($conn in $tcpConns) {
                if ($conn.State -eq 'Established') {
                    $localPort = $conn.LocalPort
                    if (-not $portConnectionCounts.ContainsKey($localPort)) {
                        $portConnectionCounts[$localPort] = 0
                    }
                    $portConnectionCounts[$localPort]++
                }
            }

            $script:NetworkActivity.ActiveConnections = @($tcpConns | Where-Object { $_.State -eq 'Established' }).Count
            $script:NetworkActivity.UniqueRemoteHosts = @($remoteAddresses).Count

            # Listening ports
            $listening = $tcpConns | Where-Object { $_.State -eq 'Listen' }
            foreach ($listener in $listening) {
                $process = Get-Process -Id $listener.OwningProcess -ErrorAction SilentlyContinue
                $port = $listener.LocalPort
                $listeningPorts.Add([PSCustomObject]@{
                    Port = $port
                    Process = if ($process) { $process.Name } else { 'Unknown' }
                    ProcessId = $listener.OwningProcess
                    LocalAddress = $listener.LocalAddress
                    ActiveConnections = if ($portConnectionCounts.ContainsKey($port)) { $portConnectionCounts[$port] } else { 0 }
                })
            }
        } catch {
            Write-Verbose "Get-NetTCPConnection failed: $($_.Exception.Message)"
        }
    }
        } catch {
            Write-Verbose "Get-NetTCPConnection failed: $($_.Exception.Message)"
        }
    }

    # Fallback to netstat
    if ($listeningPorts.Count -eq 0) {
        try {
            $netstat = netstat -ano | Select-String -Pattern 'LISTENING'
            foreach ($line in $netstat) {
                if ($line -match ':(\d+)\s+.*\s+(\d+)$') {
                    $port = $Matches[1]
                    $processId = $Matches[2]
                    $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
                    $listeningPorts.Add([PSCustomObject]@{
                        Port = $port
                        Process = if ($process) { $process.Name } else { 'Unknown' }
                        ProcessId = $pid
                    })
                }
            }
        } catch {
            Write-Verbose "netstat fallback failed: $($_.Exception.Message)"
        }
    }

    $script:NetworkActivity.ListeningPorts = $listeningPorts

    # Infer criticality from connection count
    if ($script:NetworkActivity.UniqueRemoteHosts -gt 50) {
        $script:CriticalityScore += 30
    } elseif ($script:NetworkActivity.UniqueRemoteHosts -gt 20) {
        $script:CriticalityScore += 20
    } elseif ($script:NetworkActivity.UniqueRemoteHosts -gt 5) {
        $script:CriticalityScore += 10
    }
}

function Invoke-LogonAnalysis {
    Write-Progress-Status "Logons" "Analyzing user activity..." 50

    # Sample recent logons (limit to 1000 events for performance)
    $logons = @(Get-SafeEventLog -Filter @{
        LogName = 'Security'
        Id = 4624
        StartTime = $script:WindowStart
    } -MaxEvents 1000)

    if ($logons.Count -gt 0) {
        $uniqueUsers = New-Object 'System.Collections.Generic.List[string]'
        $interactiveLogons = 0

        foreach ($logon in $logons) {
            try {
                $xml = [xml]$logon.ToXml()
                $logonType = ($xml.Event.EventData.Data | Where-Object { $_.Name -eq 'LogonType' }).'#text'
                $targetUser = ($xml.Event.EventData.Data | Where-Object { $_.Name -eq 'TargetUserName' }).'#text'

                if ($logonType -in @('2', '10')) {  # Interactive or RemoteInteractive
                    $interactiveLogons++
                }

                if ($targetUser -and $targetUser -notmatch '\$$' -and 
                    $targetUser -notmatch '^(svc|system|administrator|guest|iusr|iwam|network service|local service)' -and 
                    $targetUser -notmatch 'SVC' -and 
                    $uniqueUsers -notcontains $targetUser) {
                    $uniqueUsers.Add($targetUser)
                }
            } catch {
                # Skip malformed events
            }
        }

        $script:ServerProfile.TotalLogons = $logons.Count
        $script:ServerProfile.InteractiveLogons = $interactiveLogons
        $script:ServerProfile.UniqueUsers = $uniqueUsers.Count
        $script:ServerProfile.UniqueUsersList = @($uniqueUsers | Sort-Object)
        $script:ServerProfile.UniqueUserList = ($uniqueUsers | Sort-Object) -join ', '
        $script:ServerProfile.AvgLogonsPerDay = [math]::Round($logons.Count / $DaysBack, 1)

        # Increase criticality if heavily accessed
        if ($uniqueUsers.Count -gt 50) {
            $script:CriticalityScore += 25
        } elseif ($uniqueUsers.Count -gt 20) {
            $script:CriticalityScore += 15
        }
    } else {
        $script:ServerProfile.TotalLogons = 0
        $script:ServerProfile.InteractiveLogons = 0
        $script:ServerProfile.UniqueUsers = 0
        $script:ServerProfile.AvgLogonsPerDay = 0
    }
}

function Invoke-WorkloadDetection {
    Write-Progress-Status "Workloads" "Detecting active workloads..." 60

    # Active Directory - only flag if actually has DS activity
    if ($script:ServerProfile.DetectedRoles -contains 'DomainController') {
        $adEvents = @(Get-SafeEventLog -Filter @{
            LogName = 'Directory Service'
            StartTime = $script:WindowStart
        } -MaxEvents 500)

        $adDetails = @{
            RecentEvents = $adEvents.Count
            EventActivityLevel = if ($adEvents.Count -gt 100) { 'High' } elseif ($adEvents.Count -gt 10) { 'Moderate' } else { 'Low' }
        }

        # Only consider it an active DC if there are DS events
        if ($adEvents.Count -gt 0) {
            $script:ActiveWorkloads.Add([PSCustomObject]@{
                Type = 'Active Directory Domain Controller'
                Confidence = 'High'
                Evidence = "Domain role detected, $($adEvents.Count) DS events in $DaysBack days"
                Criticality = 'CRITICAL'
                TestScenario = 'Verify AD replication, LDAP queries, DNS resolution'
                Details = $adDetails
            })
            $script:CriticalityScore += 40
        } else {
            # Domain controller services detected but no DS activity - might be a false positive or DC in maintenance mode
            Write-Verbose "Domain Controller services detected but no DS events found in last $DaysBack days"
        }
    }

    # File Server - exclude admin shares and require activity
    if ($script:ServerProfile.DetectedRoles -contains 'FileServer') {
        $allShares = @(Get-SmbShare -Special $false -ErrorAction SilentlyContinue)
        
        # Filter out admin shares (C$, ADMIN$, IPC$, print$)
        $adminShareNames = @('ADMIN$', 'C$', 'IPC$', 'print$', 'D$', 'E$', 'F$')
        $userShares = $allShares | Where-Object { $adminShareNames -notcontains $_.Name }
        $shareCount = @($userShares).Count

        # Check for actual share access via Security log (Event ID 5140 - file share access)
        $shareAccessEvents = @(Get-SafeEventLog -Filter @{
            LogName = 'Security'
            Id = 5140
            StartTime = $script:WindowStart
        } -MaxEvents 500)

        # Check for open files and sessions
        $openFiles = @()
        $activeSessions = @()
        try {
            $openFiles = @(Get-SmbOpenFile -ErrorAction SilentlyContinue)
            $activeSessions = @(Get-SmbSession -ErrorAction SilentlyContinue)
        } catch {
            Write-Verbose "Could not query SMB open files or sessions"
        }

        $activeShares = New-Object 'System.Collections.Generic.List[string]'
        $uniqueShareUsers = New-Object 'System.Collections.Generic.List[string]'
        foreach ($evt in $shareAccessEvents) {
            try {
                $xml = [xml]$evt.ToXml()
                $shareName = ($xml.Event.EventData.Data | Where-Object { $_.Name -eq 'ShareName' }).'#text'
                $userName = ($xml.Event.EventData.Data | Where-Object { $_.Name -eq 'SubjectUserName' }).'#text'
                
                # Skip if share name is null or is an admin share
                if ($shareName -and $adminShareNames -notcontains $shareName -and $activeShares -notcontains $shareName) {
                    $activeShares.Add($shareName)
                }
                if ($userName -and $userName -notmatch '\$' -and 
                    $userName -notmatch '^(svc|system|administrator|guest|network service|local service)' -and
                    $uniqueShareUsers -notcontains $userName) {
                    $uniqueShareUsers.Add($userName)
                }
            } catch {
                # Skip malformed events
            }
        }

        # Only flag as file server if there are user shares with activity or open files/sessions
        $hasUserShareActivity = $activeShares.Count -gt 0
        $hasOpenFiles = $openFiles.Count -gt 0
        $hasActiveSessions = $activeSessions.Count -gt 0
        
        $isActiveFileServer = $shareCount -gt 0 -and ($hasUserShareActivity -or $hasOpenFiles -or $hasActiveSessions)

        $shareActivityLevel = if (-not $isActiveFileServer) { 'No user share activity detected' }
                        elseif ($shareAccessEvents.Count -lt 10) { 'Low activity' }
                        elseif ($shareAccessEvents.Count -lt 100) { 'Moderate activity' }
                        else { 'High activity' }

        $script:ServerProfile.ShareDetails = @{
            TotalShares = $allShares.Count
            UserShares = $shareCount
            UserShareNames = @($userShares | Select-Object -ExpandProperty Name)
            ActiveShares = $activeShares.Count
            ActiveShareNames = $activeShares
            ShareAccessEvents = $shareAccessEvents.Count
            UniqueShareUsers = $uniqueShareUsers.Count
            OpenFiles = $openFiles.Count
            ActiveSessions = $activeSessions.Count
            ActivityLevel = $shareActivityLevel
            IsActiveFileServer = $isActiveFileServer
        }

        # Only consider it a real file server if there's user share activity
        if ($isActiveFileServer) {
            $confidence = if ($shareAccessEvents.Count -gt 0) { 'High' } else { 'Medium' }
            $criticality = if ($shareAccessEvents.Count -gt 100 -or $shareCount -gt 5) { 'HIGH' } else { 'MEDIUM' }

            $script:ActiveWorkloads.Add([PSCustomObject]@{
                Type = 'File Server'
                Confidence = $confidence
                Evidence = "$shareCount user shares, $($activeShares.Count) actively accessed ($shareActivityLevel), $($openFiles.Count) open files, $($activeSessions.Count) sessions, $($uniqueShareUsers.Count) unique users"
                Criticality = $criticality
                TestScenario = 'Test file access, permissions, DFS if applicable'
                Details = $script:ServerProfile.ShareDetails
            })

            if ($shareAccessEvents.Count -gt 100 -or $shareCount -gt 5) {
                $script:CriticalityScore += 25
            } else {
                $script:CriticalityScore += 10
            }
        } elseif ($shareCount -gt 0) {
            # Has user shares but no activity - note it but don't flag as critical workload
            Write-Verbose "Found $shareCount user shares but no recent activity detected"
        }
    }

    # Web Server
    if ($script:ServerProfile.DetectedRoles -contains 'WebServer') {
        $sites = @()
        $apps = @()
        $appPools = @()
        $vdirs = @()
        $iisDetails = @{
            Sites = @()
            Applications = @()
            AppPools = @()
            VirtualDirectories = @()
            TotalSites = 0
            TotalApplications = 0
            TotalAppPools = 0
            TotalVDirs = 0
            RecentLogEntries = 0
            LogActivityLevel = 'None'
            ActiveSites = @()
            ActiveApplications = @()
        }

        if (Get-Command -Name Get-Website -ErrorAction SilentlyContinue) {
            $sites = @(Get-Website -ErrorAction SilentlyContinue)
            $iisDetails.Sites = $sites
            $iisDetails.TotalSites = $sites.Count
        }

        if (Get-Command -Name Get-WebApplication -ErrorAction SilentlyContinue) {
            $apps = @(Get-WebApplication -ErrorAction SilentlyContinue)
            $iisDetails.Applications = $apps
            $iisDetails.TotalApplications = $apps.Count
        }

        if (Get-Command -Name Get-WebAppPoolState -ErrorAction SilentlyContinue) {
            $appPools = @(Get-WebAppPoolState -ErrorAction SilentlyContinue)
            $iisDetails.AppPools = $appPools
            $iisDetails.TotalAppPools = $appPools.Count
        }

        if (Get-Command -Name Get-WebVirtualDirectory -ErrorAction SilentlyContinue) {
            $vdirs = @(Get-WebVirtualDirectory -ErrorAction SilentlyContinue)
            $iisDetails.VirtualDirectories = $vdirs
            $iisDetails.TotalVDirs = $vdirs.Count
        }

        # Try to sample IIS logs for activity
        $iisActivity = 0
        $iisLogPath = 'C:\inetpub\logs\LogFiles'
        if (Test-Path $iisLogPath) {
            try {
                $recentLogs = @(Get-ChildItem -Path $iisLogPath -Recurse -Filter '*.log' -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.LastWriteTime -gt $script:WindowStart } |
                    Select-Object -First 3)

                foreach ($log in $recentLogs) {
                    $lineCount = @(Get-Content $log.FullName -TotalCount 100 -ErrorAction SilentlyContinue).Count
                    $iisActivity += $lineCount
                }
            } catch {
                Write-Verbose "Could not sample IIS logs"
            }
        }

        # Determine confidence and criticality based on actual usage
        $activeSites = @()
        $activeApps = @()

        # Check sites that are started
        foreach ($site in $sites) {
            if ($site.State -eq 'Started') {
                $activeSites += $site.Name
            }
        }

        # Check applications in started sites
        foreach ($app in $apps) {
            # Get the site name for this application from ItemXPath
            $siteName = $null
            if ($app.PSObject.Properties['ItemXPath'] -and $app.ItemXPath -match "site\[@name='([^']+)'\]") {
                $siteName = $Matches[1]
            }
            if ($siteName) {
                $siteObj = $sites | Where-Object { $_.Name -eq $siteName }
                if ($siteObj -and $siteObj.State -eq 'Started') {
                    $activeApps += "$siteName/$($app.Path)"
                }
            }
        }

        # Check app pools that are started
        $runningAppPools = $appPools | Where-Object { $_.Value -eq 'Started' }

        $iisDetails.ActiveSites = $activeSites
        $iisDetails.ActiveApplications = $activeApps
        $iisDetails.RecentLogEntries = $iisActivity
        $iisDetails.LogActivityLevel = if ($iisActivity -gt 1000) { 'High' } elseif ($iisActivity -gt 100) { 'Moderate' } elseif ($iisActivity -gt 0) { 'Low' } else { 'None' }

        $confidence = if ($iisActivity -gt 100 -or $activeSites.Count -gt 0) { 'High' } else { 'Medium' }
        $criticality = if ($iisActivity -gt 1000 -or $activeSites.Count -gt 2) { 'HIGH' } elseif ($iisActivity -gt 100 -or $activeSites.Count -gt 0) { 'HIGH' } else { 'MEDIUM' }

        $script:ActiveWorkloads.Add([PSCustomObject]@{
            Type = 'Web Server (IIS)'
            Confidence = $confidence
            Evidence = "$($sites.Count) sites ($($activeSites.Count) started), $($apps.Count) applications ($($activeApps.Count) active in started sites), $($appPools.Count) app pools ($($runningAppPools.Count) running), sampled $iisActivity recent log entries"
            Criticality = $criticality
            TestScenario = 'Test website access, application pools, SSL certificates'
            Details = $iisDetails
        })

        if ($iisActivity -gt 1000 -or $activeSites.Count -gt 2) {
            $script:CriticalityScore += 30
        } elseif ($iisActivity -gt 100 -or $activeSites.Count -gt 0) {
            $script:CriticalityScore += 15
        }
    }

    # SQL Server
    if ($script:ServerProfile.DetectedRoles -contains 'SQLServer') {
        $sqlCriticality = 'MEDIUM'
        $sqlEvidence = 'SQL Server service running'
        $sqlDetails = @{
            Databases = @()
            TotalConnections = 0
            ActiveDatabases = 0
            RecentActivity = $false
            DatabaseList = @()
        }

        # Try to get detailed database information including activity
        try {
            $sqlCmd = @"
SELECT 
    db.name AS DatabaseName,
    db.database_id,
    db.state_desc AS State,
    db.create_date AS Created,
    MAX(CASE WHEN session.status = 'sleeping' THEN session.last_request_start_time ELSE NULL END) AS LastActivity,
    COUNT(DISTINCT session.session_id) AS ActiveConnections,
    MAX(s.size * 8 / 1024) AS SizeMB
FROM sys.databases db
LEFT JOIN sys.dm_exec_sessions session ON db.database_id = session.database_id
LEFT JOIN sys.database_files s ON db.database_id = s.database_id
WHERE db.database_id > 4
GROUP BY db.name, db.database_id, db.state_desc, db.create_date
ORDER BY ActiveConnections DESC, SizeMB DESC
"@
            $dbResults = @(Invoke-Sqlcmd -Query $sqlCmd -ServerInstance $script:Hostname -ErrorAction Stop)
            $dbCount = $dbResults.Count
            
            $activeDbThreshold = (Get-Date).AddDays(-$DaysBack)
            $sqlDetails.Databases = $dbResults
            $sqlDetails.DatabaseList = $dbResults | Select-Object -ExpandProperty DatabaseName
            
            foreach ($db in $dbResults) {
                $hasActivity = $db.ActiveConnections -gt 0 -or ($db.LastActivity -and $db.LastActivity -gt $activeDbThreshold)
                if ($hasActivity) {
                    $sqlDetails.ActiveDatabases++
                    $sqlDetails.TotalConnections += $db.ActiveConnections
                    if ($db.LastActivity -gt $activeDbThreshold) {
                        $sqlDetails.RecentActivity = $true
                    }
                }
            }
            
            # Determine confidence and criticality based on actual usage
            if ($sqlDetails.RecentActivity -or $sqlDetails.TotalConnections -gt 0) {
                $confidence = 'High'
                if ($sqlDetails.TotalConnections -gt 50 -or $dbCount -gt 10) {
                    $sqlCriticality = 'HIGH'
                    $script:CriticalityScore += 35
                } elseif ($sqlDetails.TotalConnections -gt 10) {
                    $sqlCriticality = 'HIGH'
                    $script:CriticalityScore += 25
                } else {
                    $sqlCriticality = 'MEDIUM'
                    $script:CriticalityScore += 15
                }
            } else {
                $confidence = 'Medium'
                $sqlCriticality = 'MEDIUM'
                $script:CriticalityScore += 10
            }
            
            $sqlEvidence = "$dbCount database(s), $($sqlDetails.ActiveDatabases) with recent activity, $($sqlDetails.TotalConnections) current connections"
        } catch {
            Write-Verbose "Could not query SQL databases: $($_.Exception.Message)"
            # Fallback to basic count
            try {
                $sqlCmd = "SELECT COUNT(*) AS DbCount FROM sys.databases WHERE database_id > 4"
                $result = Invoke-Sqlcmd -Query $sqlCmd -ServerInstance $script:Hostname -ErrorAction Stop
                $dbCount = $result.DbCount
                $sqlEvidence = "$dbCount user database(s) present (activity unknown)"
                if ($dbCount -gt 5) {
                    $sqlCriticality = 'HIGH'
                    $script:CriticalityScore += 25
                } else {
                    $script:CriticalityScore += 10
                }
            } catch {
                Write-Verbose "Could not query basic SQL database count"
                $script:CriticalityScore += 10
            }
        }

        $script:ActiveWorkloads.Add([PSCustomObject]@{
            Type = 'SQL Server Database Engine'
            Confidence = $confidence
            Evidence = $sqlEvidence
            Criticality = $sqlCriticality
            TestScenario = 'Test database connectivity, run sample queries, verify backups'
            Details = $sqlDetails
        })
    }

    # DHCP Server with lease activity validation
    if ($script:ServerProfile.DetectedRoles -contains 'DHCP') {
        $dhcpActivity = 'Unknown'
        $dhcpCriticality = 'MEDIUM'
        $dhcpDetails = @{
            Scopes = @()
            TotalScopes = 0
            ActiveLeases = 0
            LeasePercentage = 0
            RecentRequests = 0
        }

        if (Get-Command -Name Get-DhcpServerv4Scope -ErrorAction SilentlyContinue) {
            try {
                $scopes = @(Get-DhcpServerv4Scope -ErrorAction Stop)
                $activeLeases = 0
                $totalAddresses = 0
                
                foreach ($scope in $scopes) {
                    $leases = @(Get-DhcpServerv4Lease -ScopeId $scope.ScopeId -ErrorAction SilentlyContinue)
                    $activeLeases += $leases.Count
                    $totalAddresses += $scope.EndRange - $scope.StartRange + 1
                    
                    $dhcpDetails.Scopes += [PSCustomObject]@{
                        ScopeId = $scope.ScopeId
                        Name = $scope.Name
                        LeaseCount = $leases.Count
                    }
                }
                
                $dhcpDetails.TotalScopes = $scopes.Count
                $dhcpDetails.ActiveLeases = $activeLeases
                if ($totalAddresses -gt 0) {
                    $dhcpDetails.LeasePercentage = [math]::Round(($activeLeases / $totalAddresses) * 100, 1)
                }
                
                # Check for recent DHCP activity in logs
                $dhcpEvents = @(Get-SafeEventLog -Filter @{
                    LogName = 'Microsoft-Windows-Dhcp-Server/Operational'
                    StartTime = $script:WindowStart
                } -MaxEvents 200)
                $dhcpDetails.RecentRequests = $dhcpEvents.Count
                
                $dhcpActivity = "$($scopes.Count) scope(s), $activeLeases active lease(s), $($dhcpDetails.LeasePercentage)% utilization, $dhcpEvents recent events"

                if ($activeLeases -gt 100 -or $dhcpDetails.LeasePercentage -gt 80) {
                    $dhcpCriticality = 'HIGH'
                    $script:CriticalityScore += 25
                } elseif ($activeLeases -gt 0) {
                    $dhcpCriticality = 'MEDIUM'
                    $script:CriticalityScore += 10
                }
            } catch {
                Write-Verbose "Could not query DHCP details"
            }
        }

        $dhcpConfidence = if ($dhcpDetails.ActiveLeases -gt 0) { 'High' } else { 'Medium' }

        $script:ActiveWorkloads.Add([PSCustomObject]@{
            Type = 'DHCP Server'
            Confidence = $dhcpConfidence
            Evidence = $dhcpActivity
            Criticality = $dhcpCriticality
            TestScenario = 'Request DHCP lease, verify scope availability'
            Details = $dhcpDetails
        })
    }

    # Print Server - check for actual print activity
    if ($script:ServerProfile.DetectedRoles -contains 'PrintServer') {
        $printers = @(Get-Printer -ErrorAction SilentlyContinue)
        
        # Check for recent print activity
        $printEvents = @(Get-SafeEventLog -Filter @{
            LogName = 'Microsoft-Windows-PrintService/Operational'
            Id = 307  # Print job completed
            StartTime = $script:WindowStart
        } -MaxEvents 200)
        
        # Also check System log for print spooler activity
        $spoolerEvents = @(Get-SafeEventLog -Filter @{
            LogName = 'System'
            ProviderName = 'PrintService'
            StartTime = $script:WindowStart
        } -MaxEvents 100)
        
        $totalPrintJobs = $printEvents.Count
        $activePrinters = New-Object 'System.Collections.Generic.List[string]'
        
        foreach ($evt in $printEvents) {
            try {
                $xml = [xml]$evt.ToXml()
                $printerName = ($xml.Event.EventData.Data | Where-Object { $_.Name -eq 'Param4' }).'#text'
                if ($printerName -and $activePrinters -notcontains $printerName) {
                    $activePrinters.Add($printerName)
                }
            } catch {
                # Skip malformed events
            }
        }
        
        $printActivity = if ($totalPrintJobs -eq 0) { 'No recent print jobs' }
                        elseif ($totalPrintJobs -lt 10) { 'Low activity' }
                        elseif ($totalPrintJobs -lt 100) { 'Moderate activity' }
                        else { 'High activity' }
        
        $printConfidence = if ($totalPrintJobs -gt 0) { 'High' } else { 'Medium' }
        $printCriticality = if ($totalPrintJobs -gt 100 -or $printers.Count -gt 10) { 'MEDIUM' } else { 'LOW' }
        
        $printDetails = @{
            TotalPrinters = $printers.Count
            ActivePrinters = $activePrinters.Count
            RecentPrintJobs = $totalPrintJobs
            ActivityLevel = $printActivity
            ActivePrinterList = $activePrinters
        }
        
        $script:ActiveWorkloads.Add([PSCustomObject]@{
            Type = 'Print Server'
            Confidence = $printConfidence
            Evidence = "$($printers.Count) printer(s), $totalPrintJobs recent jobs, $printActivity"
            Criticality = $printCriticality
            TestScenario = 'Test print job submission and spooling'
            Details = $printDetails
        })

        if ($totalPrintJobs -gt 100 -or $printers.Count -gt 10) {
            $script:CriticalityScore += 10
        }
    }
}

function Invoke-ApplicationInventory {
    Write-Progress-Status "Applications" "Inventorying installed applications..." 70

    $uninstallPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    $installedApps = New-Object 'System.Collections.Generic.List[object]'

    foreach ($path in $uninstallPaths) {
        try {
            $items = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName }

            foreach ($item in $items) {
                $installedApps.Add([PSCustomObject]@{
                    Name = $item.DisplayName
                    Version = $item.DisplayVersion
                    Publisher = $item.Publisher
                    InstallDate = $item.InstallDate
                })
            }
        } catch {
            Write-Verbose "Could not read uninstall key: $path"
        }
    }

    # Match running processes to installed apps with better detail
    $runningProcesses = @(Get-Process | Select-Object Name, Id, WorkingSet64, TotalProcessorTime, StartTime -Unique)
    $processByName = @{}
    foreach ($proc in $runningProcesses) {
        if (-not $processByName.ContainsKey($proc.Name)) {
            $processByName[$proc.Name] = @()
        }
        $processByName[$proc.Name] += $proc
    }

    foreach ($app in $installedApps) {
        $appNameClean = ($app.Name -replace '[\s\W]', '').ToLower()
        $searchPrefix = $appNameClean.Substring(0, [Math]::Min(8, $appNameClean.Length))
        
        $matchingProcs = $processByName.Keys | Where-Object { 
            $procNameClean = ($_ -replace '[\s\W]', '').ToLower()
            $procNameClean -like "*$searchPrefix*" -or $searchPrefix -like "*$procNameClean*"
        }
        
        if ($matchingProcs) {
            $primaryProc = $processByName[$matchingProcs[0]] | Select-Object -First 1
            $memoryMB = [math]::Round($primaryProc.WorkingSet64 / 1MB, 2)
            $cpuTime = if ($primaryProc.TotalProcessorTime) { 
                [math]::Round($primaryProc.TotalProcessorTime.TotalMinutes, 1) 
            } else { 0 }
            
            $script:Applications.Add([PSCustomObject]@{
                Name = $app.Name
                Version = $app.Version
                Publisher = $app.Publisher
                Status = 'Active'
                ProcessName = $matchingProcs[0]
                ProcessId = $primaryProc.Id
                MemoryMB = $memoryMB
                CPUTimeMinutes = $cpuTime
                Started = if ($primaryProc.StartTime) { $primaryProc.StartTime.ToString('yyyy-MM-dd HH:mm') } else { 'Unknown' }
                Evidence = "Running process: $($matchingProcs[0]) (PID: $($primaryProc.Id), ${memoryMB}MB)"
                TestPriority = if ($memoryMB -gt 100) { 'HIGH' } else { 'MEDIUM' }
            })
        }
    }

    $script:ServerProfile.InstalledApplications = $installedApps.Count
    $script:ServerProfile.ActiveApplications = $script:Applications.Count
    
    # Add top memory-consuming apps to profile
    $script:ServerProfile.TopActiveApplications = $script:Applications | 
        Sort-Object MemoryMB -Descending | 
        Select-Object -First 10
}

function Get-CriticalityRating {
    $score = $script:CriticalityScore

    if ($score -ge 80) {
        return [PSCustomObject]@{
            Rating = 'CRITICAL'
            Score = $score
            Color = 'Red'
            Impact = 'Immediate business impact expected if server is unavailable'
        }
    } elseif ($score -ge 50) {
        return [PSCustomObject]@{
            Rating = 'HIGH'
            Score = $score
            Color = 'Yellow'
            Impact = 'Significant user impact, degraded service expected'
        }
    } elseif ($score -ge 25) {
        return [PSCustomObject]@{
            Rating = 'MEDIUM'
            Score = $score
            Color = 'Cyan'
            Impact = 'Some users affected, workarounds likely available'
        }
    } else {
        return [PSCustomObject]@{
            Rating = 'LOW'
            Score = $score
            Color = 'Green'
            Impact = 'Minimal impact, low usage or standby server'
        }
    }
}

function Export-MarkdownReport {
    Write-Progress-Status "Export" "Generating markdown report..." 80

    $criticality = Get-CriticalityRating
    $mdPath = Join-Path -Path $OutputDirectory -ChildPath "ServerDoc_$($script:Hostname)_$($script:Timestamp).md"

    $md = New-Object 'System.Collections.Generic.List[string]'

    $md.Add("# Server Documentation: $($script:Hostname)")
    $md.Add("")
    $md.Add("**Generated:** $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    $md.Add("**Analysis Period:** Last $DaysBack days")
    $md.Add("")

    # Executive Summary
    $md.Add("## Executive Summary")
    $md.Add("")
    $md.Add("- **Primary Role:** $($script:ServerProfile.PrimaryRole)")
    $md.Add("- **Criticality:** **$($criticality.Rating)** (Score: $($criticality.Score)/100)")
    $md.Add("- **Impact if Down:** $($criticality.Impact)")
    $md.Add("- **Active Workloads:** $($script:ActiveWorkloads.Count)")
    $md.Add("- **Unique Users (last $DaysBack days):** $($script:ServerProfile.UniqueUsers)")
    $md.Add("- **Avg Daily Logons:** $($script:ServerProfile.AvgLogonsPerDay)")
    $md.Add("")

    # System Information
    $md.Add("## System Information")
    $md.Add("")
    $md.Add("| Property | Value |")
    $md.Add("|----------|-------|")
    $md.Add("| Hostname | $($script:ServerProfile.Hostname) |")
    $md.Add("| Operating System | $($script:ServerProfile.OS) |")
    $md.Add("| Build | $($script:ServerProfile.BuildNumber) |")
    $md.Add("| Domain | $($script:ServerProfile.Domain) |")
    $md.Add("| Domain Role | $($script:ServerProfile.DomainRole) |")
    $md.Add("| IP Address(es) | $($script:ServerProfile.IPAddresses) |")
    $md.Add("| Memory | $($script:ServerProfile.MemoryGB) GB |")
    $md.Add("| Processors | $($script:ServerProfile.ProcessorCount) physical, $($script:ServerProfile.LogicalProcessors) logical |")
    $md.Add("| Uptime | $($script:ServerProfile.Uptime) days |")
    $md.Add("| Last Boot | $($script:ServerProfile.LastBoot) |")
    $md.Add("")

    # Active Workloads
    $md.Add("## Active Workloads")
    $md.Add("")
    if ($script:ActiveWorkloads.Count -gt 0) {
        $md.Add("| Workload | Criticality | Confidence | Evidence |")
        $md.Add("|----------|-------------|------------|----------|")
        foreach ($workload in $script:ActiveWorkloads) {
            $md.Add("| $($workload.Type) | **$($workload.Criticality)** | $($workload.Confidence) | $($workload.Evidence) |")
        }
    } else {
        $md.Add("*No specific workloads detected. Server may be in standby or performing general-purpose tasks.*")
    }
    $md.Add("")

    # User Activity
    if ($script:ServerProfile.UniqueUsers -gt 0) {
        $md.Add("## User Activity")
        $md.Add("")
        $md.Add("- **Total Logons (last $DaysBack days):** $($script:ServerProfile.TotalLogons)")
        $md.Add("- **Interactive Logons:** $($script:ServerProfile.InteractiveLogons)")
        $md.Add("- **Unique Users:** $($script:ServerProfile.UniqueUsers)")
        $md.Add("- **Average Daily Logons:** $($script:ServerProfile.AvgLogonsPerDay)")
        $md.Add("")
        
        # Show user list in a table
        $md.Add("### Recent Users")
        $md.Add("")
        $md.Add("| Username | Type |")
        $md.Add("|----------|------|")
        $userCount = 0
        foreach ($user in $script:ServerProfile.UniqueUsersList | Select-Object -First 25) {
            $userType = if ($user -match 'admin|administrator') { 'Admin' } else { 'Standard' }
            $md.Add("| $user | $userType |")
            $userCount++
        }
        if ($script:ServerProfile.UniqueUsers -gt 25) {
            $md.Add("| ... and $($script:ServerProfile.UniqueUsers - 25) more | |")
        }
        $md.Add("")
    }

    # Network Activity
    $md.Add("## Network Activity")
    $md.Add("")
    $md.Add("- **Active TCP Connections:** $($script:NetworkActivity.ActiveConnections)")
    $md.Add("- **Unique Remote Hosts:** $($script:NetworkActivity.UniqueRemoteHosts)")
    $md.Add("")

    if ($script:NetworkActivity.ListeningPorts -and $script:NetworkActivity.ListeningPorts.Count -gt 0) {
        $md.Add("### Listening Ports")
        $md.Add("")
        $md.Add("| Port | Process | PID | Local Address | Active Connections |")
        $md.Add("|------|---------|-----|---------------|-------------------|")
        $sortedPorts = $script:NetworkActivity.ListeningPorts | Sort-Object { [int]$_.Port }
        foreach ($port in $sortedPorts | Select-Object -First 20) {
            $localAddr = if ($port.LocalAddress) { $port.LocalAddress } else { '*' }
            $activeConns = if ($port.ActiveConnections -gt 0) { $port.ActiveConnections } else { '-' }
            $md.Add("| $($port.Port) | $($port.Process) | $($port.ProcessId) | $localAddr | $activeConns |")
        }
        $md.Add("")
        
        # Add port usage summary
        $highTrafficPorts = $script:NetworkActivity.ListeningPorts | Where-Object { $_.ActiveConnections -gt 10 }
        if ($highTrafficPorts) {
            $md.Add("**High-Traffic Ports (>10 connections):** $(($highTrafficPorts | ForEach-Object { "$($_.Port)($($_.ActiveConnections))" }) -join ', ')")
            $md.Add("")
        }
    }

    # Testing Checklist
    $md.Add("## Testing Checklist")
    $md.Add("")
    if ($script:ActiveWorkloads.Count -gt 0) {
        $md.Add("### Priority Test Scenarios")
        $md.Add("")
        foreach ($workload in $script:ActiveWorkloads | Sort-Object Criticality -Descending) {
            $md.Add("- [ ] **$($workload.Type):** $($workload.TestScenario)")
            
            # Add workload-specific details
            if ($workload.Type -eq 'File Server' -and $workload.Details) {
                $md.Add("  - User shares to test: $(($workload.Details.ActiveShareNames | Select-Object -First 5) -join ', ')")
                if (@($workload.Details.ActiveShareNames).Count -gt 5) {
                    $md.Add("  - *... and $(@($workload.Details.ActiveShareNames).Count - 5) more*")
                }
                $md.Add("  - **Open Files:** $($workload.Details.OpenFiles)")
                $md.Add("  - **Active Sessions:** $($workload.Details.ActiveSessions)")
                $md.Add("  - **Activity Level:** $($workload.Details.ActivityLevel)")
                if ($workload.Details.ActivityLevel -eq 'No user share activity detected') {
                    $md.Add("  - **Warning:** No user share access detected in last $DaysBack days - verify shares are still needed")
                }
            }
            if ($workload.Type -eq 'SQL Server Database Engine' -and $workload.Details) {
                $activeDbs = $workload.Details.Databases | Where-Object { $_.ActiveConnections -gt 0 }
                $inactiveDbs = $workload.Details.Databases | Where-Object { $_.ActiveConnections -eq 0 }
                
                $md.Add("  - **Active Databases to Test:**")
                foreach ($db in $activeDbs | Select-Object -First 5) {
                    $md.Add("    - $($db.DatabaseName) ($($db.ActiveConnections) connections)")
                }
                if ($inactiveDbs.Count -gt 0) {
                    $md.Add("  - **Inactive Databases:** $(($inactiveDbs | Select-Object -ExpandProperty DatabaseName -First 5) -join ', ')")
                    $md.Add("    - *Consider reviewing $($inactiveDbs.Count) inactive database(s) for cleanup*")
                }
                $md.Add("  - Run test queries on top 3 most-used databases")
                $md.Add("  - Verify backup completion within last 24 hours")
                $md.Add("  - Test database connectivity from application servers")
            }
            if ($workload.Type -eq 'Web Server (IIS)' -and $workload.Details) {
                $details = $workload.Details
                $md.Add("  - Test all published websites")
                $md.Add("    - Started Sites to Test: $(($details.ActiveSites | Select-Object -First 5) -join ', ')")
                if ($details.ActiveSites.Count -gt 5) {
                    $md.Add("    - *... and $($details.ActiveSites.Count - 5) more started sites*")
                }
                
                $stoppedSites = $details.TotalSites - $details.ActiveSites.Count
                if ($stoppedSites -gt 0) {
                    $md.Add("    - **Note:** $stoppedSites site(s) are not started - verify if they should be")
                }
                
                $md.Add("  - Verify SSL certificates are valid")
                $md.Add("  - Check application pool health and auto-restart settings")
                $md.Add("    - App Pools: $($details.TotalAppPools) total, $(($details.AppPools | Where-Object { $_.Value -eq 'Started' }).Count) running")
                if ($details.ActiveApplications.Count -gt 0) {
                    $md.Add("    - Active Applications: $(($details.ActiveApplications | Select-Object -First 5) -join ', ')")
                }
                if ($details.RecentLogEntries -eq 0) {
                    $md.Add("  - **WARNING:** No recent IIS log activity - verify sites are serving traffic")
                }
                $md.Add("  - Review IIS logs for errors")
            }
            if ($workload.Type -eq 'DHCP Server' -and $workload.Details) {
                $md.Add("  - Test DHCP lease acquisition from each scope")
                $md.Add("  - Verify $($workload.Details.TotalScopes) scope(s) are distributing addresses")
                if ($workload.Details.LeasePercentage -gt 80) {
                    $md.Add("  - **URGENT:** Scope utilization at $($workload.Details.LeasePercentage)% - check for exhaustion")
                }
                $md.Add("  - Check DHCP failover/backup configuration")
            }
            if ($workload.Type -eq 'Print Server' -and $workload.Details) {
                if ($workload.Details.ActivePrinters -gt 0) {
                    $md.Add("  - Test print jobs on active printers: $(($workload.Details.ActivePrinterList | Select-Object -First 5) -join ', ')")
                }
                if ($workload.Details.RecentPrintJobs -eq 0) {
                    $md.Add("  - **Warning:** No print activity detected - verify printers are still needed")
                }
                $md.Add("  - Check print spooler service stability")
                $md.Add("  - Verify printer drivers are installed")
            }
            if ($workload.Type -eq 'Active Directory Domain Controller') {
                $md.Add("  - Test user authentication and Group Policy processing")
                $md.Add("  - Verify SYSVOL and NETLOGON shares are accessible")
                $md.Add("  - Run dcdiag /test:dns,repadmin /replsummary")
                $md.Add("  - Check FSMO role holders are responsive")
            }
        }
    } else {
        $md.Add("- [ ] Verify basic network connectivity")
        $md.Add("- [ ] Test domain membership and authentication")
        $md.Add("- [ ] Validate running services")
    }
    $md.Add("")
    $md.Add("### General Tests")
    $md.Add("")
    $md.Add("- [ ] Verify all services started successfully")
    $md.Add("- [ ] Check Event Viewer for errors (System, Application, Security)")
    $md.Add("- [ ] Test remote management (RDP, WinRM, PowerShell remoting)")
    $md.Add("- [ ] Validate scheduled tasks execution")
    $md.Add("- [ ] Verify backup jobs completed successfully")
    $md.Add("- [ ] Test critical listening ports are responsive")
    $md.Add("- [ ] Confirm antivirus/EDR is running and up-to-date")
    $md.Add("- [ ] Validate DNS resolution (forward and reverse)")
    $md.Add("")
    
    $md.Add("### Post-Maintenance Validation")
    $md.Add("")
    $md.Add("- [ ] Monitor for 30 minutes - check Event Viewer")
    $md.Add("- [ ] Verify no unexpected service failures")
    $md.Add("- [ ] Test user authentication and access")
    $md.Add("- [ ] Confirm monitoring/alerting tools are functional")
    if ($script:ServerProfile.DomainRole -match 'Domain Controller') {
        $md.Add("- [ ] Verify AD replication status (repadmin /replsummary)")
        $md.Add("- [ ] Check SYSVOL replication")
        $md.Add("- [ ] Confirm DNS zones are resolving")
        $md.Add("- [ ] Test Group Policy processing")
    }
    $md.Add("")
    $md.Add("")

    # SQL Server Details (if applicable)
    $sqlWorkload = $script:ActiveWorkloads | Where-Object { $_.Type -eq 'SQL Server Database Engine' }
    if ($sqlWorkload -and $sqlWorkload.Details -and $sqlWorkload.Details.Databases.Count -gt 0) {
        $md.Add("## SQL Server Database Details")
        $md.Add("")
        $md.Add("| Database | Status | Size (MB) | Active Connections | Last Activity |")
        $md.Add("|----------|--------|-----------|-------------------|---------------|")
        foreach ($db in $sqlWorkload.Details.Databases | Select-Object -First 15) {
            $lastActivity = if ($db.LastActivity) { $db.LastActivity.ToString('yyyy-MM-dd HH:mm') } else { 'Never/Unknown' }
            $md.Add("| $($db.DatabaseName) | $($db.State) | $($db.SizeMB) | $($db.ActiveConnections) | $lastActivity |")
        }
        if ($sqlWorkload.Details.Databases.Count -gt 15) {
            $md.Add("| *... and $($sqlWorkload.Details.Databases.Count - 15) more databases* | | | | |")
        }
        $md.Add("")
        
        if ($sqlWorkload.Details.ActiveDatabases -lt $sqlWorkload.Details.Databases.Count) {
            $inactiveCount = $sqlWorkload.Details.Databases.Count - $sqlWorkload.Details.ActiveDatabases
            $md.Add("**Note:** $inactiveCount database(s) show no recent activity. Consider reviewing for decommissioning.")
            $md.Add("")
        }
    }

    # File Server Share Details (if applicable)
    $fileServerWorkload = $script:ActiveWorkloads | Where-Object { $_.Type -eq 'File Server' }
    if ($fileServerWorkload -and $fileServerWorkload.Details -and $fileServerWorkload.Details.IsActiveFileServer) {
        $md.Add("## Active File Shares")
        $md.Add("")
        $md.Add("User shares with recent activity:")
        $md.Add("")
        $md.Add("**Total User Shares:** $($fileServerWorkload.Details.UserShares)")
        $md.Add("**Active Shares:** $($fileServerWorkload.Details.ActiveShares)")
        $md.Add("**Open Files:** $($fileServerWorkload.Details.OpenFiles)")
        $md.Add("**Active Sessions:** $($fileServerWorkload.Details.ActiveSessions)")
        $md.Add("**Activity Level:** $($fileServerWorkload.Details.ActivityLevel)")
        $md.Add("")
        foreach ($share in $fileServerWorkload.Details.ActiveShareNames | Select-Object -First 20) {
            $md.Add("- $share")
        }
        if (@($fileServerWorkload.Details.ActiveShareNames).Count -gt 20) {
            $remaining = @($fileServerWorkload.Details.ActiveShareNames).Count - 20
            $md.Add("")
            $md.Add("*... and $remaining more active shares*")
        }
        if ($fileServerWorkload.Details.ActiveShares -lt $fileServerWorkload.Details.UserShares) {
            $unusedShares = $fileServerWorkload.Details.UserShares - $fileServerWorkload.Details.ActiveShares
            $md.Add("")
            $md.Add("**Note:** $unusedShares user share(s) exist but show no access in the last $DaysBack days.")
        }
        $md.Add("")
    }

    # Print Server Details (if applicable)
    $printWorkload = $script:ActiveWorkloads | Where-Object { $_.Type -eq 'Print Server' }
    if ($printWorkload -and $printWorkload.Details) {
        $details = $printWorkload.Details
        $md.Add("## Print Server Activity")
        $md.Add("")
        $md.Add("- **Total Printers:** $($details.TotalPrinters)")
        $md.Add("- **Active Printers (recent jobs):** $($details.ActivePrinters)")
        $md.Add("- **Recent Print Jobs:** $($details.RecentPrintJobs)")
        $md.Add("- **Activity Level:** $($details.ActivityLevel)")
        $md.Add("")
        if ($details.ActivePrinterList.Count -gt 0) {
            $md.Add("**Active Printers:** $(($details.ActivePrinterList | Select-Object -First 10) -join ', ')")
            $md.Add("")
        }
        if ($details.RecentPrintJobs -eq 0) {
            $md.Add("**Warning:** No print jobs detected in the last $DaysBack days. Verify printers are still needed.")
            $md.Add("")
        }
    }

    # Web Server Details (if applicable)
    $webWorkload = $script:ActiveWorkloads | Where-Object { $_.Type -eq 'Web Server (IIS)' }
    if ($webWorkload -and $webWorkload.Details) {
        $details = $webWorkload.Details
        $md.Add("## IIS Web Server Details")
        $md.Add("")
        $md.Add("### Sites")
        $md.Add("")
        $md.Add("| Name | State | Bindings |")
        $md.Add("|------|-------|----------|")
        foreach ($site in $details.Sites | Select-Object -First 10) {
            $bindings = ""
            $siteBindings = @($site.Bindings)
            if ($siteBindings.Count -gt 0) {
                $bindings = ($siteBindings | Where-Object { $_ -and $_.PSObject.Properties['BindingInformation'] } | ForEach-Object { $_.BindingInformation }) -join ', '
            }
            if ([string]::IsNullOrWhiteSpace($bindings)) {
                $bindings = "No bindings"
            }
            $md.Add("| $($site.Name) | $($site.State) | $bindings |")
        }
        if (@($details.Sites).Count -gt 10) {
            $md.Add("| *... and $(@($details.Sites).Count - 10) more sites* | | |")
        }
        $md.Add("")
        
        $md.Add("### Applications")
        $md.Add("")
        $md.Add("| Site/Application | Application Pool | Virtual Path | Physical Path |")
        $md.Add("|------------------|------------------|--------------|---------------|")
        foreach ($app in @($details.Applications) | Select-Object -First 10) {
            # Extract site name from ItemXPath if SiteName property doesn't exist
            $siteName = "Unknown"
            if ($app.PSObject.Properties['SiteName']) {
                $siteName = $app.SiteName
            } elseif ($app.PSObject.Properties['ItemXPath'] -and $app.ItemXPath) {
                try {
                    # Parse site name from ItemXPath using regex: /site[@name='SiteName']/...
                    if ($app.ItemXPath -match "site\[@name='([^']+)'\]") {
                        $siteName = $Matches[1]
                    }
                } catch {
                    $siteName = "Unknown"
                }
            }
            $appPath = if ($app.Path) { $app.Path } else { "/" }
            $siteApp = "$siteName$appPath"
            $appPool = if ($app.ApplicationPool) { $app.ApplicationPool } else { "DefaultAppPool" }
            $physicalPath = if ($app.PhysicalPath) { $app.PhysicalPath } else { "Not configured" }
            $md.Add("| $siteApp | $appPool | $appPath | $physicalPath |")
        }
        if (@($details.Applications).Count -gt 10) {
            $md.Add("| *... and $(@($details.Applications).Count - 10) more applications* | | | |")
        }
        $md.Add("")
        
        $md.Add("### Application Pools")
        $md.Add("")
        $md.Add("| Name | .NET CLR Version | Pipeline Mode | State |")
        $md.Add("|------|------------------|---------------|-------|")
        foreach ($pool in @($details.AppPools) | Select-Object -First 10) {
            $poolName = if ($pool.Name) { $pool.Name } else { "Unknown" }
            $dotNetVer = if ($pool.dotNetVersion) { $pool.dotNetVersion } else { "N/A" }
            $pipeline = if ($pool.pipelineMode) { $pool.pipelineMode } else { "Integrated" }
            $state = if ($pool.Value) { $pool.Value } else { "Unknown" }
            $md.Add("| $poolName | $dotNetVer | $pipeline | $state |")
        }
        if (@($details.AppPools).Count -gt 10) {
            $md.Add("| *... and $(@($details.AppPools).Count - 10) more app pools* | | | |")
        }
        $md.Add("")
        
        $md.Add("### Activity Summary")
        $md.Add("")
        $md.Add("- **Total Sites:** $($details.TotalSites)")
        $md.Add("- **Started Sites:** $(@($details.ActiveSites).Count)")
        $md.Add("- **Total Applications:** $($details.TotalApplications)")
        $md.Add("- **Active Applications (in started sites):** $(@($details.ActiveApplications).Count)")
        $md.Add("- **Total App Pools:** $($details.TotalAppPools)")
        $md.Add("- **Running App Pools:** $(@(if ($details.AppPools) { $details.AppPools | Where-Object { $_.Value -eq 'Started' } }).Count)")
        $md.Add("- **Recent Log Entries Sampled:** $($details.RecentLogEntries)")
        $md.Add("- **Log Activity Level:** $($details.LogActivityLevel)")
        $md.Add("")
        
        # Show warnings for inactive sites/apps
        $inactiveSites = $details.TotalSites - @($details.ActiveSites).Count
        if ($inactiveSites -gt 0) {
            $md.Add("**Warning:** $inactiveSites site(s) are not started. Verify if they should be running.")
            $md.Add("")
        }
        
        $inactiveApps = $details.TotalApplications - @($details.ActiveApplications).Count
        if ($inactiveApps -gt 0) {
            $md.Add("**Note:** $inactiveApps application(s) exist in stopped sites or are not active. Review for cleanup.")
            $md.Add("")
        }
    }

    # Active Applications with enhanced details
    if ($script:Applications.Count -gt 0) {
        $md.Add("## Active Applications")
        $md.Add("")
        $md.Add("Applications with running processes (sorted by memory usage):")
        $md.Add("")
        $md.Add("| Application | Version | Process | PID | Memory (MB) | CPU (min) | Priority |")
        $md.Add("|-------------|---------|---------|-----|-------------|-----------|----------|")
        foreach ($app in $script:Applications | Sort-Object MemoryMB -Descending | Select-Object -First 25) {
            $md.Add("| $($app.Name) | $($app.Version) | $($app.ProcessName) | $($app.ProcessId) | $($app.MemoryMB) | $($app.CPUTimeMinutes) | $($app.TestPriority) |")
        }
        if ($script:Applications.Count -gt 25) {
            $md.Add("| *... and $($script:Applications.Count - 25) more* | | | | | | |")
        }
        $md.Add("")
        $md.Add("**Note:** HIGH priority indicates applications using >100MB RAM or critical business software")
        $md.Add("")
    }

    # Top Processes
    if ($script:ServerProfile.TopProcesses) {
        $md.Add("## Top Resource Consumers")
        $md.Add("")
        $md.Add("| Process | Memory (MB) | CPU (sec) | Started |")
        $md.Add("|---------|-------------|-----------|---------|")
        foreach ($proc in $script:ServerProfile.TopProcesses | Select-Object -First 10) {
            $md.Add("| $($proc.Name) | $($proc.WorkingSetMB) | $($proc.CPUSeconds) | $($proc.StartTime) |")
        }
        $md.Add("")
    }

    # Recommendations
    $md.Add("## Recommendations")
    $md.Add("")

    if ($criticality.Rating -eq 'CRITICAL' -or $criticality.Rating -eq 'HIGH') {
        $md.Add("1. **Test thoroughly before production changes** - This server handles critical workloads")
        $md.Add("2. Schedule maintenance during approved change windows only")
        $md.Add("3. Ensure backup and rollback procedures are validated")
        $md.Add("4. Notify stakeholders of any planned downtime")
    } elseif ($criticality.Rating -eq 'MEDIUM') {
        $md.Add("1. Standard testing procedures recommended")
        $md.Add("2. Coordinate with workload owners for maintenance windows")
    } else {
        $md.Add("1. Low usage detected - verify server is still needed")
        $md.Add("2. Consider decommissioning if no longer required")
    }
    $md.Add("")

    $md.Add("---")
    $md.Add("*Generated by ServerDocumentation-Discovery.ps1*")

    try {
        $md | Set-Content -Path $mdPath -Encoding UTF8
        Write-Host "Markdown report: $mdPath" -ForegroundColor Cyan
    } catch {
        Write-Warning "Could not write markdown report: $($_.Exception.Message)"
    }
}

function Export-CsvReports {
    Write-Progress-Status "Export" "Generating CSV reports..." 90

    # Workload summary
    $workloadPath = Join-Path -Path $OutputDirectory -ChildPath "Workloads_$($script:Hostname)_$($script:Timestamp).csv"
    if ($script:ActiveWorkloads.Count -gt 0) {
        try {
            $script:ActiveWorkloads | Export-Csv -Path $workloadPath -NoTypeInformation -Encoding UTF8
            Write-Host "Workload CSV: $workloadPath" -ForegroundColor Cyan
        } catch {
            Write-Warning "Could not write workload CSV: $($_.Exception.Message)"
        }
    }

    # Test plan
    $testPath = Join-Path -Path $OutputDirectory -ChildPath "TestPlan_$($script:Hostname)_$($script:Timestamp).csv"
    $testPlan = New-Object 'System.Collections.Generic.List[object]'

    foreach ($workload in $script:ActiveWorkloads) {
        $detailSummary = ""
        if ($workload.Details) {
            switch ($workload.Type) {
                'SQL Server Database Engine' {
                    $detailSummary = "$($workload.Details.ActiveDatabases)/$($workload.Details.Databases.Count) active DBs, $($workload.Details.TotalConnections) connections"
                }
                'File Server' {
                    $detailSummary = "$($workload.Details.UserShares) user shares, $($workload.Details.ActiveShares) active, $($workload.Details.OpenFiles) open files, $($workload.Details.ActiveSessions) sessions"
                }
                'DHCP Server' {
                    $detailSummary = "$($workload.Details.ActiveLeases) leases, $($workload.Details.LeasePercentage)% utilized"
                }
                'Print Server' {
                    $detailSummary = "$($workload.Details.ActivePrinters) active, $($workload.Details.RecentPrintJobs) recent jobs"
                }
                'Web Server (IIS)' {
                    $detailSummary = "$($workload.Details.ActiveSites.Count)/$($workload.Details.TotalSites) sites started, $($workload.Details.TotalAppPools) app pools, $($workload.Details.RecentLogEntries) log entries"
                }
            }
        }
        
        $testPlan.Add([PSCustomObject]@{
            Component = $workload.Type
            Criticality = $workload.Criticality
            Confidence = $workload.Confidence
            Evidence = $workload.Evidence
            ActivityDetails = $detailSummary
            TestScenario = $workload.TestScenario
            Owner = ''
            Status = 'Not Started'
            Notes = ''
        })
    }

    # Add general tests
    $testPlan.Add([PSCustomObject]@{
        Component = 'General'
        Criticality = 'HIGH'
        TestScenario = 'Verify all services started successfully'
        Owner = ''
        Status = 'Not Started'
        Notes = ''
    })

    try {
        $testPlan | Export-Csv -Path $testPath -NoTypeInformation -Encoding UTF8
        Write-Host "Test Plan CSV: $testPath" -ForegroundColor Cyan
    } catch {
        Write-Warning "Could not write test plan CSV: $($_.Exception.Message)"
    }
}

# Main execution
try {
    Write-Host "`n==== Server Documentation Discovery ====" -ForegroundColor Cyan
    Write-Host "Server: $($script:Hostname)" -ForegroundColor Cyan
    Write-Host "Analysis Period: Last $DaysBack days`n" -ForegroundColor Cyan

    Invoke-ServerBaseline
    Invoke-RoleDiscovery
    Invoke-ServiceAnalysis
    Invoke-ProcessAnalysis
    Invoke-NetworkAnalysis
    Invoke-LogonAnalysis
    Invoke-WorkloadDetection
    Invoke-ApplicationInventory

    Export-MarkdownReport
    Export-CsvReports

    Write-Progress -Activity "Server Documentation Discovery" -Completed

    $duration = ((Get-Date) - $script:StartTime).TotalSeconds
    $criticality = Get-CriticalityRating

    Write-Host "`n==== Summary ====" -ForegroundColor Cyan
    Write-Host "Server Role: $($script:ServerProfile.PrimaryRole)" -ForegroundColor White
    Write-Host "Criticality: $($criticality.Rating) (Score: $($criticality.Score))" -ForegroundColor $criticality.Color
    Write-Host "Active Workloads: $($script:ActiveWorkloads.Count)" -ForegroundColor White
    
    # Show listening ports summary
    if ($script:NetworkActivity.ListeningPorts -and $script:NetworkActivity.ListeningPorts.Count -gt 0) {
        $highTraffic = $script:NetworkActivity.ListeningPorts | Where-Object { $_.ActiveConnections -gt 0 } | Sort-Object ActiveConnections -Descending | Select-Object -First 5
        if ($highTraffic) {
            Write-Host "High-Traffic Ports:" -ForegroundColor White
            foreach ($port in $highTraffic) {
                Write-Host "  Port $($port.Port) ($($port.Process)): $($port.ActiveConnections) connections" -ForegroundColor Gray
            }
        }
    }
    
    # Show recent users summary
    if ($script:ServerProfile.UniqueUsers -gt 0) {
        Write-Host "Recent Activity: $($script:ServerProfile.UniqueUsers) unique users, $($script:ServerProfile.TotalLogons) logons" -ForegroundColor White
        $topUsers = $script:ServerProfile.UniqueUsersList | Select-Object -First 5
        Write-Host "Top users: $($topUsers -join ', ')" -ForegroundColor Gray
    }
    
    # Show share activity if applicable
    $fileServerWorkload = $script:ActiveWorkloads | Where-Object { $_.Type -eq 'File Server' }
    if ($fileServerWorkload -and $fileServerWorkload.Details) {
        $details = $fileServerWorkload.Details
        Write-Host "File Server: $($details.UserShares) user shares, $($details.ActiveShares) active, $($details.OpenFiles) open files, $($details.ActiveSessions) sessions" -ForegroundColor White
        if ($details.ActivityLevel -eq 'No user share activity detected') {
            Write-Host "  WARNING: No user share activity detected in last $DaysBack days" -ForegroundColor Yellow
        }
    }
    
    # Show DHCP activity if applicable
    $dhcpWorkload = $script:ActiveWorkloads | Where-Object { $_.Type -eq 'DHCP Server' }
    if ($dhcpWorkload -and $dhcpWorkload.Details) {
        $details = $dhcpWorkload.Details
        Write-Host "DHCP Server: $($details.TotalScopes) scopes, $($details.ActiveLeases) active leases" -ForegroundColor White
        if ($details.LeasePercentage -gt 80) {
            Write-Host "  WARNING: Scope utilization at $($details.LeasePercentage)% - near capacity" -ForegroundColor Yellow
        }
        if ($details.RecentRequests -eq 0) {
            Write-Host "  Note: No recent DHCP log activity detected" -ForegroundColor Gray
        }
    }
    
    # Show SQL Server activity if applicable
    $sqlWorkload = $script:ActiveWorkloads | Where-Object { $_.Type -eq 'SQL Server Database Engine' }
    if ($sqlWorkload -and $sqlWorkload.Details) {
        $details = $sqlWorkload.Details
        Write-Host "SQL Server: $($details.Databases.Count) databases, $($details.ActiveDatabases) active, $($details.TotalConnections) current connections" -ForegroundColor White
        if ($details.TotalConnections -eq 0) {
            Write-Host "  WARNING: No active SQL connections detected" -ForegroundColor Yellow
        }
        if ($details.Databases.Count -gt 0 -and $details.ActiveDatabases -lt $details.Databases.Count) {
            $inactive = $details.Databases.Count - $details.ActiveDatabases
            Write-Host "  Note: $inactive database(s) show no recent activity" -ForegroundColor Gray
        }
    }
    
    # Show Print Server activity if applicable
    $printWorkload = $script:ActiveWorkloads | Where-Object { $_.Type -eq 'Print Server' }
    if ($printWorkload -and $printWorkload.Details) {
        $details = $printWorkload.Details
        Write-Host "Print Server: $($details.TotalPrinters) printers, $($details.RecentPrintJobs) recent jobs" -ForegroundColor White
        if ($details.RecentPrintJobs -eq 0) {
            Write-Host "  WARNING: No print jobs in last $DaysBack days" -ForegroundColor Yellow
        }
    }
    
    # Show Web Server activity if applicable
    $webWorkload = $script:ActiveWorkloads | Where-Object { $_.Type -eq 'Web Server (IIS)' }
    if ($webWorkload -and $webWorkload.Details) {
        $details = $webWorkload.Details
        $runningPools = ($details.AppPools | Where-Object { $_.Value -eq 'Started' }).Count
        Write-Host "Web Server: $($details.TotalSites) sites ($($details.ActiveSites.Count) started), $($details.TotalApplications) applications, $($details.TotalAppPools) app pools ($runningPools running)" -ForegroundColor White
        Write-Host "  Recent Log Entries: $($details.RecentLogEntries), Activity Level: $($details.LogActivityLevel)" -ForegroundColor Gray
        
        if ($details.RecentLogEntries -eq 0) {
            Write-Host "  WARNING: No recent IIS log activity detected" -ForegroundColor Yellow
        }
        
        # Show started sites
        if ($details.ActiveSites.Count -gt 0) {
            Write-Host "  Started Sites: $(($details.ActiveSites | Select-Object -First 5) -join ', ')" -ForegroundColor Gray
        }
        
        # Show stopped sites warning
        $stoppedSites = $details.TotalSites - $details.ActiveSites.Count
        if ($stoppedSites -gt 0) {
            Write-Host "  WARNING: $stoppedSites site(s) are not started" -ForegroundColor Yellow
        }
    }
    
    # Show top active applications
    if ($script:Applications.Count -gt 0) {
        $topApps = $script:Applications | Sort-Object MemoryMB -Descending | Select-Object -First 3
        Write-Host "Top Active Applications (by memory):" -ForegroundColor White
        foreach ($app in $topApps) {
            Write-Host "  $($app.Name): $($app.MemoryMB) MB, PID $($app.ProcessId)" -ForegroundColor Gray
        }
    }
    
    Write-Host "Analysis completed in $([math]::Round($duration, 1)) seconds" -ForegroundColor Gray
    Write-Host ""

} catch {
    Write-Error "Discovery failed: $($_.Exception.Message)"
    Write-Error $_.ScriptStackTrace
    exit 1
}
