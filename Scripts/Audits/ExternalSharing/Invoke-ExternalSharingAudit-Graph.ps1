<#
.SYNOPSIS
    Audits SharePoint and OneDrive for external sharing using Microsoft Graph API.

.DESCRIPTION
    Searches SharePoint sites and OneDrive libraries for files explicitly shared
    with external users using Microsoft Graph API instead of tenant-level commands.

.PARAMETER SearchName
    Name to search for in external shares (e.g., "Virginia")

.PARAMETER OutputPath
    Path for the audit report CSV file

.EXAMPLE
    ./Invoke-ExternalSharingAudit-Graph.ps1 -SearchName "Virginia"

.NOTES
    This script uses Microsoft Graph and works with delegated permissions.
    Does not require SharePoint Administrator role.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SearchName,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "./external-sharing-audit-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
)

# Check if Microsoft.Graph modules are installed
$requiredModules = @('Microsoft.Graph.Authentication', 'Microsoft.Graph.Sites', 'Microsoft.Graph.Users')
foreach ($module in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $module)) {
        Write-Host "Installing $module..." -ForegroundColor Cyan
        Install-Module $module -Scope CurrentUser -Force -AllowClobber
    }
}

Import-Module Microsoft.Graph.Authentication
Import-Module Microsoft.Graph.Sites
Import-Module Microsoft.Graph.Users

$results = @()
$ErrorActionPreference = 'Continue'

try {
    Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Cyan
    Connect-MgGraph -Scopes "Sites.Read.All","User.Read.All","Files.Read.All" -NoWelcome

    Write-Host "Successfully connected!" -ForegroundColor Green

    # First, find all external users matching the search name
    Write-Host "`nSearching for external users matching '$SearchName'..." -ForegroundColor Cyan

    $externalUsers = Get-MgUser -Filter "userType eq 'Guest'" -All -Property Id,DisplayName,Mail,UserPrincipalName,UserType |
        Where-Object {
            $_.DisplayName -like "*$SearchName*" -or
            $_.Mail -like "*$SearchName*" -or
            $_.UserPrincipalName -like "*$SearchName*"
        }

    if (-not $externalUsers -or $externalUsers.Count -eq 0) {
        Write-Host "`n==================================" -ForegroundColor Green
        Write-Host "NO EXTERNAL USERS FOUND" -ForegroundColor Green
        Write-Host "==================================" -ForegroundColor Green
        Write-Host "No external (guest) users matching '$SearchName' were found." -ForegroundColor Green
        Write-Host "Therefore, no files can be explicitly shared with external Virginia users." -ForegroundColor Green
        return
    }

    Write-Host "Found $($externalUsers.Count) external user(s) matching '$SearchName':" -ForegroundColor Yellow
    foreach ($user in $externalUsers) {
        Write-Host "  - $($user.DisplayName) ($($user.Mail))" -ForegroundColor White
    }

    $externalUserIds = $externalUsers | Select-Object -ExpandProperty Id

    Write-Host "`nRetrieving SharePoint sites..." -ForegroundColor Cyan
    $sites = Get-MgSite -All -Property Id,DisplayName,WebUrl,SiteCollection

    Write-Host "Found $($sites.Count) sites to check" -ForegroundColor Green

    $siteCounter = 0
    foreach ($site in $sites) {
        $siteCounter++
        $percentComplete = [math]::Round(($siteCounter / $sites.Count) * 100, 2)
        Write-Progress -Activity "Scanning sites for external sharing" -Status "Processing $($site.DisplayName)" -PercentComplete $percentComplete

        $isOneDrive = $site.WebUrl -like "*/personal/*"
        $siteType = if ($isOneDrive) { "OneDrive" } else { "SharePoint Site" }

        try {
            Write-Host "  Checking $siteType : $($site.DisplayName)" -ForegroundColor Yellow

            # Get all drives in the site
            $drives = Get-MgSiteDrive -SiteId $site.Id -ErrorAction SilentlyContinue

            foreach ($drive in $drives) {
                try {
                    # Get all items in the drive
                    $driveItems = Get-MgDriveItem -DriveId $drive.Id -ErrorAction SilentlyContinue

                    foreach ($item in $driveItems) {
                        if ($item.File) {  # It's a file
                            try {
                                # Get permissions for the item
                                $permissions = Get-MgDriveItemPermission -DriveId $drive.Id -DriveItemId $item.Id -ErrorAction SilentlyContinue

                                foreach ($permission in $permissions) {
                                    $isMatch = $false
                                    $matchInfo = ""

                                    # Check if permission is for an external user matching our search
                                    if ($permission.GrantedToIdentitiesV2) {
                                        foreach ($identity in $permission.GrantedToIdentitiesV2) {
                                            $userId = $identity.User.Id
                                            if ($externalUserIds -contains $userId) {
                                                $isMatch = $true
                                                $matchedUser = $externalUsers | Where-Object { $_.Id -eq $userId }
                                                $matchInfo = "$($matchedUser.DisplayName) ($($matchedUser.Mail))"
                                            }
                                        }
                                    }

                                    if ($permission.GrantedToV2) {
                                        $userId = $permission.GrantedToV2.User.Id
                                        if ($externalUserIds -contains $userId) {
                                            $isMatch = $true
                                            $matchedUser = $externalUsers | Where-Object { $_.Id -eq $userId }
                                            $matchInfo = "$($matchedUser.DisplayName) ($($matchedUser.Mail))"
                                        }
                                    }

                                    # Check for anonymous/anyone links
                                    if ($permission.Link -and ($permission.Link.Type -eq 'view' -or $permission.Link.Type -eq 'edit') -and
                                        $permission.Link.Scope -eq 'anonymous') {
                                        $results += [PSCustomObject]@{
                                            SiteType = $siteType
                                            SiteUrl = $site.WebUrl
                                            SiteName = $site.DisplayName
                                            FilePath = $item.WebUrl
                                            FileName = $item.Name
                                            ShareType = "Anonymous Link"
                                            SharedWith = "Anyone with link"
                                            Permissions = $permission.Link.Type
                                            MatchReason = "Potential external access (anonymous link)"
                                        }
                                    }

                                    if ($isMatch) {
                                        $results += [PSCustomObject]@{
                                            SiteType = $siteType
                                            SiteUrl = $site.WebUrl
                                            SiteName = $site.DisplayName
                                            FilePath = $item.WebUrl
                                            FileName = $item.Name
                                            ShareType = "Direct Permission"
                                            SharedWith = $matchInfo
                                            Permissions = $permission.Roles -join ", "
                                            MatchReason = "External user match: $SearchName"
                                        }

                                        Write-Host "    MATCH FOUND: $($item.Name) shared with $matchInfo" -ForegroundColor Red
                                    }
                                }
                            }
                            catch {
                                Write-Verbose "    Could not check permissions for: $($item.Name)"
                            }
                        }
                    }
                }
                catch {
                    Write-Verbose "  Could not access drive: $($drive.Name)"
                }
            }
        }
        catch {
            Write-Warning "  Could not access site: $($site.DisplayName) - $($_.Exception.Message)"
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
        Write-Host "No files found shared with external '$SearchName' users" -ForegroundColor Green
        Write-Host "(External users exist but no files are shared with them)" -ForegroundColor Yellow
    }
}
catch {
    Write-Error "An error occurred: $($_.Exception.Message)"
    Write-Error $_.ScriptStackTrace
}
finally {
    Disconnect-MgGraph -ErrorAction SilentlyContinue
}
