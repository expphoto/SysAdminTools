<#
.SYNOPSIS
    Windows Server 2025 production-safe readiness assessment.

.DESCRIPTION
    Performs a read-only, evidence-based assessment for Windows Server 2016, 2019,
    and 2022 systems that are candidates for an upgrade to Windows Server 2025.

    The script is designed to be safe on production systems:
    - No registry writes
    - No role or feature changes
    - No audit/logging enablement
    - No service restarts
    - No network probes unless explicitly requested

    It prefers evidence of active use over simple inventory. When evidence is not
    available, the script reports the gap instead of changing system state.

.PARAMETER DaysBack
    Number of days of history to scan in existing event logs. Default is 7.

.PARAMETER MaxEventsPerQuery
    Maximum events to retrieve for any single log query. Default is 3000.

.PARAMETER OutputDirectory
    Directory for CSV and JSON exports. Defaults to the temp directory.

.PARAMETER IncludeNetworkProbes
    Optional, explicit opt-in for outbound TLS 1.2 capability probes against
    common Microsoft endpoints. Disabled by default.

.EXAMPLE
    .\WS2025_ProductionReadiness.ps1

.EXAMPLE
    .\WS2025_ProductionReadiness.ps1 -DaysBack 30 -OutputDirectory C:\Reports

.EXAMPLE
    .\WS2025_ProductionReadiness.ps1 -IncludeNetworkProbes
#>

[CmdletBinding()]
param(
    [ValidateRange(1, 365)]
    [int]$DaysBack = 7,

    [ValidateRange(100, 50000)]
    [int]$MaxEventsPerQuery = 3000,

    [string]$OutputDirectory = '',

    [switch]$IncludeNetworkProbes
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:Results = New-Object 'System.Collections.Generic.List[object]'
$script:StartedAt = Get-Date
$script:WindowStart = $script:StartedAt.AddDays(-$DaysBack)
$script:ComputerName = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { [System.Net.Dns]::GetHostName() }
$script:Timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$resolvedOutputDirectory = $OutputDirectory
if ([string]::IsNullOrWhiteSpace($resolvedOutputDirectory)) {
    if (-not [string]::IsNullOrWhiteSpace($env:TEMP)) {
        $resolvedOutputDirectory = $env:TEMP
    } elseif (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        $resolvedOutputDirectory = $PSScriptRoot
    } else {
        $resolvedOutputDirectory = (Get-Location).Path
    }
}
$OutputDirectory = $resolvedOutputDirectory
$script:CsvPath = Join-Path -Path $OutputDirectory -ChildPath ("WS2025_ProductionReadiness_{0}_{1}.csv" -f $script:ComputerName, $script:Timestamp)
$script:JsonPath = Join-Path -Path $OutputDirectory -ChildPath ("WS2025_ProductionReadiness_{0}_{1}.json" -f $script:ComputerName, $script:Timestamp)
$script:ChangeRequestPath = Join-Path -Path $OutputDirectory -ChildPath ("WS2025_ProductionReadiness_{0}_{1}_ChangeRequest.md" -f $script:ComputerName, $script:Timestamp)

function Write-Banner {
    $sep = '=' * 72
    Write-Host $sep -ForegroundColor Cyan
    Write-Host ("WS2025 Production Readiness - {0}" -f $script:ComputerName) -ForegroundColor Cyan
    Write-Host ("Read-only evidence window: last {0} day(s)" -f $DaysBack) -ForegroundColor Cyan
    Write-Host ("Output directory: {0}" -f $OutputDirectory) -ForegroundColor Cyan
    if ($IncludeNetworkProbes) {
        Write-Host 'Optional outbound TLS probes: enabled' -ForegroundColor Yellow
    } else {
        Write-Host 'Optional outbound TLS probes: disabled' -ForegroundColor DarkGray
    }
    Write-Host $sep -ForegroundColor Cyan
}

function Add-Check {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Category,

        [Parameter(Mandatory = $true)]
        [string]$Check,

        [Parameter(Mandatory = $true)]
        [ValidateSet('PASS', 'WARN', 'FAIL', 'INFO', 'SKIP')]
        [string]$Status,

        [Parameter(Mandatory = $true)]
        [string]$Detail,

        [string]$Evidence = '',
        [string]$Action = ''
    )

    $entry = [PSCustomObject]@{
        Timestamp = (Get-Date).ToString('s')
        Computer  = $script:ComputerName
        Category  = $Category
        Check     = $Check
        Status    = $Status
        Detail    = $Detail
        Evidence  = $Evidence
        Action    = $Action
    }

    $script:Results.Add($entry)

    $color = switch ($Status) {
        'PASS' { 'Green' }
        'WARN' { 'Yellow' }
        'FAIL' { 'Red' }
        'INFO' { 'Cyan' }
        default { 'DarkGray' }
    }

    Write-Host (("[{0}] {1} / {2}: {3}" -f $Status, $Category, $Check, $Detail)) -ForegroundColor $color
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

function Get-RegistryValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    try {
        if (Test-Path -LiteralPath $Path) {
            $item = Get-ItemProperty -LiteralPath $Path -ErrorAction Stop
            if ($null -ne $item.PSObject.Properties[$Name]) {
                return $item.$Name
            }
        }
    } catch {
        return $null
    }

    return $null
}

function Get-EventDataMap {
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Eventing.Reader.EventRecord]$Event
    )

    $map = @{}
    try {
        $xml = [xml]$Event.ToXml()
        foreach ($node in $xml.Event.EventData.Data) {
            if ($node.Name) {
                $map[$node.Name] = [string]$node.'#text'
            }
        }
    } catch {
        return @{}
    }

    return $map
}

function Get-LogEvents {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Filter
    )

    try {
        return ,@(Get-WinEvent -FilterHashtable $Filter -MaxEvents $MaxEventsPerQuery -ErrorAction Stop)
    } catch {
        return ,@()
    }
}

function Get-InstalledFeatureTable {
    $table = @{}

    if (Get-Command -Name Get-WindowsFeature -ErrorAction SilentlyContinue) {
        try {
            foreach ($feature in Get-WindowsFeature | Where-Object { $_.Installed }) {
                $table[$feature.Name] = $feature
            }
        } catch {
        }
    }

    return $table
}

function Test-RecentFileActivity {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [int]$Days = 30,

        [string]$Filter = '*'
    )

    try {
        if (-not (Test-Path -LiteralPath $Path)) {
            return $null
        }

        $cutoff = (Get-Date).AddDays(-$Days)
        $recent = Get-ChildItem -LiteralPath $Path -Filter $Filter -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -ge $cutoff } |
            Select-Object -First 5

        return $recent
    } catch {
        return $null
    }
}

function Expand-EnvString {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $Value
    }

    return [Environment]::ExpandEnvironmentVariables($Value)
}

function Resolve-TaskScriptPath {
    param(
        [string]$CandidatePath,
        [string]$WorkingDirectory
    )

    if ([string]::IsNullOrWhiteSpace($CandidatePath)) {
        return $null
    }

    $expandedPath = Expand-EnvString -Value $CandidatePath
    if (-not [System.IO.Path]::IsPathRooted($expandedPath) -and -not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        try {
            $expandedPath = Join-Path -Path (Expand-EnvString -Value $WorkingDirectory) -ChildPath $expandedPath
        } catch {
        }
    }

    try {
        return [System.IO.Path]::GetFullPath($expandedPath)
    } catch {
        return $expandedPath
    }
}

function Get-QuotedOrBarePs1Candidates {
    param([string]$Text)

    $candidates = New-Object 'System.Collections.Generic.List[string]'
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return @()
    }

    $patterns = @(
        '"([^\"]+\.ps1)"',
        "'([^']+\.ps1)'",
        '([\\]{2}[^\s"'']+\.ps1|[A-Za-z]:\\[^\r\n"'']+?\.ps1|\.\\[^\r\n"'']+?\.ps1|\.\.\\[^\r\n"'']+?\.ps1)'
    )

    foreach ($pattern in $patterns) {
        foreach ($match in [regex]::Matches($Text, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
            $value = $match.Groups[1].Value.Trim()
            if (-not [string]::IsNullOrWhiteSpace($value) -and -not $candidates.Contains($value)) {
                $candidates.Add($value)
            }
        }
    }

    return $candidates.ToArray()
}

function Get-ScheduledTaskPowerShellScriptPaths {
    param([Parameter(Mandatory = $true)]$Action)

    $execute = Expand-EnvString -Value ([string]$Action.Execute)
    $arguments = Expand-EnvString -Value ([string]$Action.Arguments)
    $workingDirectory = Expand-EnvString -Value ([string]$Action.WorkingDirectory)
    $resolvedPaths = New-Object 'System.Collections.Generic.List[string]'

    function Add-ResolvedPath {
        param([string]$Candidate)

        if ([string]::IsNullOrWhiteSpace($Candidate)) {
            return
        }

        $resolved = Resolve-TaskScriptPath -CandidatePath $Candidate -WorkingDirectory $workingDirectory
        if (-not [string]::IsNullOrWhiteSpace($resolved) -and -not $resolvedPaths.Contains($resolved)) {
            $resolvedPaths.Add($resolved)
        }
    }

    if ($execute -match '(?i)\.ps1$') {
        Add-ResolvedPath -Candidate $execute
    }

    if ($arguments -match '(?i)(?:^|\s)-File\s+') {
        foreach ($candidate in @(Get-QuotedOrBarePs1Candidates -Text $arguments)) {
            Add-ResolvedPath -Candidate $candidate
        }
    }

    foreach ($candidate in @(Get-QuotedOrBarePs1Candidates -Text $arguments)) {
        Add-ResolvedPath -Candidate $candidate
    }

    return $resolvedPaths.ToArray()
}


