#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Creates per-server consolidated reports combining Discovery + Readiness data.

.DESCRIPTION
    For each server, combines:
    - ServerDocumentation-Discovery.ps1 output (technical analysis)
    - Readiness-Assessment.ps1 output (upgrade readiness, if exists)
    - Workloads CSV (detailed workload info)
    - Test Plan CSV (testing scenarios)
    - Applications CSV (installed apps)

    Creates TWO outputs:
    1. Per-server consolidated report (one per server)
    2. Master summary report (across all servers)

.PARAMETER InputDirectory
    Folder containing server reports. If not provided, will prompt for selection.

.PARAMETER OutputDirectory
    Where to save consolidated reports (default: ConsolidatedReports subfolder)

.EXAMPLE
    .\Consolidated-UpgradeReport.ps1
    Prompts for folder, then processes all servers

.EXAMPLE
    .\Consolidated-UpgradeReport.ps1 -InputDirectory "C:\ServerReports\2025Readiness"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$InputDirectory,
    
    [Parameter(Mandatory=$false)]
    [string]$OutputDirectory,
    
    [int]$DaysBack = 14
)

# Set default output directory
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $PSScriptRoot "ConsolidatedReports"
}

# Interactive folder selection
if ([string]::IsNullOrWhiteSpace($InputDirectory)) {
    Write-Host "`n📁 Server Reports Consolidation" -ForegroundColor Cyan
    Write-Host "`nSelect the folder containing server discovery reports.`n" -ForegroundColor Gray
    
    # Try Windows Forms first
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = "Select folder with ServerDocumentation_*.md files"
        $dialog.RootFolder = [System.Environment+SpecialFolder]::MyComputer
        
        # Default to script parent folder
        $parentPath = Split-Path $PSScriptRoot -Parent
        if (Test-Path $parentPath) {
            $dialog.SelectedPath = $parentPath
        }
        
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $InputDirectory = $dialog.SelectedPath
        } else {
            Write-Error "No folder selected. Exiting."
            exit 1
        }
    } catch {
        # Text fallback
        Write-Host "Enter folder path: " -NoNewline -ForegroundColor Yellow
        $InputDirectory = Read-Host
        if (-not (Test-Path $InputDirectory)) {
            Write-Error "Invalid path. Exiting."
            exit 1
        }
    }
}

# Validate input
if (-not (Test-Path $InputDirectory)) {
    Write-Error "Input directory not found: $InputDirectory"
    exit 1
}

# Create output folder
if (-not (Test-Path $OutputDirectory)) {
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
}

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$reportDate = Get-Date -Format "yyyy-MM-dd HH:mm"

Write-Host "`n╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║     SERVER UPGRADE READINESS - CONSOLIDATED REPORTS           ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host "Input:  $InputDirectory" -ForegroundColor Gray
Write-Host "Output: $OutputDirectory`n" -ForegroundColor Gray

# Scan for files
Write-Host "Scanning for server reports..." -ForegroundColor White

$discoveryFiles = Get-ChildItem -Path $InputDirectory -Filter "ServerDocumentation_*.md" -Recurse -ErrorAction SilentlyContinue
$readinessFiles = Get-ChildItem -Path $InputDirectory -Filter "Readiness_*.md" -Recurse -ErrorAction SilentlyContinue
$workloadFiles = Get-ChildItem -Path $InputDirectory -Filter "Workloads_*.csv" -Recurse -ErrorAction SilentlyContinue
$testPlanFiles = Get-ChildItem -Path $InputDirectory -Filter "TestPlan_*.csv" -Recurse -ErrorAction SilentlyContinue
$appFiles = Get-ChildItem -Path $InputDirectory -Filter "Applications_*.csv" -Recurse -ErrorAction SilentlyContinue

Write-Host "  Found: $($discoveryFiles.Count) Discovery, $($readinessFiles.Count) Readiness, $($workloadFiles.Count) Workloads, $($testPlanFiles.Count) Test Plans, $($appFiles.Count) Apps" -ForegroundColor Gray

# Group by server name
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
    Write-Error "No server reports found. Expected files like ServerDocumentation_SERVERNAME_*.md"
    exit 1
}

# Arrays for master summary
$allServerSummaries = New-Object 'System.Collections.Generic.List[object]'

