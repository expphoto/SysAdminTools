#Requires -Modules DnsServer

<#
.SYNOPSIS
    Audits DNS records on a Domain Controller and reports records based on age thresholds.

.DESCRIPTION
    This script queries DNS records from a Domain Controller and generates reports for records
    older than 90, 180, and 365 days. Outputs both JSON and HTML formats for easy viewing
    and further processing.

.PARAMETER DNSServer
    The DNS server to query (defaults to local computer)

.PARAMETER ZoneName
    The DNS zone to audit (e.g., "contoso.com"). If not specified, audits all zones.

.PARAMETER OutputPath
    Base path for output files (default: C:\Reports\DNS)

.PARAMETER IncludeStaticRecords
    Include static DNS records in the audit (default: only scavenging-enabled records)

.PARAMETER ExcludeReverseLookup
    Exclude reverse lookup zones from the audit

.EXAMPLE
    .\Invoke-DNSAgeAudit.ps1 -DNSServer "DC01" -ZoneName "contoso.com"

.EXAMPLE
    .\Invoke-DNSAgeAudit.ps1 -OutputPath "C:\Temp\DNSReports" -IncludeStaticRecords

.NOTES
    Author: SysAdmin Tools
    Requires: DNS Server PowerShell module and Administrator privileges
#>

param(
    [string]$DNSServer = $env:COMPUTERNAME,

    [string]$ZoneName,

    [string]$OutputPath = "C:\Reports\DNS",

    [switch]$IncludeStaticRecords,

    [switch]$ExcludeReverseLookup
)

$ErrorActionPreference = "Stop"

function Get-DNSRecordsWithAge {
    param(
        [string]$Server,
        [string]$Zone,
        [bool]$IncludeStatic,
        [bool]$ExcludeReverse
    )

    Write-Output "Querying DNS zones from server: $Server"

    try {
        $zones = if ($Zone) {
            Get-DnsServerZone -ComputerName $Server -Name $Zone -ErrorAction Stop
        } else {
            Get-DnsServerZone -ComputerName $Server -ErrorAction Stop | Where-Object {
                $_.IsAutoCreated -eq $false -and
                $_.ZoneType -eq "Primary" -and
                (-not $ExcludeReverse -or -not $_.IsReverseLookupZone)
            }
        }
    } catch {
        Write-Error "Failed to query DNS zones from $Server"
        Write-Error "Error: $($_.Exception.Message)"
        Write-Error ""
        Write-Error "Troubleshooting steps:"
        Write-Error "  1. Verify the DNS Server name is correct: $Server"
        Write-Error "  2. Ensure you have permissions to query DNS (DNSAdmins group or equivalent)"
        Write-Error "  3. Check if the DNS Server service is running on $Server"
        Write-Error "  4. Try running PowerShell as Administrator"
        Write-Error "  5. Test connectivity: Test-NetConnection -ComputerName $Server -Port 53"
        Write-Error "  6. If querying remote server, ensure WinRM/PowerShell Remoting is enabled"
        throw
    }

    if (-not $zones) {
        Write-Warning "No zones found matching criteria"
        return @()
    }

    Write-Output "Found $($zones.Count) zone(s) to audit"

    $allRecords = @()
    $currentDate = Get-Date

    foreach ($z in $zones) {
        Write-Output "Processing zone: $($z.ZoneName)"

        try {
            $records = Get-DnsServerResourceRecord -ComputerName $Server -ZoneName $z.ZoneName -ErrorAction Stop

            foreach ($record in $records) {
                $timestamp = $null
                $age = $null
                $isStale = $false

                if ($record.TimeStamp) {
                    $timestamp = $record.TimeStamp
                    $age = ($currentDate - $timestamp).Days
                    $isStale = $true
                } elseif ($IncludeStatic) {
                    $timestamp = $null
                    $age = $null
                    $isStale = $false
                } else {
                    continue
                }

                $recordType = $record.RecordType
                $recordData = switch ($recordType) {
                    "A"     { $record.RecordData.IPv4Address.ToString() }
                    "AAAA"  { $record.RecordData.IPv6Address.ToString() }
                    "CNAME" { $record.RecordData.HostNameAlias }
                    "MX"    { "$($record.RecordData.MailExchange) (Priority: $($record.RecordData.Preference))" }
                    "PTR"   { $record.RecordData.PtrDomainName }
                    "TXT"   { $record.RecordData.DescriptiveText -join "; " }
                    "SRV"   { "$($record.RecordData.DomainName):$($record.RecordData.Port) (Priority: $($record.RecordData.Priority))" }
                    default { $record.RecordData.ToString() }
                }

                $ageCategory = if ($age -eq $null) {
                    "Static"
                } elseif ($age -ge 365) {
                    "Over365Days"
                } elseif ($age -ge 180) {
                    "Over180Days"
                } elseif ($age -ge 90) {
                    "Over90Days"
                } else {
                    "Under90Days"
                }

                $allRecords += [PSCustomObject]@{
                    ZoneName = $z.ZoneName
                    HostName = $record.HostName
                    RecordType = $recordType
                    RecordData = $recordData
                    TimeStamp = $timestamp
                    Age = $age
                    AgeCategory = $ageCategory
                    IsStale = $isStale
                    TimeToLive = $record.TimeToLive
                    DistinguishedName = $record.DistinguishedName
                }
            }

            Write-Output "  Processed $($records.Count) records in $($z.ZoneName)"

        } catch {
            Write-Warning "Failed to process zone $($z.ZoneName): $_"
        }
    }

    Write-Output "Total records collected: $($allRecords.Count)"

    return $allRecords
}

