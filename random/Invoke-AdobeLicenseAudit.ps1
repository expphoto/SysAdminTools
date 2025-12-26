#Requires -Modules @{ ModuleName = "Microsoft.Graph"; ModuleVersion = "2.0.0" }

param(
    [Parameter(Mandatory = $true)]
    [string]$AdobeUserExportPath,
    
    [Parameter(Mandatory = $true)]
    [string]$AdobeDCGroupName = "Adobe-DC",
    
    [string]$AdobeProGroupName = "Adobe-Pro",
    
    [string]$OutputPath = "C:\Reports\AdobeLicenseAudit.csv",
    
    [switch]$SendEmail,
    [string]$EmailFrom = "admin@yourdomain.com",
    [string]$EmailTo = "license-admin@yourdomain.com",
    [string]$SmtpServer = "smtp.yourdomain.com",
    
    [switch]$DetailedReport
)

$ErrorActionPreference = "Stop"

function Connect-MgGraphRequired {
    $requiredScopes = @("GroupMember.Read.All", "User.Read.All")
    
    Write-Output "Connecting to Microsoft Graph..."
    
    try {
        $currentScopes = (Get-MgContext -ErrorAction SilentlyContinue).Scopes
        $missingScopes = $requiredScopes | Where-Object { $_ -notin $currentScopes }
        
        if ($missingScopes) {
            Connect-MgGraph -Scopes $requiredScopes
        } else {
            Write-Output "Already connected with required scopes"
        }
    } catch {
        Connect-MgGraph -Scopes $requiredScopes
    }
}

function Get-AdobeUsers {
    param([string]$FilePath)
    
    Write-Output "Reading Adobe user export from: $FilePath"
    
    if (-not (Test-Path $FilePath)) {
        Write-Error "Adobe user export file not found: $FilePath"
        throw
    }
    
    $adobeUsers = Import-Csv -Path $FilePath
    
    Write-Output "Found $($adobeUsers.Count) users in Adobe export"
    
    return $adobeUsers | ForEach-Object {
        $email = $_.Email -replace '\s+', ''
        $productProfile = $_.'Product Profile' -replace '\s+', ''
        
        [PSCustomObject]@{
            User = $_.User
            Email = $email
            ProductProfile = $productProfile
            Source = "Adobe"
        }
    }
}

function Get-AzureGroupMembers {
    param(
        [object]$GraphContext,
        [string]$GroupName
    )
    
    Write-Output "Getting Azure AD group members for: $GroupName"
    
    $group = Get-MgGroup -Filter "displayName eq '$GroupName'" -ErrorAction SilentlyContinue
    
    if (-not $group) {
        Write-Warning "Azure AD group not found: $GroupName"
        return @()
    }
    
    $members = Get-MgGroupMember -GroupId $group.Id -All | ForEach-Object {
        $user = Get-MgUser -UserId $_.Id
        [PSCustomObject]@{
            User = $user.DisplayName
            Email = $user.UserPrincipalName
            Group = $GroupName
            Source = "AzureAD"
        }
    }
    
    Write-Output "Found $($members.Count) members in group: $GroupName"
    return $members
}

function Compare-LicenseAssignments {
    param(
        [array]$AdobeUsers,
        [array]$AzureDCMembers,
        [array]$AzureProMembers
    )
    
    Write-Output "Comparing license assignments..."
    
    $adobeDCUsers = $AdobeUsers | Where-Object { $_.ProductProfile -match "DC|Creative Cloud" }
    $adobeProUsers = $AdobeUsers | Where-Object { $_.ProductProfile -match "Pro|Acrobat Pro" }
    
    $azureDCEmails = $AzureDCMembers | Select-Object -ExpandProperty Email -Unique
    $azureProEmails = $AzureProMembers | Select-Object -ExpandProperty Email -Unique
    
    $discrepancies = @()
    
    foreach ($user in $adobeDCUsers) {
        $inAzureGroup = $user.Email -in $azureDCEmails
        
        $discrepancies += [PSCustomObject]@{
            Type = "Adobe DC License"
            Email = $user.Email
            User = $user.User
            InAdobe = $true
            InAzureGroup = $inAzureGroup
            Issue = if (-not $inAzureGroup) { "User has Adobe DC license but not in Azure AD group" } else { "OK" }
        }
    }
    
    foreach ($user in $AzureDCMembers) {
        $inAdobe = $user.Email -in ($adobeDCUsers | Select-Object -ExpandProperty Email)
        
        if (-not $inAdobe) {
            $discrepancies += [PSCustomObject]@{
                Type = "Azure AD DC Group"
                Email = $user.Email
                User = $user.User
                InAdobe = $inAdobe
                InAzureGroup = $true
                Issue = "User is in Azure AD group but has no Adobe DC license"
            }
        }
    }
    
    foreach ($user in $adobeProUsers) {
        $inAzureGroup = $user.Email -in $azureProEmails
        
        $discrepancies += [PSCustomObject]@{
            Type = "Adobe Pro License"
            Email = $user.Email
            User = $user.User
            InAdobe = $true
            InAzureGroup = $inAzureGroup
            Issue = if (-not $inAzureGroup) { "User has Adobe Pro license but not in Azure AD group" } else { "OK" }
        }
    }
    
    foreach ($user in $AzureProMembers) {
        $inAdobe = $user.Email -in ($adobeProUsers | Select-Object -ExpandProperty Email)
        
        if (-not $inAdobe) {
            $discrepancies += [PSCustomObject]@{
                Type = "Azure AD Pro Group"
                Email = $user.Email
                User = $user.User
                InAdobe = $inAdobe
                InAzureGroup = $true
                Issue = "User is in Azure AD group but has no Adobe Pro license"
            }
        }
    }
    
    $wrongTierUsers = $adobeDCUsers | Where-Object { $_.Email -in $azureProEmails }
    foreach ($user in $wrongTierUsers) {
        $discrepancies += [PSCustomObject]@{
            Type = "Tier Mismatch"
            Email = $user.Email
            User = $user.User
            InAdobe = $true
            InAzureGroup = $true
            Issue = "User has Adobe DC license but is in Adobe-Pro group (should be in Adobe-DC)"
        }
    }
    
    $wrongTierUsers = $adobeProUsers | Where-Object { $_.Email -in $azureDCEmails }
    foreach ($user in $wrongTierUsers) {
        $discrepancies += [PSCustomObject]@{
            Type = "Tier Mismatch"
            Email = $user.Email
            User = $user.User
            InAdobe = $true
            InAzureGroup = $true
            Issue = "User has Adobe Pro license but is in Adobe-DC group (should be in Adobe-Pro)"
        }
    }
    
    return $discrepancies
}

