<#
.SYNOPSIS
    Creates change-ready consolidated reports from discovery and readiness outputs.

.DESCRIPTION
    Produces a per-server markdown report intended to support change requests,
    due diligence, upgrade planning, and CAB review. The report pulls forward:
    - Current state and workloads
    - Upgrade decision and blockers
    - Evidence-backed findings
    - Pre-change and post-change validation steps
    - Rollback and execution notes

    Also creates a master summary across all discovered servers.

.NOTES
    Corrected behavior:
    - Defaults input/output to the current working directory
    - Scans only the current folder (no recursion)
    - Uses more tolerant filename parsing for server names
    - Prefers newest matching file per server/type
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$InputDirectory,

    [Parameter(Mandatory = $false)]
    [string]$OutputDirectory,

    [int]$DaysBack = 14
)

function Get-MatchValue {
    param(
        [string]$Text,
        [string]$Pattern,
        [int]$Group = 1
    )

    $match = [regex]::Match($Text, $Pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($match.Success) {
        return $match.Groups[$Group].Value.Trim()
    }

    return $null
}

function Get-SectionContent {
    param(
        [string]$Text,
        [string]$Heading
    )

    $pattern = '(?ms)^##\s+' + [regex]::Escape($Heading) + '\s*\r?\n(.*?)(?=^##\s+|\Z)'
    $match = [regex]::Match($Text, $pattern)
    if ($match.Success) {
        return $match.Groups[1].Value.Trim()
    }

    return $null
}

function Get-BulletLines {
    param(
        [string]$SectionText
    )

    if ([string]::IsNullOrWhiteSpace($SectionText)) {
        return @()
    }

    return @(
        ($SectionText -split "`r?`n") |
        Where-Object { $_ -match '^\s*-\s+' } |
        ForEach-Object { $_.Trim() }
    )
}

function Get-FirstTable {
    param(
        [string]$SectionText,
        [int]$MaxLines = 12
    )

    if ([string]::IsNullOrWhiteSpace($SectionText)) {
        return @()
    }

    $lines = $SectionText -split "`r?`n"
    $table = New-Object 'System.Collections.Generic.List[string]'
    $inTable = $false

    foreach ($line in $lines) {
        if ($line.Trim().StartsWith('|')) {
            $inTable = $true
            if ($table.Count -lt $MaxLines) {
                $table.Add($line)
            }
            continue
        }

        if ($inTable) {
            break
        }
    }

    return $table.ToArray()
}

function Get-KeyValueBullets {
    param(
        [string]$SectionText,
        [int]$MaxLines = 8
    )

    return @(Get-BulletLines -SectionText $SectionText | Select-Object -First $MaxLines)
}

function Add-Lines {
    param(
        [System.Collections.Generic.List[string]]$Report,
        [string[]]$Lines
    )

    foreach ($line in $Lines) {
        $Report.Add($line)
    }
}

function Get-ReadinessFindings {
    param(
        [string]$Content,
        [string]$Heading
    )

    $section = Get-SectionContent -Text $Content -Heading $Heading
    if ([string]::IsNullOrWhiteSpace($section)) {
        return @()
    }

    $findings = New-Object 'System.Collections.Generic.List[object]'
    $pattern = '(?ms)^-\s+(.*?)\s*\|\s*Confidence:\s*\*\*(.*?)\*\*\s*\r?\n\s*Evidence:\s*(.*?)\s*\r?\n\s*Why 2025:\s*(.*?)\s*\r?\n\s*Action:\s*(.*?)(?=^\s*-\s+.*?\|\s*Confidence:|\Z)'
    $matches = [regex]::Matches($section, $pattern)

    foreach ($match in $matches) {
        $findings.Add([PSCustomObject]@{
            Name       = $match.Groups[1].Value.Trim()
            Confidence = $match.Groups[2].Value.Trim()
            Evidence   = $match.Groups[3].Value.Trim()
            Why        = $match.Groups[4].Value.Trim()
            Action     = $match.Groups[5].Value.Trim()
        })
    }

    return $findings.ToArray()
}

function Get-ReadinessGapLines {
    param(
        [string]$Content
    )

    $section = Get-SectionContent -Text $Content -Heading '2025 Telemetry Gaps'
    return @(Get-BulletLines -SectionText $section)
}

function Get-LogEvidenceFindings {
    param(
        [object[]]$Findings
    )

    if ($null -eq $Findings -or @($Findings).Count -eq 0) {
        return @()
    }

    return @(
        $Findings |
        Where-Object {
            $_.Evidence -match '(?i)\b(log|event|session|audit)\b'
        }
    )
}

function Get-ReadinessRowsFromJson {
    param(
        [System.IO.FileInfo]$File
    )

    if ($null -eq $File -or -not (Test-Path -LiteralPath $File.FullName)) {
        return @()
    }

    try {
        $json = Get-Content -LiteralPath $File.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($json -is [System.Array]) {
            return @($json)
        }

        return @($json)
    } catch {
        Write-Host "  [WARN] Could not parse readiness JSON: $($File.Name) - $($_.Exception.Message)" -ForegroundColor Yellow
        return @()
    }
}

function Convert-ReadinessRowsToFindings {
    param(
        [object[]]$Rows,
        [string]$UsageState
    )

    if ($null -eq $Rows -or @($Rows).Count -eq 0) {
        return @()
    }

    return @(
        foreach ($row in ($Rows | Where-Object {
            $_.IsWS2025Change -eq $true -and
            [string]$_.UsageState -eq $UsageState -and
            [string]$_.Status -ne 'PASS'
        })) {
            [PSCustomObject]@{
                Name       = [string]$row.Check
                Confidence = [string]$row.BreakConfidence
                Evidence   = [string]$row.Evidence
                Why        = [string]$row.WS2025ChangeNote
                Action     = [string]$row.Action
            }
        }
    )
}

function Convert-ReadinessRowsToGapLines {
    param(
        [object[]]$Rows
    )

    if ($null -eq $Rows -or @($Rows).Count -eq 0) {
        return @()
    }

    return @(
        foreach ($row in ($Rows | Where-Object {
            $_.IsWS2025Change -eq $true -and
            [string]$_.UsageState -eq 'EvidenceGap' -and
            [string]$_.Status -ne 'PASS'
        })) {
            $gap = New-Object 'System.Collections.Generic.List[string]'
            $gap.Add("- $([string]$row.Check)")
            if (-not [string]::IsNullOrWhiteSpace([string]$row.Evidence)) {
                $gap.Add("  Evidence: $([string]$row.Evidence)")
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$row.WS2025ChangeNote)) {
                $gap.Add("  Why 2025: $([string]$row.WS2025ChangeNote)")
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$row.Action)) {
                $gap.Add("  Action: $([string]$row.Action)")
            }
            $gap.ToArray()
        }
    )
}

