<#
.SYNOPSIS
    Comprehensive audit for anonymous "Anyone with the link" sharing across SharePoint and OneDrive.

.DESCRIPTION
    Uses Microsoft Graph API to scan all sites and OneDrive for anonymous sharing links.
    Identifies files shared via "Anyone with the link" that don't require authentication.

.PARAMETER MaxSites
    Maximum number of sites to scan (default: all sites)

.PARAMETER OutputPath
    Base path for output files

.EXAMPLE
    ./Invoke-AnonymousLinksAudit.ps1

.EXAMPLE
    ./Invoke-AnonymousLinksAudit.ps1 -MaxSites 20

.NOTES
    This script uses Microsoft Graph API and works without SharePoint Administrator role.
    Scans all accessible sites and drives for anonymous sharing links.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [int]$MaxSites = 0,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "./anonymous-links-audit-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
)

# Check if Microsoft.Graph modules are installed
$requiredModules = @('Microsoft.Graph.Authentication', 'Microsoft.Graph.Sites', 'Microsoft.Graph.Files')
foreach ($module in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $module)) {
        Write-Host "Installing $module..." -ForegroundColor Cyan
        Install-Module $module -Scope CurrentUser -Force -AllowClobber
    }
}

Import-Module Microsoft.Graph.Authentication
Import-Module Microsoft.Graph.Sites
Import-Module Microsoft.Graph.Files

$anonymousLinks = @()
$allSharingLinks = @()
$siteSummary = @()
$ErrorActionPreference = 'Continue'

