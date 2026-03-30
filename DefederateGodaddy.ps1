#Requires -Modules Microsoft.Graph.Authentication, Microsoft.Graph.Identity.DirectoryManagement, Microsoft.Graph.Users, ExchangeOnlineManagement

# ============================================================
#  DEFEDERATE commonsharerx.org — Microsoft Graph Edition
#  No MSOnline. No AzureAD. Pure Graph + EXO.
# ============================================================

$TargetDomain = "commonsharerx.org"
$TempPassword = "Temp1234!"
$LogPath      = "$env:USERPROFILE\Desktop\DefederationLog_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
$ErrorActionPreference = "Stop"

# ─────────────────────────────────────────────────────────────
#  BANNER / LOGIN REMINDER
# ─────────────────────────────────────────────────────────────
Write-Host @"

╔══════════════════════════════════════════════════════════════╗
║              ⚠  IMPORTANT — READ BEFORE CONTINUING  ⚠       ║
║                                                              ║
║  Log in with your  NETORG  domain admin account              ║
║  (e.g.  admin@yourtenant.onmicrosoft.com  or netorg UPN)     ║
║                                                              ║
║  Do  NOT  log in with the commonsharerx.org primary account  ║
║  or you will lose access mid-script.                         ║
╚══════════════════════════════════════════════════════════════╝

"@ -ForegroundColor Yellow

$confirm = Read-Host "Are you logged in with your NETORG account? (yes/no)"
if ($confirm -ne "yes") {
    Write-Host "Aborted. Re-run after switching to the correct account." -ForegroundColor Red
    exit
}

# ─────────────────────────────────────────────────────────────
#  INSTALL MODULES IF MISSING
# ─────────────────────────────────────────────────────────────
$requiredModules = @(
    "Microsoft.Graph.Authentication",
    "Microsoft.Graph.Identity.DirectoryManagement",
    "Microsoft.Graph.Users",
    "ExchangeOnlineManagement"
)
foreach ($mod in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        Write-Host "Installing $mod..." -ForegroundColor Yellow
        Install-Module $mod -Scope CurrentUser -Force -AllowClobber
    }
}

# ─────────────────────────────────────────────────────────────
#  CONNECT
# ─────────────────────────────────────────────────────────────
Write-Host "`n[1/6] Connecting to Microsoft Graph..." -ForegroundColor Cyan
Connect-MgGraph -Scopes `
    "Domain.ReadWrite.All",`
    "User.ReadWrite.All",`
    "Directory.ReadWrite.All",`
    "RoleManagement.Read.Directory" `
    -NoWelcome

Write-Host "[2/6] Connecting to Exchange Online..." -ForegroundColor Cyan
Connect-ExchangeOnline -ShowBanner:$false

# ─────────────────────────────────────────────────────────────
#  STEP 1 — CHECK FEDERATION STATUS
# ─────────────────────────────────────────────────────────────
Write-Host "`n[3/6] Checking federation status for $TargetDomain..." -ForegroundColor Cyan

try {
    $domain = Get-MgDomain -DomainId $TargetDomain
} catch {
    Write-Host "ERROR: Domain '$TargetDomain' not found in this tenant." -ForegroundColor Red
    exit
}

Write-Host "    Domain Status : $($domain.IsVerified)" -ForegroundColor White
Write-Host "    Authentication: $($domain.AuthenticationType)" -ForegroundColor White

if ($domain.AuthenticationType -eq "Federated") {
    Write-Host "`n    Converting $TargetDomain → Managed..." -ForegroundColor Yellow

    # Must delete federation config object before switching auth type
    $fedConfigs = Get-MgDomainFederationConfiguration -DomainId $TargetDomain -ErrorAction SilentlyContinue
    foreach ($fc in $fedConfigs) {
        Remove-MgDomainFederationConfiguration -DomainId $TargetDomain -InternalDomainFederationId $fc.Id
        Write-Host "    ✔ Removed federation config ID: $($fc.Id)" -ForegroundColor Green
    }

    # Now flip auth type to Managed
    Update-MgDomain -DomainId $TargetDomain -BodyParameter @{ authenticationType = "Managed" }
    Start-Sleep -Seconds 3

    $recheck = Get-MgDomain -DomainId $TargetDomain
    if ($recheck.AuthenticationType -eq "Managed") {
        Write-Host "    ✔ Successfully converted to Managed authentication." -ForegroundColor Green
    } else {
        Write-Host "    ✘ Auth type did not update — check Entra ID > Domains manually." -ForegroundColor Red
    }
} else {
    Write-Host "    ✔ Domain already Managed — skipping conversion." -ForegroundColor Green
}

# ─────────────────────────────────────────────────────────────
#  STEP 2 — MIGRATE UPNs OFF TARGET DOMAIN
# ─────────────────────────────────────────────────────────────
Write-Host "`n[4/6] Migrating users/objects off $TargetDomain..." -ForegroundColor Cyan

