#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Consolidates server discovery reports into a single upgrade readiness summary.

.DESCRIPTION
    This script combines outputs from ServerDocumentation-Discovery.ps1 and analyzes
    all generated .md and .csv files to create a master upgrade report with:
    - Executive summary of all servers
    - Criticality ranking across environment
    - Workload consolidation and prioritization
    - Upgrade recommendations and risk assessment
    - Grouped test scenarios by workload type

.PARAMETER InputDirectory
    Directory containing discovery outputs (defaults to 2025Readiness folder)

.PARAMETER OutputDirectory
    Directory for consolidated report output

.PARAMETER DaysBack
    Analysis window in days (default: 14)

.EXAMPLE
    .\Consolidated-UpgradeReport.ps1
    Generates consolidated report from all discovery outputs

.EXAMPLE
    .\Consolidated-UpgradeReport.ps1 -InputDirectory "C:\\Reports" -OutputDirectory "C:\\Consolidated"
#>

[CmdletBinding()]
param(
    [string]$InputDirectory = (Join-Path $PSScriptRoot ".."),
    [string]$OutputDirectory = (Join-Path $PSScriptRoot ".." "ConsolidatedReports"),
    [int]$DaysBack = 14
)

# Initialize
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$reportDate = Get-Date -Format "yyyy-MM-dd HH:mm"

# Ensure output directory exists
if (-not (Test-Path $OutputDirectory)) {
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
}

