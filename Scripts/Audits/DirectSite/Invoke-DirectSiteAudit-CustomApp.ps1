<#
.SYNOPSIS
    Direct audit of specific SharePoint site URLs using custom Azure AD app.

.DESCRIPTION
    Scans provided URLs for all sharing links using custom app authentication.

.PARAMETER SiteUrls
    Array of specific site URLs to scan

.PARAMETER ClientId
    Azure AD App Client ID

.PARAMETER TenantId
    Azure AD Tenant ID

.PARAMETER OutputPath
    Base path for output files

.EXAMPLE
    $sites = @("https://netorg368294.sharepoint.com")
    ./Invoke-DirectSiteAudit-CustomApp.ps1 -SiteUrls $sites -ClientId "87f1f77d-4fbb-4375-ae34-a702b2ab8521" -TenantId "8fbe6cee-1229-4e2d-921a-46b1f93d7242"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]]$SiteUrls,

    [Parameter(Mandatory = $true)]
    [string]$ClientId,

    [Parameter(Mandatory = $true)]
    [string]$TenantId,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "./direct-site-audit-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
)

if (-not (Get-Module -ListAvailable -Name PnP.PowerShell)) {
    Write-Error "PnP.PowerShell module is not installed."
    exit 1
}

$allSharingLinks = @()
$anonymousLinks = @()
$externalUserLinks = @()
$siteSummary = @()

