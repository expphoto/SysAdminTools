#Requires -Modules DHCPServer

<#
.SYNOPSIS
    Audits DHCP scopes and validates lease times against DNS scavenging settings.

.DESCRIPTION
    This script queries DHCP server scopes and validates lease duration settings
    to ensure proper alignment with DNS scavenging configuration. Outputs JSON,
    HTML, and CSV reports for easy viewing and analysis.

    Best Practices:
    - DHCP lease duration should be less than DNS scavenging no-refresh + refresh interval
    - Recommended: DHCP lease = 8 days, DNS no-refresh = 7 days, DNS refresh = 7 days

.PARAMETER DHCPServer
    The DHCP server to query (defaults to local computer)

.PARAMETER ScopeId
    Specific DHCP scope to audit (e.g., "192.168.1.0"). If not specified, audits all scopes.

.PARAMETER DNSServer
    DNS server to query for scavenging settings (defaults to same as DHCP server)

.PARAMETER OutputPath
    Base path for output files (default: C:\Reports\DHCP)

.PARAMETER IncludeInactive
    Include inactive DHCP scopes in the audit

.PARAMETER SkipDNSCheck
    Skip DNS scavenging alignment check (useful if DNS module not available)

.EXAMPLE
    .\Invoke-DHCPLeaseValidation.ps1 -DHCPServer "SERVER01"

.EXAMPLE
    .\Invoke-DHCPLeaseValidation.ps1 -DHCPServer "SERVER01" -ScopeId "192.168.1.0" -OutputPath "C:\Temp"

.EXAMPLE
    .\Invoke-DHCPLeaseValidation.ps1 -DHCPServer "SERVER01" -IncludeInactive

.EXAMPLE
    .\Invoke-DHCPLeaseValidation.ps1 -DHCPServer "SERVER01" -SkipDNSCheck

.NOTES
    Author: SysAdmin Tools
    Requires: DHCP Server PowerShell module and Administrator privileges
    Optional: DNS Server PowerShell module (for scavenging alignment check)
#>

param(
    [string]$DHCPServer = $env:COMPUTERNAME,

    [string]$ScopeId,

    [string]$DNSServer,

    [string]$OutputPath = "C:\Reports\DHCP",

    [switch]$IncludeInactive,

    [switch]$SkipDNSCheck
)

$ErrorActionPreference = "Stop"

$dnsModuleAvailable = $false
if (-not $SkipDNSCheck) {
    $dnsModuleAvailable = $null -ne (Get-Module -ListAvailable -Name DnsServer -ErrorAction SilentlyContinue)
    if (-not $dnsModuleAvailable) {
        Write-Warning "DnsServer module not available - DNS scavenging alignment check will be skipped"
        Write-Warning "Install with: Install-WindowsFeature RSAT-DNS-Server-Tools"
        $SkipDNSCheck = $true
    }
}