$currentDirectory = (Get-Location).Path

if ([string]::IsNullOrWhiteSpace($InputDirectory)) {
    $InputDirectory = $currentDirectory
}

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = $currentDirectory
}

Write-Host "`n==============================================================" -ForegroundColor Cyan
Write-Host 'SERVER UPGRADE READINESS - CHANGE-READY REPORTS' -ForegroundColor Cyan
Write-Host '==============================================================' -ForegroundColor Cyan

Write-Host "`nInput directory : $InputDirectory" -ForegroundColor Gray
Write-Host "Output directory: $OutputDirectory" -ForegroundColor Gray
Write-Host "Scan mode       : Current folder only (no subfolders)" -ForegroundColor DarkGray

if (-not (Test-Path $InputDirectory)) {
    Write-Error "Input directory not found: $InputDirectory"
    exit 1
}

if (-not (Test-Path $OutputDirectory)) {
    Write-Host "`nCreating output directory: $OutputDirectory" -ForegroundColor Yellow
    try {
        New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
        Write-Host '  Created.' -ForegroundColor Green
    } catch {
        Write-Error "Could not create output directory: $($_.Exception.Message)"
        exit 1
    }
}

$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$reportDate = Get-Date -Format 'yyyy-MM-dd HH:mm'

Write-Host "`n--------------------------------------------------------------" -ForegroundColor DarkGray
Write-Host 'Scanning for server reports...' -ForegroundColor White

# CURRENT FOLDER ONLY - NO RECURSION
$discoveryFiles = @(
    Get-ChildItem -Path $InputDirectory -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like 'ServerDocumentation_*.md' -or $_.Name -like 'ServerDoc_*.md' }
)

$readinessFiles = @(
    Get-ChildItem -Path $InputDirectory -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like 'Readiness_*.md' -or $_.Name -like 'WS2025_ProductionReadiness_*.md' }
)

$readinessJsonFiles = @(
    Get-ChildItem -Path $InputDirectory -File -Filter 'WS2025_ProductionReadiness_*.json' -ErrorAction SilentlyContinue
)

$workloadFiles = @(
    Get-ChildItem -Path $InputDirectory -File -Filter 'Workloads_*.csv' -ErrorAction SilentlyContinue
)

$testPlanFiles = @(
    Get-ChildItem -Path $InputDirectory -File -Filter 'TestPlan_*.csv' -ErrorAction SilentlyContinue
)

$appFiles = @(
    Get-ChildItem -Path $InputDirectory -File -Filter 'Applications_*.csv' -ErrorAction SilentlyContinue
)