Write-Host "`n╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║       SERVER UPGRADE READINESS - CONSOLIDATED REPORT          ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host "Analysis Period: Last $DaysBack days`n" -ForegroundColor Gray

# Find all discovery outputs
Write-Progress -Activity "Consolidating Reports" -Status "Scanning for discovery outputs..." -PercentComplete 10

$mdFiles = Get-ChildItem -Path $InputDirectory -Filter "ServerDocumentation_*.md" -Recurse -ErrorAction SilentlyContinue
$workloadCsvs = Get-ChildItem -Path $InputDirectory -Filter "Workloads_*.csv" -Recurse -ErrorAction SilentlyContinue
$testPlanCsvs = Get-ChildItem -Path $InputDirectory -Filter "TestPlan_*.csv" -Recurse -ErrorAction SilentlyContinue
$appCsvs = Get-ChildItem -Path $InputDirectory -Filter "Applications_*.csv" -Recurse -ErrorAction SilentlyContinue

Write-Host "Found:" -ForegroundColor White
Write-Host "  - $($mdFiles.Count) Server Documentation reports (.md)" -ForegroundColor Gray
Write-Host "  - $($workloadCsvs.Count) Workload analysis files (.csv)" -ForegroundColor Gray
Write-Host "  - $($testPlanCsvs.Count) Test plan files (.csv)" -ForegroundColor Gray
Write-Host "  - $($appCsvs.Count) Application inventory files (.csv)" -ForegroundColor Gray
Write-Host ""

if ($mdFiles.Count -eq 0) {
    Write-Warning "No discovery outputs found in $InputDirectory"
    Write-Host "Please run ServerDocumentation-Discovery.ps1 first." -ForegroundColor Yellow
    exit 1
}

# Data structures for consolidation
$allServers = New-Object 'System.Collections.Generic.List[object]'
$allWorkloads = New-Object 'System.Collections.Generic.List[object]'
$allApplications = New-Object 'System.Collections.Generic.List[object]'
$criticalitySummary = @{
    CRITICAL = 0
    HIGH = 0
    MEDIUM = 0
    LOW = 0
}
$workloadTypes = @{}
$serverRoles = @{}

# Parse each server's documentation
Write-Progress -Activity "Consolidating Reports" -Status "Parsing server documentation..." -PercentComplete 30

foreach ($mdFile in $mdFiles) {
    try {
        $content = Get-Content $mdFile.FullName -Raw
        $serverName = ($mdFile.BaseName -split '_')[1]
        
        # Extract key metrics using regex
        $criticality = if ($content -match '\*\*Criticality:\*\* (\w+)') { $Matches[1] } else { 'Unknown' }
        $primaryRole = if ($content -match '\*\*Primary Role:\*\* ([^\r\n]+)') { $Matches[1].Trim() } else { 'Unknown' }
        $activeWorkloads = if ($content -match '\*\*Active Workloads:\*\* (\d+)') { [int]$Matches[1] } else { 0 }
        $uniqueUsers = if ($content -match '\*\*Unique Users:\*\* (\d+)') { [int]$Matches[1] } else { 0 }
        $criticalScore = if ($content -match '\(Score: (\d+)\)') { [int]$Matches[1] } else { 0 }
        
        # Extract detected workloads
        $workloadMatches = [regex]::Matches($content, '- \[ \] \*\*([^:]+):\*\*')
        $workloadList = $workloadMatches | ForEach-Object { $_.Groups[1].Value }
        
        $serverInfo = [PSCustomObject]@{
            ServerName = $serverName
            FileName = $mdFile.Name
            Criticality = $criticality
            CriticalScore = $criticalScore
            PrimaryRole = $primaryRole
            ActiveWorkloads = $activeWorkloads
            UniqueUsers = $uniqueUsers
            Workloads = $workloadList
            FilePath = $mdFile.FullName
        }
        
        $allServers.Add($serverInfo)
        
        # Update criticality counts
        if ($criticalitySummary.ContainsKey($criticality)) {
            $criticalitySummary[$criticality]++
        }
        
        # Update role counts
        if ($serverRoles.ContainsKey($primaryRole)) {
            $serverRoles[$primaryRole]++
        } else {
            $serverRoles[$primaryRole] = 1
        }
        
        # Track workload types
        foreach ($wl in $workloadList) {
            if ($workloadTypes.ContainsKey($wl)) {
                $workloadTypes[$wl]++
            } else {
                $workloadTypes[$wl] = 1
            }
        }
        
    } catch {
        Write-Warning "Could not parse $($mdFile.Name): $($_.Exception.Message)"
    }
}

# Parse workload CSVs for detailed data
Write-Progress -Activity "Consolidating Reports" -Status "Analyzing workload details..." -PercentComplete 50

foreach ($csvFile in $workloadCsvs) {
    try {
        $workloads = Import-Csv $csvFile.FullName
        foreach ($wl in $workloads) {
            $allWorkloads.Add([PSCustomObject]@{
                ServerName = ($csvFile.BaseName -split '_')[1]
                Component = $wl.Type
                Criticality = $wl.Criticality
                Confidence = $wl.Confidence
                Evidence = $wl.Evidence
                TestScenario = $wl.TestScenario
            })
        }
    } catch {
        Write-Warning "Could not import $($csvFile.Name): $($_.Exception.Message)"
    }
}

# Parse application CSVs
Write-Progress -Activity "Consolidating Reports" -Status "Analyzing application inventory..." -PercentComplete 70

foreach ($csvFile in $appCsvs) {
    try {
        $apps = Import-Csv $csvFile.FullName
        foreach ($app in $apps) {
            $allApplications.Add([PSCustomObject]@{
                ServerName = ($csvFile.BaseName -split '_')[1]
                ApplicationName = $app.Name
                Version = $app.Version
                Publisher = $app.Publisher
                Status = $app.Status
                Priority = $app.TestPriority
            })
        }
    } catch {
        Write-Warning "Could not import $($csvFile.Name): $($_.Exception.Message)"
    }
}

Write-Progress -Activity "Consolidating Reports" -Status "Generating consolidated report..." -PercentComplete 90

# Generate Consolidated Report
$consolidatedReport = New-Object 'System.Collections.Generic.List[string]'

# Header
$consolidatedReport.Add("# Server Upgrade Readiness - Consolidated Report")
$consolidatedReport.Add("")
$consolidatedReport.Add("**Generated:** $reportDate  ")
$consolidatedReport.Add("**Analysis Period:** Last $DaysBack days  ")
$consolidatedReport.Add("**Servers Analyzed:** $($allServers.Count)  ")
$consolidatedReport.Add("**Total Active Workloads:** $($allWorkloads.Count)  ")
$consolidatedReport.Add("")
$consolidatedReport.Add("---")
$consolidatedReport.Add("")

# Executive Summary
$consolidatedReport.Add("## Executive Summary")
$consolidatedReport.Add("")
$consolidatedReport.Add("### Environment Overview")
$consolidatedReport.Add("")
$consolidatedReport.Add("| Metric | Count |")
$consolidatedReport.Add("|--------|-------|")
$consolidatedReport.Add("| Total Servers | $($allServers.Count) |")
$consolidatedReport.Add("| CRITICAL Priority | $($criticalitySummary.CRITICAL) |")
$consolidatedReport.Add("| HIGH Priority | $($criticalitySummary.HIGH) |")
$consolidatedReport.Add("| MEDIUM Priority | $($criticalitySummary.MEDIUM) |")
$consolidatedReport.Add("| LOW Priority | $($criticalitySummary.LOW) |")
$consolidatedReport.Add("| Total Active Workloads | $($allWorkloads.Count) |")
$consolidatedReport.Add("| Total Applications | $($allApplications.Count) |")
$consolidatedReport.Add("")

# Criticality Distribution
$consolidatedReport.Add("### Criticality Distribution")
$consolidatedReport.Add("")
$totalCritical = $criticalitySummary.CRITICAL + $criticalitySummary.HIGH + $criticalitySummary.MEDIUM + $criticalitySummary.LOW
if ($totalCritical -gt 0) {
    $criticalPct = [math]::Round(($criticalitySummary.CRITICAL / $totalCritical) * 100, 1)
    $highPct = [math]::Round(($criticalitySummary.HIGH / $totalCritical) * 100, 1)
    $medPct = [math]::Round(($criticalitySummary.MEDIUM / $totalCritical) * 100, 1)
    $lowPct = [math]::Round(($criticalitySummary.LOW / $totalCritical) * 100, 1)
    
    $consolidatedReport.Add("```")
    $consolidatedReport.Add(("CRITICAL:  " + $criticalitySummary.CRITICAL + " servers (" + $criticalPct + "%) - Immediate attention required"))
    $consolidatedReport.Add(("HIGH:      " + $criticalitySummary.HIGH + " servers (" + $highPct + "%) - Plan carefully, test thoroughly"))
    $consolidatedReport.Add(("MEDIUM:    " + $criticalitySummary.MEDIUM + " servers (" + $medPct + "%) - Standard change process"))
    $consolidatedReport.Add(("LOW:       " + $criticalitySummary.LOW + " servers (" + $lowPct + "%) - Can be batched/deferred"))
    $consolidatedReport.Add("```")
}
$consolidatedReport.Add("")

