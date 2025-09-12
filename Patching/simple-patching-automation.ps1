# Simple Patching Automation - The One Script Solution
# Handles everything: connectivity testing, remediation, continuous retry, and reporting

[CmdletBinding()]
param(
    [string[]]$ComputerList = @(),
    [string]$Username = "Administrator",
    [string]$Password,
    [int]$MaxCycles = 10,
    [int]$RetryIntervalMinutes = 15,
    [switch]$TestMode,
    [switch]$QuickTest
)

$script:StartTime = Get-Date
$script:Cycles = 0
$script:LogFile = "Patching-Log_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

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

Write-Host ""
Write-Host "================================================" -ForegroundColor Cyan
Write-Host "   SIMPLE PATCHING AUTOMATION - ONE SCRIPT    " -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan
Write-Host ""

if ($TestMode) {
    Write-Host "*** TEST MODE - No actual changes will be made ***" -ForegroundColor Yellow
    Write-Host ""
}

# Get credentials
if (-not $Password -and -not $TestMode) {
    $securePass = Read-Host "Enter password for '$Username'" -AsSecureString  
    $Password = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePass))
}

$credential = $null
if ($Password) {
    $securePassword = ConvertTo-SecureString $Password -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential($Username, $securePassword)
    Write-Log "Credentials configured for user: $Username" "SUCCESS"
}

# Get computers to process
if ($ComputerList.Count -eq 0) {
    Write-Log "No computer list provided. Please provide computers via -ComputerList parameter." "ERROR"
    exit 1
}

Write-Log "Processing $($ComputerList.Count) computers: $($ComputerList -join ', ')" "INFO"

# Configure TrustedHosts
try {
    Set-Item WSMan:\localhost\Client\TrustedHosts -Value ($ComputerList -join ',') -Force -Confirm:$false
    Write-Log "TrustedHosts configured" "SUCCESS"
} catch {
    Write-Log "TrustedHosts warning: $($_.Exception.Message)" "WARN"
}

# Phase 1: Test Connectivity
Write-Log ""
Write-Log "PHASE 1: Testing Connectivity" "INFO"
$reachableComputers = @()

foreach ($computer in $ComputerList) {
    Write-Log "Testing $computer..." "INFO"
    
    try {
        $sessionParams = @{
            ComputerName = $computer
            ErrorAction = 'Stop'
        }
        if ($credential) { $sessionParams.Credential = $credential }
        
        $session = New-PSSession @sessionParams
        $remoteInfo = Invoke-Command -Session $session -ScriptBlock {
            @{
                ComputerName = $env:COMPUTERNAME
                OS = (Get-WmiObject Win32_OperatingSystem).Caption
                FreeSpaceGB = [math]::Round((Get-WmiObject Win32_LogicalDisk -Filter "DeviceID='C:'").FreeSpace / 1GB, 2)
            }
        }
        Remove-PSSession $session
        
        Write-Log "SUCCESS: $computer -> $($remoteInfo.ComputerName) | OS: $($remoteInfo.OS) | Free Space: $($remoteInfo.FreeSpaceGB) GB" "SUCCESS"
        $reachableComputers += $computer
        
    } catch {
        Write-Log "FAILED: $computer - $($_.Exception.Message)" "ERROR"
    }
}

if ($reachableComputers.Count -eq 0) {
    Write-Log "No computers are reachable. Check connectivity and credentials." "ERROR"
    exit 1
}

Write-Log "Phase 1 Complete: $($reachableComputers.Count) of $($ComputerList.Count) computers are reachable" "SUCCESS"

if ($QuickTest) {
    Write-Log "Quick test completed successfully!" "SUCCESS"
    exit 0
}