function Invoke-BaselineChecks {
    Write-Host "`n[1/8] Baseline and upgrade path..." -ForegroundColor Magenta

    $os = $null
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    } catch {
        Add-Check 'Baseline' 'Operating system query' 'FAIL' 'Could not query Win32_OperatingSystem.' 'CIM/WMI query failed.' 'Run elevated and verify WMI health.'
        return
    }

    $caption = [string]$os.Caption
    $version = [string]$os.Version
    $build = [string]$os.BuildNumber
    $supportedSource = $caption -match '2016|2019|2022'
    if ($supportedSource) {
        Add-Check 'Baseline' 'Source OS' 'PASS' ("Detected {0} ({1}, build {2})." -f $caption.Trim(), $version, $build) 'Win32_OperatingSystem' 'Use the documented Microsoft upgrade path for this source OS.'
    } else {
        Add-Check 'Baseline' 'Source OS' 'WARN' ("Detected {0} ({1}, build {2})." -f $caption.Trim(), $version, $build) 'Win32_OperatingSystem' 'Confirm this server is on a supported path to Windows Server 2025 before planning an in-place upgrade.'
    }

    try {
        $memoryGb = [math]::Round(($os.TotalVisibleMemorySize * 1KB) / 1GB, 2)
        if ($memoryGb -ge 4) {
            Add-Check 'Baseline' 'Memory' 'PASS' ("{0} GB RAM detected." -f $memoryGb) 'Win32_OperatingSystem.TotalVisibleMemorySize' ''
        } else {
            Add-Check 'Baseline' 'Memory' 'WARN' ("{0} GB RAM detected." -f $memoryGb) 'Win32_OperatingSystem.TotalVisibleMemorySize' 'Upgrade headroom is tight; validate workload sizing before proceeding.'
        }
    } catch {
        Add-Check 'Baseline' 'Memory' 'SKIP' 'Could not determine physical memory.' 'WMI/CIM query failed.' ''
    }

    try {
        $systemDrive = if ($env:SystemDrive) { $env:SystemDrive } else { 'C:' }
        $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $systemDrive) -ErrorAction Stop
        $freeGb = [math]::Round($disk.FreeSpace / 1GB, 2)
        $sizeGb = [math]::Round($disk.Size / 1GB, 2)
        if ($freeGb -ge 20) {
            Add-Check 'Baseline' 'System drive capacity' 'PASS' ("{0} has {1} GB free of {2} GB." -f $systemDrive, $freeGb, $sizeGb) 'Win32_LogicalDisk' ''
        } else {
            Add-Check 'Baseline' 'System drive capacity' 'WARN' ("{0} has {1} GB free of {2} GB." -f $systemDrive, $freeGb, $sizeGb) 'Win32_LogicalDisk' 'Free additional space before attempting an in-place upgrade.'
        }
    } catch {
        Add-Check 'Baseline' 'System drive capacity' 'SKIP' 'Could not determine free space on the system drive.' 'WMI/CIM query failed.' ''
    }

    if (Test-IsAdministrator) {
        Add-Check 'Baseline' 'Execution context' 'PASS' 'Running elevated.' 'Windows principal is in the Administrators group.' ''
    } else {
        Add-Check 'Baseline' 'Execution context' 'WARN' 'Not running elevated.' 'Administrator token not detected.' 'Some event log, feature, service, and session checks may be incomplete.'
    }
}

function Invoke-TlsChecks {
    Write-Host "`n[2/8] TLS and certificate evidence..." -ForegroundColor Magenta

    $schannelPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL'
    $eventLoggingLevel = Get-RegistryValue -Path $schannelPath -Name 'EventLogging'
    if ($null -eq $eventLoggingLevel -or [int]$eventLoggingLevel -lt 4) {
        Add-Check 'TLS' 'SCHANNEL logging coverage' 'WARN' 'Detailed SCHANNEL logging is not enabled.' 'Registry HKLM\...\SCHANNEL\EventLogging is missing or below informational level.' 'Enable SCHANNEL logging only during a planned observation window, then rerun after normal traffic.'
    } else {
        Add-Check 'TLS' 'SCHANNEL logging coverage' 'PASS' ("SCHANNEL EventLogging is set to {0}." -f $eventLoggingLevel) 'Registry HKLM\...\SCHANNEL\EventLogging' ''
    }

    foreach ($protocol in @('SSL 2.0', 'SSL 3.0', 'TLS 1.0', 'TLS 1.1')) {
        $serverPath = Join-Path -Path $schannelPath -ChildPath ("Protocols\{0}\Server" -f $protocol)
        $clientPath = Join-Path -Path $schannelPath -ChildPath ("Protocols\{0}\Client" -f $protocol)
        $serverEnabled = Get-RegistryValue -Path $serverPath -Name 'Enabled'
        $clientEnabled = Get-RegistryValue -Path $clientPath -Name 'Enabled'
        if ($serverEnabled -eq 0 -and $clientEnabled -eq 0) {
            Add-Check 'TLS' ("Protocol configuration: {0}" -f $protocol) 'PASS' ("{0} is explicitly disabled for client and server." -f $protocol) 'SCHANNEL protocol registry keys' ''
        } else {
            Add-Check 'TLS' ("Protocol configuration: {0}" -f $protocol) 'WARN' ("{0} is not explicitly disabled on both client and server paths." -f $protocol) 'SCHANNEL protocol registry keys' 'Validate application compatibility, then explicitly disable legacy protocols before the upgrade.'
        }
    }

    $schEvents = Get-LogEvents -Filter @{ LogName = 'System'; Id = 36880, 36874; StartTime = $script:WindowStart }
    if ($schEvents.Count -eq 0) {
        Add-Check 'TLS' 'Handshake evidence' 'INFO' 'No SCHANNEL handshake events were found in the selected window.' 'System log Event IDs 36880 and 36874' 'This is an evidence gap, not proof of safety. Observe traffic with SCHANNEL logging enabled in a maintenance window if needed.'
    } else {
        $protocolHits = @{}
        $failures = 0
        foreach ($event in $schEvents) {
            if ($event.Id -eq 36874) {
                $failures++
                continue
            }

            $message = [string]$event.Message
            if ($message -match 'Protocol version:\s*(TLS\s*[0-9\.]+|SSL\s*[0-9\.]+)') {
                $protocolName = ($Matches[1] -replace '\s+', ' ').Trim().ToUpperInvariant()
                if (-not $protocolHits.ContainsKey($protocolName)) {
                    $protocolHits[$protocolName] = 0
                }
                $protocolHits[$protocolName]++
            }
        }

        if ($protocolHits.Count -gt 0) {
            $summary = ($protocolHits.GetEnumerator() | Sort-Object Name | ForEach-Object { "{0}: {1}" -f $_.Name, $_.Value }) -join '; '
            Add-Check 'TLS' 'Handshake summary' 'INFO' $summary 'System log SCHANNEL successful handshake events' ''

            foreach ($legacy in @('TLS 1.0', 'TLS 1.1', 'SSL 3.0', 'SSL 2.0')) {
                $key = $legacy.ToUpperInvariant()
                if ($protocolHits.ContainsKey($key)) {
                    Add-Check 'TLS' ("Observed legacy usage: {0}" -f $legacy) 'FAIL' ("{0} handshake(s) detected for {1}." -f $protocolHits[$key], $legacy) 'System log SCHANNEL Event ID 36880' 'Identify the client or application owners and remediate before upgrading to Windows Server 2025.'
                } else {
                    Add-Check 'TLS' ("Observed legacy usage: {0}" -f $legacy) 'PASS' ("No {0} handshakes detected in the selected window." -f $legacy) 'System log SCHANNEL Event ID 36880' ''
                }
            }
        } else {
            Add-Check 'TLS' 'Handshake summary' 'INFO' 'SCHANNEL events were present but did not expose protocol versions in a parseable format.' 'System log SCHANNEL successful handshake events' 'Review the raw event messages on this host if you need protocol-level confirmation.'
        }

        if ($failures -gt 0) {
            Add-Check 'TLS' 'Negotiation failures' 'WARN' ("{0} failed TLS negotiation event(s) detected." -f $failures) 'System log SCHANNEL Event ID 36874' 'Investigate current TLS failures because stricter defaults in Windows Server 2025 may increase impact.'
        }
    }

    $net4Path = 'HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319'
    $strongCrypto = Get-RegistryValue -Path $net4Path -Name 'SchUseStrongCrypto'
    $systemDefaultTls = Get-RegistryValue -Path $net4Path -Name 'SystemDefaultTlsVersions'
    if ($strongCrypto -eq 1 -and $systemDefaultTls -eq 1) {
        Add-Check 'TLS' '.NET 4.x TLS posture' 'PASS' '.NET Framework 4.x is configured for strong crypto and system default TLS versions.' 'Registry HKLM\SOFTWARE\Microsoft\.NETFramework\v4.0.30319' ''
    } else {
        Add-Check 'TLS' '.NET 4.x TLS posture' 'WARN' ("SchUseStrongCrypto={0}; SystemDefaultTlsVersions={1}." -f $strongCrypto, $systemDefaultTls) 'Registry HKLM\SOFTWARE\Microsoft\.NETFramework\v4.0.30319' 'Validate and standardize .NET TLS configuration so legacy apps do not hard-pin older protocols.'
    }

    try {
        $weakCerts = Get-ChildItem -Path Cert:\LocalMachine -Recurse -ErrorAction Stop |
            Where-Object {
                -not $_.PSIsContainer -and (
                    $_.SignatureAlgorithm.FriendlyName -match 'sha1' -or
                    ($_.PublicKey.Key.KeySize -as [int]) -lt 2048
                )
            } |
            Select-Object -First 10

        if ($weakCerts.Count -gt 0) {
            $subjects = ($weakCerts | ForEach-Object { $_.Subject }) -join '; '
            Add-Check 'TLS' 'Weak local machine certificates' 'WARN' ("Detected {0} certificate(s) using SHA-1 or keys under 2048 bits." -f $weakCerts.Count) $subjects 'Replace weak certificates before services are migrated or reissued on Windows Server 2025.'
        } else {
            Add-Check 'TLS' 'Weak local machine certificates' 'PASS' 'No SHA-1 or sub-2048-bit local machine certificates were found.' 'Cert:\LocalMachine' ''
        }
    } catch {
        Add-Check 'TLS' 'Weak local machine certificates' 'SKIP' 'Could not enumerate the local machine certificate stores.' 'Cert:\LocalMachine query failed.' ''
    }
}

