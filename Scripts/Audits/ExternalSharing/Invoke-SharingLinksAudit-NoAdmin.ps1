<#
.SYNOPSIS
    Sharing links audit that works without SharePoint Administrator role.

.DESCRIPTION
    Scans accessible SharePoint sites for sharing links using delegated permissions.
    Works with Site Collection Administrator or regular user permissions.

.PARAMETER SiteUrls
    Array of site URLs to scan (if empty, will try to discover accessible sites)

.PARAMETER OutputPath
    Base path for output files

.EXAMPLE
    ./Invoke-SharingLinksAudit-NoAdmin.ps1 -SiteUrls @("https://netorg368294.sharepoint.com/sites/yoursite")

.NOTES
    This version doesn't require SharePoint Administrator role.
    Only scans sites where you have access.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string[]]$SiteUrls = @(),

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "./sharing-audit-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
)

# Check if PnP.PowerShell is installed
if (-not (Get-Module -ListAvailable -Name PnP.PowerShell)) {
    Write-Error "PnP.PowerShell module is not installed. Please run: Install-Module PnP.PowerShell -Scope CurrentUser"
    exit 1
}

$allSharingLinks = @()
$externalUsers = @()
$siteSummary = @()
$ErrorActionPreference = 'Continue'

try {
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "SHARING LINKS AUDIT (No Admin Required)" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""

    # If no sites specified, use Microsoft Graph to find sites
    if ($SiteUrls.Count -eq 0) {
        Write-Host "No sites specified. Using Microsoft Graph to discover sites..." -ForegroundColor Cyan

        # Check if Microsoft.Graph is available
        if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Sites)) {
            Install-Module Microsoft.Graph.Sites -Scope CurrentUser -Force
        }

        Import-Module Microsoft.Graph.Sites
        Import-Module Microsoft.Graph.Authentication

        Connect-MgGraph -Scopes "Sites.Read.All" -NoWelcome

        Write-Host "Discovering sites..." -ForegroundColor Yellow
        $sites = Get-MgSite -All -Property Id,WebUrl,DisplayName
        $SiteUrls = $sites | Select-Object -ExpandProperty WebUrl

        Write-Host "Found $($SiteUrls.Count) sites" -ForegroundColor Green
        Disconnect-MgGraph -ErrorAction SilentlyContinue
    }

    Write-Host "Will scan $($SiteUrls.Count) site(s)" -ForegroundColor Green
    Write-Host ""

    $siteCounter = 0
    $totalAnonymousLinks = 0
    $totalExternalLinks = 0
    $totalInternalLinks = 0

    foreach ($siteUrl in $SiteUrls) {
        $siteCounter++
        Write-Progress -Activity "Scanning sites" -Status "[$siteCounter/$($SiteUrls.Count)] $siteUrl" -PercentComplete (($siteCounter / $SiteUrls.Count) * 100)

        $siteAnonymousCount = 0
        $siteExternalCount = 0
        $siteInternalCount = 0

        try {
            Write-Host "[$siteCounter/$($SiteUrls.Count)] Connecting to: $siteUrl" -ForegroundColor Yellow

            # Connect with device code authentication
            Connect-PnPOnline -Url $siteUrl -Interactive -ErrorAction Stop

            $web = Get-PnPWeb
            $siteTitle = $web.Title

            Write-Host "  Scanning: $siteTitle" -ForegroundColor Cyan

            # Get document libraries
            $lists = Get-PnPList | Where-Object {
                $_.BaseTemplate -eq 101 -and
                $_.Hidden -eq $false
            }

            Write-Host "  Found $($lists.Count) document libraries" -ForegroundColor Gray

            foreach ($list in $lists) {
                Write-Host "    Checking: $($list.Title)..." -ForegroundColor Gray

                try {
                    $items = Get-PnPListItem -List $list -PageSize 500 -Fields "ID","FileRef","FileLeafRef","File_x0020_Type"

                    foreach ($item in $items) {
                        if ($item.FileSystemObjectType -eq "File") {
                            try {
                                # Get sharing links
                                $sharingLinks = Get-PnPFileSharingLink -Identity $item.Id -List $list -ErrorAction SilentlyContinue

                                if ($sharingLinks) {
                                    foreach ($link in $sharingLinks) {
                                        $linkType = "Unknown"
                                        $scope = "Unknown"
                                        $isExternal = $false

                                        if ($link.ShareLink) {
                                            # Check for anonymous/anyone links
                                            if ($link.ShareLink.IsAnonymous -or $link.ShareLink.AllowsAnonymousAccess) {
                                                $linkType = "Anonymous (Anyone with link)"
                                                $isExternal = $true
                                                $siteAnonymousCount++
                                                $totalAnonymousLinks++

                                                Write-Host "      🔓 ANONYMOUS LINK: $($item['FileLeafRef'])" -ForegroundColor Red
                                            }
                                            elseif ($link.ShareLink.Scope -eq "Organization") {
                                                $linkType = "Organization (Internal)"
                                                $siteInternalCount++
                                                $totalInternalLinks++
                                            }
                                            else {
                                                $linkType = "Direct/Specific People"
                                                $siteInternalCount++
                                                $totalInternalLinks++
                                            }

                                            $allSharingLinks += [PSCustomObject]@{
                                                SiteUrl = $siteUrl
                                                SiteTitle = $siteTitle
                                                Library = $list.Title
                                                FilePath = $item["FileRef"]
                                                FileName = $item["FileLeafRef"]
                                                FileType = if ($item["File_x0020_Type"]) { $item["File_x0020_Type"] } else { "Unknown" }
                                                LinkType = $linkType
                                                IsExternal = $isExternal
                                                CreatedBy = if ($link.ShareLink.CreatedBy) { $link.ShareLink.CreatedBy.Email } else { "Unknown" }
                                                Created = if ($link.ShareLink.Created) { $link.ShareLink.Created.ToString() } else { "Unknown" }
                                            }
                                        }
                                    }
                                }

                                # Check for external user permissions
                                try {
                                    $roleAssignments = Get-PnPProperty -ClientObject $item -Property RoleAssignments -ErrorAction SilentlyContinue

                                    if ($roleAssignments) {
                                        Get-PnPProperty -ClientObject $roleAssignments -Property Member, RoleDefinitionBindings -ErrorAction SilentlyContinue

                                        foreach ($roleAssignment in $roleAssignments) {
                                            $member = $roleAssignment.Member

                                            # Check if external user
                                            if ($member.LoginName -like "*#ext#*" -or $member.LoginName -like "*urn:spo:guest*") {
                                                $permissions = ($roleAssignment.RoleDefinitionBindings | Select-Object -ExpandProperty Name) -join ", "

                                                # Track unique external users
                                                if (-not ($externalUsers | Where-Object { $_.Email -eq $member.Email })) {
                                                    $externalUsers += [PSCustomObject]@{
                                                        DisplayName = $member.Title
                                                        Email = $member.Email
                                                        FirstSeenSite = $siteTitle
                                                        FirstSeenUrl = $siteUrl
                                                    }
                                                }

                                                $allSharingLinks += [PSCustomObject]@{
                                                    SiteUrl = $siteUrl
                                                    SiteTitle = $siteTitle
                                                    Library = $list.Title
                                                    FilePath = $item["FileRef"]
                                                    FileName = $item["FileLeafRef"]
                                                    FileType = if ($item["File_x0020_Type"]) { $item["File_x0020_Type"] } else { "Unknown" }
                                                    LinkType = "External User: $($member.Title)"
                                                    IsExternal = $true
                                                    CreatedBy = "N/A"
                                                    Created = "N/A"
                                                }

                                                $siteExternalCount++
                                                $totalExternalLinks++

                                                Write-Host "      👤 EXTERNAL USER: $($member.Title) - $($item['FileLeafRef'])" -ForegroundColor Yellow
                                            }
                                        }
                                    }
                                }
                                catch {
                                    # Skip permission checks if we don't have access
                                }
                            }
                            catch {
                                # Skip files we can't access
                            }
                        }
                    }
                }
                catch {
                    Write-Verbose "Could not access list: $($list.Title)"
                }
            }

            $siteSummary += [PSCustomObject]@{
                SiteUrl = $siteUrl
                SiteTitle = $siteTitle
                AnonymousLinks = $siteAnonymousCount
                ExternalUserShares = $siteExternalCount
                InternalLinks = $siteInternalCount
                TotalExternal = $siteAnonymousCount + $siteExternalCount
            }

            if ($siteAnonymousCount -gt 0 -or $siteExternalCount -gt 0) {
                Write-Host "  ✓ Anonymous: $siteAnonymousCount | External Users: $siteExternalCount | Internal: $siteInternalCount" -ForegroundColor Yellow
            } else {
                Write-Host "  ✓ No external sharing found" -ForegroundColor Green
            }

            Disconnect-PnPOnline -ErrorAction SilentlyContinue
        }
        catch {
            Write-Warning "Could not access site: $siteUrl - $($_.Exception.Message)"
        }

        Write-Host ""
    }

    Write-Progress -Activity "Scanning sites" -Completed

    # Export results
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "EXPORTING RESULTS" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""

    if ($allSharingLinks.Count -gt 0) {
        $sharingLinksFile = "$OutputPath-sharing-links.csv"
        $allSharingLinks | Export-Csv -Path $sharingLinksFile -NoTypeInformation
        Write-Host "Sharing links exported to: $sharingLinksFile" -ForegroundColor Cyan
    }

    if ($externalUsers.Count -gt 0) {
        $externalUsersFile = "$OutputPath-external-users.csv"
        $externalUsers | Export-Csv -Path $externalUsersFile -NoTypeInformation
        Write-Host "External users exported to: $externalUsersFile" -ForegroundColor Cyan
    }

    if ($siteSummary.Count -gt 0) {
        $siteSummaryFile = "$OutputPath-site-summary.csv"
        $siteSummary | Export-Csv -Path $siteSummaryFile -NoTypeInformation
        Write-Host "Site summary exported to: $siteSummaryFile" -ForegroundColor Cyan
    }

    # Final Summary
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "AUDIT COMPLETE" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "📊 RESULTS:" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Sites Scanned: $($siteSummary.Count)" -ForegroundColor White
    Write-Host "  Total Sharing Links: $($allSharingLinks.Count)" -ForegroundColor White
    Write-Host ""
    Write-Host "  🔓 Anonymous Links: $totalAnonymousLinks" -ForegroundColor $(if ($totalAnonymousLinks -gt 0) { "Red" } else { "Green" })
    Write-Host "  👤 External User Shares: $totalExternalLinks" -ForegroundColor $(if ($totalExternalLinks -gt 0) { "Yellow" } else { "Green" })
    Write-Host "  🏢 Internal Only Links: $totalInternalLinks" -ForegroundColor White
    Write-Host ""
    Write-Host "  Unique External Users: $($externalUsers.Count)" -ForegroundColor $(if ($externalUsers.Count -gt 0) { "Yellow" } else { "Green" })
    Write-Host ""

    if ($externalUsers.Count -gt 0) {
        Write-Host "External Users Found:" -ForegroundColor Yellow
        foreach ($user in $externalUsers) {
            Write-Host "  - $($user.DisplayName) ($($user.Email))" -ForegroundColor White
            Write-Host "    First seen on: $($user.FirstSeenSite)" -ForegroundColor Gray
        }
        Write-Host ""
    }

    if ($totalAnonymousLinks -eq 0 -and $totalExternalLinks -eq 0) {
        Write-Host "✅ No external sharing found!" -ForegroundColor Green
        Write-Host "   All scanned sites are secure" -ForegroundColor White
    } else {
        Write-Host "⚠️  External sharing detected" -ForegroundColor Yellow
        Write-Host "   Review the exported CSV files for details" -ForegroundColor White
    }
}
catch {
    Write-Error "An error occurred: $($_.Exception.Message)"
}
finally {
    Disconnect-PnPOnline -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Audit Complete!" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