# Process each server
$serverIndex = 0
foreach ($serverEntry in $serverData.GetEnumerator() | Sort-Object Key) {
    $serverName = $serverEntry.Key
    $files = $serverEntry.Value
    $serverIndex++
    
    Write-Progress -Activity "Processing Servers" -Status $serverName -PercentComplete (($serverIndex / $serverData.Count) * 100)
    Write-Host "Processing: $serverName" -ForegroundColor White
    
    # Build consolidated report for this server
    $report = New-Object 'System.Collections.Generic.List[string]'
    
    # Header
    $report.Add("# Consolidated Report: $serverName")
    $report.Add("")
    $report.Add("**Generated:** $reportDate  ")
    $report.Add("**Analysis Period:** Last $DaysBack days  ")
    $report.Add("")
    
    # Data Sources section
    $report.Add("## Data Sources")
    $report.Add("")
    $report.Add("| Type | File | Status |")
    $report.Add("|------|------|--------|")
    $report.Add("| Discovery | $(if($files.Discovery){$files.Discovery.Name}else{'Not found'}) | $(if($files.Discovery){'Present'}else{'Missing'}) |")
    $report.Add("| Readiness | $(if($files.Readiness){$files.Readiness.Name}else{'Not found'}) | $(if($files.Readiness){'Present'}else{'Optional'}) |")
    $report.Add("| Workloads | $(if($files.Workloads){$files.Workloads.Name}else{'Not found'}) | $(if($files.Workloads){'Present'}else{'Optional'}) |")
    $report.Add("| Test Plan | $(if($files.TestPlan){$files.TestPlan.Name}else{'Not found'}) | $(if($files.TestPlan){'Present'}else{'Optional'}) |")
    $report.Add("| Applications | $(if($files.Applications){$files.Applications.Name}else{'Not found'}) | $(if($files.Applications){'Present'}else{'Optional'}) |")
    $report.Add("")
    
    $criticality = "Unknown"
    $criticalScore = 0
    $role = "Unknown"
    $workloads = @()
    $userCount = 0
    $workloadDetails = @()
    $appDetails = @()
    
    # Parse Discovery data
    if ($files.Discovery) {
        try {
            $content = Get-Content $files.Discovery.FullName -Raw
            
            # Extract metrics
            if ($content -match '\*\*Criticality:\*\*\s*(\w+)') { $criticality = $Matches[1] }
            if ($content -match 'Score:\s*(\d+)') { $criticalScore = [int]$Matches[1] }
            if ($content -match '\*\*Primary Role:\*\*\s*([^\r\n]+)') { $role = $Matches[1].Trim() }
            if ($content -match '\*\*Unique Users:\*\*\s*(\d+)') { $userCount = [int]$Matches[1] }
            
            # Extract workload list
            $workloadMatches = [regex]::Matches($content, '- \[ \] \*\*([^\*]+):\*\*')
            $workloads = $workloadMatches | ForEach-Object { $_.Groups[1].Value.Trim() }
            
            $report.Add("---")
            $report.Add("")
            $report.Add("## Executive Summary")
            $report.Add("")
            $report.Add("- **Criticality:** $criticality (Score: $criticalScore)")
            $report.Add("- **Primary Role:** $role")
            $report.Add("- **Active Workloads:** $($workloads.Count)")
            $report.Add("- **Unique Users:** $userCount")
            $report.Add("")
            
            # Add summary sections from discovery
            if ($content -match '## Workload Analysis(?s)(.*?)## ') {
                $report.Add("### Workload Analysis")
                $report.Add("")
                $report.Add($Matches[1].Trim())
                $report.Add("")
            }
            
        } catch {
            Write-Warning "Could not parse discovery for $serverName"
        }
    }
    
    # Parse Workload CSV
    if ($files.Workloads) {
        try {
            $workloadDetails = Import-Csv $files.Workloads.FullName
            
            if ($workloadDetails.Count -gt 0) {
                $report.Add("## Detected Workloads")
                $report.Add("")
                $report.Add("| Workload | Criticality | Confidence |")
                $report.Add("|----------|-------------|------------|")
                
                foreach ($wl in $workloadDetails | Sort-Object Criticality -Descending | Select-Object -First 10) {
                    $evidence = if ($wl.Evidence.Length -gt 50) { $wl.Evidence.Substring(0,50) + "..." } else { $wl.Evidence }
                    $report.Add("| $($wl.Type) | $($wl.Criticality) | $($wl.Confidence) |")
                }
                $report.Add("")
            }
        } catch {
            Write-Warning "Could not parse workloads for $serverName"
        }
    }
    
    # Parse Applications
    if ($files.Applications) {
        try {
            $appDetails = Import-Csv $files.Applications.FullName
            $activeApps = $appDetails | Where-Object { $_.Status -eq 'Active' }
            
            if ($activeApps.Count -gt 0) {
                $report.Add("## Active Applications")
                $report.Add("")
                $report.Add("| Application | Version | Publisher | Priority |")
                $report.Add("|-------------|---------|-----------|----------|")
                
                foreach ($app in $activeApps | Select-Object -First 10) {
                    $report.Add("| $($app.Name) | $($app.Version) | $($app.Publisher) | $($app.TestPriority) |")
                }
                $report.Add("")
            }
        } catch {
            Write-Warning "Could not parse applications for $serverName"
        }
    }
    
    # Parse Test Plan
    if ($files.TestPlan) {
        try {
            $testData = Import-Csv $files.TestPlan.FullName
            
            if ($testData.Count -gt 0) {
                $report.Add("## Testing Checklist")
                $report.Add("")
                
                $priorityTests = $testData | Where-Object { $_.Criticality -in @('CRITICAL','HIGH') }
                foreach ($test in $priorityTests) {
                    $report.Add("- [ ] **$($test.Component):** $($test.TestScenario)")
                }
                $report.Add("")
            }
        } catch {
            Write-Warning "Could not parse test plan for $serverName"
        }
    }
    
    # Add full discovery content at the end
    if ($files.Discovery) {
        $report.Add("---")
        $report.Add("")
        $report.Add("## Full Discovery Report")
        $report.Add("")
        $report.Add("See: $($files.Discovery.FullName)")
        $report.Add("")
    }
    
    # Save per-server report
    $serverReportPath = Join-Path $OutputDirectory "Consolidated_${serverName}_${timestamp}.md"
    $report | Out-File -FilePath $serverReportPath -Encoding UTF8
    Write-Host "  ✓ Saved: $([System.IO.Path]::GetFileName($serverReportPath))" -ForegroundColor Green
    
    # Add to summary for master report
    $allServerSummaries.Add([PSCustomObject]@{
        ServerName = $serverName
        Criticality = $criticality
        Score = $criticalScore
        Role = $role
        Workloads = $workloads.Count
        Users = $userCount
        ReportFile = $serverReportPath
        HasDiscovery = ($files.Discovery -ne $null)
        HasReadiness = ($files.Readiness -ne $null)
    })
}

