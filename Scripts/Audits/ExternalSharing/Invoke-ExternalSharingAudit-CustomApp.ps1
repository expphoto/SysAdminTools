<#
.SYNOPSIS
    Audits SharePoint and OneDrive for external sharing using custom Azure AD app.

.DESCRIPTION
    Searches SharePoint sites and OneDrive libraries for files explicitly shared
    with external users matching a specified name or email pattern.
    Uses a custom Azure AD app registration for authentication.

.PARAMETER TenantUrl
    Your SharePoint admin URL (e.g., https://netorg368294-admin.sharepoint.com)

.PARAMETER ClientId
    Azure AD App Client ID

.PARAMETER TenantId
    Your Azure AD Tenant ID (e.g., channelislandslg.com or GUID)

.PARAMETER SearchName
    Name to search for in external shares (e.g., "Virginia")

.PARAMETER CertificateThumbprint
    Certificate thumbprint for app authentication (optional - will use interactive if not provided)

.PARAMETER OutputPath
    Path for the audit report CSV file

.EXAMPLE
    ./Invoke-ExternalSharingAudit-CustomApp.ps1 -TenantUrl "https://netorg368294-admin.sharepoint.com" -ClientId "your-app-id" -TenantId "channelislandslg.com" -SearchName "Virginia"

.NOTES
    Setup Instructions:
    1. Register Azure AD App (see setup guide in README)
    2. Grant API permissions: Sites.Read.All, User.Read.All
    3. Grant admin consent for the permissions
    4. Run this script with the app's Client ID and your Tenant ID
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TenantUrl,

    [Parameter(Mandatory = $true)]
    [string]$ClientId,

    [Parameter(Mandatory = $true)]
    [string]$TenantId,

    [Parameter(Mandatory = $true)]
    [string]$SearchName,

    [Parameter(Mandatory = $false)]
    [string]$CertificateThumbprint = "",

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "./external-sharing-audit-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
)

# Check if PnP.PowerShell is installed
if (-not (Get-Module -ListAvailable -Name PnP.PowerShell)) {
    Write-Error "PnP.PowerShell module is not installed. Please run: Install-Module PnP.PowerShell -Scope CurrentUser"
    exit 1
}

$results = @()
$ErrorActionPreference = 'Continue'