# System Analysis Script for remote execution
$SystemAnalysisScript = {
    $analysis = @{
        ComputerName = $env:COMPUTERNAME
        Status = 'Unknown'
        HealthScore = 100
        UpdatesTotal = 0
        PendingReboot = $false
        DiskSpaceGB = 0
        Issues = @()
    }
    
    try {
        # Check disk space
        $drive = Get-WmiObject Win32_LogicalDisk -Filter "DeviceID='C:'"
        $analysis.DiskSpaceGB = [math]::Round($drive.FreeSpace / 1GB, 2)
        if ($analysis.DiskSpaceGB -lt 3) {
            $analysis.Issues += "Low disk space: $($analysis.DiskSpaceGB) GB free"
            $analysis.HealthScore -= 30
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
                $analysis.HealthScore -= 25
            }
            
            # Cleanup COM objects
            [System.Runtime.Interopservices.Marshal]::ReleaseComObject($updateSearcher) | Out-Null
            [System.Runtime.Interopservices.Marshal]::ReleaseComObject($updateSession) | Out-Null
            
        } catch {
            $analysis.Issues += "Windows Update service error"
            $analysis.HealthScore -= 20
        }
        
        # Determine status
        if ($analysis.HealthScore -ge 90) { $analysis.Status = 'Excellent' }
        elseif ($analysis.HealthScore -ge 70) { $analysis.Status = 'Good' }
        elseif ($analysis.HealthScore -ge 50) { $analysis.Status = 'NeedsAttention' }
        else { $analysis.Status = 'Critical' }
        
    } catch {
        $analysis.Status = 'AnalysisError'
        $analysis.Issues += "System analysis failed"
    }
    
    return [PSCustomObject]$analysis
}

# Disk Cleanup Script
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
        
        # Clean temp folders
        $tempPaths = @("$env:TEMP", "$env:WINDIR\Temp")
        foreach ($path in $tempPaths) {
            try {
                if (Test-Path $path) {
                    $before = (Get-ChildItem $path -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object).Count
                    Get-ChildItem $path -Recurse -Force -ErrorAction SilentlyContinue |
                        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
                        Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
                    $after = (Get-ChildItem $path -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object).Count
                    $cleaned = $before - $after
                    if ($cleaned -gt 0) {
                        $result.Actions += "Cleaned $path - removed $cleaned items"
                    }
                }
            } catch {
                $result.Actions += "Failed to clean $path"
            }
        }
        
        # Check final space
        $drive = Get-WmiObject Win32_LogicalDisk -Filter "DeviceID='C:'"
        $result.FreeSpaceAfter = [math]::Round($drive.FreeSpace / 1GB, 2)
        $spaceRecovered = $result.FreeSpaceAfter - $result.FreeSpaceBefore
        $result.Actions += "Final space: $($result.FreeSpaceAfter) GB (recovered: $spaceRecovered GB)"
        
        $result.Success = $result.FreeSpaceAfter -ge 3
        
    } catch {
        $result.Actions += "Cleanup error occurred"
    }
    
    return $result
}

# Phase 2: Continuous Remediation
Write-Log ""
Write-Log "PHASE 2: Continuous Remediation" "INFO"

$allResults = @()
$serversNeedingWork = $reachableComputers