function Invoke-AuthenticationChecks {
    Write-Host "`n[3/8] Authentication and crypto evidence..." -ForegroundColor Magenta

    $lsaPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
    $lmLevel = Get-RegistryValue -Path $lsaPath -Name 'LmCompatibilityLevel'
    if ($null -eq $lmLevel) {
        Add-Check 'Authentication' 'LmCompatibilityLevel' 'INFO' 'LmCompatibilityLevel is not explicitly set.' 'Registry HKLM\SYSTEM\CurrentControlSet\Control\Lsa' 'Review the effective local or domain policy to confirm NTLMv1 is not allowed.'
    } elseif ([int]$lmLevel -lt 3) {
        Add-Check 'Authentication' 'LmCompatibilityLevel' 'FAIL' ("LmCompatibilityLevel is {0}." -f $lmLevel) 'Registry HKLM\SYSTEM\CurrentControlSet\Control\Lsa' 'Raise the policy to an NTLMv2-only setting before upgrading.'
    } else {
        Add-Check 'Authentication' 'LmCompatibilityLevel' 'PASS' ("LmCompatibilityLevel is {0}." -f $lmLevel) 'Registry HKLM\SYSTEM\CurrentControlSet\Control\Lsa' ''
    }

    $logons = Get-LogEvents -Filter @{ LogName = 'Security'; Id = 4624; StartTime = $script:WindowStart }
    if ($logons.Count -eq 0) {
        Add-Check 'Authentication' 'NTLM event evidence' 'INFO' 'No qualifying 4624 logons were available in the selected window.' 'Security log Event ID 4624' 'This may indicate limited audit coverage or log rollover. Treat as an evidence gap.'
    } else {
        $ntlmV1 = @()
        $ntlmAny = 0
        foreach ($event in $logons) {
            $data = Get-EventDataMap -Event $event
            $lmPackage = [string]$data['LmPackageName']
            $authPackage = [string]$data['AuthenticationPackageName']
            if ($authPackage -match '^NTLM$') {
                $ntlmAny++
            }
            if ($lmPackage -eq 'NTLM V1') {
                $source = if ($data['IpAddress']) { $data['IpAddress'] } elseif ($data['WorkstationName']) { $data['WorkstationName'] } else { 'Unknown' }
                $ntlmV1 += $source
            }
        }

        if ($ntlmV1.Count -gt 0) {
            $topSources = ($ntlmV1 | Sort-Object -Unique | Select-Object -First 10) -join ', '
            Add-Check 'Authentication' 'NTLMv1 observed' 'FAIL' ("{0} NTLMv1 logon(s) detected." -f $ntlmV1.Count) $topSources 'NTLMv1 is removed in Windows Server 2025. Remediate those clients or integrations before the upgrade.'
        } else {
            Add-Check 'Authentication' 'NTLMv1 observed' 'PASS' 'No NTLMv1 logons were detected in the selected window.' 'Security log Event ID 4624 / LmPackageName' ''
        }

        if ($ntlmAny -gt 0) {
            Add-Check 'Authentication' 'NTLM usage volume' 'INFO' ("{0} NTLM-based logon(s) detected." -f $ntlmAny) 'Security log Event ID 4624 / AuthenticationPackageName' 'NTLMv2 still functions, but move workloads toward Kerberos where practical.'
        }
    }

    $kerberosTickets = Get-LogEvents -Filter @{ LogName = 'Security'; Id = 4769; StartTime = $script:WindowStart }
    if ($kerberosTickets.Count -eq 0) {
        Add-Check 'Kerberos' 'Ticket encryption evidence' 'INFO' 'No 4769 Kerberos service ticket events were available in the selected window.' 'Security log Event ID 4769' 'This commonly means auditing is not enabled or the host is not the right vantage point. Treat as an evidence gap.'
    } else {
        $rc4Count = 0
        $desCount = 0
        $rc4Targets = New-Object 'System.Collections.Generic.List[string]'
        foreach ($event in $kerberosTickets) {
            $data = Get-EventDataMap -Event $event
            $encType = [string]$data['TicketEncryptionType']
            switch ($encType) {
                '0x17' {
                    $rc4Count++
                    if ($data['ServiceName']) {
                        $rc4Targets.Add([string]$data['ServiceName'])
                    }
                }
                '0x1' { $desCount++ }
                '0x3' { $desCount++ }
            }
        }

        if ($rc4Count -gt 0) {
            $accounts = ($rc4Targets | Sort-Object -Unique | Select-Object -First 10) -join ', '
            Add-Check 'Kerberos' 'RC4 tickets observed' 'WARN' ("{0} RC4-encrypted Kerberos ticket(s) detected." -f $rc4Count) $accounts 'Update affected service accounts and applications to use AES-only encryption types.'
        } else {
            Add-Check 'Kerberos' 'RC4 tickets observed' 'PASS' 'No RC4-encrypted Kerberos tickets were detected.' 'Security log Event ID 4769 / TicketEncryptionType' ''
        }

        if ($desCount -gt 0) {
            Add-Check 'Kerberos' 'DES tickets observed' 'FAIL' ("{0} DES-encrypted Kerberos ticket(s) detected." -f $desCount) 'Security log Event ID 4769 / TicketEncryptionType' 'DES is removed. Eliminate DES-capable accounts and clients before upgrading.'
        } else {
            Add-Check 'Kerberos' 'DES tickets observed' 'PASS' 'No DES-encrypted Kerberos tickets were detected.' 'Security log Event ID 4769 / TicketEncryptionType' ''
        }
    }
}

function Invoke-SmbChecks {
    Write-Host "`n[4/8] SMB and file service evidence..." -ForegroundColor Magenta

    $smb1Enabled = $false
    $smb1AuditEnabled = $false
    $liveSmb1Count = 0
    $historicalSmb1Count = 0

    if (Get-Command -Name Get-SmbServerConfiguration -ErrorAction SilentlyContinue) {
        try {
            $config = Get-SmbServerConfiguration -ErrorAction Stop
            $smb1Enabled = [bool]$config.EnableSMB1Protocol
            $smb1AuditEnabled = [bool]$config.AuditSmb1Access
            if ($smb1Enabled) {
                Add-Check 'SMB' 'SMBv1 server protocol' 'WARN' 'SMBv1 is enabled on this server.' 'Get-SmbServerConfiguration' 'Configured alone is not proof of breakage, but it should be removed if any clients still depend on it.'
            } else {
                Add-Check 'SMB' 'SMBv1 server protocol' 'PASS' 'SMBv1 is disabled on this server.' 'Get-SmbServerConfiguration' ''
            }

            if ($smb1AuditEnabled) {
                Add-Check 'SMB' 'SMBv1 audit coverage' 'PASS' 'SMBv1 auditing is already enabled.' 'Get-SmbServerConfiguration' ''
            } else {
                Add-Check 'SMB' 'SMBv1 audit coverage' 'INFO' 'SMBv1 auditing is not enabled.' 'Get-SmbServerConfiguration' 'Enable auditing only during a planned observation window if you need historical client evidence.'
            }
        } catch {
            Add-Check 'SMB' 'SMB server configuration' 'SKIP' 'Could not query SMB server configuration.' 'Get-SmbServerConfiguration failed.' ''
        }
    } else {
        Add-Check 'SMB' 'SMB server configuration' 'SKIP' 'SMB cmdlets are unavailable on this host.' 'Get-SmbServerConfiguration not found.' ''
    }

    if (Get-Command -Name Get-SmbSession -ErrorAction SilentlyContinue) {
        try {
            $v1Sessions = @(Get-SmbSession -ErrorAction Stop | Where-Object { $_.Dialect -match '^1\.' -or $_.Dialect -eq 'NT LM 0.12' })
            $liveSmb1Count = $v1Sessions.Count
            if ($v1Sessions.Count -gt 0) {
                $clients = ($v1Sessions | Select-Object -ExpandProperty ClientComputerName -Unique) -join ', '
                Add-Check 'SMB' 'Live SMBv1 sessions' 'FAIL' ("{0} active SMBv1 session(s) detected." -f $v1Sessions.Count) $clients 'Those clients will break if SMBv1 is removed or unavailable after the upgrade.'
            } else {
                Add-Check 'SMB' 'Live SMBv1 sessions' 'PASS' 'No active SMBv1 sessions were detected.' 'Get-SmbSession' ''
            }
        } catch {
            Add-Check 'SMB' 'Live SMBv1 sessions' 'SKIP' 'Could not query live SMB sessions.' 'Get-SmbSession failed.' ''
        }
    }

    $smbAuditEvents = Get-LogEvents -Filter @{ LogName = 'Microsoft-Windows-SMBServer/Audit'; Id = 3000; StartTime = $script:WindowStart }
    $historicalSmb1Count = $smbAuditEvents.Count
    if ($smbAuditEvents.Count -gt 0) {
        # Events are returned newest-first by Get-WinEvent; preserve that order so the
        # first 10 reported addresses are the most recently seen clients.
        $seenAddrs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $recentClients = New-Object 'System.Collections.Generic.List[string]'
        foreach ($event in $smbAuditEvents) {
            $data = Get-EventDataMap -Event $event
            $addr = if ($data['ClientAddress']) { [string]$data['ClientAddress'] }
                    elseif ($data['ClientName'])  { [string]$data['ClientName'] }
                    else {
                        $msg = [string]$event.Message
                        if ($msg -match 'Client Address:\s*(\S+)') { $Matches[1] } else { $null }
                    }
            if ($addr -and $seenAddrs.Add($addr)) {
                $recentClients.Add($addr)
            }
        }
        $clientList = ($recentClients | Select-Object -First 10) -join ', '
        Add-Check 'SMB' 'Historical SMBv1 client attempts' 'FAIL' ("{0} SMBv1 audit event(s) from {1} unique client(s) detected." -f $smbAuditEvents.Count, $seenAddrs.Count) $clientList 'Identify and update the legacy clients before upgrading.'
    } else {
        Add-Check 'SMB' 'Historical SMBv1 client attempts' 'INFO' 'No SMBv1 audit events were found in the selected window.' 'Microsoft-Windows-SMBServer/Audit Event ID 3000' 'If SMBv1 auditing is off, this is an evidence gap rather than proof that no client uses SMBv1.'
    }

    if (Get-Command -Name Get-SmbShare -ErrorAction SilentlyContinue) {
        try {
            $shares = @(Get-SmbShare -Special $false -ErrorAction Stop)
            if ($shares.Count -gt 0) {
                Add-Check 'SMB' 'Share inventory' 'INFO' ("{0} non-special SMB share(s) are published." -f $shares.Count) (($shares | Select-Object -ExpandProperty Name) -join ', ') 'Use this with session and open-file evidence to identify business-critical file workloads.'
            }
        } catch {
        }
    }

    if ($liveSmb1Count -gt 0 -or $historicalSmb1Count -gt 0) {
        Add-Check 'SMB' 'SMBv1 upgrade impact' 'FAIL' 'Existing evidence shows SMBv1 is actually in use.' 'Live sessions and/or SMB audit events' 'This is a real upgrade blocker until those clients are remediated.'
    } elseif ($smb1Enabled) {
        Add-Check 'SMB' 'SMBv1 upgrade impact' 'WARN' 'SMBv1 is enabled, but this run did not find evidence that clients are using it.' 'Config enabled; no live or historical use observed in current evidence' 'Treat this as cleanup or validation work, not a confirmed blocker.'
    } else {
        Add-Check 'SMB' 'SMBv1 upgrade impact' 'PASS' 'No SMBv1 usage evidence was found and SMBv1 is disabled.' 'SMB config, live sessions, and audit evidence' ''
    }
}