# Server Roles Summary
$consolidatedReport.Add("### Server Roles Detected")
$consolidatedReport.Add("")
$consolidatedReport.Add("| Role | Server Count |")
$consolidatedReport.Add("|------|--------------|")
foreach ($role in ($serverRoles.GetEnumerator() | Sort-Object Value -Descending)) {
    $consolidatedReport.Add("| $($role.Key) | $($role.Value) |")
}
$consolidatedReport.Add("")

# Workload Types Summary
$consolidatedReport.Add("### Workload Types Across Environment")
$consolidatedReport.Add("")
$consolidatedReport.Add("| Workload Type | Instance Count |")
$consolidatedReport.Add("|---------------|----------------|")
foreach ($wlType in ($workloadTypes.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 15)) {
    $consolidatedReport.Add("| $($wlType.Key) | $($wlType.Value) |")
}
$consolidatedReport.Add("")
$consolidatedReport.Add("---")
$consolidatedReport.Add("")

# Critical Servers Priority List
$consolidatedReport.Add("## Critical Servers - Priority Order")
$consolidatedReport.Add("")
$consolidatedReport.Add("Servers ranked by criticality score (highest first):")
$consolidatedReport.Add("")
$consolidatedReport.Add("| Priority | Server | Criticality | Score | Role | Workloads | Users |")
$consolidatedReport.Add("|----------|--------|-------------|-------|------|-----------|-------|")

$sortedServers = $allServers | Sort-Object CriticalScore -Descending
$priority = 1
foreach ($server in $sortedServers | Select-Object -First 20) {
    $workloadCount = if ($server.Workloads) { @($server.Workloads).Count } else { 0 }
    $consolidatedReport.Add("| $priority | $($server.ServerName) | $($server.Criticality) | $($server.CriticalScore) | $($server.PrimaryRole) | $workloadCount | $($server.UniqueUsers) |")
    $priority++
}
$consolidatedReport.Add("")

# Critical Workloads Requiring Testing
$consolidatedReport.Add("## Critical Workloads Requiring Testing")
$consolidatedReport.Add("")

$criticalWorkloads = $allWorkloads | Where-Object { $_.Criticality -in @('CRITICAL', 'HIGH') } | Sort-Object Criticality, ServerName

if ($criticalWorkloads.Count -gt 0) {
    $consolidatedReport.Add("| Server | Workload | Criticality | Confidence | Evidence |")
    $consolidatedReport.Add("|--------|----------|-------------|------------|----------|")
    
    foreach ($wl in ($criticalWorkloads | Select-Object -First 25)) {
        $evidence = if ($wl.Evidence.Length -gt 60) { $wl.Evidence.Substring(0, 60) + "..." } else { $wl.Evidence }
        $consolidatedReport.Add("| $($wl.ServerName) | $($wl.Component) | $($wl.Criticality) | $($wl.Confidence) | $evidence |")
    }
} else {
    $consolidatedReport.Add("*No CRITICAL or HIGH priority workloads detected.*")
}
$consolidatedReport.Add("")

