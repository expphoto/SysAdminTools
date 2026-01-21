<#
.SYNOPSIS
    Generates comprehensive SharePoint Online sharing report including anonymous links.

.DESCRIPTION
    Uses SharePoint Online Management Shell to generate reports on:
    - Anonymous sharing links
    - External sharing settings
    - Sharing activity across all sites

.PARAMETER TenantAdminUrl
    Your SharePoint admin URL (e.g., https://netorg368294-admin.sharepoint.com)

.PARAMETER OutputPath
    Path for the audit report

.EXAMPLE
    ./Invoke-SharePointSharingReport.ps1 -TenantAdminUrl "https://netorg368294-admin.sharepoint.com"

.NOTES
    Requires SharePoint Administrator or Global Administrator role
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TenantAdminUrl,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "./sharepoint-sharing-report-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
)

# Check if SharePoint Online Management Shell is installed
if (-not (Get-Module -ListAvailable -Name Microsoft.Online.SharePoint.PowerShell)) {
    Write-Host "Installing SharePoint Online Management Shell..." -ForegroundColor Cyan
    Install-Module -Name Microsoft.Online.SharePoint.PowerShell -Scope CurrentUser -Force
}

Import-Module Microsoft.Online.SharePoint.PowerShell

$allResults = @()
$anonymousLinks = @()
$externalSharing = @()

