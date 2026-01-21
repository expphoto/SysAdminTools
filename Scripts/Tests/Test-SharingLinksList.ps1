<#
.SYNOPSIS
    Access the Sharing Links hidden list directly
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

    Write-Host "Accessing Sharing Links list..." -ForegroundColor Yellow

    try {
        $sharingList = Get-PnPList -Identity "Sharing Links"

        Write-Host ""
        Write-Host "Sharing Links List Info:" -ForegroundColor Green
        Write-Host "  Title: $($sharingList.Title)" -ForegroundColor Gray
        Write-Host "  Item Count: $($sharingList.ItemCount)" -ForegroundColor Gray
        Write-Host "  Is Hidden: $($sharingList.Hidden)" -ForegroundColor Gray

        Write-Host ""
        Write-Host "Getting all sharing links..." -ForegroundColor Yellow

        $sharingLinks = Get-PnPListItem -List "Sharing Links" -PageSize 100

        Write-Host "Found $($sharingLinks.Count) sharing links" -ForegroundColor Cyan

        $externalLinks = @()

        foreach ($item in $sharingLinks) {
            try {
                $linkType = if ($item['LinkType']) { $item['LinkType'] } else { "Unknown" }
                $scope = if ($item['Scope']) { $item['Scope'] } else { "Unknown" }

                Write-Host "  Item: $($item['FileRef'])" -ForegroundColor Gray
                Write-Host "    Type: $linkType, Scope: $scope" -ForegroundColor Gray

                # Check if external
                $isExternal = $scope -eq "Anonymous" -or $scope -eq "Guest" -or $linkType -like "*Anonymous*"

                if ($isExternal) {
                    $externalLinks += [PSCustomObject]@{
                        User = $TargetUser
                        File = if ($item['FileRef']) { $item['FileRef'] } else { "Unknown" }
                        LinkType = $linkType
                        Scope = $scope
                    }

                    Write-Host "  🌐 EXTERNAL: $($item['FileRef'])" -ForegroundColor Yellow
                }
            }
            catch {
                Write-Host "  ⚠️  Error reading item" -ForegroundColor Gray
            }
        }

        Write-Host ""
        Write-Host "External sharing links found: $($externalLinks.Count)" -ForegroundColor $(if ($externalLinks.Count -gt 0) { "Yellow" } else { "Green" })

        if ($externalLinks.Count -gt 0) {
            $outputFile = "./sharing-links-$($safeUser).csv"
            $externalLinks | Export-Csv -Path $outputFile -NoTypeInformation
            Write-Host "Exported to: $outputFile" -ForegroundColor Cyan
        }

    }
    catch {
        Write-Host "Error accessing Sharing Links list: $($_.Exception.Message)" -ForegroundColor Red
    }

}
catch {
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $($_.ScriptStackTrace) -ForegroundColor Gray
}