try {
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "ANONYMOUS SHARING LINKS AUDIT" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Scanning for 'Anyone with the link' shares..." -ForegroundColor Yellow
    Write-Host "Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Gray
    Write-Host ""

    Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Cyan
    Connect-MgGraph -Scopes "Sites.Read.All","Files.Read.All" -NoWelcome

    Write-Host "Successfully connected!" -ForegroundColor Green
    Write-Host ""

    # Get all sites
    Write-Host "Discovering SharePoint sites and OneDrive..." -ForegroundColor Cyan
    $allSites = Get-MgSite -All -Property Id,WebUrl,DisplayName,Name

    $sites = $allSites
    if ($MaxSites -gt 0 -and $allSites.Count -gt $MaxSites) {
        Write-Host "Limiting scan to first $MaxSites sites (out of $($allSites.Count) total)" -ForegroundColor Yellow
        $sites = $allSites | Select-Object -First $MaxSites
    }

    Write-Host "Found $($allSites.Count) total sites" -ForegroundColor White
    Write-Host "Will scan $($sites.Count) sites" -ForegroundColor Green
    Write-Host ""

    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "SCANNING SITES" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""

    $siteCounter = 0
    $totalAnonymousLinks = 0
    $totalExternalLinks = 0
    $totalInternalLinks = 0
    $totalFilesChecked = 0

    foreach ($site in $sites) {
        $siteCounter++
        $percentComplete = [math]::Round(($siteCounter / $sites.Count) * 100, 2)
        Write-Progress -Activity "Scanning for anonymous links" -Status "[$siteCounter/$($sites.Count)] $($site.DisplayName)" -PercentComplete $percentComplete

        $siteAnonymousCount = 0
        $siteExternalCount = 0
        $siteInternalCount = 0
        $siteFilesChecked = 0

        $isOneDrive = $site.WebUrl -like "*/personal/*"
        $siteType = if ($isOneDrive) { "OneDrive" } else { "SharePoint" }

        try {
            Write-Host "[$siteCounter/$($sites.Count)] $siteType : $($site.DisplayName)" -ForegroundColor Yellow

            # Get all drives in this site
            $drives = Get-MgSiteDrive -SiteId $site.Id -All -ErrorAction SilentlyContinue

            if (-not $drives -or $drives.Count -eq 0) {
                Write-Host "  No drives found" -ForegroundColor Gray
                continue
            }

            Write-Host "  Found $($drives.Count) drive(s)" -ForegroundColor Gray

            foreach ($drive in $drives) {
                try {
                    Write-Host "    Checking: $($drive.Name)..." -ForegroundColor Gray

                    # Get root items
                    $items = Get-MgDriveItem -DriveId $drive.Id -All -ErrorAction SilentlyContinue

                    if (-not $items) {
                        continue
                    }

                    foreach ($item in $items) {
                        # Only check files, not folders
                        if ($item.File) {
                            $siteFilesChecked++
                            $totalFilesChecked++

                            try {
                                # Get permissions for this item
                                $permissions = Get-MgDriveItemPermission -DriveId $drive.Id -DriveItemId $item.Id -All -ErrorAction SilentlyContinue

                                foreach ($permission in $permissions) {
                                    $linkType = "Unknown"
                                    $linkScope = "Unknown"
                                    $isAnonymous = $false
                                    $isExternal = $false

                                    # Check if this is a link permission
                                    if ($permission.Link) {
                                        $linkType = $permission.Link.Type
                                        $linkScope = $permission.Link.Scope

                                        # Check for anonymous access
                                        if ($linkScope -eq "anonymous" -or $permission.Link.PreventsDownload -eq $false) {
                                            $isAnonymous = $true
                                            $siteAnonymousCount++
                                            $totalAnonymousLinks++

                                            Write-Host "      🔓 ANONYMOUS LINK: $($item.Name)" -ForegroundColor Red
                                            Write-Host "         Type: $linkType | URL: $($item.WebUrl)" -ForegroundColor Gray
                                        }
                                        elseif ($linkScope -eq "organization") {
                                            $linkType = "Organization (Internal)"
                                            $siteInternalCount++
                                            $totalInternalLinks++
                                        }
                                        elseif ($linkScope -eq "users") {
                                            # Check if any users are external
                                            if ($permission.GrantedToIdentitiesV2) {
                                                foreach ($identity in $permission.GrantedToIdentitiesV2) {
                                                    $email = $identity.User.Email
                                                    if ($email -and $email -notlike "*@channelislandslg.com") {
                                                        $isExternal = $true
                                                    }
                                                }
                                            }

                                            if ($isExternal) {
                                                $siteExternalCount++
                                                $totalExternalLinks++
                                            } else {
                                                $siteInternalCount++
                                                $totalInternalLinks++
                                            }
                                        }

                                        # Record all sharing links
                                        $sharingRecord = [PSCustomObject]@{
                                            SiteType = $siteType
                                            SiteUrl = $site.WebUrl
                                            SiteName = $site.DisplayName
                                            DriveName = $drive.Name
                                            FilePath = $item.WebUrl
                                            FileName = $item.Name
                                            FileSize = if ($item.Size) { [math]::Round($item.Size / 1MB, 2) } else { 0 }
                                            LastModified = if ($item.LastModifiedDateTime) { $item.LastModifiedDateTime.ToString() } else { "Unknown" }
                                            LinkType = $linkType
                                            LinkScope = $linkScope
                                            IsAnonymous = $isAnonymous
                                            IsExternal = $isExternal
                                            PermissionId = $permission.Id
                                            HasPassword = if ($permission.Link.PreventsDownload) { "Yes" } else { "No" }
                                        }

                                        $allSharingLinks += $sharingRecord

                                        if ($isAnonymous) {
                                            $anonymousLinks += $sharingRecord
                                        }
                                    }
                                }
                            }
                            catch {
                                Write-Verbose "Could not check permissions for: $($item.Name)"
                            }
                        }
                    }
                }
                catch {
                    Write-Verbose "Could not access drive: $($drive.Name)"
                }
            }

            # Site summary
            $siteSummary += [PSCustomObject]@{
                SiteType = $siteType
                SiteUrl = $site.WebUrl
                SiteName = $site.DisplayName
                FilesChecked = $siteFilesChecked
                AnonymousLinks = $siteAnonymousCount
                ExternalLinks = $siteExternalCount
                InternalLinks = $siteInternalCount
                TotalExternal = $siteAnonymousCount + $siteExternalCount
            }

            if ($siteAnonymousCount -gt 0 -or $siteExternalCount -gt 0) {
                Write-Host "  ⚠️  Anonymous: $siteAnonymousCount | External: $siteExternalCount | Internal: $siteInternalCount" -ForegroundColor Yellow
            } else {
                Write-Host "  ✓ No external sharing (checked $siteFilesChecked files)" -ForegroundColor Green
            }
        }
        catch {
            Write-Warning "Could not access site: $($site.DisplayName)"
        }

        Write-Host ""
    }

    Write-Progress -Activity "Scanning for anonymous links" -Completed

    # Export results
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "EXPORTING RESULTS" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""

    if ($anonymousLinks.Count -gt 0) {
        $anonymousFile = "$OutputPath-anonymous-links.csv"
        $anonymousLinks | Export-Csv -Path $anonymousFile -NoTypeInformation
        Write-Host "Anonymous links exported to: $anonymousFile" -ForegroundColor Cyan
    }

    if ($allSharingLinks.Count -gt 0) {
        $allLinksFile = "$OutputPath-all-sharing-links.csv"
        $allSharingLinks | Export-Csv -Path $allLinksFile -NoTypeInformation
        Write-Host "All sharing links exported to: $allLinksFile" -ForegroundColor Cyan
    }

    if ($siteSummary.Count -gt 0) {
        $summaryFile = "$OutputPath-site-summary.csv"
        $siteSummary | Export-Csv -Path $summaryFile -NoTypeInformation
        Write-Host "Site summary exported to: $summaryFile" -ForegroundColor Cyan
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
    Write-Host "  Files Checked: $totalFilesChecked" -ForegroundColor White
    Write-Host "  Total Sharing Links: $($allSharingLinks.Count)" -ForegroundColor White
    Write-Host ""
    Write-Host "  🔓 Anonymous Links: $totalAnonymousLinks" -ForegroundColor $(if ($totalAnonymousLinks -gt 0) { "Red" } else { "Green" })
    Write-Host "  🌐 External User Links: $totalExternalLinks" -ForegroundColor $(if ($totalExternalLinks -gt 0) { "Yellow" } else { "Green" })
    Write-Host "  🏢 Internal Only Links: $totalInternalLinks" -ForegroundColor White
    Write-Host ""

    if ($totalAnonymousLinks -eq 0 -and $totalExternalLinks -eq 0) {
        Write-Host "========================================" -ForegroundColor Green
        Write-Host "✅ NO ANONYMOUS OR EXTERNAL SHARING" -ForegroundColor Green
        Write-Host "========================================" -ForegroundColor Green
        Write-Host ""
        Write-Host "Your SharePoint and OneDrive are secure:" -ForegroundColor White
        Write-Host "  • No anonymous 'Anyone with the link' shares" -ForegroundColor White
        Write-Host "  • No links shared with external users" -ForegroundColor White
        Write-Host "  • All sharing is internal only" -ForegroundColor White
    } else {
        Write-Host "========================================" -ForegroundColor Yellow
        Write-Host "⚠️  EXTERNAL SHARING DETECTED" -ForegroundColor Yellow
        Write-Host "========================================" -ForegroundColor Yellow
        Write-Host ""

        if ($totalAnonymousLinks -gt 0) {
            Write-Host "🔓 ANONYMOUS LINKS FOUND: $totalAnonymousLinks" -ForegroundColor Red
            Write-Host ""
            Write-Host "These files can be accessed by ANYONE with the link:" -ForegroundColor Yellow

            $anonymousLinks | Select-Object -First 10 | ForEach-Object {
                Write-Host "  • $($_.FileName)" -ForegroundColor White
                Write-Host "    Site: $($_.SiteName)" -ForegroundColor Gray
                Write-Host "    URL: $($_.FilePath)" -ForegroundColor Gray
                Write-Host ""
            }

            if ($anonymousLinks.Count -gt 10) {
                Write-Host "  ... and $($anonymousLinks.Count - 10) more (see CSV for full list)" -ForegroundColor Gray
                Write-Host ""
            }
        }

        if ($totalExternalLinks -gt 0) {
            Write-Host "🌐 EXTERNAL USER LINKS: $totalExternalLinks" -ForegroundColor Yellow
            Write-Host "   These links are shared with specific external users" -ForegroundColor Gray
            Write-Host ""
        }
    }

    # Sites with external sharing
    $sitesWithExternal = $siteSummary | Where-Object { $_.TotalExternal -gt 0 } | Sort-Object TotalExternal -Descending

    if ($sitesWithExternal.Count -gt 0) {
        Write-Host "========================================" -ForegroundColor Cyan
        Write-Host "SITES WITH EXTERNAL SHARING" -ForegroundColor Cyan
        Write-Host "========================================" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "$($sitesWithExternal.Count) site(s) have external sharing enabled:" -ForegroundColor Yellow
        Write-Host ""

        $sitesWithExternal | Select-Object -First 10 | ForEach-Object {
            Write-Host "  📁 $($_.SiteName) ($($_.SiteType))" -ForegroundColor White
            Write-Host "     Anonymous: $($_.AnonymousLinks) | External: $($_.ExternalLinks) | Files: $($_.FilesChecked)" -ForegroundColor Gray
            Write-Host ""
        }

        if ($sitesWithExternal.Count -gt 10) {
            Write-Host "  ... and $($sitesWithExternal.Count - 10) more (see CSV for full list)" -ForegroundColor Gray
            Write-Host ""
        }
    }

    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "RECOMMENDATIONS" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""

    if ($totalAnonymousLinks -gt 0) {
        Write-Host "🔴 CRITICAL: Anonymous links found" -ForegroundColor Red
        Write-Host "   1. Review each anonymous link for business necessity" -ForegroundColor White
        Write-Host "   2. Remove links that are no longer needed" -ForegroundColor White
        Write-Host "   3. Replace anonymous links with 'Specific people' where possible" -ForegroundColor White
        Write-Host "   4. Set expiration dates on remaining anonymous links" -ForegroundColor White
        Write-Host ""
    }

    if ($totalExternalLinks -gt 0) {
        Write-Host "⚠️  External sharing detected" -ForegroundColor Yellow
        Write-Host "   1. Verify external users are authorized" -ForegroundColor White
        Write-Host "   2. Ensure business justification exists" -ForegroundColor White
        Write-Host "   3. Remove access when collaboration ends" -ForegroundColor White
        Write-Host ""
    }

    if ($totalAnonymousLinks -eq 0 -and $totalExternalLinks -eq 0) {
        Write-Host "✅ No action required - your environment is secure" -ForegroundColor Green
        Write-Host ""
    }

    Write-Host "Completed: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Gray
}
catch {
    Write-Error "An error occurred: $($_.Exception.Message)"
    Write-Error $_.ScriptStackTrace
}
finally {
    Disconnect-MgGraph -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Audit Complete!" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
