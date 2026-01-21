<#
.SYNOPSIS
    Quick check for external users matching a name pattern using Microsoft Graph.

.DESCRIPTION
    Uses Microsoft Graph PowerShell to find external (guest) users in your tenant.
    This is a simpler alternative that often works without custom app registration.

.PARAMETER SearchName
    Name to search for (e.g., "Virginia")

.EXAMPLE
    ./Find-ExternalUsers-Simple.ps1 -SearchName "Virginia"

.NOTES
    Requirements:
    - Install-Module Microsoft.Graph -Scope CurrentUser
    - Global Reader, User Administrator, or Global Administrator role
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SearchName
)

# Check if Microsoft.Graph is installed
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Users)) {
    Write-Host "Microsoft Graph PowerShell is not installed." -ForegroundColor Yellow
    Write-Host "Installing now..." -ForegroundColor Cyan
    Install-Module Microsoft.Graph.Users -Scope CurrentUser -Force
}

try {
    Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Cyan
    Write-Host "(A browser window will open for authentication)" -ForegroundColor Yellow

    Connect-MgGraph -Scopes "User.Read.All" -NoWelcome

    Write-Host "`nSearching for external users matching '$SearchName'..." -ForegroundColor Cyan

    # Find all guest users matching the search name
    $externalUsers = Get-MgUser -Filter "userType eq 'Guest'" -All -Property DisplayName,Mail,UserPrincipalName,UserType,CreatedDateTime,AccountEnabled |
        Where-Object {
            $_.DisplayName -like "*$SearchName*" -or
            $_.Mail -like "*$SearchName*" -or
            $_.UserPrincipalName -like "*$SearchName*"
        }

    if ($externalUsers) {
        Write-Host "`n==================================" -ForegroundColor Red
        Write-Host "EXTERNAL USERS FOUND" -ForegroundColor Red
        Write-Host "==================================" -ForegroundColor Red
        Write-Host "Found $($externalUsers.Count) external user(s) matching '$SearchName'`n" -ForegroundColor Yellow

        $results = @()
        foreach ($user in $externalUsers) {
            Write-Host "Display Name: $($user.DisplayName)" -ForegroundColor White
            Write-Host "Email: $($user.Mail)" -ForegroundColor White
            Write-Host "User Principal Name: $($user.UserPrincipalName)" -ForegroundColor Gray
            Write-Host "Account Enabled: $($user.AccountEnabled)" -ForegroundColor $(if ($user.AccountEnabled) { "Green" } else { "Red" })
            Write-Host "Created: $($user.CreatedDateTime)" -ForegroundColor Gray
            Write-Host ""

            $results += [PSCustomObject]@{
                DisplayName = $user.DisplayName
                Email = $user.Mail
                UserPrincipalName = $user.UserPrincipalName
                AccountEnabled = $user.AccountEnabled
                CreatedDateTime = $user.CreatedDateTime
                UserType = $user.UserType
            }
        }

        # Export to CSV
        $outputFile = "./external-users-$SearchName-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
        $results | Export-Csv -Path $outputFile -NoTypeInformation
        Write-Host "Results exported to: $outputFile" -ForegroundColor Cyan

        Write-Host "`n==================================" -ForegroundColor Yellow
        Write-Host "NEXT STEPS" -ForegroundColor Yellow
        Write-Host "==================================" -ForegroundColor Yellow
        Write-Host "1. Review the external users listed above" -ForegroundColor White
        Write-Host "2. If these users shouldn't have access, you can:" -ForegroundColor White
        Write-Host "   - Remove them from Azure AD (they'll lose all access)" -ForegroundColor White
        Write-Host "   - Check SharePoint manually for files shared with them" -ForegroundColor White
        Write-Host "3. To scan ALL files for shares with these users," -ForegroundColor White
        Write-Host "   you'll need to set up the full audit (see SETUP-AZURE-APP.md)" -ForegroundColor White
    }
    else {
        Write-Host "`n==================================" -ForegroundColor Green
        Write-Host "NO EXTERNAL USERS FOUND" -ForegroundColor Green
        Write-Host "==================================" -ForegroundColor Green
        Write-Host "No external (guest) users matching '$SearchName' were found in your tenant." -ForegroundColor Green
        Write-Host "This is good news - it means no external Virginia users exist!" -ForegroundColor Green
    }

    # Also check for disabled internal users with that name
    Write-Host "`nChecking for disabled internal users matching '$SearchName'..." -ForegroundColor Cyan
    $disabledUsers = Get-MgUser -Filter "userType eq 'Member' and accountEnabled eq false" -All -Property DisplayName,Mail,UserPrincipalName,AccountEnabled |
        Where-Object { $_.DisplayName -like "*$SearchName*" }

    if ($disabledUsers) {
        Write-Host "Found $($disabledUsers.Count) disabled internal user(s):" -ForegroundColor Yellow
        foreach ($user in $disabledUsers) {
            Write-Host "  - $($user.DisplayName) ($($user.Mail))" -ForegroundColor Gray
        }
        Write-Host "(These are internal accounts and are expected)" -ForegroundColor Gray
    }
}
catch {
    Write-Error "An error occurred: $($_.Exception.Message)"
}
finally {
    Disconnect-MgGraph -ErrorAction SilentlyContinue
}

Write-Host "`n==================================" -ForegroundColor Cyan
Write-Host "Audit complete!" -ForegroundColor Cyan
Write-Host "==================================" -ForegroundColor Cyan