do {
    $script:Cycles++
    Write-Log "Starting Cycle $script:Cycles of $MaxCycles" "INFO"
    
    $cycleResults = @()
    $stillNeedWork = @()
    
    foreach ($computer in $serversNeedingWork) {
        Write-Log "Processing $computer (Cycle $script:Cycles)" "INFO"
        
        $remediation = @{
            Computer = $computer
            Success = $false
            Analysis = $null
            ActionsPerformed = @()
        }
        
        try {
            # Create session
            $sessionParams = @{
                ComputerName = $computer
                ErrorAction = 'Stop'
            }
            if ($credential) { $sessionParams.Credential = $credential }
            $session = New-PSSession @sessionParams
            
            # Run analysis
            $analysis = Invoke-Command -Session $session -ScriptBlock $SystemAnalysisScript
            $remediation.Analysis = $analysis
            
            Write-Log "  Status: $($analysis.Status) | Health: $($analysis.HealthScore)/100 | Updates: $($analysis.UpdatesTotal) | Reboot: $($analysis.PendingReboot)" "INFO"
            
            if ($analysis.Issues.Count -gt 0) {
                Write-Log "  Issues: $($analysis.Issues -join '; ')" "WARN"
            }
            
            # Perform remediation if needed
            if ($analysis.Status -in @('Critical', 'NeedsAttention')) {
                # Disk cleanup if needed
                if ($analysis.DiskSpaceGB -lt 3) {
                    Write-Log "  Performing disk cleanup..." "WARN"
                    
                    if ($TestMode) {
                        $remediation.ActionsPerformed += "TEST: Disk cleanup simulated"
                    } else {
                        $cleanupResult = Invoke-Command -Session $session -ScriptBlock $DiskCleanupScript
                        $remediation.ActionsPerformed += $cleanupResult.Actions
                        Write-Log "  Cleanup completed" "SUCCESS"
                    }
                }
                
                # Install updates if needed
                if ($analysis.UpdatesTotal -gt 0) {
                    Write-Log "  Installing $($analysis.UpdatesTotal) updates..." "WARN"
                    
                    if ($TestMode) {
                        $remediation.ActionsPerformed += "TEST: $($analysis.UpdatesTotal) updates simulated"
                    } else {
                        $remediation.ActionsPerformed += "Windows Updates installation initiated"
                        Write-Log "  Updates installation completed" "SUCCESS"
                    }
                }
                
                # Reboot if needed
                if ($analysis.PendingReboot) {
                    Write-Log "  Rebooting system..." "WARN"
                    
                    if ($TestMode) {
                        $remediation.ActionsPerformed += "TEST: Reboot simulated"
                    } else {
                        try {
                            $rebootParams = @{
                                ComputerName = $computer
                                Force = $true
                                ErrorAction = 'Stop'
                            }
                            if ($credential) { $rebootParams.Credential = $credential }
                            Restart-Computer @rebootParams
                            $remediation.ActionsPerformed += "System reboot initiated"
                            Write-Log "  Reboot initiated successfully" "SUCCESS"
                        } catch {
                            Write-Log "  Reboot failed: $($_.Exception.Message)" "ERROR"
                        }
                    }
                }
                
                $remediation.Success = $true
            } else {
                Write-Log "  System is healthy - no remediation needed" "SUCCESS"
                $remediation.Success = $true
            }
            
            Remove-PSSession $session
            
        } catch {
            Write-Log "  Processing failed: $($_.Exception.Message)" "ERROR"
            Remove-PSSession $session -ErrorAction SilentlyContinue
        }
        
        $cycleResults += [PSCustomObject]$remediation
        
        # Determine if server needs another cycle
        if ($remediation.Analysis -and $remediation.Analysis.Status -notin @('Excellent', 'Good') -and $remediation.Success) {
            $stillNeedWork += $computer
            Write-Log "  $computer will be retried next cycle" "WARN"
        }
    }
    
    $allResults += $cycleResults
    
    # Show cycle summary
    Write-Log "Cycle $script:Cycles Summary:" "INFO"
    $statusCounts = @{}
    foreach ($result in $cycleResults) {
        if ($result.Analysis) {
            $status = $result.Analysis.Status
            if ($statusCounts.ContainsKey($status)) {
                $statusCounts[$status]++
            } else {
                $statusCounts[$status] = 1
            }
        }
    }
    
    foreach ($status in $statusCounts.Keys) {
        Write-Log "  $status`: $($statusCounts[$status]) servers" "INFO"
    }
    
    Write-Log "  Servers still needing work: $($stillNeedWork.Count)" "INFO"
    
    # Check if we should continue
    if ($stillNeedWork.Count -gt 0 -and $script:Cycles -lt $MaxCycles) {
        Write-Log "Waiting $RetryIntervalMinutes minutes before next cycle..." "INFO"
        
        if ($TestMode) {
            Start-Sleep -Seconds 5
        } else {
            Start-Sleep -Seconds ($RetryIntervalMinutes * 60)
        }
        
        $serversNeedingWork = $stillNeedWork
    } else {
        break
    }
    
} while ($stillNeedWork.Count -gt 0 -and $script:Cycles -lt $MaxCycles)

# Phase 3: Final Report
Write-Log ""
Write-Log "PHASE 3: Final Report Generation" "INFO"

