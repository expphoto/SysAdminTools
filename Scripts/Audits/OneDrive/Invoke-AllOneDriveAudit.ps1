<#
.SYNOPSIS
    Comprehensive audit of ALL OneDrive sites for external sharing.

.DESCRIPTION
    Discovers all OneDrive personal sites and scans each for external sharing links.
    Reports on all 704+ external shares found.

.PARAMETER TenantAdminUrl
    SharePoint admin URL (e.g., https://netorg368294-admin.sharepoint.com)

.PARAMETER ClientId
    Azure AD App Client ID

.PARAMETER TenantId
    Azure AD Tenant ID

.PARAMETER MaxSites
    Optional limit for testing (0 = scan all)

.EXAMPLE
    ./Invoke-AllOneDriveAudit.ps1 -TenantAdminUrl "https://netorg368294-admin.sharepoint.com" -ClientId "87f1f77d-4fbb-4375-ae34-a702b2ab8521" -TenantId "8fbe6cee-1229-4e2d-921a-46b1f93d7242"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TenantAdminUrl,

    [Parameter(Mandatory = $true)]
    [string]$ClientId,

    [Parameter(Mandatory = $true)]
    [string]$TenantId,

    [Parameter(Mandatory = $false)]
    [int]$MaxSites = 0,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "./onedrive-external-sharing-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
)

if (-not (Get-Module -ListAvailable -Name PnP.PowerShell)) {
    Write-Error "PnP.PowerShell module not installed"
    exit 1
}

$allSharingLinks = @()
$anonymousLinks = @()
$externalLinks = @()
$siteSummary = @()

