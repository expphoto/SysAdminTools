<#
.SYNOPSIS
    Search Purview Audit Logs for historical sharing (multiple date ranges)
.DESCRIPTION
    Searches audit logs in chunks to get more than 5000 results
#>

$startDate = (Get-Date).AddYears(-2)
$chunkSize = 90 # days
$maxResults = 5000

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "HISTORICAL AUDIT LOG SEARCH (2 YEARS)" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Connect
Connect-ExchangeOnline -UserPrincipalName Joseph@channelislandslg.com -ShowBanner:$false

$allEvents = @()
$allExternal = @()
$allAnonymous = @()

$currentDate = Get-Date
endDate = $currentDate

while ($currentDate -gt $startDate) {
    $periodStart = $currentDate.AddDays(-$chunkSize)
    if ($periodStart -lt $startDate) {
        $periodStart = $startDate
    }

    $dateRange = "$($periodStart.ToString('yyyy-MM-dd')) to $($currentDate.ToString('yyyy-MM-dd'))"

    Write-Host "Searching: $dateRange..." -ForegroundColor Yellow

    try {
        $sharingOps = @("SharingSet","AnonymousLinkCreated","SecureLinkCreated")

        foreach ($op in $sharingOps) {
            $events = Search-UnifiedAuditLog `
                -StartDate $periodStart `
                -EndDate $currentDate `
                -ResultSize $maxResults `
                -Operations $op `
                -ErrorAction SilentlyContinue

            if ($events) {
                Write-Host "  Found $($events.Count) $op events" -ForegroundColor Green

                foreach ($event in $events) {
                    $auditData = $event.AuditData | ConvertFrom-Json

                    $isExternal = $false
                    $isAnonymous = $false
                    $shareType = ""

                    if ($auditData.Operation -eq "AnonymousLinkCreated") {
                        $isAnonymous = $true
                        $isExternal = $true
                        $shareType = "Anonymous Link"
                    } elseif ($auditData.Operation -eq "SharingSet") {
                        if ($auditData.TargetUserOrGroupName -like "*Anonymous*") {
                            $isAnonymous = $true
                            $isExternal = $true
                            $shareType = "Anonymous Share"
                        }
                    }

                    $itemType = if ($auditData.ItemType) { $auditData.ItemType } else { "" }
                    $itemUrl = if ($auditData.SourceRelativeUrl) { $auditData.SourceRelativeUrl } elseif ($auditData.ObjectId) { $auditData.ObjectId } else { "" }
                    $permissions = ""
                    if ($auditData.EventData -match "<PermissionsGranted>([^<]+)") {
                        $permissions = $matches[1]
                    }

                    $evt = [PSCustomObject]@{
                        DateTime = $event.CreationDate
                        User = $event.UserIds
                        Operation = $event.Operations
                        Workload = if ($auditData.Workload) { $auditData.Workload } else { "" }
                        ItemType = $itemType
                        ItemUrl = $itemUrl
                        ShareType = $shareType
                        IsExternal = $isExternal
                        IsAnonymous = $isAnonymous
                        Permissions = $permissions
                        TargetUser = if ($auditData.TargetUserOrGroupName) { $auditData.TargetUserOrGroupName } else { "" }
                        Application = if ($auditData.ApplicationDisplayName) { $auditData.ApplicationDisplayName } else { "" }
                    }

                    $allEvents += $evt

                    if ($isExternal) {
                        $allExternal += $evt
                        if ($isAnonymous) {
                            $allAnonymous += $evt
                        }
                    }
                }
            }
        }
    }
    catch {
        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
    }

    $currentDate = $periodStart.AddDays(-1)

    if ($currentDate -le $startDate) {
        break
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "RESULTS (2 YEARS)" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "Total events: $($allEvents.Count)" -ForegroundColor Green
Write-Host "External shares: $($allExternal.Count)" -ForegroundColor Yellow
Write-Host "Anonymous links: $($allAnonymous.Count)" -ForegroundColor Red
Write-Host ""

Write-Host "External sharing by user:" -ForegroundColor Cyan
$allExternal | Group-Object User | Sort-Object Count -Descending | ForEach-Object {
    $anon = ($_.Group | Where-Object { $_.IsAnonymous }).Count
    Write-Host "  $($_.Name): $($_.Count) external ($anon anonymous)" -ForegroundColor Yellow
}

# Export
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$allExternal | Export-Csv -Path "./purview-2year-external-shares-$timestamp.csv" -NoTypeInformation
$allAnonymous | Export-Csv -Path "./purview-2year-anonymous-links-$timestamp.csv" -NoTypeInformation

Write-Host ""
Write-Host "Exported:" -ForegroundColor Green
Write-Host "  ./purview-2year-external-shares-$timestamp.csv" -ForegroundColor Green
Write-Host "  ./purview-2year-anonymous-links-$timestamp.csv" -ForegroundColor Green

Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "Complete!" -ForegroundColor Cyan
