<#
.SYNOPSIS
    Audits SharePoint and OneDrive for external sharing with specific users.

.DESCRIPTION
    Searches SharePoint sites and OneDrive libraries for files explicitly shared
    with external users matching a specified name or email pattern.

.PARAMETER TenantUrl
    Your SharePoint admin URL (e.g., https://contoso-admin.sharepoint.com)

.PARAMETER SearchName
    Name to search for in external shares (e.g., "Virginia")

.PARAMETER ExternalEmailPattern
    Optional email pattern to search for (e.g., "*virginia*")

.PARAMETER OutputPath
    Path for the audit report CSV file

.EXAMPLE
    ./Invoke-ExternalSharingAudit.ps1 -TenantUrl "https://contoso-admin.sharepoint.com" -SearchName "Virginia"

.NOTES
    Requirements:
    - PowerShell 7+ (PowerShell Core for Mac)
    - PnP.PowerShell module
    - SharePoint Administrator or Global Administrator role

    Installation on Mac:
    brew install --cask powershell
    pwsh
    Install-Module PnP.PowerShell -Scope CurrentUser
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TenantUrl,

    [Parameter(Mandatory = $true)]
    [string]$SearchName,

    [Parameter(Mandatory = $false)]
    [string]$ExternalEmailPattern = "",

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
    Write-Host "Connecting to SharePoint Admin Center..." -ForegroundColor Cyan
    Connect-PnPOnline -Url $TenantUrl -Interactive

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
            Connect-PnPOnline -Url $site.Url -Interactive

            # Get all sharing links and permissions
            Write-Host "  Checking $siteType : $($site.Url)" -ForegroundColor Yellow

            # Get all files in the site
            $lists = Get-PnPList | Where-Object { $_.BaseTemplate -eq 101 -and $_.Hidden -eq $false }

            foreach ($list in $lists) {
                try {
                    $items = Get-PnPListItem -List $list -PageSize 2000

                    foreach ($item in $items) {
                        if ($item.FileSystemObjectType -eq "File") {
                            try {
                                # Get sharing information for the item
                                $sharingInfo = Get-PnPFileSharingLink -Identity $item.Id -List $list -ErrorAction SilentlyContinue

                                if ($sharingInfo) {
                                    foreach ($link in $sharingInfo) {
                                        # Check if it's shared externally
                                        if ($link.ShareLink.IsAnonymous -or $link.ShareLink.AllowsAnonymousAccess) {
                                            $results += [PSCustomObject]@{
                                                SiteType = $siteType
                                                SiteUrl = $site.Url
                                                SiteTitle = $site.Title
                                                FilePath = $item["FileRef"]
                                                FileName = $item["FileLeafRef"]
                                                ShareType = "Anonymous Link"
                                                SharedWith = "Anyone with link"
                                                LinkType = $link.ShareLink.Type
                                                CreatedBy = $link.ShareLink.CreatedBy
                                                CreatedDate = $link.ShareLink.Created
                                                MatchReason = "Potential external share (anonymous)"
                                            }
                                        }
                                    }
                                }

                                # Check item-level permissions
                                $roleAssignments = Get-PnPProperty -ClientObject $item -Property RoleAssignments
                                Get-PnPProperty -ClientObject $roleAssignments -Property Member, RoleDefinitionBindings

                                foreach ($roleAssignment in $roleAssignments) {
                                    $member = $roleAssignment.Member

                                    # Check if member is external or matches our search criteria
                                    $isMatch = $false
                                    $matchReason = ""
                                    $sharedWithEmail = ""

                                    if ($member.LoginName -like "*#ext#*") {
                                        # External user
                                        $sharedWithEmail = $member.Email
                                        $displayName = $member.Title

                                        # Check if name or email matches
                                        if ($displayName -like "*$SearchName*") {
                                            $isMatch = $true
                                            $matchReason = "Name match: $displayName"
                                        }

                                        if ($ExternalEmailPattern -and $sharedWithEmail -like "*$ExternalEmailPattern*") {
                                            $isMatch = $true
                                            $matchReason += " Email match: $sharedWithEmail"
                                        }

                                        if (-not $ExternalEmailPattern -and $sharedWithEmail -like "*$SearchName*") {
                                            $isMatch = $true
                                            $matchReason = "Email match: $sharedWithEmail"
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
                                            LinkType = $permissions
                                            CreatedBy = "N/A"
                                            CreatedDate = "N/A"
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
    Disconnect-PnPOnline
}