function Get-DHCPScopesWithLeaseInfo {
    param(
        [string]$Server,
        [string]$Scope,
        [bool]$IncludeInactive
    )

    Write-Output "Querying DHCP scopes from server: $Server"

    try {
        $scopes = if ($Scope) {
            Get-DhcpServerv4Scope -ComputerName $Server -ScopeId $Scope -ErrorAction Stop
        } else {
            $allScopes = Get-DhcpServerv4Scope -ComputerName $Server -ErrorAction Stop
            if ($IncludeInactive) {
                $allScopes
            } else {
                $allScopes | Where-Object { $_.State -eq "Active" }
            }
        }
    } catch {
        Write-Error "Failed to query DHCP scopes from $Server"
        Write-Error "Error: $($_.Exception.Message)"
        Write-Error ""
        Write-Error "Troubleshooting steps:"
        Write-Error "  1. Verify the DHCP Server name is correct: $Server"
        Write-Error "  2. Ensure you have permissions to query DHCP (DHCP Administrators group)"
        Write-Error "  3. Check if the DHCP Server service is running on $Server"
        Write-Error "  4. Test connectivity: Test-NetConnection -ComputerName $Server -Port 67"
        Write-Error "  5. Try running PowerShell as Administrator"
        throw
    }

    if (-not $scopes) {
        Write-Warning "No DHCP scopes found matching criteria"
        return @()
    }

    Write-Output "Found $($scopes.Count) scope(s) to audit"

    $scopeDetails = @()

    foreach ($s in $scopes) {
        Write-Output "Processing scope: $($s.ScopeId) ($($s.Name))"

        try {
            $leaseInfo = Get-DhcpServerv4Lease -ComputerName $Server -ScopeId $s.ScopeId -AllLeases -ErrorAction SilentlyContinue
            $scopeStats = if ($leaseInfo) {
                @{
                    TotalLeases = $leaseInfo.Count
                    ActiveLeases = ($leaseInfo | Where-Object { $_.AddressState -eq "Active" }).Count
                    InactiveLeases = ($leaseInfo | Where-Object { $_.AddressState -eq "Inactive" }).Count
                }
            } else {
                @{
                    TotalLeases = 0
                    ActiveLeases = 0
                    InactiveLeases = 0
                }
            }

            $leaseDurationDays = [Math]::Round($s.LeaseDuration.TotalDays, 2)
            $leaseDurationHours = [Math]::Round($s.LeaseDuration.TotalHours, 2)

            $recommendation = switch ($leaseDurationDays) {
                { $_ -lt 1 } { "Too short - may cause frequent DHCP renewals and excessive DNS updates" }
                { $_ -lt 4 } { "Short - OK for high churn environments (wireless, hot-desk)" }
                { $_ -lt 8 } { "Standard - matches Microsoft best practice" }
                { $_ -lt 15 } { "Long - ensure DNS scavenging intervals are longer than lease duration" }
                default { "Too long - stale records may accumulate in DNS" }
            }

            $scopeInfo = [PSCustomObject]@{
                ScopeId = $s.ScopeId
                Name = $s.Name
                SubnetMask = $s.SubnetMask
                StartRange = $s.StartRange
                EndRange = $s.EndRange
                State = $s.State
                LeaseDurationDays = $leaseDurationDays
                LeaseDurationHours = $leaseDurationHours
                LeaseDuration = $s.LeaseDuration
                Type = $s.Type
                TotalLeases = $scopeStats.TotalLeases
                ActiveLeases = $scopeStats.ActiveLeases
                InactiveLeases = $scopeStats.InactiveLeases
                UsedPercentage = if ($s.Type -eq "DHCP") {
                    $totalIPs = [System.Net.IPAddress]::Parse($s.EndRange).Address - [System.Net.IPAddress]::Parse($s.StartRange).Address + 1
                    [Math]::Round(($scopeStats.ActiveLeases / $totalIPs) * 100, 2)
                } else { $null }
                Recommendation = $recommendation
            }

            $scopeDetails += $scopeInfo
        } catch {
            Write-Warning "Failed to process scope $($s.ScopeId): $_"
            continue
        }
    }

    return $scopeDetails
}