Write-Host "  Discovery  (.md): $($discoveryFiles.Count) file(s)" -ForegroundColor $(if ($discoveryFiles.Count -gt 0) { 'Green' } else { 'Yellow' })
foreach ($f in $discoveryFiles) { Write-Host "    $($f.Name)" -ForegroundColor DarkGray }

Write-Host "  Readiness  (.md): $($readinessFiles.Count) file(s)" -ForegroundColor $(if ($readinessFiles.Count -gt 0) { 'Green' } else { 'Yellow' })
foreach ($f in $readinessFiles) { Write-Host "    $($f.Name)" -ForegroundColor DarkGray }

Write-Host "  Readiness (.json): $($readinessJsonFiles.Count) file(s)" -ForegroundColor $(if ($readinessJsonFiles.Count -gt 0) { 'Green' } else { 'DarkGray' })
foreach ($f in $readinessJsonFiles) { Write-Host "    $($f.Name)" -ForegroundColor DarkGray }

Write-Host "  Workloads  (.csv): $($workloadFiles.Count) file(s)" -ForegroundColor $(if ($workloadFiles.Count -gt 0) { 'Green' } else { 'DarkGray' })
foreach ($f in $workloadFiles) { Write-Host "    $($f.Name)" -ForegroundColor DarkGray }

Write-Host "  Test Plans (.csv): $($testPlanFiles.Count) file(s)" -ForegroundColor $(if ($testPlanFiles.Count -gt 0) { 'Green' } else { 'DarkGray' })
foreach ($f in $testPlanFiles) { Write-Host "    $($f.Name)" -ForegroundColor DarkGray }

Write-Host "  Apps       (.csv): $($appFiles.Count) file(s)" -ForegroundColor $(if ($appFiles.Count -gt 0) { 'Green' } else { 'DarkGray' })
foreach ($f in $appFiles) { Write-Host "    $($f.Name)" -ForegroundColor DarkGray }

if ($discoveryFiles.Count -eq 0 -and $readinessFiles.Count -eq 0) {
    Write-Host "`n[!] No discovery or readiness files found in: $InputDirectory" -ForegroundColor Red
    Write-Host '    Expected file name patterns:' -ForegroundColor Yellow
    Write-Host '      ServerDoc_<SERVERNAME>_<yyyyMMdd>_<HHmmss>.md' -ForegroundColor Yellow
    Write-Host '      WS2025_ProductionReadiness_<SERVERNAME>_<yyyyMMdd>_<HHmmss>_ChangeRequest.md' -ForegroundColor Yellow
    Write-Host '    Only the current folder was scanned.' -ForegroundColor Yellow
    exit 1
}

$serverData = @{}

function Get-ServerNameFromFile {
    param(
        [System.IO.FileInfo]$File
    )

    $baseName = $File.BaseName

    # Handle known multi-part prefixes before generic parsing.
    if ($baseName -match '(?i)^WS2025_ProductionReadiness_(.+?)_[0-9]{8}_[0-9]{6}(?:_|$)') {
        return $Matches[1].ToUpperInvariant()
    }

    if ($baseName -match '(?i)^ServerDocumentation_(.+?)_[0-9]{8}_[0-9]{6}(?:_|$)') {
        return $Matches[1].ToUpperInvariant()
    }

    if ($baseName -match '(?i)^ServerDoc_(.+?)_[0-9]{8}_[0-9]{6}(?:_|$)') {
        return $Matches[1].ToUpperInvariant()
    }

    # Preferred pattern: PREFIX_SERVERNAME_YYYYMMDD_HHMMSS...
    if ($baseName -match '(?i)^[^_]+_(.+?)_[0-9]{8}_[0-9]{6}(?:_|$)') {
        return $Matches[1].ToUpperInvariant()
    }

    # Fallback pattern: PREFIX_SERVERNAME_YYYYMMDD...
    if ($baseName -match '(?i)^[^_]+_(.+?)_[0-9]{8}(?:_|$)') {
        return $Matches[1].ToUpperInvariant()
    }

    # Fallback pattern: PREFIX_SERVERNAME
    if ($baseName -match '(?i)^[^_]+_(.+)$') {
        return $Matches[1].ToUpperInvariant()
    }

    return $null
}

function Add-FileToServer {
    param(
        [System.IO.FileInfo]$File,
        [string]$Type
    )

    $serverName = Get-ServerNameFromFile -File $File

    if ([string]::IsNullOrWhiteSpace($serverName)) {
        Write-Host "  [SKIP] Could not extract server name from: $($File.Name)" -ForegroundColor Yellow
        Write-Host "         Base name: $($File.BaseName)" -ForegroundColor DarkGray
        return
    }

    if (-not $serverData.ContainsKey($serverName)) {
        $serverData[$serverName] = @{
            Discovery    = $null
            Readiness    = $null
            ReadinessJson = $null
            Workloads    = $null
            TestPlan     = $null
            Applications = $null
        }
    }

    # Prefer newest file for this server/type
    if (
        $null -eq $serverData[$serverName][$Type] -or
        $File.LastWriteTime -gt $serverData[$serverName][$Type].LastWriteTime
    ) {
        $serverData[$serverName][$Type] = $File
    }
}

