# =============================================================================
# FTP Directory Structure Audit Script
# =============================================================================
# Purpose: Recursively scan FTP directory structure, identify upload/download
#          scripts (upload.bat, download.bat, etc.), retrieve NTFS & SMB
#          permissions, and correlate with Windows Task Scheduler jobs
#
# Note: Ignores blat.exe and other utility files - focuses only on scripts
#       with "upload" or "download" in the filename
#
# Author: Infrastructure Team
# Date: December 2025
# Version: 2.1 (Focused on Upload/Download scripts only)
#
# Usage Examples:
#   .\FTP_Audit_Script.ps1 -RootPath "D:\ftp" -OutputPath "C:\Reports"
#   .\FTP_Audit_Script.ps1 -RootPath "D:\ftp" -OutputPath "C:\Reports" -ScriptType "Upload"
#   .\FTP_Audit_Script.ps1 -RootPath "D:\ftp" -OutputPath "C:\Reports" -IncludeParentFolders
#
# Parameters:
#   -RootPath              : Root FTP directory to scan (required)
#   -OutputPath            : Where to save reports (default: C:\Reports)
#   -ScriptType            : Filter by Upload, Download, or All (default: All)
#   -IncludeParentFolders  : Also report on all parent folder permissions
# =============================================================================

param(
    [Parameter(Mandatory=$true)]
    [ValidateScript({Test-Path $_ -PathType Container})]
    [string]$RootPath = "D:\ftp",

    [Parameter(Mandatory=$false)]
    [string]$OutputPath = "C:\Reports",

    [Parameter(Mandatory=$false)]
    [ValidateSet("Upload", "Download", "All")]
    [string]$ScriptType = "All",

    [Parameter(Mandatory=$false)]
    [switch]$IncludeParentFolders = $false
)

# =============================================================================
# Configuration
# =============================================================================

$ErrorActionPreference = "Continue"
$WarningActionPreference = "SilentlyContinue"

# Script file extensions to search for
$ScriptExtensions = @("*.ps1", "*.bat", "*.cmd", "*.exe")

# Files to ignore (case-insensitive)
$IgnoreFiles = @("blat.exe", "blat.dll", "blat.bat", "blat.cmd", "blat.ps1")

# Create output directory if it doesn't exist
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

# Output file paths
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$CsvOutputPath = Join-Path -Path $OutputPath -ChildPath "FTP_Audit_Report_$timestamp.csv"
$ReadableCsvPath = Join-Path -Path $OutputPath -ChildPath "FTP_Audit_Report_Readable_$timestamp.csv"
$JsonOutputPath = Join-Path -Path $OutputPath -ChildPath "FTP_Audit_Report_$timestamp.json"
$ParentFoldersCsvPath = Join-Path -Path $OutputPath -ChildPath "FTP_Parent_Folders_Report_$timestamp.csv"
$ParentFoldersReadableCsvPath = Join-Path -Path $OutputPath -ChildPath "FTP_Parent_Folders_Readable_$timestamp.csv"
$ParentFoldersJsonPath = Join-Path -Path $OutputPath -ChildPath "FTP_Parent_Folders_Report_$timestamp.json"
$LogFilePath = Join-Path -Path $OutputPath -ChildPath "FTP_Audit_Log_$timestamp.txt"

# =============================================================================
# Logging Function
# =============================================================================

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("Info", "Warning", "Error")]
        [string]$Level = "Info"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    
    Write-Host $logMessage
    Add-Content -Path $LogFilePath -Value $logMessage
}

# =============================================================================
# Get NTFS Permissions Function
# =============================================================================

function Get-FolderNTFSPermissions {
    param(
        [string]$FolderPath
    )
    
    $permissions = @()
    
    try {
        $acl = Get-Acl -Path $FolderPath -ErrorAction Stop
        
        foreach ($access in $acl.Access) {
            $permissions += @{
                Identity = $access.IdentityReference.Value
                Rights = $access.FileSystemRights.ToString()
                AccessType = $access.AccessControlType.ToString()
                IsInherited = $access.IsInherited
            }
        }
    }
    catch {
        Write-Log -Message "Error reading NTFS permissions for $FolderPath : $_" -Level "Warning"
    }
    
    return $permissions
}