function Get-DNSScavengingSettings {
    param([string]$Server)

    Write-Output "Querying DNS scavenging settings from server: $Server"

    try {
        $zones = Get-DnsServerZone -ComputerName $Server -ErrorAction Stop | Where-Object {
            $_.IsAutoCreated -eq $false -and
            $_.ZoneType -eq "Primary" -and
            -not $_.IsReverseLookupZone
        }

        $scavengingSettings = @()

        foreach ($zone in $zones) {
            $scavengeConfig = $zone | Get-DnsServerZoneAging -ErrorAction SilentlyContinue

            if ($scavengeConfig -and $scavengeConfig.AgingEnabled) {
                $noRefreshDays = [Math]::Round($scavengeConfig.NoRefreshInterval.TotalDays, 2)
                $refreshDays = [Math]::Round($scavengeConfig.RefreshInterval.TotalDays, 2)
                $totalScavengeDays = $noRefreshDays + $refreshDays

                $scavengingSettings += [PSCustomObject]@{
                    ZoneName = $zone.ZoneName
                    ScavengingEnabled = $true
                    NoRefreshIntervalDays = $noRefreshDays
                    RefreshIntervalDays = $refreshDays
                    TotalScavengeDays = $totalScavengeDays
                }
            } else {
                $scavengingSettings += [PSCustomObject]@{
                    ZoneName = $zone.ZoneName
                    ScavengingEnabled = $false
                    NoRefreshIntervalDays = $null
                    RefreshIntervalDays = $null
                    TotalScavengeDays = $null
                }
            }
        }

        $serverScavenge = Get-DnsServerScavenging -ComputerName $Server -ErrorAction SilentlyContinue
        $serverLevelEnabled = if ($serverScavenge) {
            $serverScavenge.ScavengingState -eq "Enabled"
        } else { $false }

        return @{
            ServerLevelEnabled = $serverLevelEnabled
            Zones = $scavengingSettings
        }
    } catch {
        Write-Warning "Failed to query DNS scavenging settings: $_"
        return $null
    }
}

function Test-DHCPDNSAlignment {
    param(
        [array]$DHCPScopes,
        [object]$DNSSettings
    )

    if (-not $DNSSettings) {
        Write-Output "Skipping DHCP-DNS alignment check - DNS settings not available"
        return @()
    }

    Write-Output "Checking DHCP-DNS scavenging alignment..."

    $alignmentResults = @()

    foreach ($scope in $DHCPScopes) {
        $leaseDays = $scope.LeaseDurationDays
        $alignmentIssues = @()

        foreach ($zone in $DNSSettings.Zones) {
            if ($zone.ScavengingEnabled) {
                $totalScavengeDays = $zone.TotalScavengeDays

                if ($leaseDays -ge $totalScavengeDays) {
                    $alignmentIssues += "Zone '$($zone.ZoneName)': Lease ($($leaseDays)d) >= Scavenge period ($($totalScavengeDays)d) - records may be deleted before DHCP lease expires"
                } elseif ($totalScavengeDays - $leaseDays -lt 2) {
                    $alignmentIssues += "Zone '$($zone.ZoneName)': Scavenge period ($($totalScavengeDays)d) too close to lease ($($leaseDays)d) - recommend at least 2 day buffer"
                }
            } else {
                $alignmentIssues += "Zone '$($zone.ZoneName)': Scavenging not enabled"
            }
        }

        $alignmentStatus = if ($alignmentIssues.Count -eq 0) {
            "Valid"
        } elseif ($alignmentIssues -match "may be deleted") {
            "Critical"
        } else {
            "Warning"
        }

        $alignmentResults += [PSCustomObject]@{
            ScopeId = $scope.ScopeId
            ScopeName = $scope.Name
            LeaseDurationDays = $leaseDays
            AlignmentStatus = $alignmentStatus
            Issues = $alignmentIssues -join "; "
        }
    }

    return $alignmentResults
}

