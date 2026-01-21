<#
.SYNOPSIS
    Comprehensive audit of ALL sharing links across SharePoint and OneDrive.

.DESCRIPTION
    Scans all SharePoint sites and OneDrive libraries for:
    - Anonymous sharing links ("Anyone with the link")
    - External user sharing links
    - Organization-wide links
    - Specific people links
    Reports on all external users and all active sharing links.

.PARAMETER TenantUrl
    Your SharePoint admin URL (e.g., https://netorg368294-admin.sharepoint.com)

.PARAMETER ClientId
    Azure AD App Client ID

.PARAMETER TenantId
    Your Azure AD Tenant ID

.PARAMETER OutputPath
    Base path for output files (will create multiple CSVs)

.PARAMETER SampleOnly
    If specified, only scans first 10 sites (for testing)

.EXAMPLE
    ./Invoke-CompleteSharingLinksAudit.ps1 -TenantUrl "https://netorg368294-admin.sharepoint.com" -ClientId "87f1f77d-4fbb-4375-ae34-a702b2ab8521" -TenantId "8fbe6cee-1229-4e2d-921a-46b1f93d7242"

.NOTES
    This is a comprehensive audit and may take significant time for large tenants.
    Requires SharePoint Administrator or Global Administrator role.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TenantUrl,

    [Parameter(Mandatory = $true)]
    [string]$ClientId,

    [Parameter(Mandatory = $true)]
    [string]$TenantId,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "./sharing-audit-$(Get-Date -Format 'yyyyMMdd-HHmmss')",

    [Parameter(Mandatory = $false)]
    [switch]$SampleOnly
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

$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

try {
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "COMPREHENSIVE SHARING LINKS AUDIT" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Started: $timestamp" -ForegroundColor Gray
    Write-Host ""

    Write-Host "Connecting to SharePoint Admin Center..." -ForegroundColor Cyan
    Connect-PnPOnline -Url $TenantUrl -ClientId $ClientId -Tenant $TenantId -Interactive

    Write-Host "Successfully connected!" -ForegroundColor Green
    Write-Host ""

    # Get tenant information
    Write-Host "Retrieving tenant information..." -ForegroundColor Cyan
    $tenant = Get-PnPTenant

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Yellow
    Write-Host "TENANT SHARING CONFIGURATION" -ForegroundColor Yellow
    Write-Host "========================================" -ForegroundColor Yellow
    Write-Host "Tenant: $($tenant.SiteUrl)" -ForegroundColor White
    Write-Host "Sharing Capability: $($tenant.SharingCapability)" -ForegroundColor $(
        switch ($tenant.SharingCapability) {
            "Disabled" { "Green" }
            "ExternalUserSharingOnly" { "Yellow" }
            "ExternalUserAndGuestSharing" { "Red" }
            default { "White" }
        }
    )
    Write-Host "Default Sharing Link Type: $($tenant.DefaultSharingLinkType)" -ForegroundColor White
    Write-Host "Default Link Permission: $($tenant.DefaultLinkPermission)" -ForegroundColor White
    Write-Host ""

    # Get all sites
    Write-Host "Retrieving all SharePoint sites..." -ForegroundColor Cyan
    $sites = Get-PnPTenantSite -IncludeOneDriveSites -Filter "Url -like '.sharepoint.com'" |
             Where-Object { $_.Template -ne 'SRCHCEN#0' }

    if ($SampleOnly) {
        $sites = $sites | Select-Object -First 10
        Write-Host "SAMPLE MODE: Checking first 10 sites only" -ForegroundColor Yellow
    }

    Write-Host "Found $($sites.Count) sites to scan" -ForegroundColor Green
    Write-Host ""

    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "SCANNING SITES FOR SHARING LINKS" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""

    $siteCounter = 0
    $totalAnonymousLinks = 0
    $totalExternalLinks = 0
    $totalOrganizationLinks = 0
    $totalDirectLinks = 0

    foreach ($site in $sites) {
        $siteCounter++
        $percentComplete = [math]::Round(($siteCounter / $sites.Count) * 100, 2)
        Write-Progress -Activity "Scanning sites for sharing links" -Status "[$siteCounter/$($sites.Count)] $($site.Url)" -PercentComplete $percentComplete

        $isOneDrive = $site.Url -like "*/personal/*"
        $siteType = if ($isOneDrive) { "OneDrive" } else { "SharePoint Site" }

        $siteAnonymousCount = 0
        $siteExternalCount = 0
        $siteOrgCount = 0
        $siteDirectCount = 0

        try {
            # Connect to the specific site
            Connect-PnPOnline -Url $site.Url -ClientId $ClientId -Tenant $TenantId -Interactive

            Write-Host "  [$siteCounter/$($sites.Count)] Checking: $siteType - $($site.Title)" -ForegroundColor Yellow

            # Get all document libraries
            $lists = Get-PnPList | Where-Object {
                $_.BaseTemplate -eq 101 -and  # Document Library
                $_.Hidden -eq $false
            }

            foreach ($list in $lists) {
                try {
                    # Get all items
                    $items = Get-PnPListItem -List $list -PageSize 500 -Fields "ID","FileRef","FileLeafRef","File_x0020_Type"

                    foreach ($item in $items) {
                        if ($item.FileSystemObjectType -eq "File") {
                            try {
                                # Get sharing links for this file
                                $sharingLinks = Get-PnPFileSharingLink -Identity $item.Id -List $list -ErrorAction SilentlyContinue

                                if ($sharingLinks) {
                                    foreach ($link in $sharingLinks) {
                                        $linkType = "Unknown"
                                        $scope = "Unknown"
                                        $externalAccess = $false

                                        if ($link.ShareLink) {
                                            $linkType = $link.ShareLink.Type
                                            $scope = $link.ShareLink.Scope

                                            # Determine if this is external access
                                            if ($link.ShareLink.IsAnonymous -or $link.ShareLink.AllowsAnonymousAccess) {
                                                $linkType = "Anonymous"
                                                $externalAccess = $true
                                                $siteAnonymousCount++
                                                $totalAnonymousLinks++
                                            }
                                            elseif ($scope -eq "Organization") {
                                                $linkType = "Organization"
                                                $siteOrgCount++
                                                $totalOrganizationLinks++
                                            }
                                            elseif ($scope -eq "Users") {
                                                $linkType = "Direct/Specific People"
                                                $siteDirectCount++
                                                $totalDirectLinks++

                                                # Check if shared with external users
                                                if ($link.ShareLink.ShareId) {
                                                    $externalAccess = $true
                                                    $siteExternalCount++
                                                    $totalExternalLinks++
                                                }
                                            }
                                        }

                                        $allSharingLinks += [PSCustomObject]@{
                                            SiteType = $siteType
                                            SiteUrl = $site.Url
                                            SiteTitle = $site.Title
                                            ListTitle = $list.Title
                                            FilePath = $item["FileRef"]
                                            FileName = $item["FileLeafRef"]
                                            FileType = $item["File_x0020_Type"]
                                            LinkType = $linkType
                                            Scope = $scope
                                            ExternalAccess = $externalAccess
                                            CreatedBy = if ($link.ShareLink.CreatedBy) { $link.ShareLink.CreatedBy.Email } else { "Unknown" }
                                            Created = if ($link.ShareLink.Created) { $link.ShareLink.Created } else { "Unknown" }
                                            ShareId = if ($link.ShareLink.ShareId) { $link.ShareLink.ShareId } else { "N/A" }
                                            AllowsAnonymousAccess = if ($link.ShareLink.AllowsAnonymousAccess) { "Yes" } else { "No" }
                                        }

                                        if ($externalAccess) {
                                            Write-Host "    🔗 EXTERNAL LINK: $($item['FileLeafRef'])" -ForegroundColor Red
                                            Write-Host "       Type: $linkType | Scope: $scope" -ForegroundColor Gray
                                        }
                                    }
                                }

                                # Also check for direct permissions to external users
                                $roleAssignments = Get-PnPProperty -ClientObject $item -Property RoleAssignments -ErrorAction SilentlyContinue
                                if ($roleAssignments) {
                                    Get-PnPProperty -ClientObject $roleAssignments -Property Member, RoleDefinitionBindings -ErrorAction SilentlyContinue

                                    foreach ($roleAssignment in $roleAssignments) {
                                        $member = $roleAssignment.Member

                                        # Check if member is external
                                        if ($member.LoginName -like "*#ext#*" -or $member.LoginName -like "*urn:spo:guest*") {
                                            $permissions = ($roleAssignment.RoleDefinitionBindings | Select-Object -ExpandProperty Name) -join ", "

                                            # Track unique external users
                                            if (-not ($externalUsers | Where-Object { $_.Email -eq $member.Email })) {
                                                $externalUsers += [PSCustomObject]@{
                                                    DisplayName = $member.Title
                                                    Email = $member.Email
                                                    LoginName = $member.LoginName
                                                    FirstSeenOn = $site.Title
                                                    FirstSeenUrl = $site.Url
                                                }
                                            }

                                            $allSharingLinks += [PSCustomObject]@{
                                                SiteType = $siteType
                                                SiteUrl = $site.Url
                                                SiteTitle = $site.Title
                                                ListTitle = $list.Title
                                                FilePath = $item["FileRef"]
                                                FileName = $item["FileLeafRef"]
                                                FileType = $item["File_x0020_Type"]
                                                LinkType = "Direct Permission (External User)"
                                                Scope = "External User"
                                                ExternalAccess = $true
                                                CreatedBy = "N/A"
                                                Created = "N/A"
                                                ShareId = $member.Email
                                                AllowsAnonymousAccess = "No"
                                            }

                                            $siteExternalCount++
                                            $totalExternalLinks++

                                            Write-Host "    👤 EXTERNAL USER: $($member.Title) - $($item['FileLeafRef'])" -ForegroundColor Red
                                        }
                                    }
                                }
                            }
                            catch {
                                # Silently skip files we can't access
                                Write-Verbose "Could not check: $($item['FileLeafRef'])"
                            }
                        }
                    }
                }
                catch {
                    Write-Verbose "Could not access list: $($list.Title)"
                }
            }

            # Site summary
            $siteSummary += [PSCustomObject]@{
                SiteType = $siteType
                SiteUrl = $site.Url
                SiteTitle = $site.Title
                AnonymousLinks = $siteAnonymousCount
                ExternalUserLinks = $siteExternalCount
                OrganizationLinks = $siteOrgCount
                DirectLinks = $siteDirectCount
                TotalExternalSharing = $siteAnonymousCount + $siteExternalCount
            }

            if ($siteAnonymousCount -gt 0 -or $siteExternalCount -gt 0) {
                Write-Host "    Summary: Anonymous=$siteAnonymousCount | External=$siteExternalCount | Org=$siteOrgCount" -ForegroundColor Yellow
            }
        }
        catch {
            Write-Warning "  Could not access site: $($site.Url) - $($_.Exception.Message)"
        }

        Write-Host ""
    }

    Write-Progress -Activity "Scanning sites for sharing links" -Completed

    # Export results
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "EXPORTING RESULTS" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""

    $sharingLinksFile = "$OutputPath-all-sharing-links.csv"
    $externalUsersFile = "$OutputPath-external-users.csv"
    $siteSummaryFile = "$OutputPath-site-summary.csv"

    if ($allSharingLinks.Count -gt 0) {
        $allSharingLinks | Export-Csv -Path $sharingLinksFile -NoTypeInformation
        Write-Host "All sharing links exported to: $sharingLinksFile" -ForegroundColor Cyan
    }

    if ($externalUsers.Count -gt 0) {
        $externalUsers | Export-Csv -Path $externalUsersFile -NoTypeInformation
        Write-Host "External users exported to: $externalUsersFile" -ForegroundColor Cyan
    }

    if ($siteSummary.Count -gt 0) {
        $siteSummary | Export-Csv -Path $siteSummaryFile -NoTypeInformation
        Write-Host "Site summary exported to: $siteSummaryFile" -ForegroundColor Cyan
    }

    # Final Summary
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "AUDIT COMPLETE" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "📊 SHARING LINKS SUMMARY:" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Total Sharing Links Found: $($allSharingLinks.Count)" -ForegroundColor White
    Write-Host "  Anonymous Links (Anyone with link): $totalAnonymousLinks" -ForegroundColor $(if ($totalAnonymousLinks -gt 0) { "Red" } else { "Green" })
    Write-Host "  External User Links: $totalExternalLinks" -ForegroundColor $(if ($totalExternalLinks -gt 0) { "Yellow" } else { "Green" })
    Write-Host "  Organization Links (Internal only): $totalOrganizationLinks" -ForegroundColor White
    Write-Host "  Direct/Specific People Links: $totalDirectLinks" -ForegroundColor White
    Write-Host ""
    Write-Host "👥 EXTERNAL USERS:" -ForegroundColor Cyan
    Write-Host "  Unique External Users Found: $($externalUsers.Count)" -ForegroundColor $(if ($externalUsers.Count -gt 0) { "Yellow" } else { "Green" })
    Write-Host ""

    if ($externalUsers.Count -gt 0) {
        Write-Host "External Users List:" -ForegroundColor Yellow
        foreach ($user in $externalUsers) {
            Write-Host "  - $($user.DisplayName) ($($user.Email))" -ForegroundColor White
        }
        Write-Host ""
    }

    # Sites with external sharing
    $sitesWithExternal = $siteSummary | Where-Object { $_.TotalExternalSharing -gt 0 }
    Write-Host "🌐 SITES WITH EXTERNAL SHARING:" -ForegroundColor Cyan
    Write-Host "  Sites with external sharing: $($sitesWithExternal.Count) of $($siteSummary.Count)" -ForegroundColor $(if ($sitesWithExternal.Count -gt 0) { "Yellow" } else { "Green" })
    Write-Host ""

    if ($sitesWithExternal.Count -gt 0 -and $sitesWithExternal.Count -le 20) {
        Write-Host "Sites with External Sharing:" -ForegroundColor Yellow
        foreach ($s in $sitesWithExternal) {
            Write-Host "  - $($s.SiteTitle)" -ForegroundColor White
            Write-Host "    Anonymous: $($s.AnonymousLinks) | External Users: $($s.ExternalUserLinks)" -ForegroundColor Gray
        }
        Write-Host ""
    }

    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "RECOMMENDATIONS" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""

    if ($totalAnonymousLinks -gt 0) {
        Write-Host "⚠️  $totalAnonymousLinks anonymous links found" -ForegroundColor Red
        Write-Host "   These links can be accessed by ANYONE without authentication" -ForegroundColor Yellow
        Write-Host "   Recommendation: Review and remove unnecessary anonymous links" -ForegroundColor White
        Write-Host ""
    }

    if ($totalExternalLinks -gt 0) {
        Write-Host "⚠️  $totalExternalLinks external user links found" -ForegroundColor Yellow
        Write-Host "   These links provide access to external users" -ForegroundColor Yellow
        Write-Host "   Recommendation: Verify each external user is authorized" -ForegroundColor White
        Write-Host ""
    }

    if ($totalAnonymousLinks -eq 0 -and $totalExternalLinks -eq 0) {
        Write-Host "✅ No external sharing found!" -ForegroundColor Green
        Write-Host "   Your SharePoint environment is secure" -ForegroundColor White
        Write-Host ""
    }

    $endTimestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "Completed: $endTimestamp" -ForegroundColor Gray
}
catch {
    Write-Error "An error occurred: $($_.Exception.Message)"
    Write-Error $_.ScriptStackTrace
}
finally {
    Disconnect-PnPOnline -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Audit Complete!" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