function Invoke-RoleAndFeatureChecks {
    Write-Host "`n[5/8] Roles, features, and active use..." -ForegroundColor Magenta

    $installed = Get-InstalledFeatureTable
    if ($installed.Count -eq 0) {
        Add-Check 'Roles' 'Installed role inventory' 'SKIP' 'Could not enumerate installed Windows features.' 'Get-WindowsFeature unavailable or query failed.' ''
        return
    }

    $watchList = @(
        @{ Name = 'SMTP-Server'; Label = 'SMTP Server'; Status = 'FAIL'; Action = 'Migrate relay functions because the SMTP Server feature is removed.' },
        @{ Name = 'Web-Lgcy-Mgmt-Console'; Label = 'IIS 6 Management Console'; Status = 'WARN'; Action = 'Migrate any dependency on IIS 6 management tooling.' },
        @{ Name = 'PowerShell-V2'; Label = 'Windows PowerShell 2.0'; Status = 'INFO'; Action = 'Usage is assessed separately so installed-but-unused systems are not overstated.' },
        @{ Name = 'UpdateServices'; Label = 'WSUS'; Status = 'WARN'; Action = 'WSUS is deprecated. Confirm whether you still actively rely on it.' },
        @{ Name = 'ADFS-Federation'; Label = 'AD FS'; Status = 'WARN'; Action = 'Validate the farm, database backend, and app dependencies against Windows Server 2025 guidance.' },
        @{ Name = 'IPAM'; Label = 'IPAM'; Status = 'INFO'; Action = 'Confirm whether IPAM is still used or can be retired.' },
        @{ Name = 'NLB'; Label = 'Network Load Balancing'; Status = 'WARN'; Action = 'Confirm whether NLB is actively in use and whether a modern load-balancing strategy is preferred.' },
        @{ Name = 'WDS'; Label = 'Windows Deployment Services'; Status = 'WARN'; Action = 'Review deployment workflows, especially boot image and PXE dependencies.' },
        @{ Name = 'RemoteAccess'; Label = 'Remote Access'; Status = 'WARN'; Action = 'Review VPN protocol usage, especially PPTP and L2TP.' },
        @{ Name = 'FS-SMB1'; Label = 'SMB 1.0'; Status = 'INFO'; Action = 'Use the SMB usage findings below to determine whether this is a real blocker or just installed cruft.' },
        @{ Name = 'Windows-Internal-Database'; Label = 'Windows Internal Database'; Status = 'INFO'; Action = 'If this backs AD FS or IPAM, validate migration and support posture.' }
    )

    foreach ($item in $watchList) {
        if ($installed.ContainsKey($item.Name)) {
            Add-Check 'Roles' ("Installed feature: {0}" -f $item.Label) $item.Status ("{0} is installed." -f $item.Label) $item.Name $item.Action
        } else {
            Add-Check 'Roles' ("Installed feature: {0}" -f $item.Label) 'PASS' ("{0} is not installed." -f $item.Label) $item.Name ''
        }
    }

    if ($installed.ContainsKey('DHCP')) {
        if (Get-Command -Name Get-DhcpServerv4Scope -ErrorAction SilentlyContinue) {
            try {
                $scopes = @(Get-DhcpServerv4Scope -ErrorAction Stop)
                $activeScopes = 0
                $activeLeases = 0
                foreach ($scope in $scopes) {
                    $leaseCount = @(Get-DhcpServerv4Lease -ScopeId $scope.ScopeId -ErrorAction SilentlyContinue | Select-Object -First 1000).Count
                    if ($leaseCount -gt 0) {
                        $activeScopes++
                        $activeLeases += $leaseCount
                    }
                }
                if ($activeLeases -gt 0) {
                    Add-Check 'Roles' 'DHCP active use' 'PASS' ("DHCP appears active across {0} scope(s) with at least {1} sampled lease(s)." -f $activeScopes, $activeLeases) 'Get-DhcpServerv4Scope/Get-DhcpServerv4Lease' ''
                } else {
                    Add-Check 'Roles' 'DHCP active use' 'WARN' 'DHCP is installed but sampled lease activity was not observed.' 'Get-DhcpServerv4Scope/Get-DhcpServerv4Lease' 'Confirm whether this server is a standby node, an unused role, or outside the observation window.'
                }
            } catch {
                Add-Check 'Roles' 'DHCP active use' 'SKIP' 'Could not query DHCP scopes or leases.' 'DHCP cmdlets failed.' ''
            }
        } else {
            Add-Check 'Roles' 'DHCP active use' 'SKIP' 'DHCP cmdlets are unavailable on this host.' 'Get-DhcpServerv4Scope not found.' ''
        }
    }

    if ($installed.ContainsKey('DNS')) {
        if (Get-Command -Name Get-DnsServerZone -ErrorAction SilentlyContinue) {
            try {
                $zones = @(Get-DnsServerZone -ErrorAction Stop | Where-Object { -not $_.IsAutoCreated -and $_.ZoneType -ne 'Forwarder' })
                if ($zones.Count -gt 0) {
                    Add-Check 'Roles' 'DNS active use' 'PASS' ("DNS hosts {0} non-auto-created zone(s)." -f $zones.Count) (($zones | Select-Object -ExpandProperty ZoneName -First 10) -join ', ') ''
                } else {
                    Add-Check 'Roles' 'DNS active use' 'WARN' 'DNS is installed but no non-auto-created zones were found.' 'Get-DnsServerZone' 'Confirm whether this host is only caching, secondary-only, or an orphaned DNS deployment.'
                }
            } catch {
                Add-Check 'Roles' 'DNS active use' 'SKIP' 'Could not query DNS zones.' 'DNS cmdlets failed.' ''
            }
        }
    }

    if ($installed.ContainsKey('Web-Server')) {
        try {
            $sites = @()
            if (Get-Command -Name Get-Website -ErrorAction SilentlyContinue) {
                $sites = @(Get-Website)
            }
            $recentLogs = Test-RecentFileActivity -Path 'C:\inetpub\logs\LogFiles' -Days 30 -Filter '*.log'
            if ($sites.Count -gt 0 -or ($recentLogs -and $recentLogs.Count -gt 0)) {
                $siteNames = if ($sites.Count -gt 0) { ($sites | Select-Object -ExpandProperty Name -First 10) -join ', ' } else { 'IIS logs only' }
                Add-Check 'Roles' 'IIS active use' 'PASS' 'IIS sites or recent IIS logs indicate active web workload usage.' $siteNames ''
            } else {
                Add-Check 'Roles' 'IIS active use' 'WARN' 'IIS is installed but no sites or recent log activity were observed.' 'Website inventory and C:\inetpub\logs\LogFiles' 'Confirm whether IIS is unused, reverse-proxy-only, or logging elsewhere.'
            }
        } catch {
            Add-Check 'Roles' 'IIS active use' 'SKIP' 'Could not assess IIS site or log activity.' 'IIS cmdlets or log path check failed.' ''
        }
    }

    if ($installed.ContainsKey('Hyper-V')) {
        if (Get-Command -Name Get-NetLbfoTeam -ErrorAction SilentlyContinue) {
            try {
                $teams = @(Get-NetLbfoTeam -ErrorAction Stop)
                if ($teams.Count -gt 0) {
                    Add-Check 'Roles' 'Hyper-V with LBFO teams' 'FAIL' ("Hyper-V is installed and {0} LBFO team(s) were detected." -f $teams.Count) (($teams | Select-Object -ExpandProperty Name) -join ', ') 'Migrate from LBFO-backed virtual switching to SET before upgrading.'
                } else {
                    Add-Check 'Roles' 'Hyper-V with LBFO teams' 'PASS' 'Hyper-V is installed and no LBFO teams were detected.' 'Get-NetLbfoTeam' ''
                }
            } catch {
                Add-Check 'Roles' 'Hyper-V with LBFO teams' 'SKIP' 'Could not query LBFO teams.' 'Get-NetLbfoTeam failed.' ''
            }
        }
    }

    if ($installed.ContainsKey('RemoteAccess')) {
        $rrasLogEvidence = Get-LogEvents -Filter @{ LogName = 'System'; ProviderName = 'RemoteAccess'; StartTime = $script:WindowStart }
        if ($rrasLogEvidence.Count -gt 0) {
            Add-Check 'Roles' 'RRAS recent activity' 'WARN' ("{0} RemoteAccess event(s) were observed." -f $rrasLogEvidence.Count) 'System log / ProviderName RemoteAccess' 'Review protocol use and verify no clients depend on legacy VPN methods.'
        } else {
            Add-Check 'Roles' 'RRAS recent activity' 'INFO' 'Remote Access is installed but recent event evidence was not observed.' 'System log / ProviderName RemoteAccess' 'Confirm whether this role is standby-only, rarely used, or no longer needed.'
        }
    }

    if ($installed.ContainsKey('UpdateServices')) {
        $recentWsusContent = Test-RecentFileActivity -Path 'C:\WSUS\WsusContent' -Days 30
        if ($recentWsusContent -and $recentWsusContent.Count -gt 0) {
            Add-Check 'Roles' 'WSUS recent content activity' 'WARN' 'WSUS content files changed in the last 30 days.' 'C:\WSUS\WsusContent' 'This suggests WSUS is still in use. Plan migration or retirement before upgrading.'
        } else {
            Add-Check 'Roles' 'WSUS recent content activity' 'INFO' 'WSUS is installed but recent WSUS content changes were not observed.' 'C:\WSUS\WsusContent' 'Confirm whether WSUS is inactive, relocated, or still used indirectly.'
        }
    }
}

