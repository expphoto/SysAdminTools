<#
.SYNOPSIS
    Search for ALL SharePoint/OneDrive operations
.DESCRIPTION
    Find all available operations to ensure we're not missing any
#>

Write-Host "Searching for all available SharePoint/OneDrive operations..." -ForegroundColor Cyan

# Get sample of operations from audit logs
Connect-ExchangeOnline -UserPrincipalName Joseph@channelislandslg.com -ShowBanner:$false

$sampleEvents = Search-UnifiedAuditLog `
    -StartDate (Get-Date).AddDays(-30) `
    -EndDate (Get-Date) `
    -ResultSize 1000 `
    -RecordType SharePointSharingOperation `
    -ErrorAction SilentlyContinue

if ($sampleEvents) {
    Write-Host "Found operations:" -ForegroundColor Green
    $sampleEvents | Select-Object -ExpandProperty Operations | Sort-Object -Unique | ForEach-Object {
        Write-Host "  - $_" -ForegroundColor Yellow
    }
} else {
    Write-Host "No events found" -ForegroundColor Yellow
}

Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