Write-Progress -Activity "Processing Servers" -Completed

# Generate Master Summary Report
Write-Host "`nGenerating master summary report..." -ForegroundColor White

$masterReport = New-Object 'System.Collections.Generic.List[string]'

$masterReport.Add("# Master Summary - Server Upgrade Readiness")
$masterReport.Add("")
$masterReport.Add("**Generated:** $reportDate  ")
$masterReport.Add("**Total Servers:** $($allServerSummaries.Count)  ")
$masterReport.Add("**Analysis Period:** Last $DaysBack days")
$masterReport.Add("")
$masterReport.Add("---")
$masterReport.Add("")

# Summary statistics
$critCount = ($allServerSummaries | Where-Object { $_.Criticality -eq 'CRITICAL' }).Count
$highCount = ($allServerSummaries | Where-Object { $_.Criticality -eq 'HIGH' }).Count
$medCount = ($allServerSummaries | Where-Object { $_.Criticality -eq 'MEDIUM' }).Count
$lowCount = ($allServerSummaries | Where-Object { $_.Criticality -eq 'LOW' }).Count

$masterReport.Add("## Environment Overview")
$masterReport.Add("")
$masterReport.Add("### Criticality Distribution")
$masterReport.Add("")
$masterReport.Add("| Level | Count | Percentage |")
$masterReport.Add("|-------|-------|------------|")

$total = $allServerSummaries.Count
if ($total -gt 0) {
    $masterReport.Add("| CRITICAL | $critCount | $([math]::Round(($critCount/$total)*100,1))% |")
    $masterReport.Add("| HIGH | $highCount | $([math]::Round(($highCount/$total)*100,1))% |")
    $masterReport.Add("| MEDIUM | $medCount | $([math]::Round(($medCount/$total)*100,1))% |")
    $masterReport.Add("| LOW | $lowCount | $([math]::Round(($lowCount/$total)*100,1))% |")
}
$masterReport.Add("")

# Server priority table
$masterReport.Add("## Server Priority List")
$masterReport.Add("")
$masterReport.Add("Servers ranked by criticality (highest first):")
$masterReport.Add("")
$masterReport.Add("| Priority | Server | Criticality | Score | Role | Workloads | Users | Report |")
$masterReport.Add("|----------|--------|-------------|-------|------|-----------|-------|--------|")