function Export-LicenseAuditReport {
    param(
        [array]$Discrepancies,
        [string]$OutputPath,
        [bool]$Detailed
    )
    
    $outputDir = Split-Path -Parent $OutputPath
    if (!(Test-Path $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }
    
    if ($Detailed) {
        $Discrepancies | Export-Csv -Path $OutputPath -NoTypeInformation -Force
    } else {
        $Discrepancies | Where-Object { $_.Issue -ne "OK" } | Export-Csv -Path $OutputPath -NoTypeInformation -Force
    }
    
    Write-Output "Report exported to: $OutputPath"
}

function Send-LicenseAuditEmail {
    param(
        [array]$Discrepancies,
        [array]$AdobeDCUsers,
        [array]$AdobeProUsers,
        [array]$AzureDCMembers,
        [array]$AzureProMembers,
        [string]$SmtpServer,
        [string]$EmailFrom,
        [string]$EmailTo
    )
    
    $subject = "Adobe License Audit Report - $(Get-Date -Format 'yyyy-MM-dd')"
    
    $issues = $Discrepancies | Where-Object { $_.Issue -ne "OK" }
    $issueCount = $issues.Count
    
    $body = "Adobe License / Azure AD Group Parity Check`n"
    $body += "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n"
    $body += "=" * 50 + "`n`n"
    
    $body += "SUMMARY`n"
    $body += "-" * 50 + "`n"
    $body += "Adobe DC Licenses: $($AdobeDCUsers.Count)`n"
    $body += "Adobe Pro Licenses: $($AdobeProUsers.Count)`n"
    $body += "Azure AD DC Group Members: $($AzureDCMembers.Count)`n"
    $body += "Azure AD Pro Group Members: $($AzureProMembers.Count)`n"
    $body += "Issues Found: $issueCount`n`n"
    
    if ($issueCount -gt 0) {
        $body += "ISSUES DETECTED`n"
        $body += "-" * 50 + "`n"
        
        foreach ($issue in ($issues | Group-Object -Property Type)) {
            $body += "`n$($issue.Name) ($($issue.Count)):`n"
            foreach ($item in $issue.Group) {
                $body += "  - $($item.User) <$($item.Email)>: $($item.Issue)`n"
            }
        }
    } else {
        $body += "All license assignments are in sync! No issues detected.`n"
    }
    
    try {
        Send-MailMessage -From $EmailFrom -To $EmailTo -Subject $subject -Body $body -SmtpServer $SmtpServer
        Write-Output "Email report sent to: $EmailTo"
    } catch {
        Write-Error "Failed to send email: $_"
    }
}

try {
    Connect-MgGraphRequired
    
    $adobeUsers = Get-AdobeUsers -FilePath $AdobeUserExportPath
    
    $azureDCMembers = Get-AzureGroupMembers -GroupName $AdobeDCGroupName
    
    if ($AdobeProGroupName) {
        $azureProMembers = Get-AzureGroupMembers -GroupName $AdobeProGroupName
    } else {
        $azureProMembers = @()
    }
    
    $discrepancies = Compare-LicenseAssignments -AdobeUsers $adobeUsers -AzureDCMembers $azureDCMembers -AzureProMembers $azureProMembers
    
    Export-LicenseAuditReport -Discrepancies $discrepancies -OutputPath $OutputPath -Detailed:$DetailedReport
    
    if ($SendEmail) {
        $adobeDCUsers = $adobeUsers | Where-Object { $_.ProductProfile -match "DC|Creative Cloud" }
        $adobeProUsers = $adobeUsers | Where-Object { $_.ProductProfile -match "Pro|Acrobat Pro" }
        
        Send-LicenseAuditEmail -Discrepancies $discrepancies -AdobeDCUsers $adobeDCUsers -AdobeProUsers $adobeProUsers -AzureDCMembers $azureDCMembers -AzureProMembers $azureProMembers -SmtpServer $SmtpServer -EmailFrom $EmailFrom -EmailTo $EmailTo
    }
    
    $issuesCount = ($discrepancies | Where-Object { $_.Issue -ne "OK" }).Count
    
    Write-Output "`nAudit complete. Found $issuesCount issue(s)."
    
    return @{
        Discrepancies = $discrepancies
        AdobeDCCount = ($adobeUsers | Where-Object { $_.ProductProfile -match "DC|Creative Cloud" }).Count
        AdobeProCount = ($adobeUsers | Where-Object { $_.ProductProfile -match "Pro|Acrobat Pro" }).Count
        AzureDCCount = $azureDCMembers.Count
        AzureProCount = $azureProMembers.Count
        IssuesCount = $issuesCount
    }
    
} catch {
    Write-Error "Script failed: $_"
    throw
} finally {
    Disconnect-MgGraph | Out-Null
}