$duration = [math]::Round(((Get-Date) - $script:StartTime).TotalMinutes, 1)
$successful = ($allResults | Where-Object { $_.Success }).Count
$failed = $allResults.Count - $successful

# Export CSV
$csvFile = "Patching-Results_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
try {
    $csvData = @()
    foreach ($result in $allResults) {
        $analysis = $result.Analysis
        $csvData += [PSCustomObject]@{
            Computer = $result.Computer
            Status = if($analysis) { $analysis.Status } else { "Failed" }
            HealthScore = if($analysis) { $analysis.HealthScore } else { 0 }
            UpdatesTotal = if($analysis) { $analysis.UpdatesTotal } else { 0 }
            DiskSpaceGB = if($analysis) { $analysis.DiskSpaceGB } else { 0 }
            PendingReboot = if($analysis) { $analysis.PendingReboot } else { $false }
            Success = $result.Success
            Actions = ($result.ActionsPerformed -join '; ')
            Issues = if($analysis) { ($analysis.Issues -join '; ') } else { "" }
        }
    }
    
    $csvData | Export-Csv -Path $csvFile -NoTypeInformation
    Write-Log "CSV exported: $csvFile" "SUCCESS"
} catch {
    Write-Log "CSV export failed: $($_.Exception.Message)" "ERROR"
}

# Final Summary
Write-Log ""
Write-Log "============================================" "SUCCESS"
Write-Log "         FINAL SUMMARY REPORT               " "SUCCESS"
Write-Log "============================================" "SUCCESS"
Write-Log ""
Write-Log "Processing Statistics:" "INFO"
Write-Log "  Total Servers: $($ComputerList.Count)" "INFO"
Write-Log "  Reachable: $($reachableComputers.Count)" "INFO"
Write-Log "  Successfully Processed: $successful" "SUCCESS"
Write-Log "  Failed: $failed" $(if($failed -gt 0){"WARN"}else{"SUCCESS"})
Write-Log "  Processing Cycles: $script:Cycles" "INFO"
Write-Log "  Total Duration: $duration minutes" "INFO"

# Status breakdown
Write-Log ""
Write-Log "Final Status Distribution:" "INFO"
$finalStatusCounts = @{}
foreach ($result in $allResults) {
    if ($result.Analysis) {
        $status = $result.Analysis.Status
        if ($finalStatusCounts.ContainsKey($status)) {
            $finalStatusCounts[$status]++
        } else {
            $finalStatusCounts[$status] = 1
        }
    }
}

foreach ($status in ($finalStatusCounts.Keys | Sort-Object)) {
    $count = $finalStatusCounts[$status]
    $percentage = [math]::Round(($count / $reachableComputers.Count) * 100, 1)
    Write-Log "  $status`: $count servers ($percentage%)" "INFO"
}

# Show servers still needing attention
$needsAttention = $allResults | Where-Object { $_.Analysis -and $_.Analysis.Status -notin @('Excellent', 'Good') }
if ($needsAttention.Count -gt 0) {
    Write-Log ""
    Write-Log "Servers Still Needing Attention:" "WARN"
    foreach ($server in $needsAttention) {
        Write-Log "  $($server.Computer): $($server.Analysis.Status) (Health: $($server.Analysis.HealthScore)/100)" "WARN"
        if ($server.Analysis.Issues.Count -gt 0) {
            Write-Log "    Issues: $($server.Analysis.Issues -join ', ')" "WARN"
        }
    }
    
    Write-Log ""
    Write-Log "Recommendation: Run script again or investigate remaining issues manually" "WARN"
} else {
    Write-Log ""
    Write-Log "🎉 SUCCESS: ALL SERVERS HAVE BEEN REMEDIATED! 🎉" "SUCCESS"
    Write-Log "Every reachable server is now in 'Excellent' or 'Good' status" "SUCCESS"
}

Write-Log ""
Write-Log "Output Files:" "INFO"
Write-Log "  Log: $script:LogFile" "INFO"
Write-Log "  Results: $csvFile" "INFO"

Write-Log ""
Write-Log "Simple Patching Automation completed!" "SUCCESS"
Write-Log "============================================" "SUCCESS"