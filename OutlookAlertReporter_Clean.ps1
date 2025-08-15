#Requires -Version 5.1
<#
.SYNOPSIS
    Interactive PowerShell script to analyze alert emails in Outlook and generate comprehensive reports.

.DESCRIPTION
    This script connects to Outlook via COM, analyzes alert emails based on user-defined criteria,
    and generates console summaries, CSV exports, and HTML reports. It supports duplicate detection,
    priority classification, and server name extraction.

.PARAMETER WhatIf
    Parse and classify emails but skip writing output files.

.EXAMPLE
    .\OutlookAlertReporter.ps1
    Run the script interactively with prompts for all options.

.EXAMPLE
    .\OutlookAlertReporter.ps1 -WhatIf -Verbose
    Run in test mode with detailed output but no file generation.
#>

[CmdletBinding()]
param(
    [switch]$WhatIf
)

# Script-level variables and defaults
$script:HighPriorityKeywords = @(
    'down','outage','critical','fail','failure','unreachable','offline','data loss',
    'disk full','rto','rpo','panic','sev1','p1','escalation','security','ransom','malware'
)

$script:LowHangingFruitKeywords = @(
    'auto-resolved','cleared','restarted','resolved','recovered','informational','success','ok'
)

$script:ServerNameRegexes = @(
    '(?i)\b(?:srv|server|host|node|dc|sql|exch|rdp|fs|web)[-_ ]?([a-z0-9\-]{2,})\b',
    '(?i)\b([a-z0-9\-]{3,})\.(?:local|lan|corp|internal|example\.com)\b'
)

$script:DuplicateBucketMinutes = 30
$script:ComObjectsToCleanup = @()
$script:SelectedFolderObject = $null

#region COM Object Management
function Initialize-OutlookCom {
    try {
        Write-Verbose "Initializing Outlook COM application..."
        
        $outlook = New-Object -ComObject Outlook.Application
        $script:ComObjectsToCleanup += $outlook
        
        $namespace = $outlook.GetNamespace("MAPI")
        $script:ComObjectsToCleanup += $namespace
        
        Write-Verbose "Outlook COM initialized successfully"
        return @{ Outlook = $outlook; Namespace = $namespace }
    }
    catch {
        Write-Error "Failed to initialize Outlook COM: $($_.Exception.Message)"
        Write-Host "Please ensure Outlook is installed and you have a configured profile."
        return $null
    }
}

function Cleanup-ComObjects {
    if ($script:ComObjectsToCleanup.Count -gt 0) {
        Write-Verbose "Cleaning up $($script:ComObjectsToCleanup.Count) COM objects..."
    }
    
    foreach ($comObject in $script:ComObjectsToCleanup) {
        if ($comObject) {
            try {
                [System.Runtime.InteropServices.Marshal]::ReleaseComObject($comObject) | Out-Null
            }
            catch {
                # Ignore cleanup errors
            }
        }
    }
    
    $script:ComObjectsToCleanup = @()
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
}
#endregion

#region User Input Functions
function Show-MainMenu {
    Write-Host ""
    Write-Host "=== Outlook Alert Reporter ===" -ForegroundColor Cyan
    Write-Host "Analyze alert emails and generate comprehensive reports"
    Write-Host ""
    
    $config = @{}
    
    # Get folder selection
    $config.Folder = Get-FolderSelection
    if (-not $config.Folder) { return $null }
    
    # Get filter type and address
    $filterConfig = Get-FilterConfiguration
    if (-not $filterConfig) { return $null }
    $config.FilterType = $filterConfig.Type
    $config.FilterAddress = $filterConfig.Address
    
    # Get time window
    $timeConfig = Get-TimeWindowConfiguration
    if (-not $timeConfig) { return $null }
    $config.StartDate = $timeConfig.StartDate
    $config.EndDate = $timeConfig.EndDate
    $config.TimeDescription = $timeConfig.Description
    
    # Get keyword configuration
    $keywordConfig = Get-KeywordConfiguration
    $config.HighPriorityKeywords = $keywordConfig.HighPriority
    $config.LowHangingFruitKeywords = $keywordConfig.LowHangingFruit
    
    # Get duplicate policy
    $duplicateConfig = Get-DuplicateConfiguration
    $config.DuplicateBucketMinutes = $duplicateConfig.BucketMinutes
    
    # Get output folder
    $config.OutputFolder = Get-OutputFolder
    if (-not $config.OutputFolder) { return $null }
    
    return $config
}

function Get-FolderSelection {
    Write-Host ""
    Write-Host "--- Folder Selection ---" -ForegroundColor Yellow
    Write-Host "1. Use Inbox (default)"
    Write-Host "2. Browse and select specific folder"
    Write-Host "3. Search entire mailbox (all folders)"
    
    do {
        $choice = Read-Host "Choose folder option (1-3) [1]"
        if ([string]::IsNullOrEmpty($choice)) { $choice = "1" }
    } while ($choice -notin @("1", "2", "3"))
    
    switch ($choice) {
        "1" { return "Inbox" }
        "2" { return Get-FolderBrowser }
        "3" { return "EntireMailbox" }
    }
}

function Get-FolderBrowser {
    try {
        $comApp = Initialize-OutlookCom
        if (-not $comApp) { return "Inbox" }
        
        $inbox = $comApp.Namespace.GetDefaultFolder(6) # olFolderInbox
        $script:ComObjectsToCleanup += $inbox
        
        Write-Host ""
        Write-Host "Available folders:"
        Write-Host "0. Inbox (root)" -ForegroundColor Green
        
        $folders = @()
        $folderDisplayInfo = @()
        
        # Add inbox
        $folders += $inbox
        $folderDisplayInfo += @{ Index = 0; Name = "Inbox"; Folder = $inbox; Path = "Inbox" }
        
        $folderIndex = 1
        
        # Add inbox subfolders
        foreach ($subfolder in $inbox.Folders) {
            $script:ComObjectsToCleanup += $subfolder
            Write-Host "$folderIndex. $($subfolder.Name)" -ForegroundColor Cyan
            $folders += $subfolder
            $folderDisplayInfo += @{ Index = $folderIndex; Name = $subfolder.Name; Folder = $subfolder; Path = "Inbox\$($subfolder.Name)" }
            $folderIndex++
        }
        
        do {
            $selection = Read-Host "`nSelect folder number [0]"
            if ([string]::IsNullOrEmpty($selection)) { $selection = "0" }
            $selectionInt = 0
            $validSelection = [int]::TryParse($selection, [ref]$selectionInt) -and $selectionInt -ge 0 -and $selectionInt -lt $folders.Count
        } while (-not $validSelection)
        
        $selectedInfo = $folderDisplayInfo[$selectionInt]
        Write-Host "Selected folder: $($selectedInfo.Name)" -ForegroundColor Green
        
        # Store the actual folder object for later use
        $script:SelectedFolderObject = $selectedInfo.Folder
        
        # Return a simple identifier that we can handle
        return "SELECTED_FOLDER_$selectionInt"
    }
    catch {
        Write-Warning "Could not browse folders: $($_.Exception.Message)"
        return "Inbox"
    }
}