try {
    Write-Host "Connecting to SharePoint Admin Center with custom app..." -ForegroundColor Cyan

    if ($CertificateThumbprint) {
        # Certificate-based authentication
        Connect-PnPOnline -Url $TenantUrl -ClientId $ClientId -Tenant $TenantId -Thumbprint $CertificateThumbprint
    } else {
        # Interactive authentication with custom app
        Connect-PnPOnline -Url $TenantUrl -ClientId $ClientId -Interactive -Tenant $TenantId
    }

    Write-Host "Successfully connected!" -ForegroundColor Green
    Write-Host "Retrieving all SharePoint sites..." -ForegroundColor Cyan

    $sites = Get-PnPTenantSite -Filter "Url -like '-my.sharepoint.com/personal/' -or Template -ne 'RedirectSite'" |
             Where-Object { $_.Template -ne 'SRCHCEN#0' -and $_.Url -notlike '*/portals/*' }

    Write-Host "Found $($sites.Count) sites to check" -ForegroundColor Green

    $siteCounter = 0
    foreach ($site in $sites) {
        $siteCounter++
        $percentComplete = [math]::Round(($siteCounter / $sites.Count) * 100, 2)
        Write-Progress -Activity "Scanning sites for external sharing" -Status "Processing $($site.Url)" -PercentComplete $percentComplete

        $isOneDrive = $site.Url -like "*/personal/*"
        $siteType = if ($isOneDrive) { "OneDrive" } else { "SharePoint Site" }

        try {
            # Connect to the specific site
            if ($CertificateThumbprint) {
                Connect-PnPOnline -Url $site.Url -ClientId $ClientId -Tenant $TenantId -Thumbprint $CertificateThumbprint
            } else {
                Connect-PnPOnline -Url $site.Url -ClientId $ClientId -Interactive -Tenant $TenantId
            }

            Write-Host "  Checking $siteType : $($site.Url)" -ForegroundColor Yellow

            # Get all document libraries
            $lists = Get-PnPList | Where-Object { $_.BaseTemplate -eq 101 -and $_.Hidden -eq $false }

            foreach ($list in $lists) {
                try {
                    $items = Get-PnPListItem -List $list -PageSize 2000

                    foreach ($item in $items) {
                        if ($item.FileSystemObjectType -eq "File") {
                            try {
                                # Check item-level permissions
                                $roleAssignments = Get-PnPProperty -ClientObject $item -Property RoleAssignments
                                Get-PnPProperty -ClientObject $roleAssignments -Property Member, RoleDefinitionBindings

                                foreach ($roleAssignment in $roleAssignments) {
                                    $member = $roleAssignment.Member

                                    # Check if member is external or matches our search criteria
                                    $isMatch = $false
                                    $matchReason = ""
                                    $sharedWithEmail = ""

                                    # External users have #ext# in their login name or LoginName contains urn:spo:guest
                                    if ($member.LoginName -like "*#ext#*" -or $member.LoginName -like "*urn:spo:guest*") {
                                        $sharedWithEmail = $member.Email
                                        $displayName = $member.Title

                                        # Check if name or email matches
                                        if ($displayName -like "*$SearchName*") {
                                            $isMatch = $true
                                            $matchReason = "Name match: $displayName"
                                        }

                                        if ($sharedWithEmail -like "*$SearchName*") {
                                            $isMatch = $true
                                            $matchReason += " Email match: $sharedWithEmail"
                                        }
                                    }

                                    if ($isMatch) {
                                        $permissions = ($roleAssignment.RoleDefinitionBindings | Select-Object -ExpandProperty Name) -join ", "

                                        $results += [PSCustomObject]@{
                                            SiteType = $siteType
                                            SiteUrl = $site.Url
                                            SiteTitle = $site.Title
                                            FilePath = $item["FileRef"]
                                            FileName = $item["FileLeafRef"]
                                            ShareType = "Direct Permission"
                                            SharedWith = "$($member.Title) ($sharedWithEmail)"
                                            Permissions = $permissions
                                            MatchReason = $matchReason
                                        }

                                        Write-Host "    MATCH FOUND: $($item['FileLeafRef']) shared with $($member.Title)" -ForegroundColor Red
                                    }
                                }
                            }
                            catch {
                                Write-Verbose "    Could not check permissions for: $($item['FileLeafRef'])"
                            }
                        }
                    }
                }
                catch {
                    Write-Verbose "  Could not access list: $($list.Title)"
                }
            }
        }
        catch {
            Write-Warning "  Could not access site: $($site.Url) - $($_.Exception.Message)"
        }
    }

    Write-Progress -Activity "Scanning sites for external sharing" -Completed

    # Export results
    if ($results.Count -gt 0) {
        $results | Export-Csv -Path $OutputPath -NoTypeInformation
        Write-Host "`n==================================" -ForegroundColor Green
        Write-Host "AUDIT COMPLETE" -ForegroundColor Green
        Write-Host "==================================" -ForegroundColor Green
        Write-Host "Found $($results.Count) items with external sharing matching '$SearchName'" -ForegroundColor Yellow
        Write-Host "Report saved to: $OutputPath" -ForegroundColor Cyan
        Write-Host "`nSummary:" -ForegroundColor Cyan
        Write-Host "  SharePoint Sites: $(($results | Where-Object { $_.SiteType -eq 'SharePoint Site' }).Count)" -ForegroundColor White
        Write-Host "  OneDrive: $(($results | Where-Object { $_.SiteType -eq 'OneDrive' }).Count)" -ForegroundColor White
    }
    else {
        Write-Host "`n==================================" -ForegroundColor Green
        Write-Host "AUDIT COMPLETE" -ForegroundColor Green
        Write-Host "==================================" -ForegroundColor Green
        Write-Host "No external shares found matching '$SearchName'" -ForegroundColor Green
    }
}
catch {
    Write-Error "An error occurred: $($_.Exception.Message)"
}
finally {
    Disconnect-PnPOnline -ErrorAction SilentlyContinue
}