function Export-DNSReportJSON {
    param(
        [array]$Records,
        [string]$OutputPath
    )

    $outputDir = Split-Path -Parent $OutputPath
    if (!(Test-Path $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }

    $exportData = @{
        GeneratedDate = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        DNSServer = $DNSServer
        TotalRecords = $Records.Count
        Records = $Records
        Summary = @{
            Over365Days = ($Records | Where-Object { $_.AgeCategory -eq "Over365Days" }).Count
            Over180Days = ($Records | Where-Object { $_.AgeCategory -eq "Over180Days" }).Count
            Over90Days = ($Records | Where-Object { $_.AgeCategory -eq "Over90Days" }).Count
            Under90Days = ($Records | Where-Object { $_.AgeCategory -eq "Under90Days" }).Count
            Static = ($Records | Where-Object { $_.AgeCategory -eq "Static" }).Count
        }
    }

    $exportData | ConvertTo-Json -Depth 10 | Out-File -FilePath $OutputPath -Encoding UTF8
    Write-Output "JSON report exported to: $OutputPath"
}

function Export-DNSReportHTML {
    param(
        [array]$Records,
        [string]$OutputPath
    )

    $outputDir = Split-Path -Parent $OutputPath
    if (!(Test-Path $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }

    $over90 = $Records | Where-Object { $_.AgeCategory -eq "Over90Days" }
    $over180 = $Records | Where-Object { $_.AgeCategory -eq "Over180Days" }
    $over365 = $Records | Where-Object { $_.AgeCategory -eq "Over365Days" }
    $static = $Records | Where-Object { $_.AgeCategory -eq "Static" }

    $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>DNS Age Audit Report - $(Get-Date -Format 'yyyy-MM-dd')</title>
    <style>
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            margin: 20px;
            background-color: #f5f5f5;
        }
        h1 {
            color: #333;
            border-bottom: 3px solid #0078d4;
            padding-bottom: 10px;
        }
        h2 {
            color: #555;
            margin-top: 30px;
            border-bottom: 2px solid #ccc;
            padding-bottom: 5px;
        }
        .summary {
            background-color: white;
            padding: 20px;
            border-radius: 5px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
            margin-bottom: 20px;
        }
        .summary-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 15px;
            margin-top: 15px;
        }
        .summary-item {
            background-color: #f9f9f9;
            padding: 15px;
            border-left: 4px solid #0078d4;
            border-radius: 3px;
        }
        .summary-item.critical {
            border-left-color: #d13438;
        }
        .summary-item.warning {
            border-left-color: #ff8c00;
        }
        .summary-item.info {
            border-left-color: #ffd700;
        }
        .summary-item h3 {
            margin: 0 0 5px 0;
            font-size: 14px;
            color: #666;
        }
        .summary-item .count {
            font-size: 32px;
            font-weight: bold;
            color: #333;
        }
        table {
            width: 100%;
            border-collapse: collapse;
            background-color: white;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
            margin-bottom: 30px;
        }
        th {
            background-color: #0078d4;
            color: white;
            padding: 12px;
            text-align: left;
            font-weight: 600;
            position: sticky;
            top: 0;
        }
        td {
            padding: 10px 12px;
            border-bottom: 1px solid #e0e0e0;
        }
        tr:hover {
            background-color: #f5f5f5;
        }
        .age-critical {
            color: #d13438;
            font-weight: bold;
        }
        .age-warning {
            color: #ff8c00;
            font-weight: bold;
        }
        .age-info {
            color: #ffd700;
            font-weight: bold;
        }
        .record-type {
            background-color: #e8e8e8;
            padding: 3px 8px;
            border-radius: 3px;
            font-size: 12px;
            font-weight: 600;
        }
        .metadata {
            color: #666;
            font-size: 12px;
            margin-bottom: 20px;
        }
        .section-count {
            color: #0078d4;
            font-weight: 600;
        }
    </style>
</head>
<body>
    <h1>DNS Age Audit Report</h1>
    <div class="metadata">
        <strong>Generated:</strong> $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') |
        <strong>DNS Server:</strong> $DNSServer |
        <strong>Total Records:</strong> $($Records.Count)
    </div>

    <div class="summary">
        <h2>Summary</h2>
        <div class="summary-grid">
            <div class="summary-item critical">
                <h3>Over 365 Days</h3>
                <div class="count">$($over365.Count)</div>
            </div>
            <div class="summary-item warning">
                <h3>Over 180 Days</h3>
                <div class="count">$($over180.Count)</div>
            </div>
            <div class="summary-item info">
                <h3>Over 90 Days</h3>
                <div class="count">$($over90.Count)</div>
            </div>
            <div class="summary-item">
                <h3>Static Records</h3>
                <div class="count">$($static.Count)</div>
            </div>
        </div>
    </div>
"@

    if ($over365.Count -gt 0) {
        $html += @"
    <h2>Records Over 365 Days Old <span class="section-count">($($over365.Count))</span></h2>
    <table>
        <thead>
            <tr>
                <th>Zone</th>
                <th>Host Name</th>
                <th>Type</th>
                <th>Record Data</th>
                <th>Timestamp</th>
                <th>Age (Days)</th>
                <th>TTL</th>
            </tr>
        </thead>
        <tbody>
"@
        foreach ($record in ($over365 | Sort-Object Age -Descending)) {
            $html += @"
            <tr>
                <td>$($record.ZoneName)</td>
                <td>$($record.HostName)</td>
                <td><span class="record-type">$($record.RecordType)</span></td>
                <td>$($record.RecordData)</td>
                <td>$($record.TimeStamp)</td>
                <td class="age-critical">$($record.Age)</td>
                <td>$($record.TimeToLive)</td>
            </tr>
"@
        }
        $html += @"
        </tbody>
    </table>
"@
    }

    if ($over180.Count -gt 0) {
        $html += @"
    <h2>Records Over 180 Days Old <span class="section-count">($($over180.Count))</span></h2>
    <table>
        <thead>
            <tr>
                <th>Zone</th>
                <th>Host Name</th>
                <th>Type</th>
                <th>Record Data</th>
                <th>Timestamp</th>
                <th>Age (Days)</th>
                <th>TTL</th>
            </tr>
        </thead>
        <tbody>
"@
        foreach ($record in ($over180 | Sort-Object Age -Descending)) {
            $html += @"
            <tr>
                <td>$($record.ZoneName)</td>
                <td>$($record.HostName)</td>
                <td><span class="record-type">$($record.RecordType)</span></td>
                <td>$($record.RecordData)</td>
                <td>$($record.TimeStamp)</td>
                <td class="age-warning">$($record.Age)</td>
                <td>$($record.TimeToLive)</td>
            </tr>
"@
        }
        $html += @"
        </tbody>
    </table>
"@
    }

    if ($over90.Count -gt 0) {
        $html += @"
    <h2>Records Over 90 Days Old <span class="section-count">($($over90.Count))</span></h2>
    <table>
        <thead>
            <tr>
                <th>Zone</th>
                <th>Host Name</th>
                <th>Type</th>
                <th>Record Data</th>
                <th>Timestamp</th>
                <th>Age (Days)</th>
                <th>TTL</th>
            </tr>
        </thead>
        <tbody>
"@
        foreach ($record in ($over90 | Sort-Object Age -Descending)) {
            $html += @"
            <tr>
                <td>$($record.ZoneName)</td>
                <td>$($record.HostName)</td>
                <td><span class="record-type">$($record.RecordType)</span></td>
                <td>$($record.RecordData)</td>
                <td>$($record.TimeStamp)</td>
                <td class="age-info">$($record.Age)</td>
                <td>$($record.TimeToLive)</td>
            </tr>
"@
        }
        $html += @"
        </tbody>
    </table>
"@
    }

    $html += @"
</body>
</html>
"@

    $html | Out-File -FilePath $OutputPath -Encoding UTF8
    Write-Output "HTML report exported to: $OutputPath"
}

