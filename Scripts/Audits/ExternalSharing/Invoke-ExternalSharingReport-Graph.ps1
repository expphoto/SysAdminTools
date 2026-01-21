<#
.SYNOPSIS
    Complete external sharing report using only Microsoft Graph PowerShell.

.DESCRIPTION
    Uses Microsoft Graph to find all external users and report comprehensive details.
    Works without SharePoint Administrator role using Graph API only.

.PARAMETER OutputPath
    Base path for output files

.EXAMPLE
    ./Invoke-ExternalSharingReport-Graph.ps1

.NOTES
    This uses Microsoft Graph PowerShell which typically has better app consent in organizations.
    Reports on external users from Azure AD perspective.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "./external-sharing-report-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
)

# Check if Microsoft.Graph modules are installed
$requiredModules = @('Microsoft.Graph.Authentication', 'Microsoft.Graph.Users', 'Microsoft.Graph.Identity.SignIns')
foreach ($module in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $module)) {
        Write-Host "Installing $module..." -ForegroundColor Cyan
        Install-Module $module -Scope CurrentUser -Force -AllowClobber
    }
}

Import-Module Microsoft.Graph.Authentication
Import-Module Microsoft.Graph.Users
Import-Module Microsoft.Graph.Identity.SignIns

$ErrorActionPreference = 'Continue'

