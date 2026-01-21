<#
.SYNOPSIS
    Quick OneDrive external sharing scan with timeouts
.DESCRIPTION
    Scans specific OneDrive sites for external sharing with better error handling
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$TenantAdminUrl,

    [Parameter(Mandatory = $true)]
    [string]$ClientId,

    [Parameter(Mandatory = $true)]
    [string]$TenantId,

    [Parameter(Mandatory = $false)]
    [int]$SiteTimeoutSeconds = 300,

    [Parameter(Mandatory = $false)]
    [int]$MaxFilesPerSite = 0
)

if (-not (Get-Module -ListAvailable -Name PnP.PowerShell)) {
    Write-Error "PnP.PowerShell module not installed"
    exit 1
}

$allExternalShares = @()
$userSummary = @()

# All users found in tenant
$allUsers = @(
    "alissa@charvonia.com",
    "backupadminQNDx@channelislandslg.com",
    "Joseph@channelislandslg.com",
    "keith@charvonia.com",
    "kevin@channelislandslg.com",
    "lawcus@channelislandslg.com",
    "linda@charvonia.com",
    "max@channelislandslg.com",
    "Michael@channelislandslg.com",
    "rhiannon@channelislandslg.com",
    "russ@channelislandslg.com",
    "russcharvonia@channelislandslg.com",
    "sherry@channelislandslg.com",
    "virginia@channelislandslg.com"
)

