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
            Name = $match.Groups[1].Value.Trim()
            Confidence = $match.Groups[2].Value.Trim()
            Evidence = $match.Groups[3].Value.Trim()
            Why = $match.Groups[4].Value.Trim()
            Action = $match.Groups[5].Value.Trim()
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

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $PSScriptRoot 'ConsolidatedReports'
}

if ([string]::IsNullOrWhiteSpace($InputDirectory)) {
    Write-Host "`n== Server Reports Consolidation ==" -ForegroundColor Cyan
    Write-Host "`nSelect the folder containing the generated markdown reports.`n" -ForegroundColor Gray

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = 'Select folder with readiness/discovery markdown reports'
        $dialog.RootFolder = [System.Environment+SpecialFolder]::MyComputer
        if (Test-Path $PSScriptRoot) {
            $dialog.SelectedPath = $PSScriptRoot
        }

        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $InputDirectory = $dialog.SelectedPath
        } else {
            Write-Error 'No folder selected. Exiting.'
            exit 1
        }
    } catch {
        Write-Host 'Enter folder path: ' -NoNewline -ForegroundColor Yellow
        $InputDirectory = Read-Host
    }
}

if (-not (Test-Path $InputDirectory)) {
    Write-Error "Input directory not found: $InputDirectory"
    exit 1
}

if (-not (Test-Path $OutputDirectory)) {
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
}

$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$reportDate = Get-Date -Format 'yyyy-MM-dd HH:mm'

Write-Host "`n==============================================================" -ForegroundColor Cyan
Write-Host 'SERVER UPGRADE READINESS - CHANGE-READY REPORTS' -ForegroundColor Cyan
Write-Host '==============================================================' -ForegroundColor Cyan
Write-Host "Input:  $InputDirectory" -ForegroundColor Gray
Write-Host "Output: $OutputDirectory`n" -ForegroundColor Gray

Write-Host 'Scanning for server reports...' -ForegroundColor White

$discoveryFiles = Get-ChildItem -Path $InputDirectory -Recurse -ErrorAction SilentlyContinue -File |
    Where-Object { $_.Name -like 'ServerDocumentation_*.md' -or $_.Name -like 'ServerDoc_*.md' }
$readinessFiles = Get-ChildItem -Path $InputDirectory -Recurse -ErrorAction SilentlyContinue -File |
    Where-Object { $_.Name -like 'Readiness_*.md' -or $_.Name -like 'WS2025_ProductionReadiness_*.md' }
$workloadFiles = Get-ChildItem -Path $InputDirectory -Filter 'Workloads_*.csv' -Recurse -ErrorAction SilentlyContinue
$testPlanFiles = Get-ChildItem -Path $InputDirectory -Filter 'TestPlan_*.csv' -Recurse -ErrorAction SilentlyContinue
$appFiles = Get-ChildItem -Path $InputDirectory -Filter 'Applications_*.csv' -Recurse -ErrorAction SilentlyContinue

Write-Host "  Found: $($discoveryFiles.Count) Discovery, $($readinessFiles.Count) Readiness, $($workloadFiles.Count) Workloads, $($testPlanFiles.Count) Test Plans, $($appFiles.Count) Apps" -ForegroundColor Gray

$serverData = @{}

function Add-FileToServer($file, $type) {
    if ($file.BaseName -match '_([A-Z0-9-]+)_[0-9]{8}_') {
        $serverName = $Matches[1]

        if (-not $serverData.ContainsKey($serverName)) {
            $serverData[$serverName] = @{
                Discovery = $null
                Readiness = $null
                Workloads = $null
                TestPlan = $null
                Applications = $null
            }
        }

        $serverData[$serverName][$type] = $file
    }
}

$discoveryFiles | ForEach-Object { Add-FileToServer $_ 'Discovery' }
$readinessFiles | ForEach-Object { Add-FileToServer $_ 'Readiness' }
$workloadFiles | ForEach-Object { Add-FileToServer $_ 'Workloads' }
$testPlanFiles | ForEach-Object { Add-FileToServer $_ 'TestPlan' }
$appFiles | ForEach-Object { Add-FileToServer $_ 'Applications' }

Write-Host "  Identified: $($serverData.Count) unique servers`n" -ForegroundColor White

if ($serverData.Count -eq 0) {
    Write-Error 'No server reports found.'
    exit 1
}

$allServerSummaries = New-Object 'System.Collections.Generic.List[object]'