# Get fallback .onmicrosoft.com domain
$fallbackDomain = (Get-MgDomain | Where-Object {
    $_.Id -like "*.onmicrosoft.com" -and $_.Id -notlike "*.mail.onmicrosoft.com"
} | Select-Object -First 1).Id

Write-Host "    Fallback domain: $fallbackDomain" -ForegroundColor DarkGray

# Migrate user UPNs
$usersOnDomain = Get-MgUser -All -Filter "endsWith(userPrincipalName,'@$TargetDomain')" `
    -ConsistencyLevel eventual -CountVariable c `
    -Property Id,DisplayName,UserPrincipalName

foreach ($u in $usersOnDomain) {
    $prefix = ($u.UserPrincipalName -split "@")[0]
    $newUPN = "$prefix@$fallbackDomain"
    try {
        Update-MgUser -UserId $u.Id -UserPrincipalName $newUPN
        Write-Host "    ✔ UPN migrated: $($u.UserPrincipalName) → $newUPN" -ForegroundColor Green
    } catch {
        Write-Host "    ✘ Failed: $($u.UserPrincipalName) — $($_.Exception.Message)" -ForegroundColor Red
    }
}

# Migrate Exchange mailboxes primary SMTP
$mailboxes = Get-Mailbox -ResultSize Unlimited | Where-Object { $_.PrimarySmtpAddress -like "*@$TargetDomain" }
foreach ($mbx in $mailboxes) {
    $prefix  = ($mbx.PrimarySmtpAddress -split "@")[0]
    $newSMTP = "$prefix@$fallbackDomain"
    try {
        Set-Mailbox -Identity $mbx.Identity -EmailAddresses "SMTP:$newSMTP" `
            -WindowsEmailAddress $newSMTP -MicrosoftOnlineServicesID $newSMTP
        Write-Host "    ✔ Mailbox migrated: $($mbx.PrimarySmtpAddress) → $newSMTP" -ForegroundColor Green
    } catch {
        Write-Host "    ✘ Mailbox failed: $($mbx.Identity) — $($_.Exception.Message)" -ForegroundColor Red
    }
}

# Migrate M365 Groups
$groups = Get-UnifiedGroup -ResultSize Unlimited | Where-Object { $_.PrimarySmtpAddress -like "*@$TargetDomain" }
foreach ($grp in $groups) {
    $prefix  = ($grp.PrimarySmtpAddress -split "@")[0]
    $newSMTP = "$prefix@$fallbackDomain"
    try {
        Set-UnifiedGroup -Identity $grp.Identity -EmailAddresses "SMTP:$newSMTP" `
            -WindowsEmailAddress $newSMTP -MicrosoftOnlineServicesID $newSMTP
        Write-Host "    ✔ Group migrated: $($grp.PrimarySmtpAddress) → $newSMTP" -ForegroundColor Green
    } catch {
        Write-Host "    ✘ Group failed: $($grp.Identity) — $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ─────────────────────────────────────────────────────────────
#  STEP 3 — REMOVE DOMAIN FROM TENANT
# ─────────────────────────────────────────────────────────────
Write-Host "`n[5/6] Removing $TargetDomain from Entra ID tenant..." -ForegroundColor Cyan
Start-Sleep -Seconds 5

try {
    Remove-MgDomain -DomainId $TargetDomain
    Write-Host "    ✔ Domain $TargetDomain successfully removed!" -ForegroundColor Green
} catch {
    Write-Host "    ✘ Removal failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "    Manually check: https://entra.microsoft.com > Custom domain names" -ForegroundColor Yellow
}

# ─────────────────────────────────────────────────────────────
#  STEP 4 — PASSWORD RESET (Non-Admins Only)
# ─────────────────────────────────────────────────────────────
Write-Host "`n[6/6] Resetting passwords for non-admin users..." -ForegroundColor Cyan

# Pull members of all privileged roles to exclude
$excludedIds = [System.Collections.Generic.HashSet[string]]::new()
$privilegedRoleNames = @(
    "Global Administrator",
    "Privileged Role Administrator",
    "User Administrator",
    "Password Administrator",
    "Helpdesk Administrator"
)

$allRoles = Get-MgDirectoryRole -All
foreach ($roleName in $privilegedRoleNames) {
    $role = $allRoles | Where-Object { $_.DisplayName -eq $roleName }
    if ($role) {
        $members = Get-MgDirectoryRoleMember -DirectoryRoleId $role.Id -All
        foreach ($m in $members) { $excludedIds.Add($m.Id) | Out-Null }
    }
}

Write-Host "    $($excludedIds.Count) privileged users excluded from reset." -ForegroundColor Yellow

# Get all enabled, non-guest users
$allUsers = Get-MgUser -All `
    -Filter "accountEnabled eq true and userType eq 'Member'" `
    -Property Id,DisplayName,UserPrincipalName

$resetLog   = [System.Collections.Generic.List[PSCustomObject]]::new()
$resetCount = 0
$skipCount  = 0

$pwParams = @{
    passwordProfile = @{
        password                      = $TempPassword
        forceChangePasswordNextSignIn = $true
    }
}

foreach ($user in $allUsers) {
    if ($excludedIds.Contains($user.Id)) {
        Write-Host "    [SKIP]  $($user.UserPrincipalName) — Privileged role member" -ForegroundColor DarkYellow
        $skipCount++
        continue
    }

    try {
        Update-MgUser -UserId $user.Id -BodyParameter $pwParams
        Write-Host "    [RESET] $($user.UserPrincipalName)" -ForegroundColor Green
        $resetLog.Add([PSCustomObject]@{
            DisplayName       = $user.DisplayName
            UserPrincipalName = $user.UserPrincipalName
            Status            = "Reset"
            TempPassword      = $TempPassword
            MustChangePW      = "Yes"
        })
        $resetCount++
    } catch {
        Write-Host "    [ERROR] $($user.UserPrincipalName) — $($_.Exception.Message)" -ForegroundColor Red
        $resetLog.Add([PSCustomObject]@{
            DisplayName       = $user.DisplayName
            UserPrincipalName = $user.UserPrincipalName
            Status            = "ERROR: $($_.Exception.Message)"
            TempPassword      = "N/A"
            MustChangePW      = "N/A"
        })
    }
}

$resetLog | Export-Csv -Path $LogPath -NoTypeInformation -Encoding UTF8
Write-Host "`n    ✔ $resetCount passwords reset | $skipCount admins skipped" -ForegroundColor Green
Write-Host "    ✔ Log saved: $LogPath" -ForegroundColor Green

# ─────────────────────────────────────────────────────────────
#  NEXT STEPS — GODADDY FINALIZATION
# ─────────────────────────────────────────────────────────────
Write-Host @"

╔══════════════════════════════════════════════════════════════════════╗
║        ✅  DEFEDERATION COMPLETE — WHAT'S NEXT (GODADDY)            ║
╚══════════════════════════════════════════════════════════════════════╝

  ┌─ STEP 1 ── Log into GoDaddy ──────────────────────────────────────
  │  URL  : https://dcc.godaddy.com/manage/commonsharerx.org/dns
  │  Login: Domain owner account (NOT the M365 admin)
  │  Nav  : My Products ▶ commonsharerx.org ▶ DNS Management

  ┌─ STEP 2 ── Delete All Microsoft 365 DNS Records ──────────────────
  │
  │  MX  : commonsharerx-org.mail.protection.outlook.com     ← DELETE
  │
  │  TXT : MS=msXXXXXXXX  (ownership verification)           ← DELETE
  │  TXT : v=spf1 include:spf.protection.outlook.com ~all    ← DELETE
  │
  │  CNAME: autodiscover        → autodiscover.outlook.com   ← DELETE
  │  CNAME: selector1._domainkey                             ← DELETE
  │  CNAME: selector2._domainkey                             ← DELETE
  │  CNAME: msoid               → clientconfig.microsoftonline-p.net ← DELETE
  │  CNAME: enterpriseregistration → enterpriseregistration.windows.net ← DELETE
  │  CNAME: enterpriseenrollment   → enterpriseenrollment.manage.microsoft.com ← DELETE
  │
  │  SRV : _sip._tls                                         ← DELETE
  │  SRV : _sipfederationtls._tcp                            ← DELETE

  ┌─ STEP 3 ── Verify Domain Gone from Entra ─────────────────────────
  │  URL : https://entra.microsoft.com
  │  Nav : Identity ▶ Settings ▶ Domain Names
  │  Confirm commonsharerx.org is NOT listed

  ┌─ STEP 4 ── Verify DNS Propagation ────────────────────────────────
  │  Tool: https://dnschecker.org/#MX/commonsharerx.org
  │  Allow up to 48 hours for full global propagation

  ┌─ STEP 5 ── Transfer or Release Domain (GoDaddy) ──────────────────
  │  Transfer : Unlock domain → get EPP/Auth code → submit to new registrar
  │  Retire   : Disable auto-renew and let it expire
  │  URL  : https://dcc.godaddy.com/manage/commonsharerx.org

  ┌─ STEP 6 ── Notify Users + Clean Up ───────────────────────────────
  │  • Notify users: temp password is  Temp1234!  (forced change on login)
  │  • Review Entra App Registrations for redirect URIs on commonsharerx.org
  │  • Update any service accounts / API keys tied to @commonsharerx.org
  │  • Check Conditional Access policies referencing the domain

══════════════════════════════════════════════════════════════════════
  Completed : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
  Log file  : $LogPath
══════════════════════════════════════════════════════════════════════
"@ -ForegroundColor Cyan