function Get-FilterConfiguration {
    Write-Host ""
    Write-Host "--- Email Filter Configuration ---" -ForegroundColor Yellow
    Write-Host "Choose filter type:"
    Write-Host "1. Filter by From address"
    Write-Host "2. Filter by To address" 
    Write-Host "3. No address filter (analyze all emails in scope)"
    
    do {
        $filterType = Read-Host "Choose filter type (1-3)"
    } while ($filterType -notin @("1", "2", "3"))
    
    if ($filterType -eq "3") {
        Write-Host "No address filtering - will analyze all emails in the selected folder/mailbox scope" -ForegroundColor Green
        return @{
            Type = "None"
            Address = ""
        }
    }
    
    $filterTypeName = if ($filterType -eq "1") { "From" } else { "To" }
    
    do {
        $address = Read-Host "Enter $filterTypeName email address"
    } while ([string]::IsNullOrWhiteSpace($address))
    
    return @{
        Type = $filterTypeName
        Address = $address.Trim()
    }
}

function Get-TimeWindowConfiguration {
    Write-Host ""
    Write-Host "--- Time Window Configuration ---" -ForegroundColor Yellow
    Write-Host "1. Last 7 days"
    Write-Host "2. Last 30 days"
    Write-Host "3. Custom date range"
    
    do {
        $timeChoice = Read-Host "Choose time window (1-3) [1]"
        if ([string]::IsNullOrEmpty($timeChoice)) { $timeChoice = "1" }
    } while ($timeChoice -notin @("1", "2", "3"))
    
    $endDate = Get-Date
    
    switch ($timeChoice) {
        "1" {
            return @{
                StartDate = $endDate.AddDays(-7)
                EndDate = $endDate
                Description = "Last 7 days"
            }
        }
        "2" {
            return @{
                StartDate = $endDate.AddDays(-30)
                EndDate = $endDate
                Description = "Last 30 days"
            }
        }
        "3" {
            do {
                $startDateInput = Read-Host "Enter start date (yyyy-MM-dd)"
                $startDate = $null
                $validStart = [DateTime]::TryParseExact($startDateInput, "yyyy-MM-dd", $null, [System.Globalization.DateTimeStyles]::None, [ref]$startDate)
            } while (-not $validStart)
            
            do {
                $endDateInput = Read-Host "Enter end date (yyyy-MM-dd) [$($endDate.ToString('yyyy-MM-dd'))]"
                if ([string]::IsNullOrEmpty($endDateInput)) {
                    $endDateInput = $endDate.ToString('yyyy-MM-dd')
                }
                $customEndDate = $null
                $validEnd = [DateTime]::TryParseExact($endDateInput, "yyyy-MM-dd", $null, [System.Globalization.DateTimeStyles]::None, [ref]$customEndDate)
            } while (-not $validEnd -or $customEndDate -lt $startDate)
            
            $startStr = $startDate.ToString('yyyy-MM-dd')
            $endStr = $customEndDate.ToString('yyyy-MM-dd')
            
            return @{
                StartDate = $startDate
                EndDate = $customEndDate.AddDays(1).AddSeconds(-1)
                Description = "Custom range: $startStr to $endStr"
            }
        }
    }
}

function Get-KeywordConfiguration {
    Write-Host ""
    Write-Host "--- Keyword Configuration ---" -ForegroundColor Yellow
    
    Write-Host "Current high priority keywords:"
    Write-Host ($script:HighPriorityKeywords -join ", ") -ForegroundColor Red
    
    $highPriorityInput = Read-Host "`nEnter high priority keywords (comma-separated) or press Enter to use defaults"
    if (-not [string]::IsNullOrWhiteSpace($highPriorityInput)) {
        $highPriorityKeywords = $highPriorityInput -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    } else {
        $highPriorityKeywords = $script:HighPriorityKeywords
    }
    
    Write-Host ""
    Write-Host "Current low-hanging fruit keywords:"
    Write-Host ($script:LowHangingFruitKeywords -join ", ") -ForegroundColor Green
    
    $lowHangingInput = Read-Host "`nEnter low-hanging fruit keywords (comma-separated) or press Enter to use defaults"
    if (-not [string]::IsNullOrWhiteSpace($lowHangingInput)) {
        $lowHangingKeywords = $lowHangingInput -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    } else {
        $lowHangingKeywords = $script:LowHangingFruitKeywords
    }
    
    return @{
        HighPriority = $highPriorityKeywords
        LowHangingFruit = $lowHangingKeywords
    }
}

function Get-DuplicateConfiguration {
    Write-Host ""
    Write-Host "--- Duplicate Detection Configuration ---" -ForegroundColor Yellow
    Write-Host "Duplicate detection will use Message-ID when available."
    Write-Host "For fallback, emails within the same time bucket are considered potential duplicates."
    
    $bucketInput = Read-Host "Enter time bucket size in minutes [$script:DuplicateBucketMinutes]"
    if ([string]::IsNullOrEmpty($bucketInput)) {
        $bucketMinutes = $script:DuplicateBucketMinutes
    } else {
        $bucketMinutes = 0
        if (-not [int]::TryParse($bucketInput, [ref]$bucketMinutes) -or $bucketMinutes -le 0) {
            Write-Warning "Invalid bucket size, using default: $script:DuplicateBucketMinutes"
            $bucketMinutes = $script:DuplicateBucketMinutes
        }
    }
    
    return @{
        BucketMinutes = $bucketMinutes
    }
}

function Get-OutputFolder {
    $desktop = [Environment]::GetFolderPath("Desktop")
    $defaultOutput = Join-Path $desktop "OutlookAlertReports"
    
    Write-Host ""
    Write-Host "--- Output Configuration ---" -ForegroundColor Yellow
    $outputFolder = Read-Host "Enter output folder path [$defaultOutput]"
    
    if ([string]::IsNullOrEmpty($outputFolder)) {
        $outputFolder = $defaultOutput
    }
    
    if (-not (Test-Path $outputFolder)) {
        try {
            New-Item -Path $outputFolder -ItemType Directory -Force | Out-Null
            Write-Host "Created output folder: $outputFolder" -ForegroundColor Green
        }
        catch {
            Write-Error "Could not create output folder: $outputFolder"
            return $null
        }
    }
    
    return $outputFolder
}
#endregion