try {
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "DIRECT SITE AUDIT (Custom App)" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Sites to scan: $($SiteUrls.Count)" -ForegroundColor Yellow
    Write-Host ""

    $siteCounter = 0

    foreach ($siteUrl in $SiteUrls) {
        $siteCounter++
        Write-Host "[$siteCounter/$($SiteUrls.Count)] Scanning: $siteUrl" -ForegroundColor Cyan

        try {
            Connect-PnPOnline -Url $siteUrl -ClientId $ClientId -Tenant $TenantId -Interactive

            $web = Get-PnPWeb
            $siteTitle = $web.Title

            Write-Host "  Connected: $siteTitle" -ForegroundColor Green

            $siteAnonymousCount = 0
            $siteExternalCount = 0
            $siteInternalCount = 0
            $filesChecked = 0

            $lists = Get-PnPList | Where-Object { $_.BaseTemplate -eq 101 -and $_.Hidden -eq $false }

            Write-Host "  Libraries: $($lists.Count)" -ForegroundColor Gray

            foreach ($list in $lists) {
                Write-Host "    $($list.Title)..." -ForegroundColor Gray

                try {
                    $items = Get-PnPListItem -List $list -PageSize 500

                    foreach ($item in $items) {
                        if ($item.FileSystemObjectType -eq "File") {
                            $filesChecked++

                            try {
                                $sharingLinks = Get-PnPFileSharingLink -Identity $item.Id -List $list -ErrorAction SilentlyContinue

                                if ($sharingLinks) {
                                    foreach ($link in $sharingLinks) {
                                        $linkType = "Unknown"
                                        $isAnonymous = $false
                                        $isExternal = $false

                                        if ($link.ShareLink) {
                                            if ($link.ShareLink.IsAnonymous -or $link.ShareLink.AllowsAnonymousAccess) {
                                                $linkType = "Anonymous (Anyone with the link)"
                                                $isAnonymous = $true
                                                $siteAnonymousCount++
                                                Write-Host "      🔓 ANONYMOUS: $($item['FileLeafRef'])" -ForegroundColor Red
                                            }
                                            elseif ($link.ShareLink.Scope -eq "Organization") {
                                                $linkType = "Organization"
                                                $siteInternalCount++
                                            }
                                            else {
                                                $linkType = "Specific People"
                                                $siteInternalCount++
                                            }

                                            $allSharingLinks += [PSCustomObject]@{
                                                SiteUrl = $siteUrl
                                                SiteTitle = $siteTitle
                                                Library = $list.Title
                                                FileName = $item["FileLeafRef"]
                                                FilePath = $item["FileRef"]
                                                LinkType = $linkType
                                                IsAnonymous = $isAnonymous
                                                Scope = $link.ShareLink.Scope
                                                CreatedBy = if ($link.ShareLink.CreatedBy) { $link.ShareLink.CreatedBy.Email } else { "Unknown" }
                                                Created = if ($link.ShareLink.Created) { $link.ShareLink.Created } else { "Unknown" }
                                            }

                                            if ($isAnonymous) {
                                                $anonymousLinks += $allSharingLinks[-1]
                                            }
                                        }
                                    }
                                }

                                # Check permissions
                                $hasUniquePerms = Get-PnPProperty -ClientObject $item -Property HasUniqueRoleAssignments
                                if ($item.HasUniqueRoleAssignments) {
                                    $roleAssignments = Get-PnPProperty -ClientObject $item -Property RoleAssignments
                                    Get-PnPProperty -ClientObject $roleAssignments -Property Member, RoleDefinitionBindings

                                    foreach ($roleAssignment in $roleAssignments) {
                                        $member = $roleAssignment.Member

                                        if ($member.LoginName -like "*#ext#*" -or $member.LoginName -like "*urn:spo:guest*") {
                                            $permissions = ($roleAssignment.RoleDefinitionBindings | Select-Object -ExpandProperty Name) -join ", "

                                            $extRecord = [PSCustomObject]@{
                                                SiteUrl = $siteUrl
                                                SiteTitle = $siteTitle
                                                Library = $list.Title
                                                FileName = $item["FileLeafRef"]
                                                FilePath = $item["FileRef"]
                                                LinkType = "External User"
                                                IsAnonymous = $false
                                                Scope = "External"
                                                CreatedBy = "$($member.Title) - $($member.Email)"
                                                Created = "N/A"
                                            }

                                            $allSharingLinks += $extRecord
                                            $externalUserLinks += $extRecord
                                            $siteExternalCount++

                                            Write-Host "      👤 EXTERNAL: $($member.Title) - $($item['FileLeafRef'])" -ForegroundColor Yellow
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
                SiteUrl = $siteUrl
                SiteTitle = $siteTitle
                FilesChecked = $filesChecked
                AnonymousLinks = $siteAnonymousCount
                ExternalUserPerms = $siteExternalCount
                InternalLinks = $siteInternalCount
                TotalExternal = $siteAnonymousCount + $siteExternalCount
            }

            Write-Host "  ✓ Files: $filesChecked | Anonymous: $siteAnonymousCount | External: $siteExternalCount | Internal: $siteInternalCount" -ForegroundColor $(if ($siteAnonymousCount -gt 0 -or $siteExternalCount -gt 0) { "Yellow" } else { "Green" })
            Write-Host ""

            Disconnect-PnPOnline
        }
        catch {
            Write-Warning "Could not access: $siteUrl - $($_.Exception.Message)"
        }
    }

    # Export
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "EXPORTING RESULTS" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""

    if ($allSharingLinks.Count -gt 0) {
        $allFile = "$OutputPath-all-links.csv"
        $allSharingLinks | Export-Csv -Path $allFile -NoTypeInformation
        Write-Host "All links: $allFile" -ForegroundColor Cyan
    }

    if ($anonymousLinks.Count -gt 0) {
        $anonFile = "$OutputPath-anonymous-links.csv"
        $anonymousLinks | Export-Csv -Path $anonFile -NoTypeInformation
        Write-Host "Anonymous: $anonFile" -ForegroundColor Cyan
    }

    if ($externalUserLinks.Count -gt 0) {
        $extFile = "$OutputPath-external-users.csv"
        $externalUserLinks | Export-Csv -Path $extFile -NoTypeInformation
        Write-Host "External users: $extFile" -ForegroundColor Cyan
    }

    $summaryFile = "$OutputPath-summary.csv"
    $siteSummary | Export-Csv -Path $summaryFile -NoTypeInformation
    Write-Host "Summary: $summaryFile" -ForegroundColor Cyan

    # Final
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "AUDIT COMPLETE" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "📊 RESULTS:" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Sites: $($siteSummary.Count)" -ForegroundColor White
    Write-Host "  Files Checked: $(($siteSummary | Measure-Object -Property FilesChecked -Sum).Sum)" -ForegroundColor White
    Write-Host "  Total Links: $($allSharingLinks.Count)" -ForegroundColor White
    Write-Host ""
    Write-Host "  🔓 Anonymous: $($anonymousLinks.Count)" -ForegroundColor $(if ($anonymousLinks.Count -gt 0) { "Red" } else { "Green" })
    Write-Host "  👤 External Users: $($externalUserLinks.Count)" -ForegroundColor $(if ($externalUserLinks.Count -gt 0) { "Yellow" } else { "Green" })
    Write-Host ""

    if ($anonymousLinks.Count -gt 0) {
        Write-Host "🔓 ANONYMOUS LINKS:" -ForegroundColor Red
        $anonymousLinks | ForEach-Object {
            Write-Host "  • $($_.FileName)" -ForegroundColor White
            Write-Host "    $($_.FilePath)" -ForegroundColor Gray
        }
        Write-Host ""
    }

    if ($externalUserLinks.Count -gt 0) {
        Write-Host "👤 EXTERNAL USERS:" -ForegroundColor Yellow
        $externalUserLinks | ForEach-Object {
            Write-Host "  • $($_.FileName)" -ForegroundColor White
            Write-Host "    User: $($_.CreatedBy)" -ForegroundColor Gray
        }
        Write-Host ""
    }
}
catch {
    Write-Error $_.Exception.Message
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Done!" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
