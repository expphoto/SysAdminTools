<#
.SYNOPSIS
    Comprehensive audit - ALL sharing operations
.DESCRIPTION
    Searches for all possible sharing-related operations
#>

param(
    [Parameter(Mandatory = $false)]
    [DateTime]$StartDate = (Get-Date).AddYears(-2),

    [Parameter(Mandatory = $false)]
    [DateTime]$EndDate = (Get-Date),

    [Parameter(Mandatory = $false)]
    [int]$MaxResults = 5000
)

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "COMPREHENSIVE SHARING AUDIT" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Date Range: $($StartDate.ToString('yyyy-MM-dd')) to $($EndDate.ToString('yyyy-MM-dd'))" -ForegroundColor Yellow
Write-Host ""

Connect-ExchangeOnline -UserPrincipalName Joseph@channelislandslg.com -ShowBanner:$false

# ALL sharing operations
$sharingOps = @(
    "AddedToGroup",
    "AnonymousLinkCreated",
    "AnonymousLinkUsed",
    "SharingInheritanceBroken",
    "SharingLinkCreated",
    "SharingLinkUsed",
    "SharingRevoked",
    "SharingSet",
    "SharingInvitationCreated",
    "SecureLinkCreated",
    "FileShared",
    "FolderShared"
)

$allEvents = @()
$allExternal = @()
$allAnonymous = @()
$allSharedFiles = @()

Write-Host "Searching for sharing operations..." -ForegroundColor Yellow
Write-Host ""

foreach ($op in $sharingOps) {
    Write-Host "  $op..." -ForegroundColor Gray

    try {
        $events = Search-UnifiedAuditLog `
            -StartDate $StartDate `
            -EndDate $EndDate `
            -ResultSize $MaxResults `
            -Operations $op `
            -ErrorAction SilentlyContinue

        if ($events) {
            Write-Host "    Found $($events.Count) events" -ForegroundColor Green

            foreach ($event in $events) {
                $auditData = $event.AuditData | ConvertFrom-Json

                $isExternal = $false
                $isAnonymous = $false
                $shareType = ""
                $itemType = ""
                $itemUrl = ""

                if ($op -eq "AnonymousLinkCreated") {
                    $isAnonymous = $true
                    $isExternal = $true
                    $shareType = "Anonymous Link"
                } elseif ($op -eq "AnonymousLinkUsed") {
                    $isAnonymous = $true
                    $isExternal = $true
                    $shareType = "Anonymous Link Used"
                } elseif ($op -eq "SharingSet") {
                    if ($auditData.TargetUserOrGroupName -like "*Anonymous*") {
                        $isAnonymous = $true
                        $isExternal = $true
                        $shareType = "Anonymous Share"
                    } elseif ($auditData.TargetUserOrGroupName -like "*Guest*") {
                        $isExternal = $true
                        $shareType = "Guest Share"
                    } else {
                        $shareType = "Direct Share"
                    }
                } elseif ($op -eq "SharingLinkCreated") {
                    $isExternal = $true
                    $shareType = "Sharing Link Created"
                } elseif ($op -eq "SharingLinkUsed") {
                    $isExternal = $true
                    $shareType = "Sharing Link Used"
                }

                if ($auditData.ItemType) {
                    $itemType = $auditData.ItemType
                }
                if ($auditData.SourceRelativeUrl) {
                    $itemUrl = $auditData.SourceRelativeUrl
                } elseif ($auditData.ObjectId) {
                    $itemUrl = $auditData.ObjectId
                }

                $permissions = ""
                if ($auditData.EventData -match "<PermissionsGranted>([^<]+)") {
                    $permissions = $matches[1]
                }

                $evt = [PSCustomObject]@{
                    DateTime = $event.CreationDate
                    User = $event.UserIds
                    Operation = $op
                    Workload = if ($auditData.Workload) { $auditData.Workload } else { "" }
                    ItemType = $itemType
                    ItemUrl = $itemUrl
                    ShareType = $shareType
                    IsExternal = $isExternal
                    IsAnonymous = $isAnonymous
                    Permissions = $permissions
                    TargetUser = if ($auditData.TargetUserOrGroupName) { $auditData.TargetUserOrGroupName } else { "" }
                    ClientIP = if ($auditData.ClientIP) { $auditData.ClientIP } else { "" }
                    Application = if ($auditData.ApplicationDisplayName) { $auditData.ApplicationDisplayName } else { "" }
                }

                $allEvents += $evt

                if ($isExternal) {
                    $allExternal += $evt
                    if ($isAnonymous) {
                        $allAnonymous += $evt
                    }
                }

                if ($op -eq "SharingLinkCreated" -or $op -eq "AnonymousLinkCreated") {
                    $allSharedFiles += $evt
                }
            }
        }
    }
    catch {
        # Skip errors
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "RESULTS" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "Total events: $($allEvents.Count)" -ForegroundColor Green
Write-Host "External shares: $($allExternal.Count)" -ForegroundColor Yellow
Write-Host "Anonymous links: $($allAnonymous.Count)" -ForegroundColor Red
Write-Host "Links created: $($allSharedFiles.Count)" -ForegroundColor Cyan
Write-Host ""

Write-Host "External sharing by user:" -ForegroundColor Cyan
$allExternal | Group-Object User | Sort-Object Count -Descending | Select-Object -First 10 | ForEach-Object {
    $anon = ($_.Group | Where-Object { $_.IsAnonymous }).Count
    Write-Host "  $($_.Name): $($_.Count) external ($anon anonymous)" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Operation breakdown:" -ForegroundColor Cyan
$allEvents | Group-Object Operation | Sort-Object Count -Descending | ForEach-Object {
    Write-Host "  $($_.Name): $($_.Count)" -ForegroundColor Gray
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$allEvents | Export-Csv -Path "./purview-comprehensive-all-$timestamp.csv" -NoTypeInformation
$allExternal | Export-Csv -Path "./purview-comprehensive-external-$timestamp.csv" -NoTypeInformation
$allAnonymous | Export-Csv -Path "./purview-comprehensive-anonymous-$timestamp.csv" -NoTypeInformation
$allSharedFiles | Export-Csv -Path "./purview-comprehensive-links-created-$timestamp.csv" -NoTypeInformation

Write-Host ""
Write-Host "Exported:" -ForegroundColor Green
Write-Host "  ./purview-comprehensive-all-$timestamp.csv" -ForegroundColor Green
Write-Host "  ./purview-comprehensive-external-$timestamp.csv" -ForegroundColor Green
Write-Host "  ./purview-comprehensive-anonymous-$timestamp.csv" -ForegroundColor Green
Write-Host "  ./purview-comprehensive-links-created-$timestamp.csv" -ForegroundColor Green

Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "Complete!" -ForegroundColor Cyan