#region Email Processing Functions
function Get-EmailData {
    param(
        [hashtable]$Config,
        [hashtable]$ComApp
    )
    
    try {
        if ($Config.Folder -eq "EntireMailbox") {
            # Search entire mailbox across all folders
            Write-Host "Searching entire mailbox..." -ForegroundColor Green
            return Get-EmailDataFromAllFolders -Config $Config -ComApp $ComApp
        } else {
            # Search specific folder
            $folder = Get-OutlookFolder -FolderPath $Config.Folder -Namespace $ComApp.Namespace
            if (-not $folder) {
                Write-Error "Could not access folder: $($Config.Folder)"
                return $null
            }
            
            Write-Verbose "Accessing folder: $($folder.FolderPath)"
            Write-Verbose "Total items in folder: $($folder.Items.Count)"
            
            return Get-EmailDataFromFolder -Folder $folder -Config $Config
        }
    }
    catch {
        Write-Error "Error processing emails: $($_.Exception.Message)"
        return $null
    }
}

function Get-EmailDataFromAllFolders {
    param(
        [hashtable]$Config,
        [hashtable]$ComApp
    )
    
    Write-Verbose "Performing comprehensive folder-by-folder search..."
    Write-Host "Enumerating all mailbox folders..." -ForegroundColor Yellow
    
    $allEmailData = @()
    $foldersToSearch = @()
    
    # Get all mail folders recursively
    try {
        $rootFolder = $ComApp.Namespace.GetDefaultFolder(6) # Inbox
        $script:ComObjectsToCleanup += $rootFolder
        $foldersToSearch += $rootFolder
        $foldersToSearch += Get-SubFoldersRecursive -Folder $rootFolder
        Write-Verbose "Added Inbox and subfolders"
    } catch {
        Write-Warning "Could not access Inbox: $($_.Exception.Message)"
    }
    
    # Add other default folders
    try {
        $sentItems = $ComApp.Namespace.GetDefaultFolder(5) # Sent Items
        $script:ComObjectsToCleanup += $sentItems
        $foldersToSearch += $sentItems
        $foldersToSearch += Get-SubFoldersRecursive -Folder $sentItems
        Write-Verbose "Added Sent Items and subfolders"
    } catch {
        Write-Verbose "Could not access Sent Items: $($_.Exception.Message)"
    }
    
    # Remove duplicates and filter out non-mail folders
    $uniqueFolders = @()
    $processedPaths = @()
    
    foreach ($folder in $foldersToSearch) {
        try {
            if ($folder.FolderPath -notin $processedPaths) {
                $processedPaths += $folder.FolderPath
                # Only include folders that contain mail items
                if ($folder.DefaultItemType -eq 0) { # olMailItem
                    $uniqueFolders += $folder
                }
            }
        }
        catch {
            Write-Verbose "Could not check folder type for $($folder.Name)"
        }
    }
    
    Write-Host "Searching $($uniqueFolders.Count) mail folders across the entire mailbox..." -ForegroundColor Green
    $folderCount = 0
    $totalFolders = $uniqueFolders.Count
    
    foreach ($folder in $uniqueFolders) {
        try {
            $folderCount++
            $script:ComObjectsToCleanup += $folder
            
            # Progress indicator
            if ($totalFolders -gt 10) {
                $percent = [Math]::Round(($folderCount / $totalFolders) * 100, 1)
                Write-Host "[$percent%] Searching folder $folderCount of $totalFolders : $($folder.Name)" -ForegroundColor Cyan
            } else {
                Write-Verbose "Searching folder: $($folder.FolderPath)"
            }
            
            $folderData = Get-EmailDataFromFolder -Folder $folder -Config $Config
            if ($folderData -and $folderData.Count -gt 0) {
                $allEmailData += $folderData
                Write-Host "  Found $($folderData.Count) matching emails in $($folder.Name)" -ForegroundColor Green
            }
        }
        catch {
            Write-Verbose "Could not search folder $($folder.Name): $($_.Exception.Message)"
        }
    }
    
    Write-Host ""
    Write-Host "Mailbox search complete! Found $($allEmailData.Count) total matching emails" -ForegroundColor Green
    
    # Add diagnostic information
    if ($allEmailData.Count -eq 0) {
        Write-Host ""
        Write-Host "No emails found matching the criteria. Troubleshooting tips:" -ForegroundColor Yellow
        Write-Host "  1. Check your date range - try expanding to last 30 days" -ForegroundColor Gray
        Write-Host "  2. If using address filter, verify the email address is correct" -ForegroundColor Gray
        Write-Host "  3. Try using 'No address filter' option to see all emails in date range" -ForegroundColor Gray
        Write-Host "  4. Run with -Verbose to see detailed processing information" -ForegroundColor Gray
        Write-Host "  5. Check if emails are in a different folder than expected" -ForegroundColor Gray
    }
    
    return $allEmailData
}

function Get-SubFoldersRecursive {
    param([object]$Folder)
    
    $subFolders = @()
    try {
        foreach ($subfolder in $Folder.Folders) {
            $script:ComObjectsToCleanup += $subfolder
            $subFolders += $subfolder
            $subFolders += Get-SubFoldersRecursive -Folder $subfolder
        }
    }
    catch {
        # Ignore errors when accessing subfolders
    }
    
    return $subFolders
}

function Get-EmailDataFromFolder {
    param(
        [object]$Folder,
        [hashtable]$Config
    )
    
    try {
        # Build restriction filter
        $restrictFilter = Build-RestrictFilter -Config $Config
        if ($restrictFilter) {
            Write-Verbose "Applying restriction filter: $restrictFilter"
        }
        
        # Apply restriction and get filtered items
        $items = $Folder.Items
        $script:ComObjectsToCleanup += $items
        
        if ($restrictFilter) {
            try {
                $items = $items.Restrict($restrictFilter)
                $script:ComObjectsToCleanup += $items
            }
            catch {
                Write-Verbose "Restriction filter failed for folder $($Folder.Name), using client-side filtering"
            }
        }
        
        # Sort by received time descending
        $items = $items.Sort("[ReceivedTime]", $true)
        $script:ComObjectsToCleanup += $items
        
        Write-Verbose "Folder $($Folder.Name): $($items.Count) items after filtering"
        
        # Process items and extract data
        $emailData = @()
        $processedCount = 0
        
        foreach ($item in $items) {
            $script:ComObjectsToCleanup += $item
            
            # Client-side date filter if restriction didn't work
            if ($item.ReceivedTime -lt $Config.StartDate -or $item.ReceivedTime -gt $Config.EndDate) {
                continue
            }
            
            # Client-side address filter if restriction didn't work
            if (-not (Test-EmailFilter -Item $item -Config $Config)) {
                continue
            }
            
            $emailInfo = Extract-EmailInfo -Item $item -FolderPath $Folder.FolderPath
            if ($emailInfo) {
                $emailData += $emailInfo
                $processedCount++
            }
        }
        
        if ($emailData.Count -gt 0) {
            Write-Verbose "Found $($emailData.Count) matching emails in folder: $($Folder.Name)"
        }
        
        return $emailData
    }
    catch {
        Write-Verbose "Error processing folder $($Folder.Name): $($_.Exception.Message)"
        return @()
    }
}