try {
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "ONEDRIVE EXTERNAL SHARING AUDIT" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Target: All OneDrive sites" -ForegroundColor Yellow
    Write-Host "Expected: ~704 external shares" -ForegroundColor Yellow
    Write-Host ""

    Write-Host "Connecting to SharePoint Admin Center..." -ForegroundColor Cyan
    Connect-PnPOnline -Url $TenantAdminUrl -ClientId $ClientId -Tenant $TenantId -Interactive

    Write-Host "Discovering OneDrive sites..." -ForegroundColor Cyan
    $allSites = Get-PnPTenantSite -IncludeOneDriveSites -Filter "Url -like '-my.sharepoint.com/personal/'"

    if ($MaxSites -gt 0 -and $allSites.Count -gt $MaxSites) {
        Write-Host "TESTING MODE: Scanning first $MaxSites of $($allSites.Count) sites" -ForegroundColor Yellow
        $allSites = $allSites | Select-Object -First $MaxSites
    }

    Write-Host "Found $($allSites.Count) OneDrive sites to scan" -ForegroundColor Green
    Write-Host ""

    $siteCounter = 0
    $totalFiles = 0
    $totalAnonymous = 0
    $totalExternal = 0
    $totalInternal = 0

    foreach ($site in $allSites) {
        $siteCounter++
        $percentComplete = [math]::Round(($siteCounter / $allSites.Count) * 100, 2)
        Write-Progress -Activity "Scanning OneDrive sites" -Status "[$siteCounter/$($allSites.Count)] $($site.Url)" -PercentComplete $percentComplete

        $owner = $site.Owner
        $siteAnonymous = 0
        $siteExternal = 0
        $siteInternal = 0
        $siteFiles = 0

        try {
            Write-Host "[$siteCounter/$($allSites.Count)] $owner" -ForegroundColor Cyan

            Connect-PnPOnline -Url $site.Url -ClientId $ClientId -Tenant $TenantId -Interactive

            $lists = Get-PnPList | Where-Object { $_.BaseTemplate -eq 101 -and $_.Hidden -eq $false }

            foreach ($list in $lists) {
                try {
                    $items = Get-PnPListItem -List $list -PageSize 1000 -Fields "ID","FileRef","FileLeafRef","File_x0020_Type"

                    foreach ($item in $items) {
                        if ($item.FileSystemObjectType -eq "File") {
                            $siteFiles++
                            $totalFiles++

                            try {
                                # Get sharing links
                                $sharingLinks = Get-PnPFileSharingLink -Identity $item.Id -List $list -ErrorAction SilentlyContinue

                                if ($sharingLinks) {
                                    foreach ($link in $sharingLinks) {
                                        if ($link.ShareLink) {
                                            $linkType = "Unknown"
                                            $isAnonymous = $false
                                            $isExternal = $false
                                            $linkUrl = $link.ShareLink.ShareId

                                            # Determine link type
                                            if ($link.ShareLink.IsAnonymous -or $link.ShareLink.AllowsAnonymousAccess) {
                                                $linkType = "Anonymous"
                                                $isAnonymous = $true
                                                $isExternal = $true
                                                $siteAnonymous++
                                                $totalAnonymous++
                                                Write-Host "    🔓 ANONYMOUS: $($item['FileLeafRef'])" -ForegroundColor Red
                                            }
                                            elseif ($link.ShareLink.Scope -eq "Organization") {
                                                $linkType = "Organization"
                                                $siteInternal++
                                                $totalInternal++
                                            }
                                            else {
                                                $linkType = "Specific People"
                                                # Assume external if shared
                                                $isExternal = $true
                                                $siteExternal++
                                                $totalExternal++
                                                Write-Host "    🌐 SHARED: $($item['FileLeafRef'])" -ForegroundColor Yellow
                                            }

                                            $allSharingLinks += [PSCustomObject]@{
                                                Owner = $owner
                                                OneDriveUrl = $site.Url
                                                FileName = $item["FileLeafRef"]
                                                FilePath = $item["FileRef"]
                                                FileType = if ($item["File_x0020_Type"]) { $item["File_x0020_Type"] } else { "Unknown" }
                                                LinkType = $linkType
                                                LinkScope = $link.ShareLink.Scope
                                                IsAnonymous = $isAnonymous
                                                IsExternal = $isExternal
                                                CreatedBy = if ($link.ShareLink.CreatedBy) { $link.ShareLink.CreatedBy.Email } else { "Unknown" }
                                                CreatedDate = if ($link.ShareLink.Created) { $link.ShareLink.Created.ToString() } else { "Unknown" }
                                                ShareType = $link.ShareLink.Type
                                            }

                                            if ($isAnonymous) {
                                                $anonymousLinks += $allSharingLinks[-1]
                                            }
                                            if ($isExternal) {
                                                $externalLinks += $allSharingLinks[-1]
                                            }
                                        }
                                    }
                                }

                                # Check direct permissions for external users
                                $hasUniquePerms = Get-PnPProperty -ClientObject $item -Property HasUniqueRoleAssignments -ErrorAction SilentlyContinue
                                if ($item.HasUniqueRoleAssignments) {
                                    $roleAssignments = Get-PnPProperty -ClientObject $item -Property RoleAssignments -ErrorAction SilentlyContinue

                                    if ($roleAssignments) {
                                        Get-PnPProperty -ClientObject $roleAssignments -Property Member, RoleDefinitionBindings -ErrorAction SilentlyContinue

                                        foreach ($roleAssignment in $roleAssignments) {
                                            $member = $roleAssignment.Member

                                            if ($member.LoginName -like "*#ext#*" -or $member.LoginName -like "*urn:spo:guest*") {
                                                $permissions = ($roleAssignment.RoleDefinitionBindings | Select-Object -ExpandProperty Name) -join ", "

                                                $extRecord = [PSCustomObject]@{
                                                    Owner = $owner
                                                    OneDriveUrl = $site.Url
                                                    FileName = $item["FileLeafRef"]
                                                    FilePath = $item["FileRef"]
                                                    FileType = if ($item["File_x0020_Type"]) { $item["File_x0020_Type"] } else { "Unknown" }
                                                    LinkType = "External User Permission"
                                                    LinkScope = "External"
                                                    IsAnonymous = $false
                                                    IsExternal = $true
                                                    CreatedBy = "$($member.Title) ($($member.Email))"
                                                    CreatedDate = "N/A"
                                                    ShareType = $permissions
                                                }

                                                $allSharingLinks += $extRecord
                                                $externalLinks += $extRecord
                                                $siteExternal++
                                                $totalExternal++

                                                Write-Host "    👤 EXTERNAL USER: $($member.Title) - $($item['FileLeafRef'])" -ForegroundColor Yellow
                                            }
                                        }
                                    }
                                }
                            }
                            catch {
                                Write-Verbose "Skip: $($item['FileLeafRef'])"
                            }
                        }
                    }
                }
                catch {
                    Write-Verbose "Skip library: $($list.Title)"
                }
            }

            $siteSummary += [PSCustomObject]@{
                Owner = $owner
                OneDriveUrl = $site.Url
                FilesChecked = $siteFiles
                AnonymousLinks = $siteAnonymous
                ExternalShares = $siteExternal
                InternalLinks = $siteInternal
                TotalExternal = $siteAnonymous + $siteExternal
            }

            if ($siteAnonymous -gt 0 -or $siteExternal -gt 0) {
                Write-Host "  ⚠️  Files: $siteFiles | Anonymous: $siteAnonymous | External: $siteExternal" -ForegroundColor Yellow
            } else {
                Write-Host "  ✓ Files: $siteFiles | No external sharing" -ForegroundColor Green
            }

            Disconnect-PnPOnline -ErrorAction SilentlyContinue
        }
        catch {
            Write-Warning "Could not access: $owner - $($_.Exception.Message)"
        }

        Write-Host ""
    }

    Write-Progress -Activity "Scanning OneDrive sites" -Completed

    # Export
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "EXPORTING RESULTS" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""

    if ($allSharingLinks.Count -gt 0) {
        $allFile = "$OutputPath-all-external-shares.csv"
        $allSharingLinks | Export-Csv -Path $allFile -NoTypeInformation
        Write-Host "All external shares: $allFile" -ForegroundColor Cyan
    }

    if ($anonymousLinks.Count -gt 0) {
        $anonFile = "$OutputPath-anonymous-links.csv"
        $anonymousLinks | Export-Csv -Path $anonFile -NoTypeInformation
        Write-Host "Anonymous links: $anonFile" -ForegroundColor Cyan
    }

    if ($externalLinks.Count -gt 0) {
        $extFile = "$OutputPath-external-links.csv"
        $externalLinks | Export-Csv -Path $extFile -NoTypeInformation
        Write-Host "External links: $extFile" -ForegroundColor Cyan
    }

    $summaryFile = "$OutputPath-summary-by-user.csv"
    $siteSummary | Export-Csv -Path $summaryFile -NoTypeInformation
    Write-Host "Summary by user: $summaryFile" -ForegroundColor Cyan

    # Final Report
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "AUDIT COMPLETE" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "📊 FINAL RESULTS:" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  OneDrive Sites Scanned: $($siteSummary.Count)" -ForegroundColor White
    Write-Host "  Total Files Checked: $totalFiles" -ForegroundColor White
    Write-Host "  Total External Shares: $totalExternal" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  🔓 Anonymous Links: $totalAnonymous" -ForegroundColor $(if ($totalAnonymous -gt 0) { "Red" } else { "Green" })
    Write-Host "  🌐 External Shares: $totalExternal" -ForegroundColor $(if ($totalExternal -gt 0) { "Yellow" } else { "Green" })
    Write-Host "  🏢 Internal Links: $totalInternal" -ForegroundColor White
    Write-Host ""

    # Users with most external sharing
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "TOP USERS BY EXTERNAL SHARING" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""

    $siteSummary | Where-Object { $_.TotalExternal -gt 0 } | Sort-Object TotalExternal -Descending | Select-Object -First 10 | ForEach-Object {
        Write-Host "  $($_.Owner): $($_.TotalExternal) external shares" -ForegroundColor Yellow
        Write-Host "    Anonymous: $($_.AnonymousLinks) | External: $($_.ExternalShares)" -ForegroundColor Gray
    }

    Write-Host ""
    Write-Host "Expected: ~704 external shares (from Avanan)" -ForegroundColor Gray
    Write-Host "Found: $totalExternal external shares" -ForegroundColor Yellow
    Write-Host ""

    if ($totalExternal -lt 704) {
        Write-Host "⚠️  Found fewer than expected. Possible reasons:" -ForegroundColor Yellow
        Write-Host "   - Some shares may be on folders (not scanned)" -ForegroundColor Gray
        Write-Host "   - Avanan may count differently" -ForegroundColor Gray
        Write-Host "   - Some OneDrive sites may be inaccessible" -ForegroundColor Gray
    }
}
catch {
    Write-Error "Error: $($_.Exception.Message)"
}
finally {
    Disconnect-PnPOnline -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Audit Complete!" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