try {
    Write-Output "Starting DNS Age Audit"
    Write-Output "DNS Server: $DNSServer"
    Write-Output "Output Path: $OutputPath"
    Write-Output ""

    $records = Get-DNSRecordsWithAge -Server $DNSServer -Zone $ZoneName -IncludeStatic:$IncludeStaticRecords -ExcludeReverse:$ExcludeReverseLookup

    if ($records.Count -eq 0) {
        Write-Warning "No records found. Exiting."
        exit
    }

    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $jsonPath = Join-Path $OutputPath "DNSAgeAudit-$timestamp.json"
    $htmlPath = Join-Path $OutputPath "DNSAgeAudit-$timestamp.html"

    Export-DNSReportJSON -Records $records -OutputPath $jsonPath
    Export-DNSReportHTML -Records $records -OutputPath $htmlPath

    Write-Output ""
    Write-Output "Audit Summary:"
    Write-Output "  Over 365 days: $(($records | Where-Object { $_.AgeCategory -eq 'Over365Days' }).Count)"
    Write-Output "  Over 180 days: $(($records | Where-Object { $_.AgeCategory -eq 'Over180Days' }).Count)"
    Write-Output "  Over 90 days:  $(($records | Where-Object { $_.AgeCategory -eq 'Over90Days' }).Count)"
    Write-Output "  Under 90 days: $(($records | Where-Object { $_.AgeCategory -eq 'Under90Days' }).Count)"
    Write-Output "  Static:        $(($records | Where-Object { $_.AgeCategory -eq 'Static' }).Count)"
    Write-Output ""
    Write-Output "Audit complete!"
    Write-Output ""
    Write-Output "Next steps:"
    Write-Output "  1. Review the HTML report: $htmlPath"
    Write-Output "  2. Use Invoke-DNSCleanup.ps1 with the JSON file to selectively delete records"

} catch {
    Write-Error "DNS Audit failed: $_"
    Write-Error $_.ScriptStackTrace
    exit 1
}
