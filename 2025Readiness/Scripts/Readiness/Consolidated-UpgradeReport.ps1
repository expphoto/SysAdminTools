#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Consolidates server discovery and readiness reports per server and creates master summary.

.DESCRIPTION
    This script combines outputs from:
    - ServerDocumentation-Discovery.ps1 (server analysis)
    - Readiness-Assessment.ps1 (if it exists, upgrade readiness data)
    
    For each server, it creates a consolidated report combining both data sources.
    Also creates a master summary report across all servers.

    Files are matched by server name extracted from filenames:
    - ServerDocumentation_SERVERNAME_*.md
    - Readiness_SERVERNAME_*.md (optional)

.PARAMETER InputDirectory
    Directory containing discovery and readiness outputs.
    If not specified, will prompt for folder selection.

.PARAMETER OutputDirectory
    Directory for consolidated report output (default: ConsolidatedReports subfolder)

.PARAMETER DaysBack
    Analysis window in days (default: 14)

.EXAMPLE
    .\Consolidated-UpgradeReport.ps1
    Prompts for input folder, then generates consolidated reports

.EXAMPLE
    .\Consolidated-UpgradeReport.ps1 -InputDirectory "C:\ServerReports\2025Readiness"
    Uses specified folder without prompting

.EXAMPLE
    .\Consolidated-UpgradeReport.ps1 -InputDirectory "C:\Reports" -OutputDirectory "C:\UpgradePlan"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$InputDirectory,
    
    [Parameter(Mandatory=$false)]
    [string]$OutputDirectory = (Join-Path $PSScriptRoot "ConsolidatedReports"),
    
    [int]$DaysBack = 14
)

# Interactive folder selection if not provided
if ([string]::IsNullOrWhiteSpace($InputDirectory)) {
    Write-Host "`n📁 Select Input Directory" -ForegroundColor Cyan
    Write-Host "This should be the folder containing server discovery reports.`n" -ForegroundColor Gray
    
    # Try to use Windows Forms folder browser (if on Windows with GUI)
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $folderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog
        $folderBrowser.Description = "Select folder containing ServerDocumentation_*.md files"
        $folderBrowser.RootFolder = [System.Environment+SpecialFolder]::MyComputer
        
        # Try to set default to parent of script location
        $defaultPath = Join-Path $PSScriptRoot ".."
        if (Test-Path $defaultPath) {
            $folderBrowser.SelectedPath = (Resolve-Path $defaultPath).Path
        }
        
        $result = $folderBrowser.ShowDialog()
        if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
            $InputDirectory = $folderBrowser.SelectedPath
        } else {
            Write-Warning "No folder selected. Exiting."
            exit 1
        }
    } catch {
        # Fallback to text input if Windows Forms not available
        Write-Host "Enter the full path to the folder containing server reports:" -ForegroundColor Yellow
        $InputDirectory = Read-Host "Folder path"
        if ([string]::IsNullOrWhiteSpace($InputDirectory) -or -not (Test-Path $InputDirectory)) {
            Write-Warning "Invalid path. Exiting."
            exit 1
        }
    }
} elseif (-not (Test-Path $InputDirectory)) {
    Write-Warning "Input directory not found: $InputDirectory"
    exit 1
}

# Initialize
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$reportDate = Get-Date -Format "yyyy-MM-dd HH:mm"

# Ensure output directory exists
if (-not (Test-Path $OutputDirectory)) {
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
}

Write-Host "`n╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║     SERVER UPGRADE READINESS - CONSOLIDATED REPORTS           ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host "Input Folder: $InputDirectory" -ForegroundColor White
Write-Host "Output Folder: $OutputDirectory" -ForegroundColor White
Write-Host "Analysis Period: Last $DaysBack days`n" -ForegroundColor Gray

# Find all discovery and readiness outputs
Write-Progress -Activity "Scanning" -Status "Looking for server reports..." -PercentComplete 10

# Look for various report types
$discoveryMdFiles = Get-ChildItem -Path $InputDirectory -Filter "ServerDocumentation_*.md" -Recurse -ErrorAction SilentlyContinue
$readinessMdFiles = Get-ChildItem -Path $InputDirectory -Filter "Readiness_*.md" -Recurse -ErrorAction SilentlyContinue
$workloadCsvs = Get-ChildItem -Path $InputDirectory -Filter "Workloads_*.csv" -Recurse -ErrorAction SilentlyContinue
$testPlanCsvs = Get-ChildItem -Path $InputDirectory -Filter "TestPlan_*.csv" -Recurse -ErrorAction SilentlyContinue
$appCsvs = Get-ChildItem -Path $InputDirectory -Filter "Applications_*.csv" -Recurse -ErrorAction SilentlyContinue

