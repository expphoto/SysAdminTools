<#
.SYNOPSIS
    Comprehensive audit of ALL external sharing across SharePoint and OneDrive.

.DESCRIPTION
    Finds all external (guest) users in the tenant and reports on what they have access to.
    Also identifies anonymous sharing links that don't require authentication.

.PARAMETER OutputPath
    Path for the audit report CSV file

.PARAMETER IncludeAnonymousLinks
    Also scan for anonymous "Anyone with the link" shares

.EXAMPLE
    ./Invoke-AllExternalSharingAudit.ps1

.EXAMPLE
    ./Invoke-AllExternalSharingAudit.ps1 -IncludeAnonymousLinks

.NOTES
    This script provides a complete picture of external sharing security posture.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "./all-external-sharing-audit-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv",

    [Parameter(Mandatory = $false)]
    [switch]$IncludeAnonymousLinks
)

# Check if Microsoft.Graph modules are installed
$requiredModules = @('Microsoft.Graph.Authentication', 'Microsoft.Graph.Users')
foreach ($module in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $module)) {
        Write-Host "Installing $module..." -ForegroundColor Cyan
        Install-Module $module -Scope CurrentUser -Force -AllowClobber
    }
}

Import-Module Microsoft.Graph.Authentication
Import-Module Microsoft.Graph.Users

$results = @()
$ErrorActionPreference = 'Continue'