$serverIndex = 0
foreach ($serverEntry in $serverData.GetEnumerator() | Sort-Object Key) {
    $serverName = $serverEntry.Key
    $files = $serverEntry.Value
    $serverIndex++

    Write-Progress -Activity 'Processing Servers' -Status $serverName -PercentComplete (($serverIndex / $serverData.Count) * 100)
    Write-Host "Processing: $serverName" -ForegroundColor White

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
        } catch {
            Write-Warning "Could not parse discovery for ${serverName}: $($_.Exception.Message)"
        }
    }

    $readinessContent = $null
    if ($files.Readiness) {
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

            $confirmedUseFindings = @(Get-ReadinessFindings -Content $readinessContent -Heading '2025 Changes With Confirmed Use')
            $configuredFindings = @(Get-ReadinessFindings -Content $readinessContent -Heading '2025 Changes Configured But Usage Not Proven')
            $telemetryGaps = @(Get-ReadinessGapLines -Content $readinessContent)
        } catch {
            Write-Warning "Could not parse readiness for ${serverName}: $($_.Exception.Message)"
        }
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
    }

    $report.Add('## Change Request Narrative')
    $report.Add('')
    $report.Add('Use the following summary in a change request description:')
    $report.Add('')
    $report.Add('> Due diligence was completed against the current server state, observed workloads, upgrade-readiness findings, and validation requirements. The server hosts identified production functions and was assessed using evidence collected from the recent analysis window. The change should only proceed in line with the decision recorded above and after completing all required validation and remediation actions.')
    $report.Add('')

    $report.Add('## Pre-Change Checklist')
    $report.Add('')
    $report.Add('- [ ] Confirm latest backup/snapshot and rollback path are available and tested.')
    $report.Add('- [ ] Confirm maintenance window, outage expectation, and stakeholder approval.')
    $report.Add('- [ ] Confirm application owners for all listed workloads are aware and available if needed.')
    $report.Add('- [ ] Review confirmed blockers and validation risks in this report.')
    if ($priorityTests.Count -gt 0) {
        foreach ($test in $priorityTests) {
            $report.Add($test)
        }
    }
    if ($generalTests.Count -gt 0) {
        foreach ($test in $generalTests) {
            $report.Add($test)
        }
    }
    $report.Add('')

    $report.Add('## Post-Change Validation')
    $report.Add('')
    if ($postMaintenanceTests.Count -gt 0) {
        foreach ($test in $postMaintenanceTests) {
            $report.Add($test)
        }
    } else {
        $report.Add('- [ ] Verify services, ports, authentication, monitoring, and workload-specific tests all pass.')
        $report.Add('- [ ] Review System/Application/Security events for new errors after the change.')
        $report.Add('- [ ] Confirm end-user or app-owner validation for all in-scope workloads.')
    }
    $report.Add('')

    $report.Add('## Rollback Considerations')
    $report.Add('')
    $report.Add('- If critical workload validation fails, initiate rollback using the approved backup/snapshot procedure.')
    $report.Add('- Preserve event logs, screenshots, installer output, and validation results for the change record.')
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
    $report.Add("| Discovery | $($files.Discovery.Name) |")
    $report.Add("| Readiness | $(if ($files.Readiness) { $files.Readiness.Name } else { 'Not found' }) |")
    $report.Add("| Workloads CSV | $(if ($files.Workloads) { $files.Workloads.Name } else { 'Not found' }) |")
    $report.Add("| Test Plan CSV | $(if ($files.TestPlan) { $files.TestPlan.Name } else { 'Not found' }) |")
    $report.Add("| Applications CSV | $(if ($files.Applications) { $files.Applications.Name } else { 'Not found' }) |")
    $report.Add('')

    $serverReportPath = Join-Path $OutputDirectory "ChangeSupport_${serverName}_${timestamp}.md"
    $report | Out-File -FilePath $serverReportPath -Encoding UTF8
    Write-Host "  Saved: $([System.IO.Path]::GetFileName($serverReportPath))" -ForegroundColor Green

    $allServerSummaries.Add([PSCustomObject]@{
        ServerName = $serverName
        Criticality = $criticality
        Score = $criticalScore
        Role = $role
        Decision = $decision
        GoStatus = $goStatus
        Blockers = $blockerCount
        Risks = $riskCount
        Workloads = $workloadCount
        Users = $userCount
        ReportFile = $serverReportPath
    })
}

Write-Progress -Activity 'Processing Servers' -Completed
Write-Host "`nGenerating master summary report..." -ForegroundColor White

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
$masterReport | Out-File -FilePath $masterPath -Encoding UTF8

Write-Host "`nMaster report saved: $([System.IO.Path]::GetFileName($masterPath))" -ForegroundColor Green
Write-Host 'Summary:' -ForegroundColor Cyan
Write-Host "   Per-server reports: $($allServerSummaries.Count)" -ForegroundColor White
Write-Host "All reports saved to: $OutputDirectory" -ForegroundColor Cyan
