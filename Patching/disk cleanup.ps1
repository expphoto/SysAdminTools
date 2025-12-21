<#
.SYNOPSIS
    Automated disk cleanup and Windows Update trigger for remote servers
.DESCRIPTION
    Safely clears disk space and re-triggers Windows updates on remote servers.
    Production-safe with error handling, logging, and no automatic reboots.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string[]]$ServerNamesParam,

    [Parameter(Mandatory=$false)]
    [PSCredential]$Credential,

    [Parameter(Mandatory=$false)]
    [string]$LogPath = "C:\Temp\DiskCleanup-Updates-Log_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
)

# =================== EDIT HERE ===================
# Comma-separated list of servers to process
$ServerNames = @(
    "SERVER01","SERVER02","SERVER03"
)
# =================================================

# If server names provided via parameter, use those instead
if ($PSBoundParameters.ContainsKey('ServerNamesParam') -and $ServerNamesParam) {
    $ServerNames = $ServerNamesParam
}

# Function to write log entries
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    Write-Host $logMessage
    Add-Content -Path $LogPath -Value $logMessage -ErrorAction SilentlyContinue
}

# Function to get disk space info
function Get-DiskSpaceInfo {
    param([string]$ServerName)
    try {
        $scriptBlock = {
            $drive = Get-PSDrive C -ErrorAction Stop
            [PSCustomObject]@{
                FreeSpaceGB = [math]::Round($drive.Free / 1GB, 2)
                UsedSpaceGB = [math]::Round($drive.Used / 1GB, 2)
                TotalSpaceGB = [math]::Round(($drive.Free + $drive.Used) / 1GB, 2)
                PercentFree = [math]::Round(($drive.Free / ($drive.Free + $drive.Used)) * 100, 2)
            }
        }
        
        if ($ServerName -eq $env:COMPUTERNAME) {
            & $scriptBlock
        } else {
            $params = @{ComputerName = $ServerName; ScriptBlock = $scriptBlock}
            if ($Credential) { $params.Credential = $Credential }
            Invoke-Command @params
        }
    } catch {
        Write-Log "Failed to get disk space info for $ServerName : $_" "ERROR"
        return $null
    }
}