function Invoke-LegacyToolingChecks {
    Write-Host "`n[6/8] Legacy tooling and automation inventory..." -ForegroundColor Magenta

    $taskHits = New-Object 'System.Collections.Generic.List[string]'
    $ps2TaskHits = New-Object 'System.Collections.Generic.List[string]'
    $taskScriptReferences = New-Object 'System.Collections.Generic.List[object]'
    $taskScriptNotFound = New-Object 'System.Collections.Generic.List[string]'
    $opaquePowerShellTasks = New-Object 'System.Collections.Generic.List[string]'
    $taskInventoryCompleted = $false
    if (Get-Command -Name Get-ScheduledTask -ErrorAction SilentlyContinue) {
        $allTasks = $null
        try {
            $allTasks = @(Get-ScheduledTask -ErrorAction Stop)
        } catch {
            Add-Check 'Legacy Tooling' 'Scheduled task inventory' 'SKIP' 'Could not inventory scheduled tasks.' ("Get-ScheduledTask failed: {0}" -f $_.Exception.Message) ''
        }
        if ($null -ne $allTasks) {
            $taskErrors = New-Object 'System.Collections.Generic.List[string]'
            foreach ($task in $allTasks) {
                try {
                    foreach ($action in @($task.Actions)) {
                        $actionType = $null
                        try { $actionType = $action.CimClass.CimClassName } catch { }
                        if ($null -eq $actionType) {
                            try { $actionType = $action.GetType().Name } catch { }
                        }
                        if ($actionType -and $actionType -notmatch 'ExecAction') { continue }

                        $actionExe = $null
                        $actionArgs = ''
                        try {
                            $actionExe = [string]$action.Execute
                            $actionArgs = [string]$action.Arguments
                        } catch {
                            continue
                        }
                        if ([string]::IsNullOrWhiteSpace($actionExe)) { continue }
                        $commandLine = ($actionExe + ' ' + $actionArgs).Trim()
                        $isPowerShellHost = $commandLine -match '(?i)(^|\s|\\)(powershell|pwsh)(\.exe)?(\s|$)'
                        if ($commandLine -match 'wmic(\.exe)?|wscript(\.exe)?|cscript(\.exe)?|\.vbs\b|powershell(\.exe)?\s+.*-version\s+2') {
                            $taskHits.Add(("{0}: {1}" -f $task.TaskName, $commandLine))
                        }
                        if ($commandLine -match 'powershell(\.exe)?\s+.*-version\s+2') {
                            $ps2TaskHits.Add(("{0}: {1}" -f $task.TaskName, $commandLine))
                        }

                        if ($isPowerShellHost) {
                            if ([string]$action.Arguments -match '(?i)-EncodedCommand\b|-enc\b') {
                                $opaquePowerShellTasks.Add(("{0}: {1}" -f $task.TaskName, $commandLine))
                            }

                            foreach ($scriptPath in @(Get-ScheduledTaskPowerShellScriptPaths -Action $action)) {
                                if ([string]::IsNullOrWhiteSpace($scriptPath)) {
                                    continue
                                }

                                if (Test-Path -LiteralPath $scriptPath) {
                                    $taskScriptReferences.Add([PSCustomObject]@{
                                        TaskName = $task.TaskName
                                        TaskPath = $task.TaskPath
                                        ScriptPath = $scriptPath
                                        CommandLine = $commandLine
                                    })
                                } else {
                                    $taskScriptNotFound.Add(("{0}{1}: {2}" -f $task.TaskPath, $task.TaskName, $scriptPath))
                                }
                            }
                        }
                    }
                } catch {
                    $taskErrors.Add(("{0}{1}: {2}" -f $task.TaskPath, $task.TaskName, $_.Exception.Message))
                }
            }
            $taskInventoryCompleted = $true
            if ($taskErrors.Count -gt 0) {
                Add-Check 'Legacy Tooling' 'Scheduled task inspection errors' 'WARN' ("{0} task(s) could not be fully inspected." -f $taskErrors.Count) (($taskErrors | Select-Object -First 10) -join '; ') 'These tasks may have corrupted definitions or incompatible action types. Review them manually.'
            }
        }
    } else {
        Add-Check 'Legacy Tooling' 'Scheduled task inventory' 'SKIP' 'Scheduled task cmdlets are unavailable on this host.' 'Get-ScheduledTask not found.' ''
    }

    if ($taskInventoryCompleted -and $taskHits.Count -gt 0) {
        Add-Check 'Legacy Tooling' 'Legacy commands in scheduled tasks' 'WARN' ("{0} scheduled task action(s) reference WMIC, VBScript, WSH, or PowerShell 2.0." -f $taskHits.Count) (($taskHits | Select-Object -First 10) -join '; ') 'Update the affected automation before upgrading.'
    } elseif ($taskInventoryCompleted) {
        Add-Check 'Legacy Tooling' 'Legacy commands in scheduled tasks' 'PASS' 'No scheduled task actions referencing the targeted legacy tooling were found.' 'Scheduled task actions' ''
    }

    $uniqueTaskScriptReferences = @($taskScriptReferences | Sort-Object ScriptPath -Unique)
    if ($taskInventoryCompleted -and $uniqueTaskScriptReferences.Count -gt 0) {
        Add-Check 'Legacy Tooling' 'Scheduled task PowerShell script inventory' 'INFO' ("{0} scheduled PowerShell script path(s) were resolved for inspection." -f $uniqueTaskScriptReferences.Count) (($uniqueTaskScriptReferences | Select-Object -ExpandProperty ScriptPath | Select-Object -First 10) -join '; ') 'Review flagged script commands before upgrading.'
    } elseif ($taskInventoryCompleted) {
        Add-Check 'Legacy Tooling' 'Scheduled task PowerShell script inventory' 'INFO' 'No scheduled task PowerShell script paths were resolved for deep inspection.' 'Scheduled task actions' 'This can occur when tasks use inline commands or non-PowerShell hosts.'
    }

    if ($taskInventoryCompleted -and $taskScriptNotFound.Count -gt 0) {
        Add-Check 'Legacy Tooling' 'Scheduled task referenced script not found' 'WARN' ("{0} scheduled task script path(s) could not be found on disk." -f $taskScriptNotFound.Count) (($taskScriptNotFound | Select-Object -First 10) -join '; ') 'Validate whether the path is remote, dynamically created, or stale before upgrade planning.'
    }

    if ($taskInventoryCompleted -and $opaquePowerShellTasks.Count -gt 0) {
        Add-Check 'Legacy Tooling' 'Scheduled task PowerShell script inspection gap' 'INFO' ("{0} scheduled PowerShell task(s) use encoded command content that was not inspected." -f $opaquePowerShellTasks.Count) (($opaquePowerShellTasks | Select-Object -First 10) -join '; ') 'Review these tasks manually because inline encoded content may hide legacy command usage.'
    }

    if ($taskInventoryCompleted -and ($uniqueTaskScriptReferences.Count -gt 0 -or $opaquePowerShellTasks.Count -gt 0)) {
        $totalScripts = $uniqueTaskScriptReferences.Count + $opaquePowerShellTasks.Count
        Add-Check 'Legacy Tooling' 'Scheduled task deep script scan needed' 'WARN' ("{0} scheduled PowerShell task(s) require deep script inspection for WS2025 deprecated patterns." -f $totalScripts) (($uniqueTaskScriptReferences | Select-Object -ExpandProperty ScriptPath -First 10) -join '; ') 'Run Scan-ScheduledTaskScripts.ps1 on this server to inspect the actual script content for WMIC, PS 2.0, VBScript, and other deprecated patterns.'
    } elseif ($taskInventoryCompleted) {
        Add-Check 'Legacy Tooling' 'Scheduled task deep script scan needed' 'PASS' 'No scheduled PowerShell script tasks require deep inspection.' 'No script-based PowerShell tasks found' ''
    }

    try {
        $legacyProcesses = @(Get-Process -ErrorAction Stop | Where-Object { $_.ProcessName -match '^(wmic|wscript|cscript)$' })
        if ($legacyProcesses.Count -gt 0) {
            Add-Check 'Legacy Tooling' 'Running legacy host processes' 'WARN' ("{0} active WMIC/WSH process(es) were observed." -f $legacyProcesses.Count) (($legacyProcesses | Select-Object -ExpandProperty ProcessName -Unique) -join ', ') 'Identify the owning automation and replace it.'
        } else {
            Add-Check 'Legacy Tooling' 'Running legacy host processes' 'PASS' 'No active WMIC or Windows Script Host processes were observed.' 'Process table sample' ''
        }
    } catch {
        Add-Check 'Legacy Tooling' 'Running legacy host processes' 'SKIP' 'Could not query active processes.' 'Get-Process failed.' ''
    }

    $ps2ProcHits = New-Object 'System.Collections.Generic.List[string]'
    if (Get-Command -Name Get-CimInstance -ErrorAction SilentlyContinue) {
        try {
            $psProcesses = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop)
            foreach ($proc in $psProcesses) {
                if ([string]$proc.CommandLine -match '-version\s+2') {
                    $ps2ProcHits.Add(("PID {0}: {1}" -f $proc.ProcessId, $proc.CommandLine))
                }
            }
        } catch {
        }
    }

    # Check the classic Windows PowerShell event log for actual PS 2.0 engine starts.
    # Event ID 400 is written each time the PowerShell engine initialises; the free-text
    # body contains "EngineVersion=2.0" when invoked with -Version 2.
    $ps2LogHits = New-Object 'System.Collections.Generic.List[string]'
    $ps2LogEvents = Get-LogEvents -Filter @{ LogName = 'Windows PowerShell'; Id = 400; StartTime = $script:WindowStart }
    foreach ($ps2Evt in $ps2LogEvents) {
        $msg = [string]$ps2Evt.Message
        if ($msg -match 'EngineVersion=2\.') {
            $hostApp = if ($msg -match 'HostApplication=([^\r\n]+)') { $Matches[1].Trim() } else { 'unknown' }
            if ($hostApp.Length -gt 120) { $hostApp = $hostApp.Substring(0, 120) + '...' }
            $ps2LogHits.Add(("Event at {0}: {1}" -f $ps2Evt.TimeCreated.ToString('yyyy-MM-dd HH:mm'), $hostApp))
        }
    }

    $installedFeatures = Get-InstalledFeatureTable
    $ps2Installed = $installedFeatures.ContainsKey('PowerShell-V2')

    if ($ps2Installed) {
        if ($ps2LogHits.Count -gt 0) {
            Add-Check 'Legacy Tooling' 'PowerShell 2.0 event log evidence' 'FAIL' ("{0} PowerShell 2.0 engine start event(s) detected in this window." -f $ps2LogHits.Count) (($ps2LogHits | Select-Object -First 5) -join '; ') 'PowerShell 2.0 was actively invoked. Identify and remediate those callers before upgrading.'
        } elseif ($ps2LogEvents.Count -gt 0) {
            Add-Check 'Legacy Tooling' 'PowerShell 2.0 event log evidence' 'PASS' 'Windows PowerShell log has entries but no PowerShell 2.0 engine starts were detected.' 'Windows PowerShell Event ID 400' ''
        } else {
            Add-Check 'Legacy Tooling' 'PowerShell 2.0 event log evidence' 'INFO' 'No Windows PowerShell Event ID 400 entries were found in the selected window.' 'Windows PowerShell log Event ID 400' 'The log may have rolled over or PowerShell was not invoked in this window. Treat as an evidence gap.'
        }
    }

    $ps2EvidenceCount = $ps2TaskHits.Count + $ps2ProcHits.Count + $ps2LogHits.Count
    if ($ps2Installed -and $ps2EvidenceCount -gt 0) {
        $evidence = (($ps2TaskHits + $ps2ProcHits) | Select-Object -First 10) -join '; '
        Add-Check 'Legacy Tooling' 'PowerShell 2.0 upgrade impact' 'FAIL' 'PowerShell 2.0 is installed and active usage evidence was found.' $evidence 'These scripts or processes are likely to break on Windows Server 2025 and must be remediated first.'
    } elseif ($ps2Installed) {
        Add-Check 'Legacy Tooling' 'PowerShell 2.0 upgrade impact' 'WARN' 'PowerShell 2.0 is installed, but this run did not find direct usage evidence.' 'Installed feature without task or process evidence in the current observation set' 'Treat this as cleanup or targeted validation work, not a confirmed blocker.'
    } else {
        Add-Check 'Legacy Tooling' 'PowerShell 2.0 upgrade impact' 'PASS' 'PowerShell 2.0 is not installed.' 'Get-WindowsFeature PowerShell-V2' ''
    }
}