try {
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "EXTERNAL SHARING COMPREHENSIVE REPORT" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Using Microsoft Graph API" -ForegroundColor Gray
    Write-Host "Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Gray
    Write-Host ""

    Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Cyan
    Connect-MgGraph -Scopes "User.Read.All","AuditLog.Read.All","Directory.Read.All","UserAuthenticationMethod.Read.All" -NoWelcome

    Write-Host "Successfully connected!" -ForegroundColor Green
    $context = Get-MgContext
    Write-Host "Account: $($context.Account)" -ForegroundColor Gray
    Write-Host ""

    # Get ALL external/guest users with detailed information
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "RETRIEVING EXTERNAL USERS" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Querying Azure AD for all guest users..." -ForegroundColor Yellow
    Write-Host "(This includes all B2B collaboration accounts)" -ForegroundColor Gray
    Write-Host ""

    $allExternalUsers = Get-MgUser -Filter "userType eq 'Guest'" -All `
        -Property Id,DisplayName,Mail,UserPrincipalName,UserType,CreatedDateTime,AccountEnabled,SignInActivity,ExternalUserState,ExternalUserStateChangeDateTime,Identities `
        -ExpandProperty "signInActivity" -ErrorAction SilentlyContinue

    if (-not $allExternalUsers -or $allExternalUsers.Count -eq 0) {
        Write-Host "========================================" -ForegroundColor Green
        Write-Host "NO EXTERNAL USERS FOUND" -ForegroundColor Green
        Write-Host "========================================" -ForegroundColor Green
        Write-Host ""
        Write-Host "✅ Your tenant has ZERO external (guest) users" -ForegroundColor Green
        Write-Host ""
        Write-Host "This means:" -ForegroundColor White
        Write-Host "  • No B2B collaboration accounts exist" -ForegroundColor White
        Write-Host "  • No external users have been invited" -ForegroundColor White
        Write-Host "  • No files are shared with external email addresses (via authenticated access)" -ForegroundColor White
        Write-Host ""
        Write-Host "⚠️  Note: This doesn't include anonymous 'Anyone with the link' shares" -ForegroundColor Yellow
        Write-Host "   Those would require SharePoint-specific scanning" -ForegroundColor Gray
        Write-Host ""

        # Save empty report
        @() | Export-Csv -Path "$OutputPath-external-users.csv" -NoTypeInformation
        Write-Host "Empty report saved to: $OutputPath-external-users.csv" -ForegroundColor Cyan

        return
    }

    # External users found - generate detailed report
    Write-Host "========================================" -ForegroundColor Yellow
    Write-Host "EXTERNAL USERS FOUND: $($allExternalUsers.Count)" -ForegroundColor Yellow
    Write-Host "========================================" -ForegroundColor Yellow
    Write-Host ""

    $externalUserDetails = @()

    Write-Host "Analyzing external users..." -ForegroundColor Cyan
    $userCounter = 0

    foreach ($user in $allExternalUsers) {
        $userCounter++
        Write-Progress -Activity "Analyzing external users" -Status "Processing $($user.DisplayName)" -PercentComplete (($userCounter / $allExternalUsers.Count) * 100)

        # Get sign-in activity
        $lastSignIn = "Never"
        $lastSuccessfulSignIn = "Never"

        if ($user.SignInActivity) {
            if ($user.SignInActivity.LastSignInDateTime) {
                $lastSignIn = $user.SignInActivity.LastSignInDateTime
            }
            if ($user.SignInActivity.LastSuccessfulSignInDateTime) {
                $lastSuccessfulSignIn = $user.SignInActivity.LastSuccessfulSignInDateTime
            }
        }

        # Extract external domain
        $externalDomain = "Unknown"
        $externalEmail = $user.Mail

        if ($externalEmail) {
            if ($externalEmail -match '@(.+)$') {
                $externalDomain = $matches[1]
            }
        } elseif ($user.UserPrincipalName -match '#EXT#@(.+)') {
            # Parse from UPN
            if ($user.UserPrincipalName -match '(.+)#EXT#') {
                $cleanUPN = $matches[1]
                if ($cleanUPN -match '_(.+)#') {
                    $externalDomain = $matches[1]
                }
            }
        }

        # Invitation state
        $invitationState = $user.ExternalUserState
        if ([string]::IsNullOrEmpty($invitationState)) {
            $invitationState = "Accepted" # Default assumption
        }

        $invitationAcceptedDate = $user.ExternalUserStateChangeDateTime
        if ($invitationAcceptedDate) {
            $invitationAcceptedDate = $invitationAcceptedDate.ToString()
        } else {
            $invitationAcceptedDate = "Unknown"
        }

        # Calculate days since creation
        $daysSinceCreated = if ($user.CreatedDateTime) {
            [math]::Round(((Get-Date) - $user.CreatedDateTime).TotalDays, 0)
        } else {
            "Unknown"
        }

        # Calculate days since last sign-in
        $daysSinceLastSignIn = "Never"
        if ($lastSuccessfulSignIn -ne "Never") {
            $daysSinceLastSignIn = [math]::Round(((Get-Date) - $lastSuccessfulSignIn).TotalDays, 0)
        }

        $externalUserDetails += [PSCustomObject]@{
            DisplayName = $user.DisplayName
            Email = $externalEmail
            UserPrincipalName = $user.UserPrincipalName
            ExternalDomain = $externalDomain
            AccountEnabled = $user.AccountEnabled
            InvitationState = $invitationState
            CreatedDateTime = if ($user.CreatedDateTime) { $user.CreatedDateTime.ToString() } else { "Unknown" }
            DaysSinceCreated = $daysSinceCreated
            InvitationAcceptedDate = $invitationAcceptedDate
            LastSignIn = if ($lastSignIn -is [DateTime]) { $lastSignIn.ToString() } else { $lastSignIn }
            LastSuccessfulSignIn = if ($lastSuccessfulSignIn -is [DateTime]) { $lastSuccessfulSignIn.ToString() } else { $lastSuccessfulSignIn }
            DaysSinceLastSignIn = $daysSinceLastSignIn
            UserId = $user.Id
        }
    }

    Write-Progress -Activity "Analyzing external users" -Completed

    # Export detailed report
    $csvFile = "$OutputPath-external-users.csv"
    $externalUserDetails | Export-Csv -Path $csvFile -NoTypeInformation
    Write-Host "External users report saved to: $csvFile" -ForegroundColor Cyan
    Write-Host ""

    # Display summary
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "DETAILED ANALYSIS" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""

    # Group by domain
    Write-Host "📧 External Users by Domain:" -ForegroundColor Yellow
    $byDomain = $externalUserDetails | Group-Object ExternalDomain | Sort-Object Count -Descending
    foreach ($domain in $byDomain) {
        Write-Host "  $($domain.Name): $($domain.Count) user(s)" -ForegroundColor White
    }
    Write-Host ""

    # Account status
    $activeUsers = ($externalUserDetails | Where-Object { $_.AccountEnabled -eq $true }).Count
    $disabledUsers = ($externalUserDetails | Where-Object { $_.AccountEnabled -eq $false }).Count

    Write-Host "👤 Account Status:" -ForegroundColor Yellow
    Write-Host "  Active: $activeUsers" -ForegroundColor Green
    Write-Host "  Disabled: $disabledUsers" -ForegroundColor Red
    Write-Host ""

    # Sign-in activity
    $neverSignedIn = ($externalUserDetails | Where-Object { $_.LastSuccessfulSignIn -eq "Never" }).Count
    $signedInLast30Days = ($externalUserDetails | Where-Object {
        $_.DaysSinceLastSignIn -ne "Never" -and
        [int]$_.DaysSinceLastSignIn -le 30
    }).Count
    $signedIn30to90Days = ($externalUserDetails | Where-Object {
        $_.DaysSinceLastSignIn -ne "Never" -and
        [int]$_.DaysSinceLastSignIn -gt 30 -and
        [int]$_.DaysSinceLastSignIn -le 90
    }).Count
    $staleUsers = ($externalUserDetails | Where-Object {
        $_.DaysSinceLastSignIn -ne "Never" -and
        [int]$_.DaysSinceLastSignIn -gt 90
    }).Count

    Write-Host "📊 Sign-In Activity:" -ForegroundColor Yellow
    Write-Host "  Never signed in: $neverSignedIn" -ForegroundColor $(if ($neverSignedIn -gt 0) { "Yellow" } else { "White" })
    Write-Host "  Last 30 days: $signedInLast30Days" -ForegroundColor Green
    Write-Host "  31-90 days ago: $signedIn30to90Days" -ForegroundColor Yellow
    Write-Host "  90+ days ago (stale): $staleUsers" -ForegroundColor Red
    Write-Host ""

    # Invitation state
    Write-Host "📬 Invitation Status:" -ForegroundColor Yellow
    $byInvitationState = $externalUserDetails | Group-Object InvitationState
    foreach ($state in $byInvitationState) {
        Write-Host "  $($state.Name): $($state.Count)" -ForegroundColor White
    }
    Write-Host ""

    # Display user list
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "ALL EXTERNAL USERS" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""

    foreach ($user in $externalUserDetails | Sort-Object DisplayName) {
        $statusColor = if ($user.AccountEnabled -eq $true) { "Green" } else { "Red" }
        $status = if ($user.AccountEnabled -eq $true) { "✓" } else { "✗" }

        Write-Host "  $status $($user.DisplayName)" -ForegroundColor $statusColor
        Write-Host "    Email: $($user.Email)" -ForegroundColor Gray
        Write-Host "    Domain: $($user.ExternalDomain)" -ForegroundColor Gray
        Write-Host "    Last Sign-In: $($user.LastSuccessfulSignIn)" -ForegroundColor Gray

        if ($user.DaysSinceLastSignIn -eq "Never") {
            Write-Host "    ⚠️  Never signed in" -ForegroundColor Yellow
        } elseif ([int]$user.DaysSinceLastSignIn -gt 90) {
            Write-Host "    ⚠️  Inactive for $($user.DaysSinceLastSignIn) days" -ForegroundColor Red
        }
        Write-Host ""
    }

    # Recommendations
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "RECOMMENDATIONS" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""

    if ($neverSignedIn -gt 0) {
        Write-Host "⚠️  $neverSignedIn user(s) have never signed in" -ForegroundColor Yellow
        Write-Host "   • These may be pending invitations or stale accounts" -ForegroundColor White
        Write-Host "   • Consider removing if invitations are old" -ForegroundColor White
        Write-Host ""
    }

    if ($staleUsers -gt 0) {
        Write-Host "⚠️  $staleUsers user(s) haven't signed in for 90+ days" -ForegroundColor Yellow
        Write-Host "   • Review if these accounts are still needed" -ForegroundColor White
        Write-Host "   • Consider removing inactive external accounts" -ForegroundColor White
        Write-Host ""
    }

    if ($disabledUsers -gt 0) {
        Write-Host "ℹ️  $disabledUsers disabled account(s) found" -ForegroundColor Cyan
        Write-Host "   • These accounts cannot sign in" -ForegroundColor White
        Write-Host "   • Consider removing if no longer needed" -ForegroundColor White
        Write-Host ""
    }

    Write-Host "✓ For each external user, verify:" -ForegroundColor Green
    Write-Host "  • They have a legitimate business reason for access" -ForegroundColor White
    Write-Host "  • Their domain is authorized for collaboration" -ForegroundColor White
    Write-Host "  • They're still actively using their access" -ForegroundColor White
    Write-Host ""

    Write-Host "========================================" -ForegroundColor Green
    Write-Host "AUDIT COMPLETE" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Total External Users: $($externalUserDetails.Count)" -ForegroundColor Yellow
    Write-Host "Report saved to: $csvFile" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Completed: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Gray
}
catch {
    Write-Error "An error occurred: $($_.Exception.Message)"
    Write-Error $_.ScriptStackTrace
}
finally {
    Disconnect-MgGraph -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Script Complete!" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