# Group files by server name
$serversWithData = @{}

# Process discovery files
foreach ($file in $discoveryMdFiles) {
    # Extract server name from filename: ServerDocumentation_SERVERNAME_2025*.md
    if ($file.BaseName -match '^ServerDocumentation_([^_]+)_') {
        $serverName = $Matches[1]
        if (-not $serversWithData.ContainsKey($serverName)) {
            $serversWithData[$serverName] = @{
                DiscoveryFile = $file
                ReadinessFile = $null
                WorkloadCsv = $null
                TestPlanCsv = $null
                AppCsv = $null
            }
        } else {
            $serversWithData[$serverName].DiscoveryFile = $file
        }
    }
}

# Process readiness files and match to servers
foreach ($file in $readinessMdFiles) {
    if ($file.BaseName -match '^Readiness_([^_]+)_') {
        $serverName = $Matches[1]
        if (-not $serversWithData.ContainsKey($serverName)) {
            $serversWithData[$serverName] = @{
                DiscoveryFile = $null
                ReadinessFile = $file
                WorkloadCsv = $null
                TestPlanCsv = $null
                AppCsv = $null
            }
        } else {
            $serversWithData[$serverName].ReadinessFile = $file
        }
    }
}

# Process CSVs and match by server name
foreach ($file in $workloadCsvs) {
    if ($file.BaseName -match '^Workloads_([^_]+)_') {
        $serverName = $Matches[1]
        if (-not $serversWithData.ContainsKey($serverName)) {
            $serversWithData[$serverName] = @{
                DiscoveryFile = $null
                ReadinessFile = $null
                WorkloadCsv = $file
                TestPlanCsv = $null
                AppCsv = $null
            }
        } else {
            $serversWithData[$serverName].WorkloadCsv = $file
        }
    }
}

foreach ($file in $testPlanCsvs) {
    if ($file.BaseName -match '^TestPlan_([^_]+)_') {
        $serverName = $Matches[1]
        if (-not $serversWithData.ContainsKey($serverName)) {
            $serversWithData[$serverName] = @{
                DiscoveryFile = $null
                ReadinessFile = $null
                WorkloadCsv = $null
                TestPlanCsv = $file
                AppCsv = $null
            }
        } else {
            $serversWithData[$serverName].TestPlanCsv = $file
        }
    }
}

foreach ($file in $appCsvs) {
    if ($file.BaseName -match '^Applications_([^_]+)_') {
        $serverName = $Matches[1]
        if (-not $serversWithData.ContainsKey($serverName)) {
            $serversWithData[$serverName] = @{
                DiscoveryFile = $null
                ReadinessFile = $null
                WorkloadCsv = $null
                TestPlanCsv = $null
                AppCsv = $file
            }
        } else {
            $serversWithData[$serverName].AppCsv = $file
        }
    }
}

Write-Host "Found Data For:" -ForegroundColor White
Write-Host "  - $($discoveryMdFiles.Count) Discovery reports (.md)" -ForegroundColor Gray
Write-Host "  - $($readinessMdFiles.Count) Readiness reports (.md)" -ForegroundColor Gray
Write-Host "  - $($workloadCsvs.Count) Workload files (.csv)" -ForegroundColor Gray
Write-Host "  - $($testPlanCsvs.Count) Test plan files (.csv)" -ForegroundColor Gray
Write-Host "  - $($appCsvs.Count) Application files (.csv)" -ForegroundColor Gray
Write-Host "  - $($serversWithData.Count) unique servers identified" -ForegroundColor White
Write-Host ""

if ($serversWithData.Count -eq 0) {
    Write-Warning "No server reports found in $InputDirectory"
    Write-Host "Expected files like:" -ForegroundColor Yellow
    Write-Host "  - ServerDocumentation_SERVERNAME_*.md" -ForegroundColor Gray
    Write-Host "  - Readiness_SERVERNAME_*.md (optional)" -ForegroundColor Gray
    Write-Host "  - Workloads_SERVERNAME_*.csv (optional)" -ForegroundColor Gray
    exit 1
}
        
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