function Get-OutlookFolder {
    param(
        [string]$FolderPath,
        [object]$Namespace
    )
    
    try {
        if ($FolderPath -eq "Inbox" -or [string]::IsNullOrEmpty($FolderPath)) {
            return $Namespace.GetDefaultFolder(6) # olFolderInbox
        }
        
        # Handle selected folder from browser
        if ($FolderPath.StartsWith("SELECTED_FOLDER_") -and $script:SelectedFolderObject) {
            Write-Verbose "Using pre-selected folder object: $($script:SelectedFolderObject.Name)"
            return $script:SelectedFolderObject
        }
        
        Write-Verbose "Attempting to resolve folder path: $FolderPath"
        
        # Parse the folder path - handle different formats
        $pathParts = @()
        if ($FolderPath.Contains('\')) {
            # Split on backslashes and filter out empty parts
            $pathParts = $FolderPath -split '\\' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        } else {
            $pathParts = @($FolderPath)
        }
        
        Write-Verbose "Parsed path parts: $($pathParts -join ' -> ')"
        
        # Start from the appropriate root folder
        $currentFolder = $null
        $startIndex = 0
        
        # Determine starting folder based on first path part
        $firstPart = $pathParts[0].ToLower()
        if ($firstPart -match "inbox|mailbox|personal folders") {
            $currentFolder = $Namespace.GetDefaultFolder(6) # Inbox
            $startIndex = 1
        } elseif ($firstPart -match "sent") {
            $currentFolder = $Namespace.GetDefaultFolder(5) # Sent Items
            $startIndex = 1
        } elseif ($firstPart -match "draft") {
            $currentFolder = $Namespace.GetDefaultFolder(16) # Drafts
            $startIndex = 1
        } elseif ($firstPart -match "delete") {
            $currentFolder = $Namespace.GetDefaultFolder(3) # Deleted Items
            $startIndex = 1
        } else {
            # Default to Inbox if we can't determine the root
            $currentFolder = $Namespace.GetDefaultFolder(6)
            $startIndex = 0
        }
        
        Write-Verbose "Starting from folder: $($currentFolder.Name)"
        
        # Navigate through the remaining path parts
        for ($i = $startIndex; $i -lt $pathParts.Count; $i++) {
            $folderName = $pathParts[$i].Trim()
            if ([string]::IsNullOrWhiteSpace($folderName)) {
                continue
            }
            
            Write-Verbose "Looking for subfolder: $folderName"
            $found = $false
            
            foreach ($subfolder in $currentFolder.Folders) {
                $script:ComObjectsToCleanup += $subfolder
                Write-Verbose "  Checking: $($subfolder.Name)"
                
                if ($subfolder.Name -eq $folderName) {
                    $currentFolder = $subfolder
                    $found = $true
                    Write-Verbose "  Found match: $($subfolder.Name)"
                    break
                }
            }
            
            if (-not $found) {
                Write-Warning "Could not find folder: $folderName in path: $FolderPath"
                Write-Host "Available subfolders in $($currentFolder.Name):" -ForegroundColor Yellow
                foreach ($subfolder in $currentFolder.Folders) {
                    Write-Host "  - $($subfolder.Name)" -ForegroundColor Gray
                }
                return $Namespace.GetDefaultFolder(6) # Fallback to Inbox
            }
        }
        
        Write-Verbose "Successfully resolved to folder: $($currentFolder.Name)"
        return $currentFolder
    }
    catch {
        Write-Warning "Error accessing folder $FolderPath : $($_.Exception.Message)"
        return $Namespace.GetDefaultFolder(6) # Fallback to Inbox
    }
}

function Build-RestrictFilter {
    param([hashtable]$Config)
    
    $filters = @()
    
    # Date filter
    $startDateStr = $Config.StartDate.ToString("MM/dd/yyyy HH:mm")
    $endDateStr = $Config.EndDate.ToString("MM/dd/yyyy HH:mm")
    $filters += "[ReceivedTime] >= '$startDateStr'"
    $filters += "[ReceivedTime] <= '$endDateStr'"
    
    # Address filter (only if not "None")
    if ($Config.FilterType -eq "From") {
        $filters += "[SenderEmailAddress] = '$($Config.FilterAddress)'"
    } elseif ($Config.FilterType -eq "To") {
        $filters += "[To] LIKE '%$($Config.FilterAddress)%'"
    }
    # If FilterType is "None", don't add any address filters
    
    return ($filters -join " AND ")
}

function Test-EmailFilter {
    param(
        [object]$Item,
        [hashtable]$Config
    )
    
    try {
        # If no address filter is specified, include all emails
        if ($Config.FilterType -eq "None") {
            return $true
        }
        
        if ($Config.FilterType -eq "From") {
            return $Item.SenderEmailAddress -eq $Config.FilterAddress
        } else {
            # Check To, CC, and BCC recipients
            $recipients = @()
            foreach ($recipient in $Item.Recipients) {
                $recipients += $recipient.Address
            }
            return $recipients -contains $Config.FilterAddress
        }
    }
    catch {
        return $false
    }
}

function Extract-EmailInfo {
    param(
        [object]$Item,
        [string]$FolderPath
    )
    
    try {
        $emailInfo = @{
            ReceivedTime = $Item.ReceivedTime
            SenderEmailAddress = $Item.SenderEmailAddress
            To = Get-RecipientsString -Item $Item
            Subject = $Item.Subject
            NormalizedSubject = Get-NormalizedSubject -Subject $Item.Subject
            Body = Get-EmailBodyPreview -Item $Item
            EntryID = $Item.EntryID
            FolderPath = $FolderPath
            InternetMessageId = $null
            ServerName = $null
        }
        
        # Get Internet Message ID via PropertyAccessor
        try {
            $propertyAccessor = $Item.PropertyAccessor
            $script:ComObjectsToCleanup += $propertyAccessor
            $emailInfo.InternetMessageId = $propertyAccessor.GetProperty("http://schemas.microsoft.com/mapi/proptag/0x1035001E")
        }
        catch {
            # Internet Message ID not available
            $emailInfo.InternetMessageId = ""
        }
        
        # Extract server name from subject and body
        $emailInfo.ServerName = Extract-ServerName -Subject $Item.Subject -Body $emailInfo.Body
        
        return $emailInfo
    }
    catch {
        Write-Verbose "Could not extract info from email: $($_.Exception.Message)"
        return $null
    }
}

function Get-RecipientsString {
    param([object]$Item)
    
    try {
        $recipients = @()
        foreach ($recipient in $Item.Recipients) {
            $script:ComObjectsToCleanup += $recipient
            $recipients += $recipient.Address
        }
        return ($recipients -join "; ")
    }
    catch {
        return ""
    }
}

function Get-NormalizedSubject {
    param([string]$Subject)
    
    if ([string]::IsNullOrWhiteSpace($Subject)) {
        return ""
    }
    
    # Remove common prefixes and normalize
    $normalized = $Subject -replace '^\s*(?:RE:|FW:|FWD:|\[ALERT\]|\[WARNING\]|\[ERROR\])\s*', '' -replace '\s+', ' '
    $normalized = $normalized -replace '[^\w\s\-]', '' # Remove special characters except word chars, spaces, hyphens
    $normalized = $normalized.Trim()
    
    return $normalized
}

function Get-EmailBodyPreview {
    param([object]$Item)
    
    try {
        # Try to get plain text body first
        $body = ""
        
        try {
            $body = $Item.Body
        }
        catch {
            Write-Verbose "Could not access Body property"
        }
        
        # If body is empty or very short, try HTMLBody and strip HTML
        if ([string]::IsNullOrEmpty($body) -or $body.Length -lt 50) {
            try {
                $htmlBody = $Item.HTMLBody
                if (-not [string]::IsNullOrEmpty($htmlBody)) {
                    # Simple HTML tag removal for keyword matching
                    $body = $htmlBody -replace '<[^>]+>', ' ' -replace '&nbsp;', ' ' -replace '&[a-zA-Z]+;', ' '
                    Write-Verbose "Used HTML body and stripped tags"
                }
            }
            catch {
                Write-Verbose "Could not access HTMLBody property"
            }
        }
        
        if ([string]::IsNullOrEmpty($body)) {
            Write-Verbose "No body content found for email"
            return ""
        }
        
        # Clean up whitespace
        $body = $body -replace '\s+', ' '
        $body = $body.Trim()
        
        # Get more content for keyword matching (2000 characters)
        if ($body.Length -gt 2000) {
            $preview = $body.Substring(0, 2000)
            Write-Verbose "Using first 2000 characters of body (total: $($body.Length))"
            return $preview
        }
        
        Write-Verbose "Using full body content ($($body.Length) characters)"
        return $body
    }
    catch {
        Write-Verbose "Error extracting email body: $($_.Exception.Message)"
        return ""
    }
}

function Extract-ServerName {
    param(
        [string]$Subject,
        [string]$Body
    )
    
    $textToSearch = "$Subject $Body"
    
    foreach ($regex in $script:ServerNameRegexes) {
        if ($textToSearch -match $regex) {
            $serverName = $matches[1]
            if ($serverName) {
                return $serverName.ToLower().Trim()
            }
        }
    }
    
    return "Unknown"
}

function Process-EmailData {
    param(
        [array]$EmailData,
        [hashtable]$Config
    )
    
    Write-Verbose "Processing $($EmailData.Count) emails for classification and duplicate detection..."
    
    # Classify emails
    Write-Verbose "Classifying emails with keywords..."
    Write-Verbose "High Priority Keywords: $($Config.HighPriorityKeywords -join ', ')"
    Write-Verbose "Low-Hanging Fruit Keywords: $($Config.LowHangingFruitKeywords -join ', ')"
    
    $keywordDebugMode = $VerbosePreference -eq 'Continue'
    
    foreach ($email in $EmailData) {
        $searchText = "$($email.Subject) $($email.Body)"
        
        if ($keywordDebugMode) {
            Write-Host ""
            Write-Host "Processing email: $($email.Subject)" -ForegroundColor Cyan
            Write-Host "  Search text length: $($searchText.Length) characters" -ForegroundColor Gray
            if ($searchText.Length -gt 200) {
                Write-Host "  First 200 chars: $($searchText.Substring(0, 200))..." -ForegroundColor Gray
            } else {
                Write-Host "  Full text: $searchText" -ForegroundColor Gray
            }
        }
        
        $email.HighPriority = Test-KeywordMatch -Text $searchText -Keywords $Config.HighPriorityKeywords -EmailSubject $email.Subject -Verbose:$keywordDebugMode
        $email.LowHangingFruit = Test-KeywordMatch -Text $searchText -Keywords $Config.LowHangingFruitKeywords -EmailSubject $email.Subject -Verbose:$keywordDebugMode
        $email.IsDuplicate = $false
        $email.DuplicateGroupId = ""
        
        if ($keywordDebugMode) {
            Write-Host "  High Priority: $($email.HighPriority)" -ForegroundColor $(if ($email.HighPriority) { "Red" } else { "Gray" })
            Write-Host "  Low-Hanging Fruit: $($email.LowHangingFruit)" -ForegroundColor $(if ($email.LowHangingFruit) { "Green" } else { "Gray" })
        }
    }
    
    # Handle duplicates
    $duplicateGroups = @{}
    $groupCounter = 1
    
    foreach ($email in $EmailData) {
        $duplicateKey = Get-DuplicateKey -Email $email -BucketMinutes $Config.DuplicateBucketMinutes
        
        if ($duplicateGroups.ContainsKey($duplicateKey)) {
            # This is a duplicate
            $email.IsDuplicate = $true
            $email.DuplicateGroupId = $duplicateGroups[$duplicateKey].GroupId
            $duplicateGroups[$duplicateKey].Count++
        } else {
            # This is the first occurrence (canonical)
            $groupId = "GROUP_$groupCounter"
            $email.DuplicateGroupId = $groupId
            $duplicateGroups[$duplicateKey] = @{
                GroupId = $groupId
                CanonicalEmail = $email
                Count = 1
            }
            $groupCounter++
        }
    }
    
    $duplicateCount = ($EmailData | Where-Object { $_.IsDuplicate }).Count
    $uniqueCount = $EmailData.Count - $duplicateCount
    Write-Verbose "Found $uniqueCount unique emails and $duplicateCount duplicates"
    
    return @{
        AllEmails = $EmailData
        UniqueEmails = $EmailData | Where-Object { -not $_.IsDuplicate }
        DuplicateEmails = $EmailData | Where-Object { $_.IsDuplicate }
        DuplicateGroups = $duplicateGroups
    }
}

function Test-KeywordMatch {
    param(
        [string]$Text,
        [array]$Keywords,
        [string]$EmailSubject = "",
        [switch]$Verbose
    )
    
    if ([string]::IsNullOrWhiteSpace($Text) -or $Keywords.Count -eq 0) {
        return $false
    }
    
    $lowerText = $Text.ToLower()
    foreach ($keyword in $Keywords) {
        $lowerKeyword = $keyword.ToLower()
        if ($lowerText.Contains($lowerKeyword)) {
            if ($Verbose) {
                Write-Host "  ✓ Found keyword '$keyword' in email: $EmailSubject" -ForegroundColor Green
            }
            return $true
        }
    }
    
    if ($Verbose -and -not [string]::IsNullOrWhiteSpace($EmailSubject)) {
        Write-Verbose "  ✗ No keywords found in: $EmailSubject"
    }
    
    return $false
}

function Get-DuplicateKey {
    param(
        [hashtable]$Email,
        [int]$BucketMinutes
    )
    
    # Prefer Internet Message ID if available
    if (-not [string]::IsNullOrWhiteSpace($Email.InternetMessageId)) {
        return $Email.InternetMessageId
    }
    
    # Fallback to hash of normalized subject + server + bucketed timestamp
    $bucketedTime = [Math]::Floor($Email.ReceivedTime.Ticks / (600000000L * $BucketMinutes)) # Convert to bucket
    $fallbackKey = $Email.NormalizedSubject + "|" + $Email.ServerName + "|" + $bucketedTime.ToString()
    
    return $fallbackKey
}
#endregion

#region Reporting Functions
function Generate-Reports {
    param(
        [hashtable]$ProcessedData,
        [hashtable]$Config
    )
    
    Write-Host ""
    Write-Host "Generating reports..." -ForegroundColor Cyan
    
    # Generate console summary
    Show-ConsoleSummary -ProcessedData $ProcessedData -Config $Config
    
    # Generate CSV files
    Export-CsvReports -ProcessedData $ProcessedData -Config $Config
    
    # Generate HTML report
    Export-HtmlReport -ProcessedData $ProcessedData -Config $Config
    
    Write-Host ""
    Write-Host "All reports generated successfully in: $($Config.OutputFolder)" -ForegroundColor Green
}

function Show-ConsoleSummary {
    param(
        [hashtable]$ProcessedData,
        [hashtable]$Config
    )
    
    $allEmails = $ProcessedData.AllEmails
    $uniqueEmails = $ProcessedData.UniqueEmails
    $duplicateEmails = $ProcessedData.DuplicateEmails
    
    Write-Host ""
    Write-Host "=== OUTLOOK ALERT ANALYSIS SUMMARY ===" -ForegroundColor Cyan
    Write-Host "======================================="
    
    # Configuration summary
    Write-Host ""
    Write-Host "Configuration:" -ForegroundColor Yellow
    Write-Host "  Time Window: $($Config.TimeDescription)"
    if ($Config.FilterType -eq "None") {
        Write-Host "  Filter: No address filter (all emails in scope)"
    } else {
        Write-Host "  Filter: $($Config.FilterType) = $($Config.FilterAddress)"
    }
    Write-Host "  Folder: $($Config.Folder)"
    Write-Host "  Duplicate Bucket: $($Config.DuplicateBucketMinutes) minutes"
    
    # Basic statistics
    Write-Host ""
    Write-Host "Email Statistics:" -ForegroundColor Yellow
    Write-Host "  Total Matching Emails: $($allEmails.Count)"
    Write-Host "  Unique Alerts: $($uniqueEmails.Count)"
    Write-Host "  Duplicates: $($duplicateEmails.Count)"
    if ($allEmails.Count -gt 0) {
        $duplicateRatio = [Math]::Round(($duplicateEmails.Count / $allEmails.Count) * 100, 1)
        Write-Host "  Duplicate Ratio: $duplicateRatio%"
    }
    
    # Priority classification
    $highPriorityCount = ($allEmails | Where-Object { $_.HighPriority }).Count
    $lowHangingCount = ($allEmails | Where-Object { $_.LowHangingFruit }).Count
    $otherCount = $allEmails.Count - $highPriorityCount - $lowHangingCount
    
    Write-Host ""
    Write-Host "Alert Classification:" -ForegroundColor Yellow
    Write-Host "  High Priority: $highPriorityCount" -ForegroundColor Red
    Write-Host "  Low-Hanging Fruit: $lowHangingCount" -ForegroundColor Green
    Write-Host "  Other: $otherCount"
    
    # Top 10 subjects
    Write-Host ""
    Write-Host "Top 10 Subjects by Frequency:" -ForegroundColor Yellow
    $topSubjects = $allEmails | Group-Object NormalizedSubject | Sort-Object Count -Descending | Select-Object -First 10
    foreach ($subject in $topSubjects) {
        Write-Host "  $($subject.Count)x - $($subject.Name)"
    }
    
    # Top 10 servers
    Write-Host ""
    Write-Host "Top 10 Servers by Frequency:" -ForegroundColor Yellow
    $topServers = $allEmails | Group-Object ServerName | Sort-Object Count -Descending | Select-Object -First 10
    foreach ($server in $topServers) {
        Write-Host "  $($server.Count)x - $($server.Name)"
    }
    
    # Alerts per day
    Write-Host ""
    Write-Host "Alerts per Day:" -ForegroundColor Yellow
    $alertsPerDay = $allEmails | Group-Object { $_.ReceivedTime.Date } | Sort-Object Name
    foreach ($day in $alertsPerDay) {
        $date = [DateTime]$day.Name
        Write-Host "  $($date.ToString('yyyy-MM-dd')): $($day.Count) alerts"
    }
    
    # Most recent unique alerts
    Write-Host ""
    Write-Host "10 Most Recent Unique Alerts:" -ForegroundColor Yellow
    $recentUnique = $uniqueEmails | Sort-Object ReceivedTime -Descending | Select-Object -First 10
    foreach ($email in $recentUnique) {
        $priority = if ($email.HighPriority) { " [HIGH]" } elseif ($email.LowHangingFruit) { " [LOW]" } else { "" }
        $timeStr = $email.ReceivedTime.ToString('yyyy-MM-dd HH:mm')
        Write-Host "  $timeStr - $($email.ServerName) - $($email.Subject)$priority"
    }
}

function Export-CsvReports {
    param(
        [hashtable]$ProcessedData,
        [hashtable]$Config
    )
    
    Write-Verbose "Exporting CSV reports..."
    
    # Convert email data to CSV-friendly format
    $csvAllEmails = Convert-EmailsForCsv -Emails $ProcessedData.AllEmails
    $csvUniqueEmails = Convert-EmailsForCsv -Emails $ProcessedData.UniqueEmails
    $csvDuplicateEmails = Convert-EmailsForCsv -Emails $ProcessedData.DuplicateEmails
    
    # Export CSV files
    $allCsvPath = Join-Path $Config.OutputFolder "alerts_all.csv"
    $uniqueCsvPath = Join-Path $Config.OutputFolder "alerts_unique.csv"
    $duplicatesCsvPath = Join-Path $Config.OutputFolder "alerts_duplicates.csv"
    
    $csvAllEmails | Export-Csv -Path $allCsvPath -NoTypeInformation -Encoding UTF8
    $csvUniqueEmails | Export-Csv -Path $uniqueCsvPath -NoTypeInformation -Encoding UTF8
    $csvDuplicateEmails | Export-Csv -Path $duplicatesCsvPath -NoTypeInformation -Encoding UTF8
    
    $allCount = $csvAllEmails.Count
    $uniqueCount = $csvUniqueEmails.Count 
    $duplicateCount = $csvDuplicateEmails.Count
    
    Write-Host "  Exported: alerts_all.csv ($allCount rows)" -ForegroundColor Green
    Write-Host "  Exported: alerts_unique.csv ($uniqueCount rows)" -ForegroundColor Green
    Write-Host "  Exported: alerts_duplicates.csv ($duplicateCount rows)" -ForegroundColor Green
}

function Convert-EmailsForCsv {
    param([array]$Emails)
    
    return $Emails | ForEach-Object {
        [PSCustomObject]@{
            ReceivedTime = $_.ReceivedTime.ToString('yyyy-MM-dd HH:mm:ss')
            SenderEmailAddress = $_.SenderEmailAddress
            To = $_.To
            Subject = $_.Subject
            NormalizedSubject = $_.NormalizedSubject
            ServerName = $_.ServerName
            HighPriority = $_.HighPriority
            LowHangingFruit = $_.LowHangingFruit
            IsDuplicate = $_.IsDuplicate
            DuplicateGroupId = $_.DuplicateGroupId
            EntryID = $_.EntryID
            InternetMessageId = $_.InternetMessageId
            FolderPath = $_.FolderPath
        }
    }
}

function Export-HtmlReport {
    param(
        [hashtable]$ProcessedData,
        [hashtable]$Config
    )
    
    Write-Verbose "Generating HTML report..."
    
    $allEmails = $ProcessedData.AllEmails
    $uniqueEmails = $ProcessedData.UniqueEmails
    $duplicateEmails = $ProcessedData.DuplicateEmails
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    
    # Calculate statistics
    $highPriorityCount = ($allEmails | Where-Object { $_.HighPriority }).Count
    $lowHangingCount = ($allEmails | Where-Object { $_.LowHangingFruit }).Count
    $otherCount = $allEmails.Count - $highPriorityCount - $lowHangingCount
    $duplicateRatio = if ($allEmails.Count -gt 0) { [Math]::Round(($duplicateEmails.Count / $allEmails.Count) * 100, 1) } else { 0 }
    
    $filterDesc = if ($Config.FilterType -eq "None") { "No address filter (all emails in scope)" } else { "$($Config.FilterType) = $($Config.FilterAddress)" }
    
    # Build HTML content with simple string concatenation
    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Outlook Alert Analysis Report</title>
    <style>
        body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; margin: 0; padding: 20px; background-color: #f5f5f5; color: #333; }
        .container { max-width: 1200px; margin: 0 auto; background-color: white; padding: 30px; border-radius: 8px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); }
        h1 { color: #2c3e50; text-align: center; margin-bottom: 10px; border-bottom: 3px solid #3498db; padding-bottom: 10px; }
        .subtitle { text-align: center; color: #7f8c8d; margin-bottom: 30px; }
        .section { margin-bottom: 30px; }
        .section h2 { color: #34495e; border-left: 4px solid #3498db; padding-left: 15px; margin-bottom: 15px; }
        .config-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(250px, 1fr)); gap: 15px; margin-bottom: 20px; }
        .config-item { background-color: #ecf0f1; padding: 15px; border-radius: 5px; }
        .config-item strong { color: #2c3e50; }
        .stats-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 15px; margin-bottom: 20px; }
        .stat-card { background-color: #ecf0f1; padding: 20px; border-radius: 8px; text-align: center; }
        .stat-number { font-size: 2em; font-weight: bold; color: #2c3e50; }
        .stat-label { color: #7f8c8d; margin-top: 5px; }
        .priority-high { background-color: #fdf2f2; border-left: 4px solid #e74c3c; }
        .priority-high .stat-number { color: #e74c3c; }
        .priority-low { background-color: #f0f9f4; border-left: 4px solid #27ae60; }
        .priority-low .stat-number { color: #27ae60; }
        table { width: 100%; border-collapse: collapse; margin-top: 15px; }
        th, td { text-align: left; padding: 12px; border-bottom: 1px solid #ddd; }
        th { background-color: #34495e; color: white; font-weight: 600; }
        tr:nth-child(even) { background-color: #f9f9f9; }
        tr:hover { background-color: #f5f5f5; }
        .top-list { background-color: #f8f9fa; padding: 15px; border-radius: 5px; margin-top: 10px; }
        .top-item { display: flex; justify-content: space-between; padding: 8px 0; border-bottom: 1px solid #e9ecef; }
        .top-item:last-child { border-bottom: none; }
        .count-badge { background-color: #3498db; color: white; padding: 2px 8px; border-radius: 10px; font-size: 0.9em; font-weight: bold; }
        .footer { margin-top: 30px; text-align: center; color: #7f8c8d; font-size: 0.9em; border-top: 1px solid #ddd; padding-top: 15px; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Outlook Alert Analysis Report</h1>
        <div class="subtitle">Generated on $timestamp</div>
        
        <div class="section">
            <h2>Configuration</h2>
            <div class="config-grid">
                <div class="config-item"><strong>Time Window:</strong><br>$($Config.TimeDescription)</div>
                <div class="config-item"><strong>Filter:</strong><br>$filterDesc</div>
                <div class="config-item"><strong>Folder:</strong><br>$($Config.Folder)</div>
                <div class="config-item"><strong>Duplicate Bucket:</strong><br>$($Config.DuplicateBucketMinutes) minutes</div>
            </div>
        </div>
        
        <div class="section">
            <h2>Summary Statistics</h2>
            <div class="stats-grid">
                <div class="stat-card"><div class="stat-number">$($allEmails.Count)</div><div class="stat-label">Total Emails</div></div>
                <div class="stat-card"><div class="stat-number">$($uniqueEmails.Count)</div><div class="stat-label">Unique Alerts</div></div>
                <div class="stat-card"><div class="stat-number">$($duplicateEmails.Count)</div><div class="stat-label">Duplicates</div></div>
                <div class="stat-card"><div class="stat-number">$duplicateRatio%</div><div class="stat-label">Duplicate Ratio</div></div>
            </div>
        </div>
        
        <div class="section">
            <h2>Alert Classification</h2>
            <div class="stats-grid">
                <div class="stat-card priority-high"><div class="stat-number">$highPriorityCount</div><div class="stat-label">High Priority</div></div>
                <div class="stat-card priority-low"><div class="stat-number">$lowHangingCount</div><div class="stat-label">Low-Hanging Fruit</div></div>
                <div class="stat-card"><div class="stat-number">$otherCount</div><div class="stat-label">Other</div></div>
            </div>
        </div>
        
        <div class="section">
            <h2>Top 10 Subjects by Frequency</h2>
            <div class="top-list">
"@

    # Add top subjects
    $topSubjects = $allEmails | Group-Object NormalizedSubject | Sort-Object Count -Descending | Select-Object -First 10
    foreach ($subject in $topSubjects) {
        $safeSubjectName = if ($subject.Name) { $subject.Name -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;' -replace '&', '&amp;' } else { "(No Subject)" }
        $html += "<div class=""top-item""><span>$safeSubjectName</span><span class=""count-badge"">$($subject.Count)</span></div>"
    }

    $html += @"
            </div>
        </div>
        
        <div class="section">
            <h2>Top 10 Servers by Frequency</h2>
            <div class="top-list">
"@

    # Add top servers
    $topServers = $allEmails | Group-Object ServerName | Sort-Object Count -Descending | Select-Object -First 10
    foreach ($server in $topServers) {
        $safeServerName = if ($server.Name) { $server.Name -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;' -replace '&', '&amp;' } else { "Unknown" }
        $html += "<div class=""top-item""><span>$safeServerName</span><span class=""count-badge"">$($server.Count)</span></div>"
    }

    $html += @"
            </div>
        </div>
        
        <div class="section">
            <h2>Alerts per Day</h2>
            <table>
                <thead><tr><th>Date</th><th>Alert Count</th></tr></thead>
                <tbody>
"@

    # Add daily stats
    $alertsPerDay = $allEmails | Group-Object { $_.ReceivedTime.Date } | Sort-Object Name
    foreach ($day in $alertsPerDay) {
        $date = [DateTime]$day.Name
        $dateStr = $date.ToString('yyyy-MM-dd')
        $html += "<tr><td>$dateStr</td><td>$($day.Count)</td></tr>"
    }

    $html += @"
                </tbody>
            </table>
        </div>
        
        <div class="section">
            <h2>10 Most Recent Unique Alerts</h2>
            <table>
                <thead><tr><th>Date/Time</th><th>Server</th><th>Subject</th><th>Priority</th></tr></thead>
                <tbody>
"@

    # Add recent alerts
    $recentUnique = $uniqueEmails | Sort-Object ReceivedTime -Descending | Select-Object -First 10
    foreach ($email in $recentUnique) {
        $priorityBadge = if ($email.HighPriority) { 
            'High' 
        } elseif ($email.LowHangingFruit) { 
            'Low' 
        } else { 
            'Other' 
        }
        
        $safeServerName = if ($email.ServerName) { $email.ServerName -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;' -replace '&', '&amp;' } else { "Unknown" }
        $safeSubject = if ($email.Subject) { $email.Subject -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;' -replace '&', '&amp;' } else { "(No Subject)" }
        $timeStr = $email.ReceivedTime.ToString('yyyy-MM-dd HH:mm')
        
        $html += "<tr><td>$timeStr</td><td>$safeServerName</td><td>$safeSubject</td><td>$priorityBadge</td></tr>"
    }

    $html += @"
                </tbody>
            </table>
        </div>
        
        <div class="footer">
            <p>Report generated by PowerShell Outlook Alert Reporter</p>
            <p>High Priority Keywords: $($Config.HighPriorityKeywords -join ', ')</p>
            <p>Low-Hanging Fruit Keywords: $($Config.LowHangingFruitKeywords -join ', ')</p>
        </div>
    </div>
</body>
</html>
"@

    # Write HTML file
    $htmlPath = Join-Path $Config.OutputFolder "alerts_report.html"
    $html | Out-File -FilePath $htmlPath -Encoding UTF8
    
    Write-Host "  Exported: alerts_report.html" -ForegroundColor Green
}

function Show-WhatIfSummary {
    param(
        [hashtable]$ProcessedData,
        [hashtable]$Config
    )
    
    Write-Host ""
    Write-Host "=== WHATIF MODE - NO FILES GENERATED ===" -ForegroundColor Magenta
    Show-ConsoleSummary -ProcessedData $ProcessedData -Config $Config
    Write-Host ""
    Write-Host "WhatIf complete. No files were written." -ForegroundColor Magenta
}

function Generate-EmptyReport {
    param([hashtable]$Config)
    
    $emptyData = @{
        AllEmails = @()
        UniqueEmails = @()
        DuplicateEmails = @()
        DuplicateGroups = @{}
    }
    
    Generate-Reports -ProcessedData $emptyData -Config $Config
}
#endregion

# Initialize error handling
$ErrorActionPreference = "Stop"
trap {
    Write-Error "Script terminated due to error: $($_.Exception.Message)"
    Cleanup-ComObjects
    exit 1
}

# Register cleanup on script exit
Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
    Cleanup-ComObjects
}

# Main execution starts here
try {
    Write-Host "PowerShell Outlook Alert Reporter" -ForegroundColor Cyan
    Write-Host "=================================="
    Write-Host ""
    
    if ($WhatIf) {
        Write-Host "Running in WhatIf mode - no files will be written" -ForegroundColor Yellow
    }
    
    if ($VerbosePreference -eq 'Continue') {
        Write-Host "Verbose mode enabled - detailed progress will be shown" -ForegroundColor Yellow
    }
    
    # Get user configuration
    $config = Show-MainMenu
    if (-not $config) {
        Write-Host "Configuration cancelled. Exiting." -ForegroundColor Red
        exit 0
    }
    
    Write-Host ""
    Write-Host "Configuration complete. Starting analysis..." -ForegroundColor Green
    
    # Initialize Outlook and analyze emails
    $comApp = Initialize-OutlookCom
    if (-not $comApp) {
        Write-Error "Failed to initialize Outlook COM"
        exit 1
    }
    
    # Process emails
    $emailData = Get-EmailData -Config $config -ComApp $comApp
    if (-not $emailData -or $emailData.Count -eq 0) {
        Write-Host "No matching emails found for the specified criteria." -ForegroundColor Yellow
        if (-not $WhatIf) {
            Generate-EmptyReport -Config $config
        }
        exit 0
    }
    
    # Classify and process emails
    $processedData = Process-EmailData -EmailData $emailData -Config $config
    
    # Generate reports
    if (-not $WhatIf) {
        Generate-Reports -ProcessedData $processedData -Config $config
    } else {
        Show-WhatIfSummary -ProcessedData $processedData -Config $config
    }
    
}
finally {
    Cleanup-ComObjects
}