$sortedServers = $allServerSummaries | Sort-Object Score -Descending
$priority = 1
foreach ($srv in $sortedServers) {
    $reportFileName = [System.IO.Path]::GetFileName($srv.ReportFile)
    $masterReport.Add("| $priority | $($srv.ServerName) | $($srv.Criticality) | $($srv.Score) | $($srv.Role) | $($srv.Workloads) | $($srv.Users) | [$($srv.ServerName)]($reportFileName) |")
    $priority++
}
$masterReport.Add("")

# Phased upgrade plan
$masterReport.Add("## Recommended Upgrade Phases")
$masterReport.Add("")

if ($lowCount -gt 0) {
    $masterReport.Add("### Phase 1 - LOW Priority (Pilot)")
    $masterReport.Add("")
    $lowServers = $sortedServers | Where-Object { $_.Criticality -eq 'LOW' } | Select-Object -ExpandProperty ServerName
    $masterReport.Add("**Servers:** $($lowServers -join ', ')")
    $masterReport.Add("")
    $masterReport.Add("- Validate upgrade process")
    $masterReport.Add("- Identify issues early")
    $masterReport.Add("- Build confidence")
    $masterReport.Add("")
}

if ($medCount -gt 0) {
    $masterReport.Add("### Phase 2 - MEDIUM Priority")
    $medServers = $sortedServers | Where-Object { $_.Criticality -eq 'MEDIUM' } | Select-Object -ExpandProperty ServerName
    $masterReport.Add("**Servers:** $($medServers -join ', ')")
    $masterReport.Add("")
    $masterReport.Add("- Standard production upgrades")
    $masterReport.Add("- Use validated process")
    $masterReport.Add("")
}

if ($highCount -gt 0) {
    $masterReport.Add("### Phase 3 - HIGH Priority")
    $highServers = $sortedServers | Where-Object { $_.Criticality -eq 'HIGH' } | Select-Object -ExpandProperty ServerName
    $masterReport.Add("**Servers:** $($highServers -join ', ')")
    $masterReport.Add("")
    $masterReport.Add("- Important workloads")
    $masterReport.Add("- Extra testing recommended")
    $masterReport.Add("")
}

if ($critCount -gt 0) {
    $masterReport.Add("### Phase 4 - CRITICAL Priority")
    $critServers = $sortedServers | Where-Object { $_.Criticality -eq 'CRITICAL' } | Select-Object -ExpandProperty ServerName
    $masterReport.Add("**Servers:** $($critServers -join ', ')")
    $masterReport.Add("")
    $masterReport.Add("- Mission-critical systems")
    $masterReport.Add("- Maximum planning and testing")
    $masterReport.Add("- Maintenance windows required")
    $masterReport.Add("")
}

# Per-server links
$masterReport.Add("## Individual Server Reports")
$masterReport.Add("")
$masterReport.Add("Detailed consolidated reports for each server:")
$masterReport.Add("")

foreach ($srv in $sortedServers) {
    $reportFileName = [System.IO.Path]::GetFileName($srv.ReportFile)
    $dataTypes = @()
    if ($srv.HasDiscovery) { $dataTypes += "Discovery" }
    if ($srv.HasReadiness) { $dataTypes += "Readiness" }
    
    $masterReport.Add("- [$($srv.ServerName)]($reportFileName) - $($srv.Criticality) priority - $($dataTypes -join ' + ')")
}
$masterReport.Add("")

# Save master report
$masterPath = Join-Path $OutputDirectory "MASTER-Summary_${timestamp}.md"
$masterReport | Out-File -FilePath $masterPath -Encoding UTF8

Write-Host "`n✓ Master report saved: $([System.IO.Path]::GetFileName($masterPath))" -ForegroundColor Green
Write-Host "`n📊 Summary:" -ForegroundColor Cyan
Write-Host "   Per-server reports: $($allServerSummaries.Count)" -ForegroundColor White
Write-Host "   CRITICAL priority: $critCount" -ForegroundColor Red
Write-Host "   HIGH priority: $highCount" -ForegroundColor Yellow
Write-Host "   MEDIUM priority: $medCount" -ForegroundColor Gray
Write-Host "   LOW priority: $lowCount" -ForegroundColor Gray
Write-Host "`n📁 All reports saved to: $OutputDirectory" -ForegroundColor Cyan