# Function to perform safe disk cleanup
function Invoke-SafeDiskCleanup {
    param([string]$ServerName)
    
    $cleanupScript = {
        $results = @()
        
        # 1. Clear Windows Temp folder
        try {
            $tempPath = "$env:SystemRoot\Temp\*"
            $before = (Get-ChildItem $tempPath -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum / 1MB
            Get-ChildItem $tempPath -Recurse -Force -ErrorAction SilentlyContinue | 
                Where-Object { !$_.PSIsContainer -and $_.LastWriteTime -lt (Get-Date).AddDays(-7) } | 
                Remove-Item -Force -ErrorAction SilentlyContinue
            $after = (Get-ChildItem $tempPath -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum / 1MB
            $results += "Windows Temp: Cleared $([math]::Round($before - $after, 2)) MB"
        } catch {
            $results += "Windows Temp: Error - $_"
        }
        
        # 2. Clear Windows Update Cache (SoftwareDistribution\Download)
        try {
            $downloadPath = "$env:SystemRoot\SoftwareDistribution\Download\*"
            $before = (Get-ChildItem $downloadPath -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum / 1MB
            Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
            Get-ChildItem $downloadPath -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            Start-Service wuauserv -ErrorAction SilentlyContinue
            $after = (Get-ChildItem $downloadPath -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum / 1MB
            $results += "WU Download Cache: Cleared $([math]::Round($before - $after, 2)) MB"
        } catch {
            Start-Service wuauserv -ErrorAction SilentlyContinue
            $results += "WU Download Cache: Error - $_"
        }
        
        # 3. Run DISM cleanup for superseded components
        try {
            $dismResult = & Dism.exe /online /Cleanup-Image /StartComponentCleanup /ResetBase /Quiet
            $results += "DISM Component Cleanup: Completed"
        } catch {
            $results += "DISM Component Cleanup: Error - $_"
        }
        
        # 4. Clear old Windows logs (older than 30 days)
        try {
            $logsPath = "$env:SystemRoot\Logs"
            $before = (Get-ChildItem $logsPath -Recurse -Filter "*.log" -ErrorAction SilentlyContinue | 
                       Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } | 
                       Measure-Object -Property Length -Sum).Sum / 1MB
            Get-ChildItem $logsPath -Recurse -Filter "*.log" -ErrorAction SilentlyContinue | 
                Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } | 
                Remove-Item -Force -ErrorAction SilentlyContinue
            $results += "Old Windows Logs: Cleared $([math]::Round($before, 2)) MB"
        } catch {
            $results += "Old Windows Logs: Error - $_"
        }
        
        # 5. Run Windows Disk Cleanup with safe options
        try {
            # Configure StateFlags for safe cleanup
            $volumeCaches = @(
                'Active Setup Temp Folders',
                'Downloaded Program Files',
                'Internet Cache Files',
                'Old ChkDsk Files',
                'Recycle Bin',
                'Setup Log Files',
                'Temporary Files',
                'Temporary Setup Files',
                'Thumbnail Cache',
                'Update Cleanup',
                'Windows Error Reporting Files',
                'Windows Upgrade Log Files'
            )
            
            foreach ($cache in $volumeCaches) {
                $regPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches\$cache"
                if (Test-Path $regPath) {
                    Set-ItemProperty -Path $regPath -Name StateFlags0100 -Value 2 -Type DWord -ErrorAction SilentlyContinue
                }
            }
            
            $cleanmgrProcess = Start-Process -FilePath cleanmgr.exe -ArgumentList "/sagerun:100" -Wait -PassThru -WindowStyle Hidden
            $results += "CleanMgr: Completed with exit code $($cleanmgrProcess.ExitCode)"
        } catch {
            $results += "CleanMgr: Error - $_"
        }
        
        return $results
    }
    
    try {
        Write-Log "Starting disk cleanup on $ServerName..." "INFO"
        
        if ($ServerName -eq $env:COMPUTERNAME) {
            $cleanupResults = & $cleanupScript
        } else {
            $params = @{ComputerName = $ServerName; ScriptBlock = $cleanupScript}
            if ($Credential) { $params.Credential = $Credential }
            $cleanupResults = Invoke-Command @params
        }
        
        foreach ($result in $cleanupResults) {
            Write-Log "  $result" "INFO"
        }
        return $true
    } catch {
        Write-Log "Disk cleanup failed for $ServerName : $_" "ERROR"
        return $false
    }
}

# Function to trigger Windows Updates
function Invoke-WindowsUpdateTrigger {
    param([string]$ServerName)
    
    $updateScript = {
        $results = @()
        
        try {
            # Stop Windows Update service
            Stop-Service wuauserv -Force -ErrorAction Stop
            $results += "Windows Update service stopped"
            
            # Clear Windows Update qmgr files
            $qmgrPath = "$env:ALLUSERSPROFILE\Microsoft\Network\Downloader\qmgr*.dat"
            if (Test-Path $qmgrPath) {
                Remove-Item $qmgrPath -Force -ErrorAction SilentlyContinue
                $results += "Cleared BITS queue files"
            }
            
            # Start Windows Update service
            Start-Service wuauserv -ErrorAction Stop
            $results += "Windows Update service started"
            
            # Trigger Windows Update detection
            $updateSession = New-Object -ComObject Microsoft.Update.Session
            $updateSearcher = $updateSession.CreateUpdateSearcher()
            $results += "Windows Update detection triggered"
            
            # Use wuauclt/UsoClient to force update check (compatible with different Windows versions)
            if (Test-Path "$env:SystemRoot\System32\UsoClient.exe") {
                Start-Process -FilePath "$env:SystemRoot\System32\UsoClient.exe" -ArgumentList "StartScan" -NoNewWindow -ErrorAction SilentlyContinue
                $results += "UsoClient scan initiated (Windows 10/11/Server 2016+)"
            } else {
                Start-Process -FilePath "$env:SystemRoot\System32\wuauclt.exe" -ArgumentList "/detectnow" -NoNewWindow -ErrorAction SilentlyContinue
                $results += "wuauclt detection initiated (legacy)"
            }
            
            return @{Success = $true; Results = $results}
        } catch {
            return @{Success = $false; Results = $results; Error = $_.Exception.Message}
        }
    }
    
    try {
        Write-Log "Triggering Windows Updates on $ServerName..." "INFO"
        
        if ($ServerName -eq $env:COMPUTERNAME) {
            $updateResults = & $updateScript
        } else {
            $params = @{ComputerName = $ServerName; ScriptBlock = $updateScript}
            if ($Credential) { $params.Credential = $Credential }
            $updateResults = Invoke-Command @params
        }
        
        foreach ($result in $updateResults.Results) {
            Write-Log "  $result" "INFO"
        }
        
        if (-not $updateResults.Success) {
            Write-Log "  Error: $($updateResults.Error)" "ERROR"
            return $false
        }
        return $true
    } catch {
        Write-Log "Windows Update trigger failed for $ServerName : $_" "ERROR"
        return $false
    }
}

# Main execution
Write-Log "=== Disk Cleanup and Windows Update Automation Script Started ===" "INFO"

# Create log directory if it doesn't exist
$logDir = Split-Path $LogPath -Parent
if (-not (Test-Path $logDir)) {
    New-Item -Path $logDir -ItemType Directory -Force | Out-Null
}

# Validate server names
if (-not $ServerNames -or $ServerNames.Count -eq 0) {
    Write-Log "No server names configured. Please edit the server list at the top of the script." "ERROR"
    exit 1
}

Write-Log "Processing $($ServerNames.Count) server(s): $($ServerNames -join ', ')" "INFO"

# Process each server
$summary = @()
foreach ($server in $ServerNames) {
    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "Processing: $server" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    
    $serverResult = [PSCustomObject]@{
        ServerName = $server
        Available = $false
        DiskCleanup = "Not Run"
        UpdateTrigger = "Not Run"
        SpaceBefore = "N/A"
        SpaceAfter = "N/A"
        SpaceReclaimed = "N/A"
    }
    
    # Test connectivity
    Write-Log "Testing connectivity to $server..." "INFO"
    $testConnection = Test-Connection -ComputerName $server -Count 1 -Quiet -ErrorAction SilentlyContinue
    
    if (-not $testConnection) {
        Write-Log "$server is not reachable" "ERROR"
        $summary += $serverResult
        continue
    }
    
    $serverResult.Available = $true
    Write-Log "$server is reachable" "INFO"
    
    # Get disk space before
    $spaceBefore = Get-DiskSpaceInfo -ServerName $server
    if ($spaceBefore) {
        $serverResult.SpaceBefore = "$($spaceBefore.FreeSpaceGB) GB ($($spaceBefore.PercentFree)% free)"
        Write-Log "Disk space before: $($serverResult.SpaceBefore)" "INFO"
    }
    
    # Perform disk cleanup
    $cleanupSuccess = Invoke-SafeDiskCleanup -ServerName $server
    $serverResult.DiskCleanup = if ($cleanupSuccess) { "Success" } else { "Failed" }
    
    # Get disk space after cleanup
    Start-Sleep -Seconds 5
    $spaceAfter = Get-DiskSpaceInfo -ServerName $server
    if ($spaceAfter) {
        $serverResult.SpaceAfter = "$($spaceAfter.FreeSpaceGB) GB ($($spaceAfter.PercentFree)% free)"
        Write-Log "Disk space after: $($serverResult.SpaceAfter)" "INFO"
        
        if ($spaceBefore) {
            $reclaimed = [math]::Round($spaceAfter.FreeSpaceGB - $spaceBefore.FreeSpaceGB, 2)
            $serverResult.SpaceReclaimed = "$reclaimed GB"
            Write-Log "Space reclaimed: $($serverResult.SpaceReclaimed)" "INFO"
        }
    }
    
    # Trigger Windows Updates
    $updateSuccess = Invoke-WindowsUpdateTrigger -ServerName $server
    $serverResult.UpdateTrigger = if ($updateSuccess) { "Success" } else { "Failed" }
    
    $summary += $serverResult
    Write-Log "Completed processing $server" "INFO"
}

# Display summary
Write-Host "`n" -NoNewline
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "SUMMARY REPORT" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Log "`n=== SUMMARY REPORT ===" "INFO"

$summary | Format-Table -AutoSize | Out-String | ForEach-Object {
    Write-Host $_
    Write-Log $_ "INFO"
}

Write-Log "=== Script Completed ===" "INFO"
Write-Host "`nLog file saved to: $LogPath" -ForegroundColor Yellow