# Workload-Specific Testing Consolidation
$consolidatedReport.Add("## Consolidated Testing Scenarios by Workload Type")
$consolidatedReport.Add("")
$consolidatedReport.Add("Group test scenarios by workload type to streamline validation:")
$consolidatedReport.Add("")

$workloadsByType = $allWorkloads | Group-Object Component
foreach ($wlGroup in ($workloadsByType | Sort-Object Count -Descending)) {
    $wlType = $wlGroup.Name
    $count = $wlGroup.Count
    
    $consolidatedReport.Add("### $wlType ($count instances)")
    $consolidatedReport.Add("")
    
    # Get unique test scenarios for this workload type
    $testScenarios = $wlGroup.Group | Select-Object -ExpandProperty TestScenario -Unique
    
    foreach ($scenario in $testScenarios) {
        $consolidatedReport.Add("- [ ] $scenario")
    }
    
    # List servers with this workload
    $serversWithWl = ($wlGroup.Group | Select-Object -ExpandProperty ServerName -Unique) -join ', '
    $consolidatedReport.Add("")
    $consolidatedReport.Add("**Servers:** $serversWithWl")
    $consolidatedReport.Add("")
}

# Application Inventory Summary
if ($allApplications.Count -gt 0) {
    $consolidatedReport.Add("## Application Inventory Summary")
    $consolidatedReport.Add("")
    
    $activeApps = $allApplications | Where-Object { $_.Status -eq 'Active' }
    $highPriorityApps = $allApplications | Where-Object { $_.Priority -eq 'HIGH' }
    
    $consolidatedReport.Add("| Metric | Count |")
    $consolidatedReport.Add("|--------|-------|")
    $consolidatedReport.Add("| Total Applications | $($allApplications.Count) |")
    $consolidatedReport.Add("| Active (Running) | $($activeApps.Count) |")
    $consolidatedReport.Add("| High Priority | $($highPriorityApps.Count) |")
    $consolidatedReport.Add("")
    
    if ($highPriorityApps.Count -gt 0) {
        $consolidatedReport.Add("### High Priority Applications (Require Testing)")
        $consolidatedReport.Add("")
        $consolidatedReport.Add("| Server | Application | Version | Publisher |")
        $consolidatedReport.Add("|--------|-------------|---------|-----------|")
        
        foreach ($app in ($highPriorityApps | Select-Object -First 20)) {
            $consolidatedReport.Add("| $($app.ServerName) | $($app.ApplicationName) | $($app.Version) | $($app.Publisher) |")
        }
        $consolidatedReport.Add("")
    }
}

# Upgrade Recommendations
$consolidatedReport.Add("## Upgrade Recommendations & Risk Assessment")
$consolidatedReport.Add("")

$consolidatedReport.Add("### Phased Approach")
$consolidatedReport.Add("")
$consolidatedReport.Add("**Phase 1 - LOW Priority (Week 1-2):**")
$consolidatedReport.Add("- Servers: $(($sortedServers | Where-Object { $_.Criticality -eq 'LOW' } | Select-Object -ExpandProperty ServerName) -join ', ')")
$consolidatedReport.Add("- Purpose: Validate upgrade process, identify issues")
$consolidatedReport.Add("")

$consolidatedReport.Add("**Phase 2 - MEDIUM Priority (Week 3-4):**")
$medServers = $sortedServers | Where-Object { $_.Criticality -eq 'MEDIUM' } | Select-Object -ExpandProperty ServerName
if ($medServers) {
    $consolidatedReport.Add("- Servers: $($medServers -join ', ')")
}
$consolidatedReport.Add("- Purpose: Standard production upgrades")
$consolidatedReport.Add("")

$consolidatedReport.Add("**Phase 3 - HIGH Priority (Week 5-6):**")
$highServers = $sortedServers | Where-Object { $_.Criticality -eq 'HIGH' } | Select-Object -ExpandProperty ServerName
if ($highServers) {
    $consolidatedReport.Add("- Servers: $($highServers -join ', ')")
}
$consolidatedReport.Add("- Purpose: Important workloads with validated process")
$consolidatedReport.Add("")

$consolidatedReport.Add("**Phase 4 - CRITICAL Priority (Week 7+):**")
$critServers = $sortedServers | Where-Object { $_.Criticality -eq 'CRITICAL' } | Select-Object -ExpandProperty ServerName
if ($critServers) {
    $consolidatedReport.Add("- Servers: $($critServers -join ', ')")
}
$consolidatedReport.Add("- Purpose: Mission-critical systems with full validation")
$consolidatedReport.Add("")