try {
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "QUICK ONEDRIVE EXTERNAL SHARING SCAN" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Users to scan: $($allUsers.Count)" -ForegroundColor Yellow
    Write-Host "Timeout per site: $SiteTimeoutSeconds seconds" -ForegroundColor Yellow
    if ($MaxFilesPerSite -gt 0) {
        Write-Host "Max files per site: $MaxFilesPerSite" -ForegroundColor Yellow
    }
    Write-Host ""

    Write-Host "Connecting to SharePoint Admin Center..." -ForegroundColor Cyan
    Connect-PnPOnline -Url $TenantAdminUrl -ClientId $ClientId -Tenant $TenantId -Interactive

    $userCounter = 0
    $totalFiles = 0
    $totalExternal = 0
    $skippedSites = 0

    foreach ($user in $allUsers) {
        $userCounter++

        $safeUser = $user.Replace("@", "_").Replace(".", "_")
        $oneDriveUrl = "https://netorg368294-my.sharepoint.com/personal/$safeUser"

        Write-Host "[$userCounter/$($allUsers.Count)] Checking: $user" -ForegroundColor Cyan
        Write-Host "  URL: $oneDriveUrl" -ForegroundColor Gray

        try {
            $job = Start-Job -ScriptBlock {
                param($url, $clientId, $tenantId, $maxFiles)
                Import-Module PnP.PowerShell

                try {
                    Connect-PnPOnline -Url $url -ClientId $clientId -Tenant $tenantId -ErrorAction Stop

                    $docLib = Get-PnPList -Identity "Documents" -ErrorAction Stop
                    $items = Get-PnPListItem -List $docLib -PageSize 500 -Fields "ID","FileRef","FileLeafRef","File_x0020_Type"

                    if ($maxFiles -gt 0 -and $items.Count -gt $maxFiles) {
                        $items = $items | Select-Object -First $maxFiles
                    }

                    $userFiles = 0
                    $userExternal = 0
                    $externalShares = @()

                    foreach ($item in $items) {
                        if ($item.FileSystemObjectType -eq "File") {
                            $userFiles++

                            try {
                                $sharingLinks = Get-PnPFileSharingLink -Identity $item.Id -List $docLib -ErrorAction SilentlyContinue

                                if ($sharingLinks) {
                                    foreach ($link in $sharingLinks) {
                                        if ($link.ShareLink) {
                                            $isExternal = $false
                                            $linkType = "Unknown"

                                            if ($link.ShareLink.IsAnonymous -or $link.ShareLink.AllowsAnonymousAccess) {
                                                $isExternal = $true
                                                $linkType = "Anonymous"
                                            }
                                            elseif ($link.ShareLink.Scope -ne "Organization") {
                                                $isExternal = $true
                                                $linkType = "External"
                                            }

                                            if ($isExternal) {
                                                $userExternal++

                                                $externalShares += [PSCustomObject]@{
                                                    User = ""
                                                    OneDriveUrl = $url
                                                    FileName = $item["FileLeafRef"]
                                                    FilePath = $item["FileRef"]
                                                    LinkType = $linkType
                                                    LinkScope = $link.ShareLink.Scope
                                                    CreatedBy = if ($link.ShareLink.CreatedBy) { $link.ShareLink.CreatedBy.Email } else { "Unknown" }
                                                    CreatedDate = if ($link.ShareLink.Created) { $link.ShareLink.Created.ToString() } else { "Unknown" }
                                                }
                                            }
                                        }
                                    }
                                }

                                $hasUniquePerms = Get-PnPProperty -ClientObject $item -Property HasUniqueRoleAssignments -ErrorAction SilentlyContinue
                                if ($item.HasUniqueRoleAssignments) {
                                    $roleAssignments = Get-PnPProperty -ClientObject $item -Property RoleAssignments -ErrorAction SilentlyContinue

                                    if ($roleAssignments) {
                                        Get-PnPProperty -ClientObject $roleAssignments -Property Member, RoleDefinitionBindings -ErrorAction SilentlyContinue

                                        foreach ($roleAssignment in $roleAssignments) {
                                            $member = $roleAssignment.Member

                                            if ($member.LoginName -like "*#ext#*" -or $member.LoginName -like "*urn:spo:guest*") {
                                                $permissions = ($roleAssignment.RoleDefinitionBindings | Select-Object -ExpandProperty Name) -join ", "

                                                $userExternal++

                                                $externalShares += [PSCustomObject]@{
                                                    User = ""
                                                    OneDriveUrl = $url
                                                    FileName = $item["FileLeafRef"]
                                                    FilePath = $item["FileRef"]
                                                    LinkType = "External User Permission"
                                                    LinkScope = "External"
                                                    CreatedBy = "$($member.Title) ($($member.Email))"
                                                    CreatedDate = "N/A"
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            catch {
                                # Skip errors on individual files
                            }
                        }
                    }

                    Disconnect-PnPOnline -ErrorAction SilentlyContinue

                    return @{
                        Success = $true
                        UserFiles = $userFiles
                        UserExternal = $userExternal
                        ExternalShares = $externalShares
                    }
                }
                catch {
                    return @{
                        Success = $false
                        Error = $_.Exception.Message
                    }
                }
            } -ArgumentList $oneDriveUrl, $ClientId, $TenantId, $MaxFilesPerSite

            if (Wait-Job $job -Timeout $SiteTimeoutSeconds) {
                $result = Receive-Job $job

                if ($result.Success) {
                    $totalFiles += $result.UserFiles
                    $totalExternal += $result.UserExternal

                    foreach ($share in $result.ExternalShares) {
                        $share.User = $user
                        $allExternalShares += $share
                    }

                    if ($result.UserExternal -gt 0) {
                        Write-Host "  ⚠️  Files: $($result.UserFiles) | External shares: $($result.UserExternal)" -ForegroundColor Yellow
                    } else {
                        Write-Host "  ✓ Files: $($result.UserFiles) | No external sharing" -ForegroundColor Green
                    }

                    $userSummary += [PSCustomObject]@{
                        User = $user
                        OneDriveUrl = $oneDriveUrl
                        FilesChecked = $result.UserFiles
                        ExternalShares = $result.UserExternal
                        Status = "Success"
                    }
                }
                else {
                    Write-Host "  ❌ Error: $($result.Error)" -ForegroundColor Red
                    $skippedSites++
                    $userSummary += [PSCustomObject]@{
                        User = $user
                        OneDriveUrl = $oneDriveUrl
                        FilesChecked = 0
                        ExternalShares = 0
                        Status = "Error: $($result.Error)"
                    }
                }
            }
            else {
                Write-Host "  ⏱️  Timeout after $SiteTimeoutSeconds seconds" -ForegroundColor Red
                Stop-Job $job -Force
                Remove-Job $job -Force
                $skippedSites++
                $userSummary += [PSCustomObject]@{
                    User = $user
                    OneDriveUrl = $oneDriveUrl
                    FilesChecked = 0
                    ExternalShares = 0
                    Status = "Timeout"
                }
            }

            Remove-Job $job -ErrorAction SilentlyContinue
        }
        catch {
            Write-Host "  ❌ Job failed: $($_.Exception.Message)" -ForegroundColor Red
            $skippedSites++
        }

        Write-Host ""
    }

    Write-Progress -Activity "Scanning OneDrive sites" -Completed

    # Export results
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $outputFile = "./onedrive-external-scan-$timestamp.csv"
    $summaryFile = "./onedrive-summary-$timestamp.csv"

    if ($allExternalShares.Count -gt 0) {
        $allExternalShares | Export-Csv -Path $outputFile -NoTypeInformation
        Write-Host ""
        Write-Host "External shares exported: $outputFile" -ForegroundColor Cyan
    }

    $userSummary | Export-Csv -Path $summaryFile -NoTypeInformation
    Write-Host "Summary exported: $summaryFile" -ForegroundColor Cyan

    # Final report
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "SCAN COMPLETE" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "📊 RESULTS:" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  OneDrives Scanned: $($userSummary.Where({$_.Status -eq 'Success'}).Count)" -ForegroundColor White
    Write-Host "  OneDrives Skipped/Timed Out: $skippedSites" -ForegroundColor Red
    Write-Host "  Total Files Checked: $totalFiles" -ForegroundColor White
    Write-Host "  Total External Shares Found: $totalExternal" -ForegroundColor $(if ($totalExternal -gt 0) { "Yellow" } else { "Green" })
    Write-Host ""

    if ($totalExternal -gt 0) {
        Write-Host "========================================" -ForegroundColor Yellow
        Write-Host "EXTERNAL SHARING BY USER" -ForegroundColor Yellow
        Write-Host "========================================" -ForegroundColor Yellow
        Write-Host ""

        $userSummary | Where-Object { $_.ExternalShares -gt 0 } | Sort-Object ExternalShares -Descending | ForEach-Object {
            Write-Host "  $($_.User): $($_.ExternalShares) external shares" -ForegroundColor Yellow
        }
        Write-Host ""
    }

    Write-Host "Expected (from Avanan): ~704 external shares" -ForegroundColor Gray
    Write-Host "Found: $totalExternal external shares" -ForegroundColor $(if ($totalExternal -lt 704) { "Yellow" } else { "Green" })
}
catch {
    Write-Error "Error: $($_.Exception.Message)"
}
finally {
    Disconnect-PnPOnline -ErrorAction SilentlyContinue
    Get-Job | Remove-Job -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "Scan Complete!" -ForegroundColor Cyan