Write-Host "`nMapping files to servers..." -ForegroundColor White
$discoveryFiles | ForEach-Object { Add-FileToServer -File $_ -Type 'Discovery' }
$readinessFiles | ForEach-Object { Add-FileToServer -File $_ -Type 'Readiness' }
$readinessJsonFiles | ForEach-Object { Add-FileToServer -File $_ -Type 'ReadinessJson' }
$workloadFiles  | ForEach-Object { Add-FileToServer -File $_ -Type 'Workloads' }
$testPlanFiles  | ForEach-Object { Add-FileToServer -File $_ -Type 'TestPlan' }
$appFiles       | ForEach-Object { Add-FileToServer -File $_ -Type 'Applications' }

Write-Host "`nServers identified: $($serverData.Count)" -ForegroundColor $(if ($serverData.Count -gt 0) { 'Green' } else { 'Red' })
foreach ($key in ($serverData.Keys | Sort-Object)) {
    $entry = $serverData[$key]
    $parts = @()
    if ($entry.Discovery)    { $parts += 'Discovery' }
    if ($entry.Readiness)    { $parts += 'Readiness' }
    if ($entry.ReadinessJson) { $parts += 'ReadinessJson' }
    if ($entry.Workloads)    { $parts += 'Workloads' }
    if ($entry.TestPlan)     { $parts += 'TestPlan' }
    if ($entry.Applications) { $parts += 'Apps' }
    Write-Host ("  {0,-30} [{1}]" -f $key, ($parts -join ', ')) -ForegroundColor $(if ($parts.Count -ge 1) { 'White' } else { 'Yellow' })
}

if ($serverData.Count -eq 0) {
    Write-Error 'No server reports could be mapped. Check file naming in the current folder.'
    exit 1
}

Write-Host ''

$allServerSummaries = New-Object 'System.Collections.Generic.List[object]'