try {
    Write-Host "=====================================" -ForegroundColor Cyan
    Write-Host "SHAREPOINT SHARING REPORT" -ForegroundColor Cyan
    Write-Host "=====================================" -ForegroundColor Cyan
    Write-Host ""

    Write-Host "Connecting to SharePoint Online..." -ForegroundColor Cyan
    Connect-SPOService -Url $TenantAdminUrl

    Write-Host "Successfully connected!" -ForegroundColor Green
    Write-Host ""

    # Get tenant-level sharing settings
    Write-Host "Retrieving tenant sharing settings..." -ForegroundColor Cyan
    $tenant = Get-SPOTenant

    Write-Host ""
    Write-Host "=====================================" -ForegroundColor Yellow
    Write-Host "TENANT SHARING CONFIGURATION" -ForegroundColor Yellow
    Write-Host "=====================================" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "External Sharing Setting: $($tenant.SharingCapability)" -ForegroundColor White
    Write-Host "Anonymous Link Types Allowed: $($tenant.DefaultLinkPermission)" -ForegroundColor White
    Write-Host "Default Link Type: $($tenant.DefaultSharingLinkType)" -ForegroundColor White
    Write-Host "External User Expiration (Days): $($tenant.ExternalUserExpirationRequired)" -ForegroundColor White
    Write-Host ""

    # Interpret sharing capability
    switch ($tenant.SharingCapability) {
        "Disabled" {
            Write-Host "  Sharing Status: External sharing is DISABLED" -ForegroundColor Green
        }
        "ExistingExternalUserSharingOnly" {
            Write-Host "  Sharing Status: Only existing external users can access" -ForegroundColor Yellow
        }
        "ExternalUserSharingOnly" {
            Write-Host "  Sharing Status: New and existing external users (requires sign-in)" -ForegroundColor Yellow
        }
        "ExternalUserAndGuestSharing" {
            Write-Host "  Sharing Status: Anonymous guest links ENABLED" -ForegroundColor Red
        }
    }
    Write-Host ""

    # Get all sites
    Write-Host "Retrieving all SharePoint sites..." -ForegroundColor Cyan
    $sites = Get-SPOSite -Limit All -IncludePersonalSite $true |
             Where-Object { $_.Template -ne "SRCHCEN#0" }

    Write-Host "Found $($sites.Count) sites" -ForegroundColor Green
    Write-Host ""

    # Analyze each site's sharing settings
    Write-Host "=====================================" -ForegroundColor Cyan
    Write-Host "SITE-LEVEL SHARING ANALYSIS" -ForegroundColor Cyan
    Write-Host "=====================================" -ForegroundColor Cyan
    Write-Host ""

    $siteCounter = 0
    $sitesWithExternalSharing = @()
    $sitesWithAnonymousLinks = @()

    foreach ($site in $sites) {
        $siteCounter++
        Write-Progress -Activity "Analyzing site sharing settings" -Status "Processing $($site.Url)" -PercentComplete (($siteCounter / $sites.Count) * 100)

        $isOneDrive = $site.Url -like "*/personal/*"
        $siteType = if ($isOneDrive) { "OneDrive" } else { "SharePoint Site" }

        # Check sharing capability
        if ($site.SharingCapability -ne "Disabled") {
            $sitesWithExternalSharing += [PSCustomObject]@{
                SiteType = $siteType
                SiteUrl = $site.Url
                Title = $site.Title
                Owner = $site.Owner
                SharingCapability = $site.SharingCapability
                AnonymousLinkAllowed = ($site.SharingCapability -eq "ExternalUserAndGuestSharing")
                LastModified = $site.LastContentModifiedDate
                StorageUsedMB = [math]::Round($site.StorageUsageCurrent, 2)
            }

            if ($site.SharingCapability -eq "ExternalUserAndGuestSharing") {
                $sitesWithAnonymousLinks += $site
                Write-Host "  ⚠️  $siteType : $($site.Title)" -ForegroundColor Yellow
                Write-Host "      URL: $($site.Url)" -ForegroundColor Gray
                Write-Host "      Anonymous Links: ENABLED" -ForegroundColor Red
                Write-Host ""
            }
        }
    }

    Write-Progress -Activity "Analyzing site sharing settings" -Completed

    # Summary statistics
    Write-Host ""
    Write-Host "=====================================" -ForegroundColor Green
    Write-Host "SUMMARY" -ForegroundColor Green
    Write-Host "=====================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Total Sites: $($sites.Count)" -ForegroundColor White
    Write-Host "Sites with External Sharing Enabled: $($sitesWithExternalSharing.Count)" -ForegroundColor $(if ($sitesWithExternalSharing.Count -gt 0) { "Yellow" } else { "Green" })
    Write-Host "Sites allowing Anonymous Links: $($sitesWithAnonymousLinks.Count)" -ForegroundColor $(if ($sitesWithAnonymousLinks.Count -gt 0) { "Red" } else { "Green" })
    Write-Host ""

    # Export results
    if ($sitesWithExternalSharing.Count -gt 0) {
        $csvPath = "$OutputPath-external-sharing-sites.csv"
        $sitesWithExternalSharing | Export-Csv -Path $csvPath -NoTypeInformation
        Write-Host "External sharing sites exported to: $csvPath" -ForegroundColor Cyan
        Write-Host ""

        # Group by sharing capability
        Write-Host "Sites by Sharing Level:" -ForegroundColor Cyan
        $sitesWithExternalSharing | Group-Object SharingCapability |
            Select-Object @{Name="Sharing Level";Expression={$_.Name}}, Count |
            Format-Table -AutoSize
    }

    # Get external users (from SPO perspective)
    Write-Host ""
    Write-Host "=====================================" -ForegroundColor Cyan
    Write-Host "EXTERNAL USER REPORT" -ForegroundColor Cyan
    Write-Host "=====================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Checking for external users in SharePoint..." -ForegroundColor Cyan

    try {
        $externalUsersReport = Get-SPOExternalUser -PageSize 50

        if ($externalUsersReport -and $externalUsersReport.Count -gt 0) {
            Write-Host "Found $($externalUsersReport.Count) external user records" -ForegroundColor Yellow
            Write-Host ""

            $externalUsersList = @()
            foreach ($extUser in $externalUsersReport) {
                Write-Host "  - $($extUser.DisplayName) ($($extUser.Email))" -ForegroundColor White
                Write-Host "    Accepted: $($extUser.AcceptedAs)" -ForegroundColor Gray
                Write-Host "    When Invited: $($extUser.WhenCreated)" -ForegroundColor Gray
                Write-Host ""

                $externalUsersList += [PSCustomObject]@{
                    DisplayName = $extUser.DisplayName
                    Email = $extUser.Email
                    AcceptedAs = $extUser.AcceptedAs
                    WhenInvited = $extUser.WhenCreated
                    UniqueId = $extUser.UniqueId
                }
            }

            # Export external users
            $extUsersCsvPath = "$OutputPath-external-users.csv"
            $externalUsersList | Export-Csv -Path $extUsersCsvPath -NoTypeInformation
            Write-Host "External users exported to: $extUsersCsvPath" -ForegroundColor Cyan
        } else {
            Write-Host "No external users found in SharePoint Online" -ForegroundColor Green
        }
    }
    catch {
        Write-Host "Could not retrieve external user report: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "(This may require SharePoint Administrator permissions)" -ForegroundColor Gray
    }

    Write-Host ""
    Write-Host "=====================================" -ForegroundColor Green
    Write-Host "REPORT COMPLETE" -ForegroundColor Green
    Write-Host "=====================================" -ForegroundColor Green
    Write-Host ""

    # Recommendations
    Write-Host "=====================================" -ForegroundColor Cyan
    Write-Host "SECURITY RECOMMENDATIONS" -ForegroundColor Cyan
    Write-Host "=====================================" -ForegroundColor Cyan
    Write-Host ""

    if ($sitesWithAnonymousLinks.Count -gt 0) {
        Write-Host "⚠️  $($sitesWithAnonymousLinks.Count) sites allow anonymous sharing links" -ForegroundColor Red
        Write-Host "   Consider:" -ForegroundColor Yellow
        Write-Host "   - Review if anonymous sharing is necessary" -ForegroundColor White
        Write-Host "   - Implement expiration dates for anonymous links" -ForegroundColor White
        Write-Host "   - Disable anonymous sharing where not needed" -ForegroundColor White
        Write-Host ""
    }

    if ($sitesWithExternalSharing.Count -eq 0) {
        Write-Host "✅ No sites have external sharing enabled" -ForegroundColor Green
        Write-Host "   Your SharePoint environment is configured securely" -ForegroundColor White
        Write-Host ""
    }

    Write-Host "To disable external sharing on a specific site:" -ForegroundColor Cyan
    Write-Host "  Set-SPOSite -Identity <SiteURL> -SharingCapability Disabled" -ForegroundColor Gray
    Write-Host ""

}
catch {
    Write-Error "An error occurred: $($_.Exception.Message)"
}
finally {
    Disconnect-SPOService -ErrorAction SilentlyContinue
}

Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "Audit complete!" -ForegroundColor Cyan
Write-Host "=====================================" -ForegroundColor Cyan
