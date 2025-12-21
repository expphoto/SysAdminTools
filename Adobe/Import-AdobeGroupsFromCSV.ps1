<#
.SYNOPSIS
    Creates Azure AD security groups from CSV files and adds users to them.

.DESCRIPTION
    This script scans the current directory for CSV files, creates Azure AD security groups
    named after each file (without .csv extension), and adds users listed in each CSV
    by their UserPrincipleName.

.NOTES
    Requirements: Microsoft.Graph PowerShell module
    The CSV files must have a column named 'UserPrincipleName'

#>

#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Groups, Microsoft.Graph.Users

# Connect to Microsoft Graph
Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Cyan
try {
    Connect-MgGraph -Scopes "Group.ReadWrite.All", "GroupMember.ReadWrite.All", "User.Read.All" -ErrorAction Stop
    Write-Host "Successfully connected to Microsoft Graph" -ForegroundColor Green
}
catch {
    Write-Error "Failed to connect to Microsoft Graph: $_"
    exit 1
}

# Get the script's directory (where the CSV files are located)
$csvFolder = $PSScriptRoot
Write-Host "`nScanning folder: $csvFolder" -ForegroundColor Cyan

# Get all CSV files in the folder
$csvFiles = Get-ChildItem -Path $csvFolder -Filter "*.csv" -File

if ($csvFiles.Count -eq 0) {
    Write-Warning "No CSV files found in $csvFolder"
    Disconnect-MgGraph
    exit 0
}

Write-Host "Found $($csvFiles.Count) CSV file(s)" -ForegroundColor Green

# Process each CSV file
foreach ($csvFile in $csvFiles) {
    Write-Host "`n================================" -ForegroundColor Yellow
    Write-Host "Processing: $($csvFile.Name)" -ForegroundColor Yellow
    Write-Host "================================" -ForegroundColor Yellow

    # Extract group name from filename (remove .csv extension)
    $groupName = [System.IO.Path]::GetFileNameWithoutExtension($csvFile.Name)

    # Import CSV file
    try {
        $users = Import-Csv -Path $csvFile.FullName -ErrorAction Stop
        Write-Host "Imported $($users.Count) user(s) from CSV" -ForegroundColor Cyan

        # Validate CSV has UserPrincipleName column
        if (-not ($users | Get-Member -Name "UserPrincipleName")) {
            Write-Warning "CSV file does not contain 'UserPrincipleName' column. Skipping..."
            continue
        }
    }
    catch {
        Write-Error "Failed to import CSV file: $_"
        continue
    }

    # Check if group already exists
    Write-Host "Checking if group '$groupName' exists..." -ForegroundColor Cyan
    try {
        $existingGroup = Get-MgGroup -Filter "displayName eq '$groupName'" -ErrorAction Stop

        if ($existingGroup) {
            Write-Host "Group '$groupName' already exists (ID: $($existingGroup.Id))" -ForegroundColor Green
            $group = $existingGroup
        }
        else {
            # Create the group
            Write-Host "Creating group '$groupName'..." -ForegroundColor Cyan
            $groupParams = @{
                DisplayName = $groupName
                MailEnabled = $false
                MailNickname = $groupName -replace '\s', ''
                SecurityEnabled = $true
                Description = "Auto-created from $($csvFile.Name)"
            }

            $group = New-MgGroup -BodyParameter $groupParams -ErrorAction Stop
            Write-Host "Successfully created group '$groupName' (ID: $($group.Id))" -ForegroundColor Green
        }
    }
    catch {
        Write-Error "Failed to check/create group: $_"
        continue
    }

    # Add users to the group
    Write-Host "Adding users to group '$groupName'..." -ForegroundColor Cyan
    $successCount = 0
    $failCount = 0
    $skippedCount = 0

    foreach ($user in $users) {
        $upn = $user.UserPrincipleName

        if ([string]::IsNullOrWhiteSpace($upn)) {
            Write-Warning "Skipping empty UserPrincipleName"
            $skippedCount++
            continue
        }

        try {
            # Get user object
            $mgUser = Get-MgUser -Filter "userPrincipalName eq '$upn'" -ErrorAction Stop

            if (-not $mgUser) {
                Write-Warning "User not found: $upn"
                $failCount++
                continue
            }

            # Check if user is already a member
            $existingMember = Get-MgGroupMember -GroupId $group.Id -Filter "id eq '$($mgUser.Id)'" -ErrorAction SilentlyContinue

            if ($existingMember) {
                Write-Host "  [SKIP] $upn (already a member)" -ForegroundColor Gray
                $skippedCount++
            }
            else {
                # Add user to group
                New-MgGroupMember -GroupId $group.Id -DirectoryObjectId $mgUser.Id -ErrorAction Stop
                Write-Host "  [OK] $upn" -ForegroundColor Green
                $successCount++
            }
        }
        catch {
            Write-Warning "  [FAIL] $upn - $($_.Exception.Message)"
            $failCount++
        }
    }

    # Summary for this file
    Write-Host "`nSummary for '$groupName':" -ForegroundColor Cyan
    Write-Host "  Added: $successCount" -ForegroundColor Green
    Write-Host "  Already members: $skippedCount" -ForegroundColor Gray
    Write-Host "  Failed: $failCount" -ForegroundColor $(if ($failCount -gt 0) { "Red" } else { "Gray" })
}

Write-Host "`n================================" -ForegroundColor Yellow
Write-Host "All files processed!" -ForegroundColor Yellow
Write-Host "================================" -ForegroundColor Yellow

# Disconnect from Microsoft Graph
Disconnect-MgGraph
Write-Host "`nDisconnected from Microsoft Graph" -ForegroundColor Cyan