function Get-WS2025ChangeMetadata {
    param([Parameter(Mandatory = $true)][psobject]$Item)

    $check = [string]$Item.Check
    $meta = [PSCustomObject]@{
        IsWS2025Change = $false
        ChangeType = ''
        ChangeNote = ''
    }

    switch -Regex ($check) {
        '^Installed feature: SMTP Server$' {
            $meta.IsWS2025Change = $true
            $meta.ChangeType = 'Removed'
            $meta.ChangeNote = 'SMTP Server role removed in Windows Server 2025.'
            break
        }
        '^Installed feature: IIS 6 Management Console$' {
            $meta.IsWS2025Change = $true
            $meta.ChangeType = 'Removed'
            $meta.ChangeNote = 'IIS 6 management compatibility features removed/deprecated.'
            break
        }
        '^Installed feature: Windows PowerShell 2.0$|^PowerShell 2.0 upgrade impact$' {
            $meta.IsWS2025Change = $true
            $meta.ChangeType = 'Removed'
            $meta.ChangeNote = 'PowerShell 2.0 engine removed from modern Windows Server paths.'
            break
        }
        '^Scheduled task script command: PowerShell 2.0 invocation$' {
            $meta.IsWS2025Change = $true
            $meta.ChangeType = 'Removed'
            $meta.ChangeNote = 'Scheduled PowerShell automation still depends on the removed PowerShell 2.0 engine.'
            break
        }
        '^Scheduled task script command: Windows Update detectnow command$' {
            $meta.IsWS2025Change = $true
            $meta.ChangeType = 'Removed'
            $meta.ChangeNote = 'wuauclt.exe /detectnow is removed and unsupported on modern Windows Server.'
            break
        }
        '^Scheduled task script command: WMIC invocation$' {
            $meta.IsWS2025Change = $true
            $meta.ChangeType = 'Deprecated'
            $meta.ChangeNote = 'WMIC is no longer installed by default in Windows Server 2025 and is only available as a Feature on Demand.'
            break
        }
        '^Scheduled task script command: WinRM\.vbs invocation$|^Scheduled task script command: scregedit\.exe invocation$|^Scheduled task script command: VBScript invocation$|^Scheduled task script command: IIS 6 legacy scripting invocation$' {
            $meta.IsWS2025Change = $true
            $meta.ChangeType = 'Deprecated'
            $meta.ChangeNote = 'Scheduled automation is using deprecated Windows Server tooling that should be migrated before a Windows Server 2025 upgrade.'
            break
        }
        '^NTLMv1 observed$|^LmCompatibilityLevel$' {
            $meta.IsWS2025Change = $true
            $meta.ChangeType = 'Removed'
            $meta.ChangeNote = 'NTLMv1 is removed; only NTLMv2/Kerberos-compatible flows should remain.'
            break
        }
        '^DES tickets observed$' {
            $meta.IsWS2025Change = $true
            $meta.ChangeType = 'Removed'
            $meta.ChangeNote = 'DES cryptography is removed and incompatible.'
            break
        }
        '^Observed legacy usage: TLS 1\.0$|^Observed legacy usage: TLS 1\.1$|^Protocol configuration: TLS 1\.0$|^Protocol configuration: TLS 1\.1$' {
            $meta.IsWS2025Change = $true
            $meta.ChangeType = 'DisabledByDefault'
            $meta.ChangeNote = 'TLS 1.0/1.1 are disabled by default and often break legacy clients.'
            break
        }
        '^SMBv1 .*|^Installed feature: SMB 1\.0$' {
            $meta.IsWS2025Change = $true
            $meta.ChangeType = 'CompatibilityRisk'
            $meta.ChangeNote = 'SMBv1 is legacy/insecure and often fails under modern hardened baselines.'
            break
        }
        '^RC4 tickets observed$' {
            $meta.IsWS2025Change = $true
            $meta.ChangeType = 'Deprecated'
            $meta.ChangeNote = 'RC4 is deprecated and should be migrated to AES.'
            break
        }
        '^Installed feature: WSUS$|^Installed feature: Windows Deployment Services$|^Installed feature: Network Load Balancing$|^Installed feature: AD FS$|^Installed feature: IPAM$' {
            $meta.IsWS2025Change = $true
            $meta.ChangeType = 'Deprecated'
            $meta.ChangeNote = 'Feature is deprecated or has migration caveats for Windows Server 2025 planning.'
            break
        }
        '^Hyper-V with LBFO teams$' {
            $meta.IsWS2025Change = $true
            $meta.ChangeType = 'CompatibilityRisk'
            $meta.ChangeNote = 'Hyper-V with LBFO requires migration (for example to SET) before upgrade.'
            break
        }
    }

    return $meta
}

function Get-UsageState {
    param([Parameter(Mandatory = $true)][psobject]$Item)

    $text = (([string]$Item.Check) + ' ' + ([string]$Item.Detail) + ' ' + ([string]$Item.Evidence)).ToLowerInvariant()

    if ($text -match 'could not |no .* were available|no .* were found|not requested|did not expose protocol|cmdlets are unavailable|evidence gap|not explicitly set') {
        return 'EvidenceGap'
    }

    if ($text -match 'installed, but this run did not find|enabled, but this run did not find|not explicitly disabled|is installed|configuration|posture|feature') {
        return 'ConfigOnly'
    }

    if ($text -match 'active |observed|detected|existing evidence shows|handshake|logon|ticket|client attempt|session|in use|appears active|recent activity|usage volume') {
        return 'ConfirmedUse'
    }

    return 'Unknown'
}

function Get-BreakConfidence {
    param(
        [Parameter(Mandatory = $true)][psobject]$Item,
        [Parameter(Mandatory = $true)][psobject]$Change,
        [Parameter(Mandatory = $true)][string]$UsageState
    )

    if ($Item.Status -eq 'PASS') {
        return 'None'
    }

    if ($UsageState -eq 'EvidenceGap') {
        return 'Insufficient'
    }

    switch ($Change.ChangeType) {
        'Removed' {
            if ($UsageState -eq 'ConfirmedUse') { return 'High' }
            if ($UsageState -eq 'ConfigOnly') { return 'Medium' }
            return 'Low'
        }
        'DisabledByDefault' {
            if ($UsageState -eq 'ConfirmedUse') { return 'Medium' }
            if ($UsageState -eq 'ConfigOnly') { return 'Low' }
            return 'Insufficient'
        }
        'CompatibilityRisk' {
            if ($UsageState -eq 'ConfirmedUse') { return 'High' }
            if ($UsageState -eq 'ConfigOnly') { return 'Low' }
            return 'Insufficient'
        }
        'Deprecated' {
            if ($UsageState -eq 'ConfirmedUse') { return 'Low' }
            if ($UsageState -eq 'ConfigOnly') { return 'Low' }
            return 'Insufficient'
        }
        default {
            if ($Item.Status -eq 'FAIL') { return 'Medium' }
            if ($Item.Status -eq 'WARN') { return 'Low' }
            return 'Insufficient'
        }
    }
}

function Get-ExportRows {
    $rows = foreach ($item in $script:Results) {
        $change = Get-WS2025ChangeMetadata -Item $item
        $usageState = Get-UsageState -Item $item
        $breakConfidence = Get-BreakConfidence -Item $item -Change $change -UsageState $usageState

        [PSCustomObject]@{
            Timestamp = $item.Timestamp
            Computer = $item.Computer
            Category = $item.Category
            Check = $item.Check
            Status = $item.Status
            Detail = $item.Detail
            Evidence = $item.Evidence
            Action = $item.Action
            UsageState = $usageState
            IsWS2025Change = $change.IsWS2025Change
            WS2025ChangeType = $change.ChangeType
            WS2025ChangeNote = $change.ChangeNote
            BreakConfidence = $breakConfidence
        }
    }

    return ,@($rows)
}

function Get-DecisionText {
    param([Parameter(Mandatory = $true)][object[]]$Rows)

    $high = @($Rows | Where-Object { $_.BreakConfidence -eq 'High' -and $_.Status -eq 'FAIL' }).Count
    $medium = @($Rows | Where-Object { $_.BreakConfidence -eq 'Medium' -and $_.Status -eq 'FAIL' }).Count
    $gaps = @($Rows | Where-Object { $_.BreakConfidence -eq 'Insufficient' }).Count

    if ($high -gt 0) {
        return 'NO-GO: confirmed high-confidence break risk exists. Remediate blockers first.'
    }

    if ($medium -gt 0) {
        return 'CONDITIONAL GO: medium-confidence failure risks exist. Proceed only with snapshot rollback and explicit app-owner sign-off.'
    }

    if ($gaps -gt 0) {
        return 'CONDITIONAL GO: no high-confidence blockers found, but telemetry gaps remain. Accept risk or collect more evidence before change window.'
    }

    return 'GO LIKELY: no high- or medium-confidence blockers were identified in this run.'
}