# =============================================================================
# Get SMB Share Information Function
# =============================================================================

function Get-SMBShareInfo {
    param(
        [string]$FolderPath
    )

    $shareInfo = @{
        ShareName = $null
        SharePath = $null
        SharePermissions = @()
    }

    try {
        # Get all SMB shares
        $shares = Get-SmbShare -ErrorAction SilentlyContinue | Where-Object { $_.ShareType -eq "FileSystemDirectory" }

        # Find the most specific share (longest path) that contains this folder
        $matchedShare = $null
        $longestMatchLength = 0

        foreach ($share in $shares) {
            # Normalize paths for comparison - ensure trailing backslash
            $sharePath = $share.Path.TrimEnd('\') + '\'
            $testPath = $FolderPath.TrimEnd('\') + '\'

            # Check if folder is within this share using proper path containment
            if ($testPath.StartsWith($sharePath, [System.StringComparison]::OrdinalIgnoreCase)) {
                # Keep the most specific (longest) match
                if ($sharePath.Length -gt $longestMatchLength) {
                    $matchedShare = $share
                    $longestMatchLength = $sharePath.Length
                }
            }
        }

        if ($matchedShare) {
            $shareInfo.ShareName = $matchedShare.Name
            $shareInfo.SharePath = $matchedShare.Path

            # Get share permissions
            try {
                $shareAccess = Get-SmbShareAccess -Name $matchedShare.Name -ErrorAction Stop
                foreach ($access in $shareAccess) {
                    $shareInfo.SharePermissions += @{
                        AccountName = $access.AccountName
                        AccessRight = $access.AccessRight.ToString()
                        AccessControlType = $access.AccessControlType.ToString()
                    }
                }
            }
            catch {
                Write-Log -Message "Error reading SMB permissions for share $($matchedShare.Name)" -Level "Warning"
            }
        }
    }
    catch {
        Write-Log -Message "Error enumerating SMB shares: $_" -Level "Warning"
    }

    return $shareInfo
}

# =============================================================================
# Find Scheduled Tasks Function
# =============================================================================

function Get-RelatedScheduledTasks {
    param(
        [string]$ScriptPath,
        [string]$ScriptName
    )

    $relatedTasks = @()

    try {
        # Get all scheduled tasks
        $allTasks = Get-ScheduledTask -ErrorAction SilentlyContinue

        # Normalize the script path for comparison (handle different path formats)
        $normalizedScriptPath = $ScriptPath.ToLowerInvariant()
        $scriptFileName = [System.IO.Path]::GetFileName($ScriptPath).ToLowerInvariant()

        foreach ($task in $allTasks) {
            try {
                # Skip Microsoft system tasks
                if ($task.TaskPath -like "*\Microsoft\*") {
                    continue
                }

                $taskActions = $task.Actions

                foreach ($action in $taskActions) {
                    # Build the full command line
                    $actionExecute = if ($action.Execute) { $action.Execute } else { "" }
                    $actionArguments = if ($action.Arguments) { $action.Arguments } else { "" }
                    $actionString = "$actionExecute $actionArguments".Trim()
                    $actionStringLower = $actionString.ToLowerInvariant()

                    # Multiple matching strategies to handle different task configurations
                    $isMatch = $false

                    # Strategy 1: Direct full path match (case-insensitive)
                    if ($actionStringLower -like "*$normalizedScriptPath*") {
                        $isMatch = $true
                    }

                    # Strategy 2: Filename match (in case of relative paths or working directory usage)
                    if (-not $isMatch -and $actionStringLower -like "*$scriptFileName*") {
                        $isMatch = $true
                    }

                    # Strategy 3: Match with cmd.exe wrapper (common for batch files)
                    # Example: cmd.exe /c "D:\ftp\folder\scripts\upload.bat"
                    if (-not $isMatch -and $actionExecute -match 'cmd\.exe|cmd' -and $actionStringLower -like "*$scriptFileName*") {
                        $isMatch = $true
                    }

                    # Strategy 4: Match PowerShell wrapper
                    # Example: powershell.exe -File "D:\ftp\folder\scripts\upload.ps1"
                    if (-not $isMatch -and $actionExecute -match 'powershell\.exe|pwsh\.exe' -and $actionStringLower -like "*$scriptFileName*") {
                        $isMatch = $true
                    }

                    # Strategy 5: UNC path or mapped drive variations
                    # Convert both paths to compare just the filename and parent folder
                    if (-not $isMatch) {
                        $scriptParentFolder = [System.IO.Path]::GetFileName([System.IO.Path]::GetDirectoryName($ScriptPath))
                        if ($scriptParentFolder -and $actionStringLower -match [regex]::Escape($scriptParentFolder.ToLowerInvariant()) -and $actionStringLower -match [regex]::Escape($scriptFileName)) {
                            $isMatch = $true
                        }
                    }

                    if ($isMatch) {
                        # Get task info
                        $taskInfo = $task | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue

                        # Get trigger information with more details
                        $triggerDetails = @()
                        if ($task.Triggers) {
                            foreach ($trigger in $task.Triggers) {
                                $triggerText = ""

                                # Trigger type
                                $triggerTypeName = $trigger.CimClass.CimClassName -replace 'MSFT_Task', '' -replace 'Trigger', ''
                                if ($triggerTypeName) {
                                    $triggerText += "${triggerTypeName}: "
                                }

                                # Start time
                                if ($trigger.StartBoundary) {
                                    try {
                                        $startTime = [DateTime]::Parse($trigger.StartBoundary)
                                        $triggerText += "Start: $($startTime.ToString('yyyy-MM-dd HH:mm:ss')) | "
                                    }
                                    catch {
                                        $triggerText += "Start: $($trigger.StartBoundary) | "
                                    }
                                }

                                # Repetition interval
                                if ($trigger.Repetition.Interval) {
                                    $triggerText += "Repeat: $($trigger.Repetition.Interval) | "
                                }

                                # Days of week (for weekly triggers)
                                if ($trigger.DaysOfWeek) {
                                    $triggerText += "Days: $($trigger.DaysOfWeek) | "
                                }

                                # Enabled status
                                if ($trigger.Enabled -eq $false) {
                                    $triggerText += "DISABLED | "
                                }

                                $triggerDetails += $triggerText.TrimEnd(" | ")
                            }
                        }

                        $relatedTasks += @{
                            TaskName = $task.TaskName
                            TaskPath = $task.TaskPath
                            State = $task.State.ToString()
                            TriggerInfo = if ($triggerDetails.Count -gt 0) { $triggerDetails -join "; " } else { "No triggers" }
                            LastRunTime = if ($taskInfo.LastRunTime) { $taskInfo.LastRunTime } else { "Never" }
                            LastTaskResult = if ($taskInfo.LastTaskResult) { $taskInfo.LastTaskResult } else { "N/A" }
                            NextRunTime = if ($taskInfo.NextRunTime) { $taskInfo.NextRunTime } else { "Not scheduled" }
                            Principal = $task.Principal.UserId
                            ActionCommand = $actionString
                        }

                        # Break after finding match to avoid duplicates
                        break
                    }
                }
            }
            catch {
                Write-Log -Message "Error processing task $($task.TaskName): $_" -Level "Warning"
                continue
            }
        }
    }
    catch {
        Write-Log -Message "Error retrieving scheduled tasks: $_" -Level "Warning"
    }

    return $relatedTasks
}

# =============================================================================
# Determine Script Type Function
# =============================================================================

function Get-ScriptType {
    param(
        [string]$ScriptPath,
        [string]$ScriptName
    )

    # Check filename pattern first (most reliable)
    # Use word boundaries to avoid false matches like "backup", "setup", "cup"
    if ($ScriptName -match '\bupload\b') {
        return "Upload"
    }
    elseif ($ScriptName -match '\bdownload\b|\bdown\b|\bget\b|\bretrieve\b|\bfetch\b') {
        return "Download"
    }

    # Try reading file content for keywords (works for .ps1, .bat, .cmd)
    if ($ScriptPath -match '\.(ps1|bat|cmd)$') {
        try {
            # Safety check: Only read files smaller than 10MB to prevent memory issues
            $fileInfo = Get-Item -Path $ScriptPath -ErrorAction SilentlyContinue
            if ($fileInfo -and $fileInfo.Length -lt 10MB) {
                $content = Get-Content -Path $ScriptPath -Raw -ErrorAction SilentlyContinue

                # PowerShell patterns
                $uploadPatterns = "Send-Item|Put-Item|\bPut-\w+|Upload|SFTP.*-?UploadFile|Invoke-Sftp.*upload|Copy-Item.*-Destination.*remote|Set-FTP.*Upload|WinSCP.*Put"
                $downloadPatterns = "Receive-Item|Get-Item.*-Source.*remote|Download|SFTP.*-?DownloadFile|Invoke-Sftp.*download|Copy-Item.*-Source.*remote|Get-FTP.*Download|WinSCP.*Get"

                # Batch file patterns (FTP commands)
                $batchUploadPatterns = "ftp.*put\s|ftp.*send\s|ftp.*mput\s"
                $batchDownloadPatterns = "ftp.*get\s|ftp.*recv\s|ftp.*mget\s"

                if ($content -match $uploadPatterns -or $content -match $batchUploadPatterns) {
                    return "Upload"
                }
                elseif ($content -match $downloadPatterns -or $content -match $batchDownloadPatterns) {
                    return "Download"
                }
            }
            elseif ($fileInfo -and $fileInfo.Length -ge 10MB) {
                Write-Log -Message "Skipping content analysis for $ScriptPath (file size: $([math]::Round($fileInfo.Length / 1MB, 2)) MB exceeds 10MB limit)" -Level "Warning"
            }
        }
        catch {
            # Silently continue if file can't be read
        }
    }

    return "Unknown"
}

# =============================================================================
# Get Parent Folder Permissions Function
# =============================================================================

function Get-ParentFolderPermissions {
    param(
        [string]$RootPath
    )

    $parentFolders = @()

    try {
        Write-Log -Message "Collecting parent folder permissions for: $RootPath"

        # Get all unique parent directories (excluding script folders)
        $directories = @(Get-ChildItem -Path $RootPath -Directory -Recurse -ErrorAction SilentlyContinue)

        # Include the root directory
        $allDirectories = @($RootPath) + $directories

        foreach ($dir in $allDirectories) {
            $folderPath = $dir
            if ($dir -is [System.IO.DirectoryInfo]) {
                $folderPath = $dir.FullName
            }

            # Get permissions
            $ntfsPerms = Get-FolderNTFSPermissions -FolderPath $folderPath
            $smbInfo = Get-SMBShareInfo -FolderPath $folderPath

            # Create parent folder object
            $parentFolderObj = [PSCustomObject]@{
                FolderPath = $folderPath
                FolderType = if ($folderPath -eq $RootPath) { "Root" } else { "Subfolder" }
                NTFSPermissions = $ntfsPerms | ConvertTo-Json -Depth 10
                SMBShareName = $smbInfo.ShareName
                SMBSharePath = $smbInfo.SharePath
                SMBSharePermissions = $smbInfo.SharePermissions | ConvertTo-Json -Depth 10
            }

            $parentFolders += $parentFolderObj
        }

        Write-Log -Message "Collected permissions for $($parentFolders.Count) parent folders"
    }
    catch {
        Write-Log -Message "Error collecting parent folder permissions: $_" -Level "Error"
    }

    return $parentFolders
}

# =============================================================================
# Main Scanning Logic
# =============================================================================

function Invoke-FTPDirectoryScan {
    param(
        [string]$RootPath
    )

    $results = @()
    
    Write-Log -Message "Starting FTP directory scan at: $RootPath"
    
    try {
        # Get all directories recursively
        $directories = @(Get-ChildItem -Path $RootPath -Directory -Recurse -ErrorAction SilentlyContinue)
        
        Write-Log -Message "Found $($directories.Count) directories to scan"
        
        # Also include the root directory
        $allDirectories = @($RootPath) + $directories
        
        $directoryCount = 0
        
        foreach ($dir in $allDirectories) {
            $directoryCount++
            $folderPath = $dir
            
            if ($dir -is [System.IO.DirectoryInfo]) {
                $folderPath = $dir.FullName
            }
            
            Write-Log -Message "[$directoryCount/$($allDirectories.Count)] Scanning: $folderPath"
            
            # Get all script files in this directory (non-recursive)
            $scripts = @()
            foreach ($extension in $ScriptExtensions) {
                $foundScripts = Get-ChildItem -Path $folderPath -Filter $extension -File -ErrorAction SilentlyContinue

                # Filter out ignored files and files without upload/download in name
                foreach ($script in $foundScripts) {
                    # Skip if file is in ignore list
                    if ($IgnoreFiles -contains $script.Name) {
                        Write-Log -Message "Skipping ignored file: $($script.Name)" -Level "Info"
                        continue
                    }

                    # Skip if file name contains "blat" (case-insensitive)
                    if ($script.Name -match 'blat') {
                        Write-Log -Message "Skipping blat-related file: $($script.Name)" -Level "Info"
                        continue
                    }

                    # Only include files with "upload" or "download" in the name
                    if ($script.Name -match '\b(upload|download)\b') {
                        $scripts += $script
                    }
                    else {
                        Write-Log -Message "Skipping file (no upload/download in name): $($script.Name)" -Level "Info"
                    }
                }
            }

            # If no scripts found, skip to next directory
            if ($scripts.Count -eq 0) {
                continue
            }
            
            # Get permissions
            $ntfsPerms = Get-FolderNTFSPermissions -FolderPath $folderPath
            $smbInfo = Get-SMBShareInfo -FolderPath $folderPath
            
            # Process each script file
            foreach ($script in $scripts) {
                $scriptType = Get-ScriptType -ScriptPath $script.FullName -ScriptName $script.Name
                
                # Filter by script type if specified
                if ($ScriptType -ne "All" -and $scriptType -ne $ScriptType) {
                    continue
                }
                
                # Find related scheduled tasks
                $relatedTasks = Get-RelatedScheduledTasks -ScriptPath $script.FullName -ScriptName $script.Name
                
                # Create result object
                $result = [PSCustomObject]@{
                    FolderPath = $folderPath
                    ScriptName = $script.Name
                    ScriptFullPath = $script.FullName
                    ScriptType = $scriptType
                    ScriptSize = "$([math]::Round($script.Length / 1KB, 2)) KB"
                    ScriptLastModified = $script.LastWriteTime
                    NTFSPermissions = $ntfsPerms | ConvertTo-Json -Depth 10
                    SMBShareName = $smbInfo.ShareName
                    SMBSharePermissions = $smbInfo.SharePermissions | ConvertTo-Json -Depth 10
                    ScheduledTaskCount = $relatedTasks.Count
                    ScheduledTasks = $relatedTasks | ConvertTo-Json -Depth 10
                }
                
                $results += $result
                
                # Log the finding
                if ($relatedTasks.Count -gt 0) {
                    Write-Log -Message "Found $($relatedTasks.Count) scheduled task(s) for $($script.Name)"
                }
            }
        }
        
        Write-Log -Message "Scan completed. Found $($results.Count) script files."
    }
    catch {
        Write-Log -Message "Critical error during scan: $_" -Level "Error"
    }
    
    return $results
}

# =============================================================================
# Generate Summary Report Function
# =============================================================================

function New-SummaryReport {
    param(
        [array]$Results
    )
    
    $summary = @()
    
    if ($Results.Count -gt 0) {
        $uploadScripts = $Results | Where-Object { $_.ScriptType -eq "Upload" }
        $downloadScripts = $Results | Where-Object { $_.ScriptType -eq "Download" }
        $unknownScripts = $Results | Where-Object { $_.ScriptType -eq "Unknown" }
        
        $summary += "=========================================="
        $summary += "FTP DIRECTORY AUDIT SUMMARY REPORT"
        $summary += "=========================================="
        $summary += "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        $summary += "Root Path Scanned: $RootPath"
        $summary += ""
        $summary += "STATISTICS:"
        $summary += "  Total Scripts Found: $($Results.Count)"
        $summary += "  Upload Scripts: $($uploadScripts.Count)"
        $summary += "  Download Scripts: $($downloadScripts.Count)"
        $summary += "  Unknown Scripts: $($unknownScripts.Count)"
        $summary += ""
        $summary += "FOLDERS WITH SMB SHARES:"
        
        $foldersWithShares = $Results | Where-Object { $_.SMBShareName -ne $null } | Select-Object -Unique -ExpandProperty FolderPath
        if ($foldersWithShares) {
            foreach ($folder in $foldersWithShares) {
                $summary += "  - $folder"
            }
        }
        else {
            $summary += "  None found"
        }
        
        $summary += ""
        $summary += "FOLDERS WITHOUT SCHEDULED TASKS:"
        
        $foldersWithoutTasks = $Results | Where-Object { $_.ScheduledTaskCount -eq 0 } | Select-Object -Unique -ExpandProperty FolderPath
        if ($foldersWithoutTasks) {
            foreach ($folder in $foldersWithoutTasks) {
                $summary += "  - $folder"
            }
        }
        else {
            $summary += "  All folders have scheduled tasks"
        }
        
        $summary += ""
        $summary += "=========================================="
    }
    
    return $summary -join "`n"
}

# =============================================================================
# Main Execution
# =============================================================================

try {
    Write-Log -Message "=========================================="
    Write-Log -Message "FTP Directory Audit Script Started"
    Write-Log -Message "=========================================="
    Write-Log -Message "Root Path: $RootPath"
    Write-Log -Message "Output Path: $OutputPath"
    Write-Log -Message "Script Type Filter: $ScriptType"
    Write-Log -Message "Include Parent Folders: $IncludeParentFolders"
    Write-Log -Message "=========================================="

    # Optionally collect parent folder permissions
    $parentFolderResults = @()
    if ($IncludeParentFolders) {
        Write-Log -Message "Collecting parent folder permissions (IncludeParentFolders is enabled)"
        $parentFolderResults = Get-ParentFolderPermissions -RootPath $RootPath
    }

    # Run the script scan
    $auditResults = Invoke-FTPDirectoryScan -RootPath $RootPath

    if ($auditResults.Count -gt 0) {
        # Export to CSV
        Write-Log -Message "Exporting results to CSV: $CsvOutputPath"

        # Create a flattened version for CSV export
        $csvExport = @()
        foreach ($result in $auditResults) {
            $csvExport += [PSCustomObject]@{
                FolderPath = $result.FolderPath
                ScriptName = $result.ScriptName
                ScriptFullPath = $result.ScriptFullPath
                ScriptType = $result.ScriptType
                ScriptSize = $result.ScriptSize
                ScriptLastModified = $result.ScriptLastModified
                NTFSPermissionCount = ($result.NTFSPermissions | ConvertFrom-Json | Measure-Object).Count
                NTFSPermissions = $result.NTFSPermissions
                SMBShareName = $result.SMBShareName
                SMBSharePermissionCount = ($result.SMBSharePermissions | ConvertFrom-Json | Measure-Object).Count
                SMBSharePermissions = $result.SMBSharePermissions
                ScheduledTaskCount = $result.ScheduledTaskCount
                ScheduledTasks = $result.ScheduledTasks
            }
        }

        $csvExport | Export-Csv -Path $CsvOutputPath -NoTypeInformation -Encoding UTF8
        Write-Log -Message "CSV report exported successfully"

        # Export Human-Readable CSV for Excel
        Write-Log -Message "Exporting human-readable CSV: $ReadableCsvPath"

        $readableCsvExport = @()
        foreach ($result in $auditResults) {

            # Flatten NTFS Permissions into readable string
            # Format: "DOMAIN\User (Rights); DOMAIN\Group (Rights)"
            $ntfsObj = $result.NTFSPermissions | ConvertFrom-Json
            $ntfsString = if ($ntfsObj) {
                ($ntfsObj | ForEach-Object { "$($_.Identity) ($($_.Rights))" }) -join "; "
            } else { "No permissions info" }

            # Flatten SMB Share Permissions
            $smbObj = $result.SMBSharePermissions | ConvertFrom-Json
            $smbString = if ($smbObj) {
                ($smbObj | ForEach-Object { "$($_.AccountName) ($($_.AccessRight))" }) -join "; "
            } else { "No share permissions" }

            # Flatten Scheduled Tasks
            # Format: "TaskName (Next: 12/25/2025 2:00 PM) | TaskName2 (Next: Never)"
            $taskObj = $result.ScheduledTasks | ConvertFrom-Json
            $taskString = if ($taskObj) {
                ($taskObj | ForEach-Object {
                    "$($_.TaskName) (Next: $($_.NextRunTime), Last: $($_.LastRunTime), Trigger: $($_.TriggerInfo))"
                }) -join " | "
            } else { "None" }

            # Create the human-readable row
            $readableCsvExport += [PSCustomObject]@{
                FolderPath         = $result.FolderPath
                ScriptName         = $result.ScriptName
                ScriptFullPath     = $result.ScriptFullPath
                ScriptType         = $result.ScriptType
                ScriptSize         = $result.ScriptSize
                LastModified       = $result.ScriptLastModified
                IsScheduled        = if ($result.ScheduledTaskCount -gt 0) { "YES" } else { "No" }
                ScheduleDetails    = $taskString
                SMBShareName       = if ($result.SMBShareName) { $result.SMBShareName } else { "Not Shared" }
                SMBSharePerms      = $smbString
                NTFSPermissions    = $ntfsString
            }
        }

        $readableCsvExport | Export-Csv -Path $ReadableCsvPath -NoTypeInformation -Encoding UTF8
        Write-Log -Message "Human-readable CSV exported successfully"

        # Export to JSON (preserves structure better)
        Write-Log -Message "Exporting results to JSON: $JsonOutputPath"
        $auditResults | ConvertTo-Json -Depth 10 | Out-File -FilePath $JsonOutputPath -Encoding UTF8
        Write-Log -Message "JSON report exported successfully"
    }
    else {
        Write-Log -Message "No scripts found matching the specified criteria" -Level "Warning"
    }

    # Export parent folder permissions if collected
    if ($IncludeParentFolders -and $parentFolderResults.Count -gt 0) {
        Write-Log -Message "Exporting parent folder permissions to CSV: $ParentFoldersCsvPath"

        # Create flattened CSV export for parent folders
        $parentCsvExport = @()
        foreach ($folder in $parentFolderResults) {
            $parentCsvExport += [PSCustomObject]@{
                FolderPath = $folder.FolderPath
                FolderType = $folder.FolderType
                NTFSPermissionCount = ($folder.NTFSPermissions | ConvertFrom-Json | Measure-Object).Count
                NTFSPermissions = $folder.NTFSPermissions
                SMBShareName = $folder.SMBShareName
                SMBSharePath = $folder.SMBSharePath
                SMBSharePermissionCount = ($folder.SMBSharePermissions | ConvertFrom-Json | Measure-Object).Count
                SMBSharePermissions = $folder.SMBSharePermissions
            }
        }

        $parentCsvExport | Export-Csv -Path $ParentFoldersCsvPath -NoTypeInformation -Encoding UTF8
        Write-Log -Message "Parent folders CSV report exported successfully"

        # Export Human-Readable Parent Folders CSV
        Write-Log -Message "Exporting human-readable parent folders CSV: $ParentFoldersReadableCsvPath"

        $parentReadableCsvExport = @()
        foreach ($folder in $parentFolderResults) {

            # Flatten NTFS Permissions
            $ntfsObj = $folder.NTFSPermissions | ConvertFrom-Json
            $ntfsString = if ($ntfsObj) {
                ($ntfsObj | ForEach-Object { "$($_.Identity) ($($_.Rights))" }) -join "; "
            } else { "No permissions info" }

            # Flatten SMB Share Permissions
            $smbObj = $folder.SMBSharePermissions | ConvertFrom-Json
            $smbString = if ($smbObj) {
                ($smbObj | ForEach-Object { "$($_.AccountName) ($($_.AccessRight))" }) -join "; "
            } else { "No share permissions" }

            $parentReadableCsvExport += [PSCustomObject]@{
                FolderPath         = $folder.FolderPath
                FolderType         = $folder.FolderType
                SMBShareName       = if ($folder.SMBShareName) { $folder.SMBShareName } else { "Not Shared" }
                SMBSharePath       = if ($folder.SMBSharePath) { $folder.SMBSharePath } else { "N/A" }
                SMBSharePerms      = $smbString
                NTFSPermissions    = $ntfsString
            }
        }

        $parentReadableCsvExport | Export-Csv -Path $ParentFoldersReadableCsvPath -NoTypeInformation -Encoding UTF8
        Write-Log -Message "Human-readable parent folders CSV exported successfully"

        # Export to JSON
        Write-Log -Message "Exporting parent folder permissions to JSON: $ParentFoldersJsonPath"
        $parentFolderResults | ConvertTo-Json -Depth 10 | Out-File -FilePath $ParentFoldersJsonPath -Encoding UTF8
        Write-Log -Message "Parent folders JSON report exported successfully"
    }

    # Generate and display summary
    $summary = New-SummaryReport -Results $auditResults
    Write-Host $summary
    Add-Content -Path $LogFilePath -Value $summary

    Write-Log -Message "=========================================="
    Write-Log -Message "FTP Directory Audit Script Completed"
    Write-Log -Message "=========================================="
    Write-Log -Message "Scripts Report (CSV - Raw Data): $CsvOutputPath"
    Write-Log -Message "Scripts Report (CSV - Excel Friendly): $ReadableCsvPath"
    Write-Log -Message "Scripts Report (JSON): $JsonOutputPath"
    if ($IncludeParentFolders) {
        Write-Log -Message "Parent Folders Report (CSV - Raw Data): $ParentFoldersCsvPath"
        Write-Log -Message "Parent Folders Report (CSV - Excel Friendly): $ParentFoldersReadableCsvPath"
        Write-Log -Message "Parent Folders Report (JSON): $ParentFoldersJsonPath"
    }
    Write-Log -Message "Log File: $LogFilePath"
    Write-Log -Message "=========================================="
    Write-Log -Message "TIP: Open the '*_Readable_*.csv' files in Excel for easy human review"
    Write-Log -Message "=========================================="

    # Return summary information
    return @{
        ScriptCount = $auditResults.Count
        ParentFolderCount = $parentFolderResults.Count
        ReportPath = $CsvOutputPath
        ReadableReportPath = $ReadableCsvPath
        ParentFoldersReportPath = if ($IncludeParentFolders) { $ParentFoldersCsvPath } else { $null }
        ParentFoldersReadablePath = if ($IncludeParentFolders) { $ParentFoldersReadableCsvPath } else { $null }
        LogPath = $LogFilePath
    }
}
catch {
    Write-Log -Message "FATAL ERROR: $_" -Level "Error"
    throw
}
