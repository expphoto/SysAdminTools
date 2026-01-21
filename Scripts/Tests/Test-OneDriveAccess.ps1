<#
.SYNOPSIS
    Test scan on single OneDrive for troubleshooting
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

    Write-Host "Getting lists..." -ForegroundColor Yellow
    $lists = Get-PnPList

    Write-Host "Found $($lists.Count) lists:" -ForegroundColor Green
    foreach ($list in $lists) {
        Write-Host "  - $($list.Title) ($($list.BaseTemplate))" -ForegroundColor Gray
    }

    $docLib = $lists | Where-Object { $_.Title -eq "Documents" }

    if ($docLib) {
        Write-Host ""
        Write-Host "Documents library found: $($docLib.Title)" -ForegroundColor Green

        Write-Host "Counting files (first 100)..." -ForegroundColor Yellow
        $items = Get-PnPListItem -List $docLib -PageSize 100 -Fields "ID","FileRef","FileLeafRef"
        $files = $items | Where-Object { $_.FileSystemObjectType -eq "File" }

        Write-Host "Found $($files.Count) files in first batch" -ForegroundColor Green

        Write-Host ""
        Write-Host "First 10 items:" -ForegroundColor Cyan
        $items | Select-Object -First 10 | ForEach-Object {
            $type = if ($_.FileSystemObjectType -eq "File") { "FILE" } else { "FOLDER" }
            Write-Host "  [$type] $($_['FileLeafRef'])" -ForegroundColor Gray
        }

        Write-Host ""
        Write-Host "Checking for sharing on first 10 items..." -ForegroundColor Yellow

        $items | Select-Object -First 10 | ForEach-Object {
            try {
                $sharingLinks = Get-PnPFileSharingLink -Identity $_.Id -List $docLib -ErrorAction SilentlyContinue
                if ($sharingLinks -and $sharingLinks.Count -gt 0) {
                    $type = if ($_.FileSystemObjectType -eq "File") { "FILE" } else { "FOLDER" }
                    Write-Host "  🌐 [$type] $($_['FileLeafRef']): $($sharingLinks.Count) sharing link(s)" -ForegroundColor Yellow

                    foreach ($link in $sharingLinks) {
                        if ($link.ShareLink) {
                            $isExternal = if ($link.ShareLink.IsAnonymous -or $link.ShareLink.AllowsAnonymousAccess -or $link.ShareLink.Scope -ne "Organization") { "EXTERNAL" } else { "INTERNAL" }
                            Write-Host "     - ${isExternal}: $($link.ShareLink.Scope)" -ForegroundColor Cyan
                        }
                    }
                } else {
                    $type = if ($_.FileSystemObjectType -eq "File") { "FILE" } else { "FOLDER" }
                    Write-Host "  ✓ [$type] $($_['FileLeafRef']): No sharing links" -ForegroundColor Green
                }
            } catch {
                Write-Host "  ❌ $($_['FileLeafRef']): Error checking sharing" -ForegroundColor Red
            }
        }
    }
    else {
        Write-Host "No documents library found" -ForegroundColor Red
    }
}
catch {
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $($_.ScriptStackTrace) -ForegroundColor Gray
}