$serverIndex = 0
foreach ($serverEntry in $serverData.GetEnumerator() | Sort-Object Key) {
    $serverName = $serverEntry.Key
    $files = $serverEntry.Value
    $serverIndex++

    Write-Progress -Activity 'Processing Servers' -Status $serverName -PercentComplete (($serverIndex / $serverData.Count) * 100)
    Write-Host ("--------------------------------------------------------------") -ForegroundColor DarkGray
    Write-Host ("[{0}/{1}] Processing: {2}" -f $serverIndex, $serverData.Count, $serverName) -ForegroundColor Cyan

    $report = New-Object 'System.Collections.Generic.List[string]'
    $criticality = 'Unknown'
    $criticalScore = 0
    $role = 'Unknown'
    $osName = 'Unknown'
    $build = 'Unknown'
    $domainRole = 'Unknown'
    $ipAddresses = 'Unknown'
    $impactIfDown = 'Unknown'
    $workloadCount = 0
    $userCount = 0
    $decision = 'Decision not available'
    $evidenceWindow = "$DaysBack day(s)"
    $goStatus = 'UNKNOWN'

    $confirmedUseFindings = @()
    $configuredFindings = @()
    $telemetryGaps = @()
    $priorityTests = @()
    $generalTests = @()
    $postMaintenanceTests = @()
    $workloadTable = @()
    $systemInfoTable = @()
    $networkActivityLines = @()
    $recommendationLines = @()
    $applicationRows = @()

    $discoveryContent = $null
    if ($files.Discovery) {
        Write-Host "  Discovery:  $($files.Discovery.Name)" -ForegroundColor DarkGray
        try {
            $discoveryContent = Get-Content -Path $files.Discovery.FullName -Raw
            $roleValue = Get-MatchValue -Text $discoveryContent -Pattern '\*\*Primary Role:\*\*\s*([^\r\n]+)'
            if ($roleValue) { $role = $roleValue }

            $criticalityValue = Get-MatchValue -Text $discoveryContent -Pattern '\*\*Criticality:\*\*\s*\*\*(\w+)\*\*'
            if (-not $criticalityValue) {
                $criticalityValue = Get-MatchValue -Text $discoveryContent -Pattern '\*\*Criticality:\*\*\s*(\w+)'
            }
            if ($criticalityValue) { $criticality = $criticalityValue.ToUpperInvariant() }

            $scoreValue = Get-MatchValue -Text $discoveryContent -Pattern 'Score:\s*(\d+)'
            if ($scoreValue) { $criticalScore = [int]$scoreValue }

            $impactValue = Get-MatchValue -Text $discoveryContent -Pattern '\*\*Impact if Down:\*\*\s*([^\r\n]+)'
            if ($impactValue) { $impactIfDown = $impactValue }

            $workloadValue = Get-MatchValue -Text $discoveryContent -Pattern '\*\*Active Workloads:\*\*\s*(\d+)'
            if ($workloadValue) { $workloadCount = [int]$workloadValue }

            $userCountValue = Get-MatchValue -Text $discoveryContent -Pattern '\*\*Unique Users(?: \(last \d+ days\))?:\*\*\s*(\d+)'
            if ($userCountValue) { $userCount = [int]$userCountValue }

            $systemInformation = Get-SectionContent -Text $discoveryContent -Heading 'System Information'
            $systemInfoTable = @(Get-FirstTable -SectionText $systemInformation)
            $osValue = Get-MatchValue -Text $systemInformation -Pattern '\|\s*Operating System\s*\|\s*([^|\r\n]+)\|'
            if ($osValue) { $osName = $osValue }
            $buildValue = Get-MatchValue -Text $systemInformation -Pattern '\|\s*Build\s*\|\s*([^|\r\n]+)\|'
            if ($buildValue) { $build = $buildValue }
            $domainRoleValue = Get-MatchValue -Text $systemInformation -Pattern '\|\s*Domain Role\s*\|\s*([^|\r\n]+)\|'
            if ($domainRoleValue) { $domainRole = $domainRoleValue }
            $ipValue = Get-MatchValue -Text $systemInformation -Pattern '\|\s*IP Address\(es\)\s*\|\s*([^|\r\n]+)\|'
            if ($ipValue) { $ipAddresses = $ipValue }

            $activeWorkloadsSection = Get-SectionContent -Text $discoveryContent -Heading 'Active Workloads'
            $workloadTable = @(Get-FirstTable -SectionText $activeWorkloadsSection -MaxLines 10)

            $testingChecklist = Get-SectionContent -Text $discoveryContent -Heading 'Testing Checklist'
            $priorityBlock = Get-MatchValue -Text $testingChecklist -Pattern '(?ms)^###\s+Priority Test Scenarios\s*\r?\n(.*?)(?=^###\s+|\Z)'
            $generalBlock = Get-MatchValue -Text $testingChecklist -Pattern '(?ms)^###\s+General Tests\s*\r?\n(.*?)(?=^###\s+|\Z)'
            $postBlock = Get-MatchValue -Text $testingChecklist -Pattern '(?ms)^###\s+Post-Maintenance Validation\s*\r?\n(.*?)(?=^###\s+|\Z)'

            $priorityTests = @(Get-BulletLines -SectionText $priorityBlock)
            $generalTests = @(Get-BulletLines -SectionText $generalBlock)
            $postMaintenanceTests = @(Get-BulletLines -SectionText $postBlock)

            $networkActivity = Get-SectionContent -Text $discoveryContent -Heading 'Network Activity'
            $networkActivityLines = @(Get-KeyValueBullets -SectionText $networkActivity -MaxLines 4)

            $recommendationsSection = Get-SectionContent -Text $discoveryContent -Heading 'Recommendations'
            if ($recommendationsSection) {
                $recommendationLines = @(
                    ($recommendationsSection -split "`r?`n") |
                    Where-Object { $_ -match '^\s*\d+\.\s+' } |
                    ForEach-Object { $_.Trim() }
                )
            }

            Write-Host ("    Role: {0}  Criticality: {1}  Score: {2}  Workloads: {3}  Users: {4}" -f $role, $criticality, $criticalScore, $workloadCount, $userCount) -ForegroundColor DarkGray
        } catch {
            Write-Warning "Could not parse discovery for ${serverName}: $($_.Exception.Message)"
        }
    } else {
        Write-Host '  Discovery:  (not found)' -ForegroundColor Yellow
    }

    $readinessContent = $null
    $readinessRows = @()
    if ($files.Readiness) {
        Write-Host "  Readiness:  $($files.Readiness.Name)" -ForegroundColor DarkGray
        try {
            $readinessContent = Get-Content -Path $files.Readiness.FullName -Raw
            $decisionValue = Get-MatchValue -Text $readinessContent -Pattern '-\s+Decision:\s*\*\*(.*?)\*\*'
            if ($decisionValue) { $decision = $decisionValue }

            $evidenceWindowValue = Get-MatchValue -Text $readinessContent -Pattern '-\s+Evidence Window:\s*([^\r\n]+)'
            if ($evidenceWindowValue) { $evidenceWindow = $evidenceWindowValue }

            if ($decision -match '^NO-GO') {
                $goStatus = 'NO-GO'
            } elseif ($decision -match '^GO') {
                $goStatus = 'GO'
            } elseif ($decision -match '^CONDITIONAL') {
                $goStatus = 'CONDITIONAL'
            }

            if ($files.ReadinessJson) {
                $readinessRows = @(Get-ReadinessRowsFromJson -File $files.ReadinessJson)
            }

            if ($readinessRows.Count -gt 0) {
                $confirmedUseFindings = @(Convert-ReadinessRowsToFindings -Rows $readinessRows -UsageState 'ConfirmedUse')
                $configuredFindings = @(Convert-ReadinessRowsToFindings -Rows $readinessRows -UsageState 'ConfigOnly')
                $telemetryGaps = @(Convert-ReadinessRowsToGapLines -Rows $readinessRows)
            } else {
                $confirmedUseFindings = @(Get-ReadinessFindings -Content $readinessContent -Heading '2025 Changes With Confirmed Use')
                $configuredFindings = @(Get-ReadinessFindings -Content $readinessContent -Heading '2025 Changes Configured But Usage Not Proven')
                $telemetryGaps = @(Get-ReadinessGapLines -Content $readinessContent)
            }

            $observedLogFindings = @(Get-LogEvidenceFindings -Findings ($confirmedUseFindings + $configuredFindings))

            Write-Host ("    Decision: {0}  Blockers: {1}  Risks: {2}  Gaps: {3}" -f $decision, $confirmedUseFindings.Count, $configuredFindings.Count, $telemetryGaps.Count) -ForegroundColor DarkGray
        } catch {
            Write-Warning "Could not parse readiness for ${serverName}: $($_.Exception.Message)"
        }
    } else {
        Write-Host '  Readiness:  (not found)' -ForegroundColor Yellow
    }

    if ($files.Applications) {
        try {
            $applicationRows = @(Import-Csv -Path $files.Applications.FullName | Where-Object { $_.Status -eq 'Active' } | Select-Object -First 10)
        } catch {
            Write-Warning "Could not parse applications for ${serverName}: $($_.Exception.Message)"
        }
    }

    $blockerCount = $confirmedUseFindings.Count
    $riskCount = $configuredFindings.Count + $telemetryGaps.Count

    $report.Add("# Change Support Report: $serverName")
    $report.Add('')
    $report.Add("**Generated:** $reportDate  ")
    $report.Add("**Analysis Period:** Last $DaysBack days  ")
    $report.Add("**Evidence Window:** $evidenceWindow  ")
    $report.Add('')

    $report.Add('## Change Summary')
    $report.Add('')
    $report.Add('| Field | Value |')
    $report.Add('|-------|-------|')
    $report.Add("| Server | $serverName |")
    $report.Add("| Proposed Activity | OS upgrade / change requiring readiness validation |")
    $report.Add("| Current Operating System | $osName |")
    $report.Add("| Current Build | $build |")
    $report.Add("| Primary Role | $role |")
    $report.Add("| Criticality | $criticality |")
    $report.Add("| Criticality Score | $criticalScore |")
    $report.Add("| Business Impact if Down | $impactIfDown |")
    $report.Add("| Decision | $decision |")
    $report.Add("| Confirmed Blockers | $blockerCount |")
    $report.Add("| Additional Risks / Gaps | $riskCount |")
    $report.Add('')

    $report.Add('## Recommended Change Position')
    $report.Add('')
    switch ($goStatus) {
        'NO-GO' {
            $report.Add("This server is currently **not ready** for the proposed change. Evidence shows at least one confirmed compatibility or dependency risk that should be remediated before approval.")
        }
        'GO' {
            $report.Add("This server appears **ready** for the proposed change based on the available evidence, provided the validation and rollback controls below are followed.")
        }
        'CONDITIONAL' {
            $report.Add("This server may proceed only as a **conditional go**. Approval should depend on completion of the remediation and validation items listed below.")
        }
        default {
            $report.Add('A definitive go/no-go statement was not found. Review the source readiness report and validation sections below before submitting a change request.')
        }
    }
    $report.Add('')

    $report.Add('## Due Diligence Evidence')
    $report.Add('')
    $report.Add('- Current state was assessed from discovery and readiness outputs generated for this server.')
    $report.Add("- Host role: **$role**")
    $report.Add("- Workloads identified: **$workloadCount**")
    $report.Add("- Unique users observed: **$userCount**")
    $report.Add("- Domain role: **$domainRole**")
    $report.Add("- IP address(es): **$ipAddresses**")
    if ($networkActivityLines.Count -gt 0) {
        Add-Lines -Report $report -Lines $networkActivityLines
    }
    $report.Add('')

    if ($systemInfoTable.Count -gt 0) {
        $report.Add('### System Baseline')
        $report.Add('')
        Add-Lines -Report $report -Lines $systemInfoTable
        $report.Add('')
    }

    if ($workloadTable.Count -gt 0) {
        $report.Add('### Active Workloads in Scope')
        $report.Add('')
        Add-Lines -Report $report -Lines $workloadTable
        $report.Add('')
    }

    $report.Add('## Findings That Affect Change Approval')
    $report.Add('')
    if ($confirmedUseFindings.Count -eq 0 -and $configuredFindings.Count -eq 0 -and $telemetryGaps.Count -eq 0) {
        $report.Add('No readiness findings were parsed from the source report. Manual review is recommended before approval.')
        $report.Add('')
    } else {
        if ($confirmedUseFindings.Count -gt 0) {
            $report.Add('### Confirmed Blockers')
            $report.Add('')
            foreach ($finding in $confirmedUseFindings) {
                $report.Add("- **$($finding.Name)** | Confidence: **$($finding.Confidence)**")
                $report.Add("  Evidence: $($finding.Evidence)")
                $report.Add("  Upgrade relevance: $($finding.Why)")
                $report.Add("  Required action: $($finding.Action)")
            }
            $report.Add('')

            $report.Add('### Blockers To Clear')
            $report.Add('')
            foreach ($finding in $confirmedUseFindings) {
                $report.Add("- **$($finding.Name)**")
                $report.Add("  Blocker evidence: $($finding.Evidence)")
                $report.Add("  Clear when: $($finding.Action)")
            }
            $report.Add('')
        }

        if ($configuredFindings.Count -gt 0) {
            $report.Add('### Risks Requiring Validation')
            $report.Add('')
            foreach ($finding in $configuredFindings) {
                $report.Add("- **$($finding.Name)** | Confidence: **$($finding.Confidence)**")
                $report.Add("  Evidence: $($finding.Evidence)")
                $report.Add("  Upgrade relevance: $($finding.Why)")
                $report.Add("  Validation action: $($finding.Action)")
            }
            $report.Add('')
        }

        if ($telemetryGaps.Count -gt 0) {
            $report.Add('### Telemetry Gaps / Assumptions')
            $report.Add('')
            foreach ($gap in $telemetryGaps) {
                $report.Add($gap)
            }
            $report.Add('')
        }

        if ($observedLogFindings.Count -gt 0) {
            $report.Add('### Observed Log Findings')
            $report.Add('')
            foreach ($finding in $observedLogFindings) {
                $report.Add("- **$($finding.Name)**: $($finding.Evidence)")
            }
            $report.Add('')
        }
    }

    $report.Add('## Change Request Narrative')
    $report.Add('')
    $report.Add('Use the following summary in a change request description:')
    $report.Add('')
    $report.Add('> Due diligence was completed against the current server state, observed workloads, upgrade-readiness findings, and validation requirements. The server hosts identified production functions and was assessed using evidence collected from the recent analysis window. The change should only proceed in line with the decision recorded above and after completing all required validation and remediation actions.')
    $report.Add('')

    $report.Add('## Pre-Change Checklist')
    $report.Add('')
    $report.Add('- [ ] Confirm latest backup/snapshot is available.')
    $report.Add('- [ ] Schedule with the application owners for all listed workloads.')
    $report.Add('- [ ] Review infrastructure team blockers in this report.')
    $report.Add('- [ ] Confirm all blockers are resolved before the change starts.')
    $report.Add('')

    $report.Add('## Post-Change Validation')
    $report.Add('')
    $report.Add('- [ ] Monitor to make sure everything works as expected after the change.')
    $report.Add('- [ ] Test to make sure all in-scope workloads and services work correctly.')
    $report.Add('- [ ] Verify no unexpected service failures.')
    $report.Add('')

    $report.Add('## Rollback Considerations')
    $report.Add('')
    $report.Add('- If critical workload validation fails, initiate rollback using the approved backup/snapshot procedure.')
    $report.Add('- Reconfirm service health, application pools, file access, and remote management after rollback.')
    $report.Add('')

    if ($applicationRows.Count -gt 0) {
        $report.Add('## Active Applications Snapshot')
        $report.Add('')
        $report.Add('| Application | Version | Publisher | Priority |')
        $report.Add('|-------------|---------|-----------|----------|')
        foreach ($app in $applicationRows) {
            $report.Add("| $($app.Name) | $($app.Version) | $($app.Publisher) | $($app.TestPriority) |")
        }
        $report.Add('')
    }

    if ($recommendationLines.Count -gt 0) {
        $report.Add('## Supporting Recommendations')
        $report.Add('')
        foreach ($line in $recommendationLines) {
            $report.Add("- $($line -replace '^\s*\d+\.\s*', '')")
        }
        $report.Add('')
    }

    $report.Add('## Source Evidence')
    $report.Add('')
    $report.Add('| Source | File |')
    $report.Add('|--------|------|')
    $report.Add("| Discovery | $(if ($files.Discovery) { $files.Discovery.Name } else { 'Not found' }) |")
    $report.Add("| Readiness | $(if ($files.Readiness) { $files.Readiness.Name } else { 'Not found' }) |")
    $report.Add("| Readiness JSON | $(if ($files.ReadinessJson) { $files.ReadinessJson.Name } else { 'Not found' }) |")
    $report.Add("| Workloads CSV | $(if ($files.Workloads) { $files.Workloads.Name } else { 'Not found' }) |")
    $report.Add("| Test Plan CSV | $(if ($files.TestPlan) { $files.TestPlan.Name } else { 'Not found' }) |")
    $report.Add("| Applications CSV | $(if ($files.Applications) { $files.Applications.Name } else { 'Not found' }) |")
    $report.Add('')

    $serverReportPath = Join-Path $OutputDirectory "ChangeSupport_${serverName}_${timestamp}.md"
    Write-Host "  Writing report..." -ForegroundColor DarkGray
    try {
        $report | Out-File -FilePath $serverReportPath -Encoding UTF8
        Write-Host ("  [OK] Saved: {0}" -f $serverReportPath) -ForegroundColor Green
    } catch {
        Write-Host ("  [FAIL] Could not write report: {0}" -f $_.Exception.Message) -ForegroundColor Red
    }

    $allServerSummaries.Add([PSCustomObject]@{
        ServerName  = $serverName
        Criticality = $criticality
        Score       = $criticalScore
        Role        = $role
        Decision    = $decision
        GoStatus    = $goStatus
        Blockers    = $blockerCount
        Risks       = $riskCount
        Workloads   = $workloadCount
        Users       = $userCount
        ReportFile  = $serverReportPath
    })
}

