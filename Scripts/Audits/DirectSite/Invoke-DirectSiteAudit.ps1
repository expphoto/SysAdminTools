<#
.SYNOPSIS
    Direct audit of specific SharePoint site URLs for all sharing links.

.DESCRIPTION
    Bypasses site discovery and directly scans provided URLs for all sharing links.
    Use this when you know specific site URLs and need to audit them.

.PARAMETER SiteUrls
    Array of specific site URLs to scan

.PARAMETER OutputPath
    Base path for output files

.EXAMPLE
    $sites = @(
        "https://netorg368294.sharepoint.com",
        "https://netorg368294.sharepoint.com/sites/yoursite"
    )
    ./Invoke-DirectSiteAudit.ps1 -SiteUrls $sites

.NOTES
    This script works with PnP PowerShell and direct site URLs.
    Use when automated site discovery fails.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]]$SiteUrls,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "./direct-site-audit-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
)

# Check if PnP.PowerShell is installed
if (-not (Get-Module -ListAvailable -Name PnP.PowerShell)) {
    Write-Error "PnP.PowerShell module is not installed. Please run: Install-Module PnP.PowerShell -Scope CurrentUser"
    exit 1
}

$allSharingLinks = @()
$anonymousLinks = @()
$externalUserLinks = @()
$internalLinks = @()
$siteSummary = @()