# Risk Factors
$consolidatedReport.Add("### Identified Risk Factors")
$consolidatedReport.Add("")

$highUserServers = $sortedServers | Where-Object { $_.UniqueUsers -gt 50 }
if ($highUserServers) {
    $consolidatedReport.Add("- **High User Impact:** $(($highUserServers | Select-Object -ExpandProperty ServerName) -join ', ') have >50 unique users")
}

$multiWorkloadServers = $sortedServers | Where-Object { $_.ActiveWorkloads -gt 3 }
if ($multiWorkloadServers) {
    $consolidatedReport.Add("- **Complex Workloads:** $(($multiWorkloadServers | Select-Object -ExpandProperty ServerName) -join ', ') have multiple active roles")
}

$consolidatedReport.Add("")

# Detailed Server Inventory
$consolidatedReport.Add("## Detailed Server Inventory")
$consolidatedReport.Add("")

foreach ($server in $sortedServers) {
    $consolidatedReport.Add("### $($server.ServerName)")
    $consolidatedReport.Add("")
    $consolidatedReport.Add("- **Criticality:** $($server.Criticality) (Score: $($server.CriticalScore))")
    $consolidatedReport.Add("- **Primary Role:** $($server.PrimaryRole)")
    $consolidatedReport.Add("- **Active Workloads:** $($server.ActiveWorkloads)")
    $consolidatedReport.Add("- **Unique Users:** $($server.UniqueUsers)")
    $consolidatedReport.Add("")
    
    if ($server.Workloads.Count -gt 0) {
        $consolidatedReport.Add("**Detected Workloads:**")
        foreach ($wl in $server.Workloads) {
            $consolidatedReport.Add("- $wl")
        }
        $consolidatedReport.Add("")
    }
    
    $consolidatedReport.Add("📄 [View Full Report]($($server.FilePath))")
    $consolidatedReport.Add("")
    $consolidatedReport.Add("---")
    $consolidatedReport.Add("")
}

# Footer
$consolidatedReport.Add("*Generated by Consolidated-UpgradeReport.ps1*")
$consolidatedReport.Add("")
$consolidatedReport.Add("---")

# Write the report
$reportPath = Join-Path $OutputDirectory "ConsolidatedUpgradeReport_$timestamp.md"
$consolidatedReport | Out-File -FilePath $reportPath -Encoding UTF8

Write-Progress -Activity "Consolidating Reports" -Status "Complete!" -PercentComplete 100

# Summary output
Write-Host "`n╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║              CONSOLIDATION COMPLETE                           ║" -ForegroundColor Green
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "📊 Summary:" -ForegroundColor White
Write-Host "   Servers Analyzed: $($allServers.Count)" -ForegroundColor Gray
Write-Host "   Total Workloads: $($allWorkloads.Count)" -ForegroundColor Gray
Write-Host "   Total Applications: $($allApplications.Count)" -ForegroundColor Gray
Write-Host ""
Write-Host "📁 Output Files:" -ForegroundColor White
Write-Host "   Consolidated Report: $reportPath" -ForegroundColor Cyan
Write-Host ""
Write-Host "🎯 Criticality Breakdown:" -ForegroundColor White
Write-Host "   CRITICAL: $($criticalitySummary.CRITICAL) servers" -ForegroundColor Red
Write-Host "   HIGH: $($criticalitySummary.HIGH) servers" -ForegroundColor Yellow
Write-Host "   MEDIUM: $($criticalitySummary.MEDIUM) servers" -ForegroundColor Gray
Write-Host "   LOW: $($criticalitySummary.LOW) servers" -ForegroundColor Gray
Write-Host ""

if ($criticalitySummary.CRITICAL -gt 0 -or $criticalitySummary.HIGH -gt 0) {
    Write-Host "⚠️  ATTENTION REQUIRED:" -ForegroundColor Red
    $topServers = $sortedServers | Where-Object { $_.Criticality -in @('CRITICAL', 'HIGH') } | Select-Object -First 5
    foreach ($srv in $topServers) {
        Write-Host "   - $($srv.ServerName) [$($srv.Criticality)] - $($srv.PrimaryRole)" -ForegroundColor Yellow
    }
    Write-Host ""
}

Write-Host "✅ Review the consolidated report for upgrade planning and prioritization." -ForegroundColor Green
Write-Host ""