Write-Progress -Activity 'Processing Servers' -Completed
Write-Host "`n--------------------------------------------------------------" -ForegroundColor DarkGray
Write-Host "Generating master summary report..." -ForegroundColor White

$masterReport = New-Object 'System.Collections.Generic.List[string]'
$masterReport.Add('# Master Change Summary - Server Upgrade Readiness')
$masterReport.Add('')
$masterReport.Add("**Generated:** $reportDate  ")
$masterReport.Add("**Total Servers:** $($allServerSummaries.Count)  ")
$masterReport.Add("**Analysis Period:** Last $DaysBack days")
$masterReport.Add('')

$masterReport.Add('## Approval Snapshot')
$masterReport.Add('')
$masterReport.Add('| Server | Role | Criticality | Score | Decision | Blockers | Risks/Gaps | Workloads | Users | Report |')
$masterReport.Add('|--------|------|-------------|-------|----------|----------|------------|-----------|-------|--------|')

foreach ($srv in $allServerSummaries | Sort-Object Score -Descending) {
    $reportFileName = [System.IO.Path]::GetFileName($srv.ReportFile)
    $masterReport.Add("| $($srv.ServerName) | $($srv.Role) | $($srv.Criticality) | $($srv.Score) | $($srv.Decision) | $($srv.Blockers) | $($srv.Risks) | $($srv.Workloads) | $($srv.Users) | [$($srv.ServerName)]($reportFileName) |")
}
$masterReport.Add('')