try {
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "DIRECT SITE AUDIT" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Will scan $($SiteUrls.Count) site(s)" -ForegroundColor Yellow
    Write-Host ""

    $siteCounter = 0

    foreach ($siteUrl in $SiteUrls) {
        $siteCounter++
        Write-Host "[$siteCounter/$($SiteUrls.Count)] Connecting to: $siteUrl" -ForegroundColor Cyan

        try {
            # Connect using interactive auth
            Connect-PnPOnline -Url $siteUrl -Interactive

            $web = Get-PnPWeb
            $siteTitle = $web.Title

            Write-Host "  Connected: $siteTitle" -ForegroundColor Green
            Write-Host "  Scanning for sharing links..." -ForegroundColor Yellow

            $siteAnonymousCount = 0
            $siteExternalCount = 0
            $siteInternalCount = 0
            $filesChecked = 0

            # Get all document libraries
            $lists = Get-PnPList | Where-Object {
                $_.BaseTemplate -eq 101 -and
                $_.Hidden -eq $false
            }

            Write-Host "  Found $($lists.Count) document libraries" -ForegroundColor Gray

            foreach ($list in $lists) {
                Write-Host "    Checking library: $($list.Title)" -ForegroundColor Gray

                try {
                    $items = Get-PnPListItem -List $list -PageSize 500

                    foreach ($item in $items) {
                        if ($item.FileSystemObjectType -eq "File") {
                            $filesChecked++

                            try {
                                # Get all sharing links
                                $sharingLinks = Get-PnPFileSharingLink -Identity $item.Id -List $list -ErrorAction SilentlyContinue

                                if ($sharingLinks) {
                                    foreach ($link in $sharingLinks) {
                                        $linkType = "Unknown"
                                        $isAnonymous = $false
                                        $isExternal = $false

                                        if ($link.ShareLink) {
                                            # Check link properties
                                            if ($link.ShareLink.IsAnonymous -or $link.ShareLink.AllowsAnonymousAccess) {
                                                $linkType = "Anonymous (Anyone with the link)"
                                                $isAnonymous = $true
                                                $siteAnonymousCount++

                                                Write-Host "      🔓 ANONYMOUS: $($item['FileLeafRef'])" -ForegroundColor Red
                                            }
                                            elseif ($link.ShareLink.Scope -eq "Organization") {
                                                $linkType = "Organization (Internal)"
                                                $siteInternalCount++
                                            }
                                            else {
                                                $linkType = "Specific People"
                                                # Could be internal or external
                                                $siteInternalCount++
                                            }

                                            $sharingRecord = [PSCustomObject]@{
                                                SiteUrl = $siteUrl
                                                SiteTitle = $siteTitle
                                                Library = $list.Title
                                                FilePath = $item["FileRef"]
                                                FileName = $item["FileLeafRef"]
                                                LinkType = $linkType
                                                IsAnonymous = $isAnonymous
                                                IsExternal = $isExternal
                                                CreatedBy = if ($link.ShareLink.CreatedBy) { $link.ShareLink.CreatedBy.Email } else { "Unknown" }
                                                Created = if ($link.ShareLink.Created) { $link.ShareLink.Created.ToString() } else { "Unknown" }
                                                LinkScope = $link.ShareLink.Scope
                                                LinkURL = $item.FieldValues["FileRef"]
                                            }

                                            $allSharingLinks += $sharingRecord

                                            if ($isAnonymous) {
                                                $anonymousLinks += $sharingRecord
                                            }
                                        }
                                    }
                                }

                                # Check for direct permissions to external users
                                $hasUniquePerms = Get-PnPProperty -ClientObject $item -Property HasUniqueRoleAssignments
                                if ($item.HasUniqueRoleAssignments) {
                                    $roleAssignments = Get-PnPProperty -ClientObject $item -Property RoleAssignments
                                    Get-PnPProperty -ClientObject $roleAssignments -Property Member, RoleDefinitionBindings

                                    foreach ($roleAssignment in $roleAssignments) {
                                        $member = $roleAssignment.Member

                                        # Check for external users
                                        if ($member.LoginName -like "*#ext#*" -or $member.LoginName -like "*urn:spo:guest*") {
                                            $permissions = ($roleAssignment.RoleDefinitionBindings | Select-Object -ExpandProperty Name) -join ", "

                                            $externalRecord = [PSCustomObject]@{
                                                SiteUrl = $siteUrl
                                                SiteTitle = $siteTitle
                                                Library = $list.Title
                                                FilePath = $item["FileRef"]
                                                FileName = $item["FileLeafRef"]
                                                LinkType = "External User Permission"
                                                IsAnonymous = $false
                                                IsExternal = $true
                                                CreatedBy = "N/A"
                                                Created = "N/A"
                                                LinkScope = "External User"
                                                LinkURL = "$($member.Title) - $($member.Email)"
                                            }

                                            $allSharingLinks += $externalRecord
                                            $externalUserLinks += $externalRecord
                                            $siteExternalCount++

                                            Write-Host "      👤 EXTERNAL USER: $($member.Title) - $($item['FileLeafRef'])" -ForegroundColor Yellow
                                        }
                                    }
                                }
                            }
                            catch {
                                Write-Verbose "Could not check: $($item['FileLeafRef'])"
                            }
                        }
                    }
                }
                catch {
                    Write-Warning "Could not access library: $($list.Title)"
                }
            }

            # Site summary
            $siteSummary += [PSCustomObject]@{
                SiteUrl = $siteUrl
                SiteTitle = $siteTitle
                FilesChecked = $filesChecked
                AnonymousLinks = $siteAnonymousCount
                ExternalUserPerms = $siteExternalCount
                InternalLinks = $siteInternalCount
                TotalExternal = $siteAnonymousCount + $siteExternalCount
            }

            Write-Host ""
            Write-Host "  ✓ Site Summary:" -ForegroundColor Cyan
            Write-Host "    Files Checked: $filesChecked" -ForegroundColor White
            Write-Host "    Anonymous Links: $siteAnonymousCount" -ForegroundColor $(if ($siteAnonymousCount -gt 0) { "Red" } else { "Green" })
            Write-Host "    External User Perms: $siteExternalCount" -ForegroundColor $(if ($siteExternalCount -gt 0) { "Yellow" } else { "Green" })
            Write-Host "    Internal Links: $siteInternalCount" -ForegroundColor White
            Write-Host ""

            Disconnect-PnPOnline
        }
        catch {
            Write-Error "Could not access site: $siteUrl - $($_.Exception.Message)"
        }
    }

    # Export results
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "EXPORTING RESULTS" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""

    if ($allSharingLinks.Count -gt 0) {
        $allLinksFile = "$OutputPath-all-links.csv"
        $allSharingLinks | Export-Csv -Path $allLinksFile -NoTypeInformation
        Write-Host "All sharing links: $allLinksFile" -ForegroundColor Cyan
    }

    if ($anonymousLinks.Count -gt 0) {
        $anonFile = "$OutputPath-anonymous-links.csv"
        $anonymousLinks | Export-Csv -Path $anonFile -NoTypeInformation
        Write-Host "Anonymous links: $anonFile" -ForegroundColor Cyan
    }

    if ($externalUserLinks.Count -gt 0) {
        $extFile = "$OutputPath-external-users.csv"
        $externalUserLinks | Export-Csv -Path $extFile -NoTypeInformation
        Write-Host "External user permissions: $extFile" -ForegroundColor Cyan
    }

    if ($siteSummary.Count -gt 0) {
        $summaryFile = "$OutputPath-summary.csv"
        $siteSummary | Export-Csv -Path $summaryFile -NoTypeInformation
        Write-Host "Site summary: $summaryFile" -ForegroundColor Cyan
    }

    # Final report
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "AUDIT COMPLETE" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "📊 TOTAL RESULTS:" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Sites Scanned: $($siteSummary.Count)" -ForegroundColor White
    Write-Host "  Files Checked: $(($siteSummary | Measure-Object -Property FilesChecked -Sum).Sum)" -ForegroundColor White
    Write-Host "  Total Sharing Links: $($allSharingLinks.Count)" -ForegroundColor White
    Write-Host ""
    Write-Host "  🔓 Anonymous Links: $($anonymousLinks.Count)" -ForegroundColor $(if ($anonymousLinks.Count -gt 0) { "Red" } else { "Green" })
    Write-Host "  👤 External User Permissions: $($externalUserLinks.Count)" -ForegroundColor $(if ($externalUserLinks.Count -gt 0) { "Yellow" } else { "Green" })
    Write-Host "  🏢 Internal Links: $($internalLinks.Count)" -ForegroundColor White
    Write-Host ""

    if ($anonymousLinks.Count -gt 0) {
        Write-Host "🔓 ANONYMOUS LINKS FOUND:" -ForegroundColor Red
        $anonymousLinks | ForEach-Object {
            Write-Host "  • $($_.FileName)" -ForegroundColor White
            Write-Host "    Site: $($_.SiteTitle)" -ForegroundColor Gray
            Write-Host "    Path: $($_.FilePath)" -ForegroundColor Gray
            Write-Host ""
        }
    }

    if ($externalUserLinks.Count -gt 0) {
        Write-Host "👤 EXTERNAL USER PERMISSIONS FOUND:" -ForegroundColor Yellow
        $externalUserLinks | ForEach-Object {
            Write-Host "  • $($_.FileName)" -ForegroundColor White
            Write-Host "    User: $($_.LinkURL)" -ForegroundColor Gray
            Write-Host "    Path: $($_.FilePath)" -ForegroundColor Gray
            Write-Host ""
        }
    }
}
catch {
    Write-Error "An error occurred: $($_.Exception.Message)"
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Audit Complete!" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