function Export-ReportJSON {
    param(
        [array]$Scopes,
        [object]$DNSSettings,
        [array]$Alignment,
        [string]$Path
    )

    $outputDir = Split-Path -Parent $Path
    if (!(Test-Path $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }

    $report = [PSCustomObject]@{
        GeneratedDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        DHCPServer = $DHCPServer
        DNSServer = if ($DNSServer) { $DNSServer } else { $DHCPServer }
        TotalScopes = $Scopes.Count
        ActiveScopes = ($Scopes | Where-Object { $_.State -eq "Active" }).Count
        InactiveScopes = ($Scopes | Where-Object { $_.State -eq "Inactive" }).Count
        Scopes = $Scopes
        DNSScavengingSettings = $DNSSettings
        DHCPDNSAlignment = $Alignment
        AlignmentSummary = if ($Alignment) {
            @{
                Valid = ($Alignment | Where-Object { $_.AlignmentStatus -eq "Valid" }).Count
                Warning = ($Alignment | Where-Object { $_.AlignmentStatus -eq "Warning" }).Count
                Critical = ($Alignment | Where-Object { $_.AlignmentStatus -eq "Critical" }).Count
            }
        } else { $null }
    }

    $report | ConvertTo-Json -Depth 10 | Set-Content -Path $Path
    Write-Output "JSON report saved to: $Path"
}

function Export-ReportHTML {
    param(
        [array]$Scopes,
        [object]$DNSSettings,
        [array]$Alignment,
        [string]$Path
    )

    $outputDir = Split-Path -Parent $Path
    if (!(Test-Path $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    $scopesTable = $Scopes | ForEach-Object {
        $statusClass = switch ($_.State) {
            "Active" { "status-active" }
            "Inactive" { "status-inactive" }
            default { "" }
        }
        $leaseClass = if ($_.LeaseDurationDays -ge 15) { "lease-warning" }
        elseif ($_.LeaseDurationDays -lt 1) { "lease-warning" }
        else { "" }
        $usedClass = if ($_.UsedPercentage -ge 90) { "usage-critical" }
        elseif ($_.UsedPercentage -ge 75) { "usage-warning" }
        else { "" }

        @"
        <tr>
            <td>$($_.ScopeId)</td>
            <td>$($_.Name)</td>
            <td>$($_.SubnetMask)</td>
            <td>$($_.StartRange)</td>
            <td>$($_.EndRange)</td>
            <td class="$statusClass">$($_.State)</td>
            <td class="$leaseClass">$($_.LeaseDurationDays) days ($($_.LeaseDurationHours) hrs)</td>
            <td>$($_.Type)</td>
            <td>$($_.TotalLeases)</td>
            <td>$($_.ActiveLeases)</td>
            <td class="$usedClass">$(if($_.UsedPercentage){ "$($_.UsedPercentage)%"}else{"N/A"})</td>
        </tr>
"@
    }

    $alignmentTable = if ($Alignment) {
        $rows = $Alignment | ForEach-Object {
            $statusClass = switch ($_.AlignmentStatus) {
                "Valid" { "status-valid" }
                "Warning" { "status-warning" }
                "Critical" { "status-critical" }
                default { "" }
            }
            @"
            <tr>
                <td>$($_.ScopeId)</td>
                <td>$($_.ScopeName)</td>
                <td>$($_.LeaseDurationDays) days</td>
                <td class="$statusClass">$($_.AlignmentStatus)</td>
                <td>$($_.Issues)</td>
            </tr>
"@
        }
        @"
        <h2>DHCP-DNS Scavenging Alignment</h2>
        <table>
            <thead>
                <tr>
                    <th>Scope ID</th>
                    <th>Scope Name</th>
                    <th>Lease Duration</th>
                    <th>Status</th>
                    <th>Issues</th>
                </tr>
            </thead>
            <tbody>$($rows)</tbody>
        </table>
"@
    } else { "" }

    $dnsScavengeSection = if ($DNSSettings) {
        $dnsRows = $DNSSettings.Zones | ForEach-Object {
            $scavengeStatus = if ($_.ScavengingEnabled) { "Enabled ($($_.TotalScavengeDays) days)" } else { "Disabled" }
            @"
            <tr>
                <td>$($_.ZoneName)</td>
                <td>$scavengeStatus</td>
                <td>$(if($_.ScavengingEnabled){ "$($_.NoRefreshIntervalDays) + $($_.RefreshIntervalDays) = $($_.TotalScavengeDays) days" }else{"N/A"})</td>
            </tr>
"@
        }
        @"
        <h2>DNS Scavenging Settings</h2>
        <p><strong>Server-level scavenging:</strong> $(if($DNSSettings.ServerLevelEnabled){"Enabled"}else{"Disabled"})</p>
        <table>
            <thead>
                <tr>
                    <th>Zone Name</th>
                    <th>Scavenging Status</th>
                    <th>Configuration</th>
                </tr>
            </thead>
            <tbody>$($dnsRows)</tbody>
        </table>
"@
    } else { "" }

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>DHCP Lease Validation Report - $(Get-Date -Format 'yyyy-MM-dd')</title>
    <style>
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            line-height: 1.6;
            margin: 0;
            padding: 20px;
            background-color: #f5f5f5;
        }
        .container {
            max-width: 1400px;
            margin: 0 auto;
            background: white;
            padding: 30px;
            border-radius: 8px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
        }
        h1 {
            color: #2c3e50;
            border-bottom: 3px solid #3498db;
            padding-bottom: 10px;
        }
        h2 {
            color: #34495e;
            margin-top: 30px;
            border-bottom: 2px solid #bdc3c7;
            padding-bottom: 5px;
        }
        .summary {
            background: #ecf0f1;
            padding: 15px;
            border-radius: 5px;
            margin: 20px 0;
        }
        .summary p {
            margin: 5px 0;
        }
        table {
            width: 100%;
            border-collapse: collapse;
            margin: 20px 0;
            font-size: 12px;
        }
        th, td {
            padding: 12px;
            text-align: left;
            border-bottom: 1px solid #ddd;
        }
        th {
            background-color: #3498db;
            color: white;
            font-weight: bold;
        }
        tr:nth-child(even) {
            background-color: #f8f9fa;
        }
        tr:hover {
            background-color: #e9ecef;
        }
        .status-active { color: #27ae60; font-weight: bold; }
        .status-inactive { color: #e74c3c; font-weight: bold; }
        .status-valid { color: #27ae60; font-weight: bold; }
        .status-warning { color: #f39c12; font-weight: bold; }
        .status-critical { color: #e74c3c; font-weight: bold; }
        .lease-warning { color: #e74c3c; font-weight: bold; }
        .usage-critical { color: #e74c3c; font-weight: bold; }
        .usage-warning { color: #f39c12; font-weight: bold; }
        .recommendation {
            background: #d5f4e6;
            padding: 10px;
            border-left: 4px solid #27ae60;
            margin: 10px 0;
        }
        .issue {
            background: #fdebd0;
            padding: 10px;
            border-left: 4px solid #f39c12;
            margin: 10px 0;
        }
        .footer {
            margin-top: 30px;
            padding-top: 20px;
            border-top: 1px solid #ddd;
            text-align: center;
            color: #7f8c8d;
            font-size: 12px;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>DHCP Lease Validation Report</h1>
        
        <div class="summary">
            <p><strong>Generated:</strong> $timestamp</p>
            <p><strong>DHCP Server:</strong> $DHCPServer</p>
            <p><strong>DNS Server:</strong> $(if($DNSServer){$DNSServer}else{$DHCPServer})</p>
            <p><strong>Total Scopes:</strong> $($Scopes.Count)</p>
            <p><strong>Active Scopes:</strong> $(($Scopes | Where-Object { $_.State -eq "Active" }).Count)</p>
            <p><strong>Inactive Scopes:</strong> $(($Scopes | Where-Object { $_.State -eq "Inactive" }).Count)</p>
        </div>

        $dnsScavengeSection

        <h2>DHCP Scopes</h2>
        <table>
            <thead>
                <tr>
                    <th>Scope ID</th>
                    <th>Name</th>
                    <th>Subnet Mask</th>
                    <th>Start Range</th>
                    <th>End Range</th>
                    <th>State</th>
                    <th>Lease Duration</th>
                    <th>Type</th>
                    <th>Total Leases</th>
                    <th>Active Leases</th>
                    <th>Used %</th>
                </tr>
            </thead>
            <tbody>$($scopesTable)</tbody>
        </table>

        $alignmentTable

        <h2>Recommendations</h2>
        $(if($Alignment -and ($Alignment | Where-Object { $_.AlignmentStatus -ne "Valid" }).Count -gt 0){
            $Alignment | Where-Object { $_.AlignmentStatus -ne "Valid" } | ForEach-Object {
                "<div class='issue'><strong>$($_.ScopeId) ($($_.AlignmentStatus)):</strong> $($_.Issues)</div>"
            }
        }else{
            "<div class='recommendation'>All DHCP scopes are properly aligned with DNS scavenging settings.</div>"
        })

        <div class="footer">
            <p>Generated by SysAdmin Tools - DHCP Lease Validation Script</p>
        </div>
    </div>
</body>
</html>
"@

    $html | Set-Content -Path $Path -Encoding UTF8
    Write-Output "HTML report saved to: $Path"
}

function Export-ReportCSV {
    param(
        [array]$Scopes,
        [array]$Alignment,
        [string]$Path
    )

    $outputDir = Split-Path -Parent $Path
    if (!(Test-Path $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }

    $Scopes | Export-Csv -Path $Path -NoTypeInformation
    Write-Output "CSV report saved to: $Path"

    if ($Alignment) {
        $alignmentPath = $Path -replace "\.csv$", "-Alignment.csv"
        $Alignment | Export-Csv -Path $alignmentPath -NoTypeInformation
        Write-Output "Alignment CSV saved to: $alignmentPath"
    }
}

try {
    Write-Output "DHCP Lease Validation Script"
    Write-Output "=" * 80
    Write-Output ""

    $dnsServer = if ($DNSServer) { $DNSServer } else { $DHCPServer }

    Write-Output "DHCP Server: $DHCPServer"
    Write-Output "DNS Server: $dnsServer"
    Write-Output ""

    $scopes = Get-DHCPScopesWithLeaseInfo -Server $DHCPServer -Scope $ScopeId -IncludeInactive $IncludeInactive

    if ($scopes.Count -eq 0) {
        Write-Output "No DHCP scopes found to audit. Exiting."
        exit
    }

    $dnsSettings = if ($SkipDNSCheck) {
        Write-Output "Skipping DNS scavenging alignment check"
        $null
    } else {
        Get-DNSScavengingSettings -Server $dnsServer
    }

    $alignment = if ($dnsSettings) {
        Test-DHCPDNSAlignment -DHCPScopes $scopes -DNSSettings $dnsSettings
    } else {
        @()
    }

    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $jsonPath = Join-Path $OutputPath "DHCPLeaseValidation-$timestamp.json"
    $htmlPath = Join-Path $OutputPath "DHCPLeaseValidation-$timestamp.html"
    $csvPath = Join-Path $OutputPath "DHCPLeaseValidation-$timestamp.csv"

    Export-ReportJSON -Scopes $scopes -DNSSettings $dnsSettings -Alignment $alignment -Path $jsonPath
    Export-ReportHTML -Scopes $scopes -DNSSettings $dnsSettings -Alignment $alignment -Path $htmlPath
    Export-ReportCSV -Scopes $scopes -Alignment $alignment -Path $csvPath

    Write-Output ""
    Write-Output "Summary:"
    Write-Output "  Total scopes audited: $($scopes.Count)"
    Write-Output "  Active scopes: $(($scopes | Where-Object { $_.State -eq "Active" }).Count)"
    Write-Output "  Inactive scopes: $(($scopes | Where-Object { $_.State -eq "Inactive" }).Count)"

    if ($alignment) {
        $validCount = ($alignment | Where-Object { $_.AlignmentStatus -eq "Valid" }).Count
        $warningCount = ($alignment | Where-Object { $_.AlignmentStatus -eq "Warning" }).Count
        $criticalCount = ($alignment | Where-Object { $_.AlignmentStatus -eq "Critical" }).Count

        Write-Output ""
        Write-Output "DHCP-DNS Alignment:"
        Write-Output "  Valid: $validCount"
        Write-Output "  Warning: $warningCount"
        Write-Output "  Critical: $criticalCount"
    }

    Write-Output ""
    Write-Output "DHCP Lease Validation complete!"

} catch {
    Write-Error "DHCP Lease Validation failed: $_"
    Write-Error $_.ScriptStackTrace
    exit 1
}
