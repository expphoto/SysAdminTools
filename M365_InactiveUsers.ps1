param(
    [int]$InactiveDays = 90,
    [string]$OutputCSV = "./M365_InactiveDesktopUsers_$(Get-Date -Format 'yyyyMMdd').csv"
)

# ---- AUTH ----
Connect-MgGraph -Scopes "Reports.Read.All", "User.Read.All", "Directory.Read.All" -NoWelcome

# ---- FIND BUSINESS STANDARD SKU ID ----
$BizStandardSku = "O365_BUSINESS_PREMIUM"
$Skus = Get-MgSubscribedSku -All
$BizStandardSkuId = ($Skus | Where-Object { $_.SkuPartNumber -eq $BizStandardSku }).SkuId

if (-not $BizStandardSkuId) {
    Write-Warning "Could not find SKU '$BizStandardSku'. Available SKUs:"
    $Skus | Select-Object SkuPartNumber, SkuId | Format-Table
    Write-Host "Update `$BizStandardSku with the correct SkuPartNumber above and re-run." -ForegroundColor Yellow
    Disconnect-MgGraph | Out-Null
    exit
}

Write-Host "Found SKU: $BizStandardSku ($BizStandardSkuId)" -ForegroundColor Green

# ---- GET ALL USERS WITH THAT LICENSE ----
Write-Host "Fetching licensed users..." -ForegroundColor Cyan
$AllUsers = Get-MgUser -All -Property "id,displayName,userPrincipalName,assignedLicenses"
$LicensedUsers = $AllUsers | Where-Object {
    $_.AssignedLicenses.SkuId -contains $BizStandardSkuId
}
Write-Host "Business Standard users found: $($LicensedUsers.Count)" -ForegroundColor Green

# ---- PULL APP USAGE REPORT (last 180 days) ----
Write-Host "Pulling M365 App User Detail report (D180)..." -ForegroundColor Cyan
$TempFile = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "m365appusage_$(Get-Random).csv")

# Graph SDK report download
Get-MgReportM365AppUserDetail -Period "D180" -OutFile $TempFile

if (-not (Test-Path $TempFile)) {
    Write-Error "Report file not created. Check Reports.Read.All permission is consented."
    exit
}

$AppUsageData = Import-Csv -Path $TempFile
Write-Host "Usage records pulled: $($AppUsageData.Count)" -ForegroundColor Green

# ---- CROSS-REFERENCE ----
$CutoffDate = (Get-Date).AddDays(-$InactiveDays)
$Results = @()

foreach ($User in $LicensedUsers) {
    $UPN      = $User.UserPrincipalName
    $UsageRow = $AppUsageData | Where-Object { $_.'User Principal Name' -eq $UPN }

    if (-not $UsageRow) {
        $Results += [PSCustomObject]@{
            DisplayName        = $User.DisplayName
            UserPrincipalName  = $UPN
            LastActivityDate   = "No Data"
            LastActivationDate = "No Data"
            Windows            = "No Data"
            Mac                = "No Data"
            Mobile             = "No Data"
            Web                = "No Data"
            InactiveDays       = "180+"
            Recommendation     = "REVIEW - No activity in 180-day window"
        }
        continue
    }

    $LastActivity  = $null
    $InactiveCount = $null

    if ($UsageRow.'Last Activity Date' -and $UsageRow.'Last Activity Date' -ne '') {
        $LastActivity  = [datetime]$UsageRow.'Last Activity Date'
        $InactiveCount = [math]::Round(((Get-Date) - $LastActivity).TotalDays)
    }

    $DesktopUsed = ($UsageRow.Windows -eq 'True') -or ($UsageRow.Mac -eq 'True')

    if ((-not $LastActivity) -or ($LastActivity -lt $CutoffDate) -or (-not $DesktopUsed)) {
        $Results += [PSCustomObject]@{
            DisplayName        = $User.DisplayName
            UserPrincipalName  = $UPN
            LastActivityDate   = if ($LastActivity) { $LastActivity.ToString("yyyy-MM-dd") } else { "Never" }
            LastActivationDate = $UsageRow.'Last Activation Date'
            Windows            = $UsageRow.Windows
            Mac                = $UsageRow.Mac
            Mobile             = $UsageRow.Mobile
            Web                = $UsageRow.Web
            InactiveDays       = if ($InactiveCount) { $InactiveCount } else { "Unknown" }
            Recommendation     = if (-not $DesktopUsed) { "Desktop never used — downgrade candidate" } else { "Inactive $InactiveDays+ days — review" }
        }
    }
}

# ---- OUTPUT ----
Write-Host "`n===== RESULTS: $($Results.Count) users flagged =====" -ForegroundColor Yellow
$Results | Sort-Object InactiveDays -Descending | Format-Table DisplayName, UserPrincipalName, LastActivityDate, Windows, Mac, InactiveDays, Recommendation -AutoSize

$Results | Export-Csv -Path $OutputCSV -NoTypeInformation
Write-Host "Exported to: $OutputCSV" -ForegroundColor Green

# Cleanup
Remove-Item $TempFile -Force -ErrorAction SilentlyContinue
Disconnect-MgGraph | Out-Null
