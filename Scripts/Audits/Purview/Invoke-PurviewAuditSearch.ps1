<#
.SYNOPSIS
    Comprehensive audit of OneDrive sharing via Purview Audit Logs
.DESCRIPTION
    Searches Microsoft Purview Audit Logs for all SharePoint/OneDrive sharing activities
#>

param(
    [Parameter(Mandatory = $false)]
    [DateTime]$StartDate = (Get-Date).AddDays(-90),

    [Parameter(Mandatory = $false)]
    [DateTime]$EndDate = (Get-Date),

    [Parameter(Mandatory = $false)]
    [int]$MaxResults = 5000
)

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "PURVIEW AUDIT LOG - SHARING AUDIT" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Date Range: $($StartDate.ToString('yyyy-MM-dd')) to $($EndDate.ToString('yyyy-MM-dd'))" -ForegroundColor Yellow
Write-Host "Max Results: $MaxResults" -ForegroundColor Yellow
Write-Host ""

# Connect to Exchange Online
Write-Host "Connecting to Exchange Online..." -ForegroundColor Cyan
Connect-ExchangeOnline -UserPrincipalName Joseph@channelislandslg.com -ShowBanner:$false

# Search for sharing operations
$sharingOps = @(
    "SharingSet",
    "SharingInvitationCreated",
    "AnonymousLinkCreated",
    "SecureLinkCreated",
    "FileShared",
    "FolderShared"
)

Write-Host "Searching audit logs for sharing activities..." -ForegroundColor Yellow
Write-Host ""

$allEvents = @()

foreach ($op in $sharingOps) {
    Write-Host "  Searching: $op..." -ForegroundColor Gray

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
                # Parse AuditData (JSON)
                $auditData = $event.AuditData | ConvertFrom-Json

                $isExternal = $false
                $isAnonymous = $false
                $externalUser = ""
                $shareType = ""
                $itemType = ""
                $itemUrl = ""

                # Determine if external/anonymous
                if ($auditData.Operation -eq "AnonymousLinkCreated") {
                    $isAnonymous = $true
                    $isExternal = $true
                    $shareType = "Anonymous Link"
                } elseif ($auditData.Operation -eq "SharingSet") {
                    $shareType = "Direct Share"
                    if ($auditData.TargetUserOrGroupName -like "*Anonymous*") {
                        $isAnonymous = $true
                        $isExternal = $true
                        $shareType = "Anonymous Share"
                    } elseif ($auditData.TargetUserOrGroupName -like "*Guest*") {
                        $isExternal = $true
                        $externalUser = $auditData.TargetUserOrGroupName
                    }
                }

                # Get item details
                if ($auditData.ItemType) {
                    $itemType = $auditData.ItemType
                }
                if ($auditData.SourceRelativeUrl) {
                    $itemUrl = $auditData.SourceRelativeUrl
                } elseif ($auditData.ObjectId) {
                    $itemUrl = $auditData.ObjectId
                }

                # Get permissions
                $permissions = ""
                if ($auditData.EventData) {
                    if ($auditData.EventData -match "<PermissionsGranted>([^<]+)") {
                        $permissions = $matches[1]
                    }
                }

                $allEvents += [PSCustomObject]@{
                    DateTime = $event.CreationDate
                    User = $event.UserIds
                    Operation = $event.Operations
                    Workload = $auditData.Workload
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
            }
        }
        else {
            Write-Host "    No events found" -ForegroundColor Gray
        }
    }
    catch {
        Write-Host "    Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "RESULTS" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

if ($allEvents.Count -gt 0) {
    Write-Host "Total events found: $($allEvents.Count)" -ForegroundColor Green
    Write-Host ""

    # Summary by user
    Write-Host "Events by user:" -ForegroundColor Cyan
    $allEvents | Group-Object User | Sort-Object Count -Descending | ForEach-Object {
        $externalCount = ($_.Group | Where-Object { $_.IsExternal }).Count
        $anonCount = ($_.Group | Where-Object { $_.IsAnonymous }).Count
        Write-Host "  $($_.Name): $($_.Count) total | $externalCount external | $anonCount anonymous" -ForegroundColor Yellow
    }

    Write-Host ""

    # External shares summary
    $externalEvents = $allEvents | Where-Object { $_.IsExternal }
    if ($externalEvents.Count -gt 0) {
        Write-Host "External sharing summary:" -ForegroundColor Cyan
        Write-Host "  Total external shares: $($externalEvents.Count)" -ForegroundColor Yellow
        Write-Host ""

        Write-Host "Anonymous links by user:" -ForegroundColor Cyan
        $externalEvents | Where-Object { $_.IsAnonymous } | Group-Object User | Sort-Object Count -Descending | ForEach-Object {
            Write-Host "  $($_.Name): $($_.Count) anonymous links" -ForegroundColor Red
        }

        Write-Host ""
        Write-Host "Recent external shares:" -ForegroundColor Cyan
        $externalEvents | Sort-Object DateTime -Descending | Select-Object -First 20 | Format-Table DateTime, User, Operation, ShareType, ItemType, ItemUrl -AutoSize

        # Export to CSV
        $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $outputFile = "./purview-sharing-audit-$timestamp.csv"
        $allEvents | Export-Csv -Path $outputFile -NoTypeInformation
        Write-Host ""
        Write-Host "All events exported: $outputFile" -ForegroundColor Green

        # Export just external
        $externalFile = "./purview-external-shares-only-$timestamp.csv"
        $externalEvents | Export-Csv -Path $externalFile -NoTypeInformation
        Write-Host "External shares exported: $externalFile" -ForegroundColor Green

        # Export just anonymous
        $anonEvents = $allEvents | Where-Object { $_.IsAnonymous }
        if ($anonEvents.Count -gt 0) {
            $anonFile = "./purview-anonymous-links-$timestamp.csv"
            $anonEvents | Export-Csv -Path $anonFile -NoTypeInformation
            Write-Host "Anonymous links exported: $anonFile" -ForegroundColor Green
        }
    }
    else {
        Write-Host "No external shares found in audit logs" -ForegroundColor Green
    }
}
else {
    Write-Host "No sharing events found in audit logs" -ForegroundColor Yellow
}

Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "Audit Complete!" -ForegroundColor Cyan