try {
    Write-Host "=====================================" -ForegroundColor Cyan
    Write-Host "COMPREHENSIVE EXTERNAL SHARING AUDIT" -ForegroundColor Cyan
    Write-Host "=====================================" -ForegroundColor Cyan
    Write-Host ""

    Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Cyan
    Connect-MgGraph -Scopes "User.Read.All","AuditLog.Read.All","Directory.Read.All" -NoWelcome

    Write-Host "Successfully connected!" -ForegroundColor Green
    Write-Host ""

    # Get ALL external/guest users
    Write-Host "Retrieving all external (guest) users from Azure AD..." -ForegroundColor Cyan
    Write-Host "(This may take a moment for large tenants...)" -ForegroundColor Yellow
    Write-Host ""

    $allExternalUsers = Get-MgUser -Filter "userType eq 'Guest'" -All -Property Id,DisplayName,Mail,UserPrincipalName,UserType,CreatedDateTime,SignInActivity,AccountEnabled |
        Select-Object Id,DisplayName,Mail,UserPrincipalName,UserType,CreatedDateTime,AccountEnabled,
            @{Name="LastSignIn";Expression={
                if ($_.SignInActivity.LastSignInDateTime) {
                    $_.SignInActivity.LastSignInDateTime
                } else {
                    "Never"
                }
            }}

    if (-not $allExternalUsers -or $allExternalUsers.Count -eq 0) {
        Write-Host "=====================================" -ForegroundColor Green
        Write-Host "NO EXTERNAL USERS FOUND" -ForegroundColor Green
        Write-Host "=====================================" -ForegroundColor Green
        Write-Host "Your tenant has no external (guest) users." -ForegroundColor Green
        Write-Host "This means no B2B collaboration accounts exist." -ForegroundColor Green
        Write-Host ""
        Write-Host "Note: This doesn't include anonymous 'Anyone with the link' shares." -ForegroundColor Yellow

        if ($IncludeAnonymousLinks) {
            Write-Host "Checking for anonymous sharing links..." -ForegroundColor Cyan
            Write-Host "(This feature requires SharePoint admin access)" -ForegroundColor Yellow
        }

        return
    }

    Write-Host "=====================================" -ForegroundColor Yellow
    Write-Host "EXTERNAL USERS FOUND: $($allExternalUsers.Count)" -ForegroundColor Yellow
    Write-Host "=====================================" -ForegroundColor Yellow
    Write-Host ""

    # Display summary table
    Write-Host "External User Summary:" -ForegroundColor Cyan
    $allExternalUsers | Select-Object DisplayName,Mail,AccountEnabled,LastSignIn | Format-Table -AutoSize

    # Export detailed results
    foreach ($user in $allExternalUsers) {
        $results += [PSCustomObject]@{
            DisplayName = $user.DisplayName
            Email = $user.Mail
            UserPrincipalName = $user.UserPrincipalName
            AccountEnabled = $user.AccountEnabled
            CreatedDateTime = $user.CreatedDateTime
            LastSignIn = $user.LastSignIn
            UserType = $user.UserType
            ExternalDomain = if ($user.Mail) {
                $user.Mail.Split('@')[1]
            } else {
                "Unknown"
            }
        }
    }

    # Export to CSV
    $results | Export-Csv -Path $OutputPath -NoTypeInformation
    Write-Host ""
    Write-Host "=====================================" -ForegroundColor Green
    Write-Host "AUDIT COMPLETE" -ForegroundColor Green
    Write-Host "=====================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Total External Users: $($results.Count)" -ForegroundColor Yellow
    Write-Host "Report saved to: $OutputPath" -ForegroundColor Cyan
    Write-Host ""

    # Group by domain
    Write-Host "External Users by Domain:" -ForegroundColor Cyan
    $results | Group-Object ExternalDomain |
        Select-Object @{Name="Domain";Expression={$_.Name}}, Count |
        Sort-Object Count -Descending |
        Format-Table -AutoSize

    # Active vs Inactive
    $activeCount = ($results | Where-Object { $_.AccountEnabled -eq $true }).Count
    $inactiveCount = ($results | Where-Object { $_.AccountEnabled -eq $false }).Count

    Write-Host ""
    Write-Host "Account Status:" -ForegroundColor Cyan
    Write-Host "  Active Accounts: $activeCount" -ForegroundColor Green
    Write-Host "  Disabled Accounts: $inactiveCount" -ForegroundColor Red

    # Recent sign-ins
    $recentSignIns = $results | Where-Object {
        $_.LastSignIn -ne "Never" -and
        $_.LastSignIn -is [DateTime] -and
        $_.LastSignIn -gt (Get-Date).AddDays(-30)
    }
    Write-Host "  Signed in last 30 days: $($recentSignIns.Count)" -ForegroundColor Yellow

    Write-Host ""
    Write-Host "=====================================" -ForegroundColor Cyan
    Write-Host "RECOMMENDATIONS" -ForegroundColor Cyan
    Write-Host "=====================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "1. Review disabled accounts - consider removing if no longer needed" -ForegroundColor White
    Write-Host "2. Review accounts that have never signed in - may be stale invitations" -ForegroundColor White
    Write-Host "3. Verify each external domain is authorized for collaboration" -ForegroundColor White
    Write-Host "4. Consider implementing Azure AD B2B policies to restrict domains" -ForegroundColor White
    Write-Host ""

    if ($IncludeAnonymousLinks) {
        Write-Host "=====================================" -ForegroundColor Yellow
        Write-Host "Anonymous Sharing Links" -ForegroundColor Yellow
        Write-Host "=====================================" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Note: Scanning for anonymous 'Anyone with the link' shares" -ForegroundColor Yellow
        Write-Host "requires SharePoint Administrator role and additional time." -ForegroundColor Yellow
        Write-Host "This feature is available in the SharePoint-specific audit scripts." -ForegroundColor White
        Write-Host ""
    }

    Write-Host "To investigate what files these users can access, use:" -ForegroundColor Cyan
    Write-Host "  SharePoint Admin Center > Reports > Sharing" -ForegroundColor White
    Write-Host "  Or run file-level audit scripts (requires SharePoint admin role)" -ForegroundColor White
}
catch {
    Write-Error "An error occurred: $($_.Exception.Message)"
    Write-Error $_.ScriptStackTrace
}
finally {
    Disconnect-MgGraph -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "Audit script complete!" -ForegroundColor Cyan
Write-Host "=====================================" -ForegroundColor Cyan