$masterPath = Join-Path $OutputDirectory "MASTER-ChangeSummary_${timestamp}.md"
try {
    $masterReport | Out-File -FilePath $masterPath -Encoding UTF8
    Write-Host ("[OK] Master summary: {0}" -f $masterPath) -ForegroundColor Green
} catch {
    Write-Host ("[FAIL] Could not write master summary: {0}" -f $_.Exception.Message) -ForegroundColor Red
}

Write-Host "`n==============================================================" -ForegroundColor Cyan
Write-Host 'DONE' -ForegroundColor Cyan
Write-Host '==============================================================' -ForegroundColor Cyan
Write-Host ("  Per-server reports : {0}" -f $allServerSummaries.Count) -ForegroundColor White
Write-Host ("  Output directory   : {0}" -f $OutputDirectory) -ForegroundColor White

$goCount   = @($allServerSummaries | Where-Object GoStatus -eq 'GO').Count
$condCount = @($allServerSummaries | Where-Object GoStatus -eq 'CONDITIONAL').Count
$noGoCount = @($allServerSummaries | Where-Object GoStatus -eq 'NO-GO').Count
$unkCount  = @($allServerSummaries | Where-Object GoStatus -eq 'UNKNOWN').Count

Write-Host ("  GO                 : {0}" -f $goCount) -ForegroundColor Green
if ($condCount -gt 0) { Write-Host ("  CONDITIONAL        : {0}" -f $condCount) -ForegroundColor Yellow }
if ($noGoCount -gt 0) { Write-Host ("  NO-GO              : {0}" -f $noGoCount) -ForegroundColor Red }
if ($unkCount -gt 0) { Write-Host ("  Unknown/no data    : {0}" -f $unkCount) -ForegroundColor DarkGray }
