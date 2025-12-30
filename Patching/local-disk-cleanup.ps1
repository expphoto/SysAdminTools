<#
.SYNOPSIS
    Local Disk Cleanup and Update Trigger (Single Server)
.DESCRIPTION
    Optimized for speed. Cleans temp/cache and triggers update scan locally.
    SAFE FOR PATCH NIGHT: Does NOT run deep compression or ResetBase.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$LogPath = "C:\Temp\LocalCleanup_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
)

# Function to write log entries
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    Write-Host $logMessage
    Add-Content -Path $LogPath -Value $logMessage -ErrorAction SilentlyContinue
}

# Create log directory
$logDir = Split-Path $LogPath -Parent
if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }

Write-Log "=== Starting Local Cleanup on $env:COMPUTERNAME ===" "INFO"

# 1. GET DISK SPACE BEFORE
try {
    $drive = Get-PSDrive C -ErrorAction Stop
    $freeBefore = [math]::Round($drive.Free / 1GB, 2)
    Write-Log "Free Space Before: $freeBefore GB" "INFO"
} catch {
    Write-Log "Could not read disk space." "WARN"
}

# 2. CLEAN WINDOWS TEMP (Safe: Older than 7 days only)
Write-Log "Cleaning Windows Temp..." "INFO"
try {
    $tempPath = "$env:SystemRoot\Temp\*"
    Get-ChildItem $tempPath -Recurse -Force -ErrorAction SilentlyContinue | 
        Where-Object { !$_.PSIsContainer -and $_.LastWriteTime -lt (Get-Date).AddDays(-7) } | 
        Remove-Item -Force -ErrorAction SilentlyContinue
    Write-Log "Windows Temp cleaned." "INFO"
} catch {
    Write-Log "Error cleaning Temp: $_" "ERROR"
}

# 3. CLEAN UPDATE CACHE (SoftwareDistribution)
Write-Log "Cleaning Update Downloads..." "INFO"
try {
    Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    $downloadPath = "$env:SystemRoot\SoftwareDistribution\Download\*"
    Get-ChildItem $downloadPath -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Start-Service wuauserv -ErrorAction SilentlyContinue
    Write-Log "Update cache cleaned." "INFO"
} catch {
    Start-Service wuauserv -ErrorAction SilentlyContinue
    Write-Log "Error cleaning Update Cache: $_" "ERROR"
}

# 4. DISM CLEANUP (SKIPPED FOR SPEED)
Write-Log "Skipping DISM /ResetBase (Too slow for patch night)." "INFO"

# 5. CLEANMGR (Standard Cleanup Only)
Write-Log "Running Disk Cleanup (CleanMgr)..." "INFO"
try {
    # Removed 'Update Cleanup' to prevent hanging
    $volumeCaches = @(
        'Active Setup Temp Folders', 'Downloaded Program Files', 'Internet Cache Files',
        'Old ChkDsk Files', 'Recycle Bin', 'Setup Log Files', 'Temporary Files',
        'Temporary Setup Files', 'Thumbnail Cache', 'Windows Error Reporting Files'
    )
    
    foreach ($cache in $volumeCaches) {
        $regPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches\$cache"
        if (Test-Path $regPath) {
            Set-ItemProperty -Path $regPath -Name StateFlags0100 -Value 2 -Type DWord -ErrorAction SilentlyContinue
        }
    }
    
    $cleanmgr = Start-Process -FilePath cleanmgr.exe -ArgumentList "/sagerun:100" -Wait -PassThru -WindowStyle Hidden
    Write-Log "CleanMgr finished." "INFO"
} catch {
    Write-Log "CleanMgr Error: $_" "ERROR"
}

# 6. TRIGGER UPDATE DETECTION
Write-Log "Triggering Windows Update detection..." "INFO"
try {
    $updateSession = New-Object -ComObject Microsoft.Update.Session
    $updateSearcher = $updateSession.CreateUpdateSearcher()
    
    if (Test-Path "$env:SystemRoot\System32\UsoClient.exe") {
        Start-Process -FilePath "$env:SystemRoot\System32\UsoClient.exe" -ArgumentList "StartScan" -NoNewWindow -ErrorAction SilentlyContinue
        Write-Log "UsoClient Scan Triggered." "INFO"
    } else {
        Start-Process -FilePath "$env:SystemRoot\System32\wuauclt.exe" -ArgumentList "/detectnow" -NoNewWindow -ErrorAction SilentlyContinue
        Write-Log "Legacy WUAUCLT Triggered." "INFO"
    }
} catch {
    Write-Log "Update Trigger Failed: $_" "ERROR"
}

# 7. GET DISK SPACE AFTER
try {
    $drive = Get-PSDrive C -ErrorAction Stop
    $freeAfter = [math]::Round($drive.Free / 1GB, 2)
    Write-Log "Free Space After:  $freeAfter GB" "INFO"
    if ($freeBefore) {
        $reclaimed = [math]::Round($freeAfter - $freeBefore, 2)
        Write-Log "Total Reclaimed:   $reclaimed GB" "INFO"
    }
} catch { }

Write-Log "=== Execution Complete ===" "INFO"
Write-Host "Done. Check $LogPath for details." -ForegroundColor Green