<#
.SYNOPSIS
    Quick test to see total items in OneDrive
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$TargetUser
)

Import-Module PnP.PowerShell

$safeUser = $TargetUser.Replace("@", "_").Replace(".", "_")
$oneDriveUrl = "https://netorg368294-my.sharepoint.com/personal/$safeUser"

Write-Host "Testing: $TargetUser" -ForegroundColor Cyan
Write-Host "OneDrive URL: $oneDriveUrl" -ForegroundColor Cyan
Write-Host ""

try {
    Write-Host "Connecting..." -ForegroundColor Yellow
    Connect-PnPOnline -Url $oneDriveUrl -ClientId "87f1f77d-4fbb-4375-ae34-a702b2ab8521" -Tenant "8fbe6cee-1229-4e2d-921a-46b1f93d7242" -Interactive

    Write-Host "Getting Documents library..." -ForegroundColor Yellow
    $docLib = Get-PnPList -Identity "Documents"

    Write-Host ""
    Write-Host "Documents Library Info:" -ForegroundColor Green
    Write-Host "  Title: $($docLib.Title)" -ForegroundColor Gray
    Write-Host "  Item Count: $($docLib.ItemCount)" -ForegroundColor Gray
    Write-Host "  Last Modified: $($docLib.LastItemModifiedDate)" -ForegroundColor Gray

    Write-Host ""
    Write-Host "Checking sharing info (quick scan of first 50 items)..." -ForegroundColor Yellow

    # Use CAML query to get just the first 50 items
    $query = "<View><RowLimit>50</RowLimit></View>"
    $items = Get-PnPListItem -List "Documents" -Query $query -Fields "ID","FileRef","FileLeafRef","FileSystemObjectType"

    $totalExternal = 0

    foreach ($item in $items) {
        try {
            $sharingLinks = Get-PnPFileSharingLink -Identity $item.Id -List "Documents" -ErrorAction SilentlyContinue

            if ($sharingLinks -and $sharingLinks.Count -gt 0) {
                $type = if ($item.FileSystemObjectType -eq "File") { "FILE" } else { "FOLDER" }

                foreach ($link in $sharingLinks) {
                    if ($link.ShareLink) {
                        $isExternal = $link.ShareLink.IsAnonymous -or $link.ShareLink.AllowsAnonymousAccess -or $link.ShareLink.Scope -ne "Organization"
                        if ($isExternal) {
                            $totalExternal++
                            Write-Host "  🌐 [$type] $($item['FileLeafRef'])" -ForegroundColor Yellow
                            Write-Host "     Scope: $($link.ShareLink.Scope)" -ForegroundColor Cyan
                        }
                    }
                }
            }
        } catch {
            # Skip errors
        }
    }

    Write-Host ""
    Write-Host "External shares found in first 50 items: $totalExternal" -ForegroundColor $(if ($totalExternal -gt 0) { "Yellow" } else { "Green" })

}
catch {
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $($_.ScriptStackTrace) -ForegroundColor Gray
}