function Write-ChangeRequestReport {
    param([Parameter(Mandatory = $true)][object[]]$Rows)

    $reviewRows = @($Rows | Where-Object { $_.Status -ne 'PASS' -and $_.Category -ne 'Output' })
    $primaryRows = @($reviewRows | Where-Object { $_.IsWS2025Change })
    $confirmedRows = @($primaryRows | Where-Object { $_.UsageState -eq 'ConfirmedUse' })
    $configRows = @($primaryRows | Where-Object { $_.UsageState -eq 'ConfigOnly' })
    $gapRows = @($primaryRows | Where-Object { $_.UsageState -eq 'EvidenceGap' })
    $decision = Get-DecisionText -Rows $primaryRows

    Write-Host "`nChange Request Ready Summary" -ForegroundColor Cyan
    Write-Host ("Server: {0}" -f $script:ComputerName) -ForegroundColor Cyan
    Write-Host ("Scan window: {0} day(s)" -f $DaysBack) -ForegroundColor Cyan
    Write-Host ("Decision: {0}" -f $decision) -ForegroundColor Yellow

    Write-Host "`n2025 Changes With Confirmed Use" -ForegroundColor Red
    if ($confirmedRows.Count -eq 0) {
        Write-Host ' - None found in this run.' -ForegroundColor Green
    } else {
        foreach ($row in $confirmedRows) {
            Write-Host (" - {0} [{1}]" -f $row.Check, $row.BreakConfidence) -ForegroundColor Red
            Write-Host ("   Evidence: {0}" -f $row.Evidence) -ForegroundColor Red
            Write-Host ("   Why 2025: {0}" -f $row.WS2025ChangeNote) -ForegroundColor Red
        }
    }

    Write-Host "`n2025 Changes Configured But Usage Not Proven" -ForegroundColor Yellow
    if ($configRows.Count -eq 0) {
        Write-Host ' - None found in this run.' -ForegroundColor Green
    } else {
        foreach ($row in $configRows) {
            Write-Host (" - {0} [{1}]" -f $row.Check, $row.BreakConfidence) -ForegroundColor Yellow
            Write-Host ("   Evidence: {0}" -f $row.Evidence) -ForegroundColor Yellow
            Write-Host ("   Why 2025: {0}" -f $row.WS2025ChangeNote) -ForegroundColor Yellow
        }
    }

    Write-Host "`n2025 Telemetry Gaps" -ForegroundColor Cyan
    if ($gapRows.Count -eq 0) {
        Write-Host ' - None found in this run.' -ForegroundColor Green
    } else {
        foreach ($row in $gapRows) {
            Write-Host (" - {0}" -f $row.Check) -ForegroundColor Cyan
            Write-Host ("   Evidence: {0}" -f $row.Evidence) -ForegroundColor Cyan
            Write-Host ("   Why 2025: {0}" -f $row.WS2025ChangeNote) -ForegroundColor Cyan
        }
    }

    $md = New-Object 'System.Collections.Generic.List[string]'
    $md.Add('# Windows Server 2025 Readiness Summary')
    $md.Add('')
    $md.Add(("- Server: {0}" -f $script:ComputerName))
    $md.Add(("- Generated: {0}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')))
    $md.Add(("- Evidence Window: {0} day(s)" -f $DaysBack))
    $md.Add(("- Decision: **{0}**" -f $decision))
    $md.Add('')
    $md.Add('## 2025 Changes With Confirmed Use')
    if ($confirmedRows.Count -eq 0) {
        $md.Add('- None found in this run.')
    } else {
        foreach ($row in $confirmedRows) {
            $md.Add(("- {0} | Confidence: **{1}**" -f $row.Check, $row.BreakConfidence))
            $md.Add(("  Evidence: {0}" -f $row.Evidence))
            $md.Add(("  Why 2025: {0}" -f $row.WS2025ChangeNote))
            if (-not [string]::IsNullOrWhiteSpace([string]$row.Action)) {
                $md.Add(("  Action: {0}" -f $row.Action))
            }
        }
    }
    $md.Add('')
    $md.Add('## 2025 Changes Configured But Usage Not Proven')
    if ($configRows.Count -eq 0) {
        $md.Add('- None found in this run.')
    } else {
        foreach ($row in $configRows) {
            $md.Add(("- {0} | Confidence: **{1}**" -f $row.Check, $row.BreakConfidence))
            $md.Add(("  Evidence: {0}" -f $row.Evidence))
            $md.Add(("  Why 2025: {0}" -f $row.WS2025ChangeNote))
            if (-not [string]::IsNullOrWhiteSpace([string]$row.Action)) {
                $md.Add(("  Action: {0}" -f $row.Action))
            }
        }
    }
    $md.Add('')
    $md.Add('## 2025 Telemetry Gaps')
    if ($gapRows.Count -eq 0) {
        $md.Add('- None found in this run.')
    } else {
        foreach ($row in $gapRows) {
            $md.Add(("- {0}" -f $row.Check))
            $md.Add(("  Evidence: {0}" -f $row.Evidence))
            $md.Add(("  Why 2025: {0}" -f $row.WS2025ChangeNote))
            if (-not [string]::IsNullOrWhiteSpace([string]$row.Action)) {
                $md.Add(("  Action: {0}" -f $row.Action))
            }
        }
    }
    $md.Add('')
    $md.Add('## Notes')
    $md.Add('- This assessment is read-only and evidence-based.')
    $md.Add('- Confidence reflects available telemetry in this run, not absolute certainty.')
    $md.Add('- Conditional go/no-go should include snapshot rollback and app-owner validation.')

    try {
        if (-not (Test-Path -LiteralPath $OutputDirectory)) {
            New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
        }
        $md | Set-Content -Path $script:ChangeRequestPath -Encoding UTF8
        Write-Host ("Change-request markdown: {0}" -f $script:ChangeRequestPath) -ForegroundColor Cyan
    } catch {
        Write-Host ("Could not write change-request markdown: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    }
}

function Write-FocusedSummary {
    function Get-SummaryBucket {
        param([psobject]$Item)

        $text = (([string]$Item.Check) + ' ' + ([string]$Item.Detail) + ' ' + ([string]$Item.Evidence)).ToLowerInvariant()

        if ($text -match 'no .* were available|not enabled|not requested|could not |evidence gap|did not expose protocol|cmdlets are unavailable|not explicitly set') {
            return 'Telemetry gaps / cannot prove'
        }

        if ($text -match 'active |observed|detected|existing evidence shows|handshake|logon|ticket|client attempts|sessions|in use|appears active|recent activity|usage volume') {
            return 'Confirmed in use / likely impact'
        }

        if ($text -match 'installed|enabled on this server|not explicitly disabled|is installed|configuration|posture|certificate|compatibilitylevel|feature') {
            return 'Configured or installed, but usage not proven'
        }

        return 'Other review items'
    }

    $buckets = @(
        'Confirmed in use / likely impact',
        'Configured or installed, but usage not proven',
        'Telemetry gaps / cannot prove',
        'Other review items'
    )

    Write-Host "`nWhat To Look At" -ForegroundColor Cyan
    foreach ($bucket in $buckets) {
        $items = @($script:Results | Where-Object { $_.Status -ne 'PASS' -and (Get-SummaryBucket $_) -eq $bucket })
        if ($items.Count -eq 0) {
            continue
        }

        $headerColor = switch ($bucket) {
            'Confirmed in use / likely impact' { 'Red' }
            'Configured or installed, but usage not proven' { 'Yellow' }
            'Telemetry gaps / cannot prove' { 'Cyan' }
            default { 'DarkGray' }
        }

        Write-Host ("`n{0}" -f $bucket) -ForegroundColor $headerColor
        foreach ($item in $items) {
            $lineColor = switch ($item.Status) {
                'FAIL' { 'Red' }
                'WARN' { 'Yellow' }
                'INFO' { 'Cyan' }
                default { 'DarkGray' }
            }

            Write-Host (" - [{0}] {1} ({2})" -f $item.Category, $item.Check, $item.Status) -ForegroundColor $lineColor
            Write-Host ("   {0}" -f $item.Detail) -ForegroundColor $lineColor
            if (-not [string]::IsNullOrWhiteSpace([string]$item.Evidence)) {
                Write-Host ("   Evidence: {0}" -f $item.Evidence) -ForegroundColor $lineColor
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$item.Action)) {
                Write-Host ("   Action: {0}" -f $item.Action) -ForegroundColor $lineColor
            }
        }
    }
}

function Invoke-SoftwareChecks {
    Write-Host "`n[7/8] Legacy software inventory..." -ForegroundColor Magenta

    $uninstallRoots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )

    $apps = New-Object 'System.Collections.Generic.List[object]'
    foreach ($root in $uninstallRoots) {
        try {
            foreach ($item in Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue) {
                try {
                    $app = Get-ItemProperty -LiteralPath $item.PSPath -ErrorAction SilentlyContinue
                    if ($app.DisplayName) {
                        $apps.Add($app)
                    }
                } catch {
                }
            }
        } catch {
        }
    }

    if ($apps.Count -eq 0) {
        Add-Check 'Software' 'Installed software inventory' 'SKIP' 'Could not enumerate installed software from uninstall registry keys.' 'HKLM uninstall registry paths' ''
        return
    }

    $patterns = @(
        @{ Name = 'Exchange 2010'; Regex = 'Exchange Server 2010'; Status = 'FAIL'; Action = 'Exchange 2010 is a major upgrade blocker and must be retired or migrated.' },
        @{ Name = 'SQL Server 2005 or older'; Regex = 'SQL Server 2005|SQL Server 2000'; Status = 'FAIL'; Action = 'SQL Server 2005 and older are not supported on Windows Server 2025 and must be retired or migrated.' },
        @{ Name = 'SQL Server 2008 / 2008 R2'; Regex = 'SQL Server 2008'; Status = 'FAIL'; Action = 'SQL Server 2008/R2 (EOL July 2019) is not supported on Windows Server 2025. Upgrade or migrate this instance.' },
        @{ Name = 'SQL Server 2012'; Regex = 'SQL Server 2012'; Status = 'FAIL'; Action = 'SQL Server 2012 (EOL July 2022) is not supported on Windows Server 2025. Upgrade or migrate this instance.' },
        @{ Name = 'SQL Server 2014'; Regex = 'SQL Server 2014'; Status = 'WARN'; Action = 'SQL Server 2014 (EOL July 2024) has limited WS2025 compatibility. Plan an upgrade before proceeding.' },
        @{ Name = 'SQL Server 2016'; Regex = 'SQL Server 2016'; Status = 'WARN'; Action = 'SQL Server 2016 requires SP3 + CU17 or later for Windows Server 2025 support. Verify the current patch level.' },
        @{ Name = 'Java 6/7'; Regex = '^Java\s+(6|7)\b|J2SE Runtime Environment'; Status = 'WARN'; Action = 'Older Java runtimes often have TLS and cipher issues. Validate every dependent application.' },
        @{ Name = 'Legacy Citrix'; Regex = 'XenApp 6|XenApp 5'; Status = 'WARN'; Action = 'Validate compatibility and published app dependencies.' }
    )

    foreach ($pattern in $patterns) {
        $hits = @($apps | Where-Object { [string]$_.DisplayName -match $pattern.Regex })
        if ($hits.Count -gt 0) {
            Add-Check 'Software' ("Legacy software: {0}" -f $pattern.Name) $pattern.Status ("{0} matching package(s) detected." -f $hits.Count) (($hits | Select-Object -ExpandProperty DisplayName -Unique | Select-Object -First 10) -join '; ') $pattern.Action
        } else {
            Add-Check 'Software' ("Legacy software: {0}" -f $pattern.Name) 'PASS' 'No matching packages were detected.' 'Installed software inventory' ''
        }
    }

    # SQL Server database engine instance deep validation.
    # The display-name patterns above catch SQL components broadly (clients, tools, SSMS).
    # This block reads actual Database Engine instances from the SQL Server registry key,
    # resolves the precise build version, and then checks whether each concerning instance
    # is currently running or has recent Application event log activity — confirming active
    # use before reporting it as a blocker vs. a dormant installation.
    $sqlInstanceRoot = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
    if (Test-Path -LiteralPath $sqlInstanceRoot) {
        $sqlInstanceProp = $null
        try {
            $sqlInstanceProp = Get-ItemProperty -LiteralPath $sqlInstanceRoot -ErrorAction Stop
        } catch { }

        if ($sqlInstanceProp) {
            foreach ($prop in $sqlInstanceProp.PSObject.Properties) {
                if ($prop.Name -like 'PS*') { continue }
                $instanceName = $prop.Name          # e.g. MSSQLSERVER or MYINSTANCE
                $regKey       = [string]$prop.Value # e.g. MSSQL15.MSSQLSERVER

                # Resolve the precise version string from the instance's registry subtree.
                $versionString = Get-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$regKey\MSSQLServer\CurrentVersion" -Name 'CurrentVersion'
                if (-not $versionString) {
                    $versionString = Get-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$regKey\Setup" -Name 'Version'
                }

                $majorVersion = 0
                if ($versionString -match '^(\d+)\.') { $majorVersion = [int]$Matches[1] }

                # Map major version to WS2025 compatibility concern.
                $sqlCheckStatus = $null
                $displayVersion = ''
                $sqlCheckAction = ''
                if ($majorVersion -ge 1 -and $majorVersion -le 9) {
                    $sqlCheckStatus = 'FAIL'
                    $displayVersion = 'SQL Server 2005 or older'
                    $sqlCheckAction = 'SQL Server 2005 and older are not supported on Windows Server 2025. Retire or migrate before upgrading.'
                } elseif ($majorVersion -eq 10) {
                    $sqlCheckStatus = 'FAIL'
                    $displayVersion = 'SQL Server 2008 / 2008 R2'
                    $sqlCheckAction = 'SQL Server 2008/R2 (EOL July 2019) is not supported on Windows Server 2025. Upgrade or migrate this instance.'
                } elseif ($majorVersion -eq 11) {
                    $sqlCheckStatus = 'FAIL'
                    $displayVersion = 'SQL Server 2012'
                    $sqlCheckAction = 'SQL Server 2012 (EOL July 2022) is not supported on Windows Server 2025. Upgrade or migrate this instance.'
                } elseif ($majorVersion -eq 12) {
                    $sqlCheckStatus = 'WARN'
                    $displayVersion = 'SQL Server 2014'
                    $sqlCheckAction = 'SQL Server 2014 (EOL July 2024) has limited WS2025 compatibility. Plan an upgrade before proceeding.'
                } elseif ($majorVersion -eq 13) {
                    $sqlCheckStatus = 'WARN'
                    $displayVersion = 'SQL Server 2016'
                    $sqlCheckAction = 'SQL Server 2016 requires SP3 + CU17 or later for Windows Server 2025 support. Verify the current patch level.'
                }

                # SQL Server 2017 (14), 2019 (15), 2022 (16) are supported on WS2025 — skip.
                if (-not $sqlCheckStatus) { continue }

                # Check whether the SQL Server service is currently running.
                $svcName = if ($instanceName -eq 'MSSQLSERVER') { 'MSSQLSERVER' } else { "MSSQL`$$instanceName" }
                $svcRunning = $false
                $svcStatusText = 'not found'
                try {
                    $svc = Get-Service -Name $svcName -ErrorAction Stop
                    $svcStatusText = [string]$svc.Status
                    $svcRunning    = ($svc.Status -eq 'Running')
                } catch { }

                # Check the Application event log for SQL Server events in the observation window.
                $sqlAppEvents = Get-LogEvents -Filter @{
                    LogName      = 'Application'
                    ProviderName = $svcName
                    StartTime    = $script:WindowStart
                }
                $recentLogActivity = $sqlAppEvents.Count -gt 0

                # Escalate to FAIL when active use is confirmed.
                $finalSqlStatus = $sqlCheckStatus
                if ($svcRunning -or $recentLogActivity) { $finalSqlStatus = 'FAIL' }

                $evidenceParts = New-Object 'System.Collections.Generic.List[string]'
                if ($versionString) { $evidenceParts.Add("Version $versionString") }
                $evidenceParts.Add("Service ${svcName}: $svcStatusText")
                if ($recentLogActivity) {
                    $evidenceParts.Add(("{0} Application log event(s) from this instance in the observation window" -f $sqlAppEvents.Count))
                }

                $inUseNote = if ($svcRunning) {
                    ' Service is currently running — active use confirmed.'
                } elseif ($recentLogActivity) {
                    ' Recent Application log activity confirms this instance was active in the observation window.'
                } else {
                    ' Service is not running and no recent Application log activity was found; instance may be dormant.'
                }

                Add-Check 'Software' ("SQL Server engine instance: $instanceName ($displayVersion)") $finalSqlStatus ("$displayVersion detected on instance $instanceName.$inUseNote") ($evidenceParts -join '; ') $sqlCheckAction
            }
        }
    }
}

function Invoke-OptionalNetworkProbes {
    Write-Host "`n[8/8] Optional outbound TLS probes..." -ForegroundColor Magenta

    if (-not $IncludeNetworkProbes) {
        Add-Check 'Network Probes' 'Outbound TLS 1.2 connectivity' 'SKIP' 'Network probes were not requested.' 'IncludeNetworkProbes switch was not supplied.' ''
        return
    }

    $targets = @(
        'login.microsoftonline.com',
        'management.azure.com',
        'download.windowsupdate.com'
    )

    foreach ($target in $targets) {
        $tcp = $null
        $ssl = $null
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $async = $tcp.BeginConnect($target, 443, $null, $null)
            if (-not $async.AsyncWaitHandle.WaitOne(3000)) {
                throw 'Connection timed out.'
            }
            $tcp.EndConnect($async)

            $callback = [System.Net.Security.RemoteCertificateValidationCallback]{ $true }
            $ssl = New-Object System.Net.Security.SslStream($tcp.GetStream(), $false, $callback)
            $ssl.AuthenticateAsClient($target, $null, [System.Security.Authentication.SslProtocols]::Tls12, $false)

            Add-Check 'Network Probes' ("TLS 1.2 probe: {0}" -f $target) 'PASS' 'TLS 1.2 handshake succeeded.' 'TcpClient + SslStream.AuthenticateAsClient' ''
        } catch {
            Add-Check 'Network Probes' ("TLS 1.2 probe: {0}" -f $target) 'WARN' ("Probe failed: {0}" -f $_.Exception.Message) 'TcpClient + SslStream.AuthenticateAsClient' 'Investigate egress filtering, TLS interception, or local crypto policy if this endpoint is business-critical.'
        } finally {
            if ($ssl) { $ssl.Dispose() }
            if ($tcp) { $tcp.Dispose() }
        }
    }
}

function Write-Summary {
    $pass = @($script:Results | Where-Object Status -eq 'PASS').Count
    $warn = @($script:Results | Where-Object Status -eq 'WARN').Count
    $fail = @($script:Results | Where-Object Status -eq 'FAIL').Count
    $info = @($script:Results | Where-Object Status -eq 'INFO').Count
    $skip = @($script:Results | Where-Object Status -eq 'SKIP').Count

    Write-Host "`nSummary" -ForegroundColor Cyan
    Write-Host ("  PASS: {0}" -f $pass) -ForegroundColor Green
    Write-Host ("  WARN: {0}" -f $warn) -ForegroundColor Yellow
    Write-Host ("  FAIL: {0}" -f $fail) -ForegroundColor Red
    Write-Host ("  INFO: {0}" -f $info) -ForegroundColor Cyan
    Write-Host ("  SKIP: {0}" -f $skip) -ForegroundColor DarkGray
}

function Export-Results {
    $exportRows = Get-ExportRows

    try {
        if (-not (Test-Path -LiteralPath $OutputDirectory)) {
            New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
        }
    } catch {
        Add-Check 'Output' 'Export directory' 'FAIL' 'Could not create or access the export directory.' $OutputDirectory 'Choose a writable export path and rerun.'
        return
    }

    try {
        $exportRows | Export-Csv -Path $script:CsvPath -NoTypeInformation -Encoding UTF8
        Add-Check 'Output' 'CSV export' 'PASS' ("CSV written to {0}" -f $script:CsvPath) $script:CsvPath ''
    } catch {
        Add-Check 'Output' 'CSV export' 'FAIL' 'Failed to write the CSV export.' $_.Exception.Message 'Verify the output path is writable.'
    }

    try {
        $exportRows | ConvertTo-Json -Depth 5 | Set-Content -Path $script:JsonPath -Encoding UTF8
        Add-Check 'Output' 'JSON export' 'PASS' ("JSON written to {0}" -f $script:JsonPath) $script:JsonPath ''
    } catch {
        Add-Check 'Output' 'JSON export' 'FAIL' 'Failed to write the JSON export.' $_.Exception.Message 'Verify the output path is writable.'
    }
}

Write-Banner
Invoke-BaselineChecks
Invoke-TlsChecks
Invoke-AuthenticationChecks
Invoke-SmbChecks
Invoke-RoleAndFeatureChecks
Invoke-LegacyToolingChecks
Invoke-SoftwareChecks
Invoke-OptionalNetworkProbes
Export-Results
Write-ChangeRequestReport -Rows (Get-ExportRows)
Write-Summary
Write-FocusedSummary
