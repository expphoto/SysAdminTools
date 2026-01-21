<#
.SYNOPSIS
    Compare permissions between two users on a folder/share to identify access differences.

.DESCRIPTION
    This script compares NTFS and share permissions for two users to help troubleshoot
    why one user can access a resource while another cannot. It's read-only and safe
    for production servers.

.PARAMETER Path
    The folder path to check permissions on (can be local path or UNC path)

.PARAMETER User1
    The first user (the one who CAN access) - format: DOMAIN\username or username

.PARAMETER User2
    The user who CANNOT access - format: DOMAIN\username or username

.PARAMETER IncludeGroupMembership
    Show detailed group membership comparison (can be slow in large domains)

.PARAMETER ServerName
    Optional: Specify the server name if checking UNC paths remotely (auto-detected from UNC path)

.EXAMPLE
    .\Compare-UserPermissions.ps1 -Path "C:\Shares\ProjectFolder" -User1 "DOMAIN\workinguser" -User2 "DOMAIN\brokenuser"

.EXAMPLE
    .\Compare-UserPermissions.ps1 -Path "\\SERVER\Share\Folder" -User1 "workinguser" -User2 "brokenuser" -IncludeGroupMembership

.EXAMPLE
    # Run this ON the file server for best results
    .\Compare-UserPermissions.ps1 -Path "C:\Shares\Data" -User1 "john" -User2 "jane" -IncludeGroupMembership
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$Path,

    [Parameter(Mandatory=$true)]
    [string]$User1,

    [Parameter(Mandatory=$true)]
    [string]$User2,

    [Parameter(Mandatory=$false)]
    [switch]$IncludeGroupMembership,

    [Parameter(Mandatory=$false)]
    [string]$ServerName
)

# Color output helper
function Write-ColorOutput {
    param(
        [string]$Message,
        [string]$Color = "White"
    )
    Write-Host $Message -ForegroundColor $Color
}

# Normalize username to include domain
function Get-NormalizedUsername {
    param([string]$Username)

    if ($Username -notlike "*\*") {
        # Try to get domain from environment
        $domain = $env:USERDOMAIN
        if ($domain) {
            return "$domain\$Username"
        }
    }
    return $Username
}

# Get all groups a user belongs to (including nested)
function Get-UserGroups {
    param([string]$Username)

    try {
        $groups = @()

        # Remove domain prefix for AD query if present
        $user = $Username -replace '^.*\\', ''

        # Try to get AD user
        $adUser = Get-ADUser -Identity $user -Properties MemberOf -ErrorAction Stop

        # Get tokenGroups for all groups including nested (this is what Windows actually uses)
        $userDN = $adUser.DistinguishedName
        $userObj = [ADSI]"LDAP://$userDN"
        $userObj.GetInfoEx(@("tokenGroups"), 0)
        $groups = $userObj.Properties["tokenGroups"] | ForEach-Object {
            $sid = New-Object System.Security.Principal.SecurityIdentifier($_, 0)
            try {
                $sid.Translate([System.Security.Principal.NTAccount]).Value
            } catch {
                $sid.Value
            }
        }

        return $groups | Sort-Object -Unique
    }
    catch {
        Write-Warning "Could not retrieve AD groups for $Username. Error: $($_.Exception.Message)"
        Write-Warning "Falling back to basic group query..."

        # Fallback: try using net user command
        try {
            $user = $Username -replace '^.*\\', ''
            $netOutput = net user $user /domain 2>&1 | Out-String
            if ($netOutput -match "Local Group Memberships(.*?)Global Group memberships") {
                # This is a very basic fallback
                Write-Warning "Using basic net user query - results may be incomplete"
            }
        }
        catch {
            Write-Warning "All methods to get groups failed: $($_.Exception.Message)"
        }

        return @()
    }
}

# Get effective NTFS permissions for a user (including group memberships)
function Get-EffectiveNTFSPermissions {
    param(
        [string]$Path,
        [string]$Username,
        [array]$UserGroups
    )

    try {
        $acl = Get-Acl -Path $Path -ErrorAction Stop
        $effectivePerms = @()

        # Check direct user permissions
        $userPerms = $acl.Access | Where-Object {
            $_.IdentityReference.Value -eq $Username
        }
        if ($userPerms) {
            $effectivePerms += $userPerms | Select-Object IdentityReference, FileSystemRights, AccessControlType, IsInherited
        }

        # Check group permissions
        foreach ($group in $UserGroups) {
            $groupPerms = $acl.Access | Where-Object {
                $_.IdentityReference.Value -eq $group
            }
            if ($groupPerms) {
                $effectivePerms += $groupPerms | Select-Object IdentityReference, FileSystemRights, AccessControlType, IsInherited
            }
        }

        # Add well-known groups that everyone is part of
        $wellKnownGroups = @("Everyone", "BUILTIN\Users", "NT AUTHORITY\Authenticated Users")
        foreach ($wkg in $wellKnownGroups) {
            $wkgPerms = $acl.Access | Where-Object {
                $_.IdentityReference.Value -eq $wkg
            }
            if ($wkgPerms) {
                $effectivePerms += $wkgPerms | Select-Object IdentityReference, FileSystemRights, AccessControlType, IsInherited
            }
        }

        return $effectivePerms
    }
    catch {
        Write-Warning "Could not get NTFS permissions for $Path : $($_.Exception.Message)"
        return @()
    }
}

# Get ALL NTFS permissions (not filtered)
function Get-AllNTFSPermissions {
    param([string]$Path)

    try {
        $acl = Get-Acl -Path $Path -ErrorAction Stop
        return $acl.Access | Select-Object IdentityReference, FileSystemRights, AccessControlType, IsInherited
    }
    catch {
        Write-Warning "Could not get NTFS permissions: $($_.Exception.Message)"
        return @()
    }
}

# Get share permissions - IMPROVED VERSION
function Get-AllSharePermissions {
    param(
        [string]$Path,
        [string]$ServerName
    )

    $result = @{
        ShareName = $null
        AllPermissions = @()
        Method = $null
        Server = $null
        Error = $null
    }

    try {
        # Extract server and share name
        $server = $null
        $shareName = $null

        if ($Path -like "\\*") {
            # UNC path: \\server\share\...
            $pathParts = $Path -replace '^\\\\', '' -split '\\'
            $server = $pathParts[0]
            $shareName = $pathParts[1]
        }
        elseif ($ServerName) {
            $server = $ServerName
            # Try to find matching share on specified server
            $shares = Get-CimInstance -ClassName Win32_Share -ComputerName $server -ErrorAction SilentlyContinue
            $matchingShare = $shares | Where-Object { $Path -like "$($_.Path)*" } | Select-Object -First 1
            if ($matchingShare) {
                $shareName = $matchingShare.Name
            }
        }
        else {
            # Local path - check if it's shared locally
            $shares = Get-SmbShare -ErrorAction SilentlyContinue | Where-Object { $Path -like "$($_.Path)*" }
            if ($shares) {
                $shareName = $shares[0].Name
                $server = $env:COMPUTERNAME
            }
        }

        if (-not $shareName) {
            $result.Error = "Could not determine share name from path"
            return $result
        }

        $result.ShareName = $shareName
        $result.Server = $server

        Write-ColorOutput "  [DEBUG] Detected Share: $shareName on Server: $server" "Gray"

        # Method 1: Try Get-SmbShareAccess (works best locally or on current machine)
        try {
            if ($server -eq $env:COMPUTERNAME -or -not $server) {
                $sharePerms = Get-SmbShareAccess -Name $shareName -ErrorAction Stop
                $result.AllPermissions = $sharePerms | Select-Object AccountName, AccessRight, AccessControlType
                $result.Method = "Get-SmbShareAccess (Local)"
                return $result
            }
        }
        catch {
            Write-ColorOutput "  [DEBUG] Get-SmbShareAccess failed: $($_.Exception.Message)" "Gray"
        }

        # Method 2: Try CIM/WMI to get share security remotely
        try {
            Write-ColorOutput "  [DEBUG] Attempting CIM query for share security on $server..." "Gray"

            # Get the share object
            $share = Get-CimInstance -ClassName Win32_Share -ComputerName $server -Filter "Name='$shareName'" -ErrorAction Stop

            if ($share) {
                # Invoke GetSecurityDescriptor method
                $sd = Invoke-CimMethod -InputObject $share -MethodName GetSecurityDescriptor -ErrorAction Stop

                if ($sd.ReturnValue -eq 0 -and $sd.Descriptor) {
                    $dacl = $sd.Descriptor.DACL

                    $permissions = @()
                    foreach ($ace in $dacl) {
                        $trustee = $ace.Trustee
                        $accountName = if ($trustee.Domain) {
                            "$($trustee.Domain)\$($trustee.Name)"
                        } else {
                            $trustee.Name
                        }

                        # Convert AccessMask to rights
                        $accessMask = $ace.AccessMask
                        $rights = switch ($accessMask) {
                            2032127 { "Full Control" }
                            1245631 { "Change" }
                            1179817 { "Read" }
                            default { "Custom (0x{0:X})" -f $accessMask }
                        }

                        # Convert ACE Type
                        $aceType = switch ($ace.AceType) {
                            0 { "Allow" }
                            1 { "Deny" }
                            default { "Unknown" }
                        }

                        $permissions += [PSCustomObject]@{
                            AccountName = $accountName
                            AccessRight = $rights
                            AccessControlType = $aceType
                        }
                    }

                    $result.AllPermissions = $permissions
                    $result.Method = "CIM/WMI (Remote)"
                    return $result
                }
            }
        }
        catch {
            Write-ColorOutput "  [DEBUG] CIM method failed: $($_.Exception.Message)" "Gray"
        }

        # Method 3: Try WMI as last resort
        try {
            Write-ColorOutput "  [DEBUG] Attempting WMI query..." "Gray"
            $share = Get-WmiObject -Class Win32_LogicalShareSecuritySetting -Filter "Name='$shareName'" -ComputerName $server -ErrorAction Stop

            if ($share) {
                $sd = $share.GetSecurityDescriptor()
                if ($sd.ReturnValue -eq 0) {
                    $permissions = @()
                    foreach ($ace in $sd.Descriptor.DACL) {
                        $trustee = $ace.Trustee
                        $accountName = if ($trustee.Domain) {
                            "$($trustee.Domain)\$($trustee.Name)"
                        } else {
                            $trustee.Name
                        }

                        $accessMask = $ace.AccessMask
                        $rights = switch ($accessMask) {
                            2032127 { "Full Control" }
                            1245631 { "Change" }
                            1179817 { "Read" }
                            default { "Custom (0x{0:X})" -f $accessMask }
                        }

                        $aceType = switch ($ace.AceType) {
                            0 { "Allow" }
                            1 { "Deny" }
                            default { "Unknown" }
                        }

                        $permissions += [PSCustomObject]@{
                            AccountName = $accountName
                            AccessRight = $rights
                            AccessControlType = $aceType
                        }
                    }

                    $result.AllPermissions = $permissions
                    $result.Method = "WMI (Legacy)"
                    return $result
                }
            }
        }
        catch {
            Write-ColorOutput "  [DEBUG] WMI method failed: $($_.Exception.Message)" "Gray"
            $result.Error = "All methods to retrieve share permissions failed"
        }

        return $result
    }
    catch {
        $result.Error = "Exception: $($_.Exception.Message)"
        return $result
    }
}

# Filter share permissions for a specific user
function Get-UserSharePermissions {
    param(
        [array]$AllSharePerms,
        [string]$Username,
        [array]$UserGroups
    )

    $effectivePerms = @()

    # Check direct user permissions (try both full and short username)
    $shortUsername = $Username -replace '^.*\\', ''
    $userPerms = $AllSharePerms | Where-Object {
        $_.AccountName -eq $Username -or
        $_.AccountName -eq $shortUsername -or
        $_.AccountName -like "*\$shortUsername"
    }
    if ($userPerms) {
        $effectivePerms += $userPerms
    }

    # Check group permissions
    foreach ($group in $UserGroups) {
        $shortGroup = $group -replace '^.*\\', ''
        $groupPerms = $AllSharePerms | Where-Object {
            $_.AccountName -eq $group -or
            $_.AccountName -eq $shortGroup -or
            $_.AccountName -like "*\$shortGroup"
        }
        if ($groupPerms) {
            $effectivePerms += $groupPerms
        }
    }

    # Check well-known groups
    $wellKnownGroups = @("Everyone", "Users", "Authenticated Users", "NT AUTHORITY\Authenticated Users", "BUILTIN\Users")
    foreach ($wkg in $wellKnownGroups) {
        $wkgPerms = $AllSharePerms | Where-Object {
            $_.AccountName -eq $wkg -or $_.AccountName -like "*$wkg*"
        }
        if ($wkgPerms) {
            $effectivePerms += $wkgPerms
        }
    }

    return $effectivePerms
}

# Main script
Write-ColorOutput "`n=== Permission Comparison Tool ===" "Cyan"
Write-ColorOutput "Comparing permissions for:" "Cyan"
Write-ColorOutput "  User 1 (WORKING): $User1" "Green"
Write-ColorOutput "  User 2 (BROKEN):  $User2" "Red"
Write-ColorOutput "  Path: $Path" "Cyan"

# Auto-detect server from UNC path if not specified
if (-not $ServerName -and $Path -like "\\*") {
    $ServerName = ($Path -replace '^\\\\', '' -split '\\')[0]
}
if ($ServerName) {
    Write-ColorOutput "  Server: $ServerName" "Cyan"
}

Write-ColorOutput "`n"

# Normalize usernames
$User1 = Get-NormalizedUsername -Username $User1
$User2 = Get-NormalizedUsername -Username $User2

# Check if path exists
if (-not (Test-Path -Path $Path)) {
    Write-ColorOutput "ERROR: Path does not exist or is not accessible: $Path" "Red"
    Write-ColorOutput "Note: If this is a permissions issue, that might be why User2 can't access it!" "Yellow"

    # Try to at least get share info even if we can't access the path
    Write-ColorOutput "`nAttempting to check share permissions anyway..." "Yellow"
}

# Get group memberships
Write-ColorOutput "Step 1: Retrieving group memberships..." "Yellow"
$user1Groups = @()
$user2Groups = @()

if ($IncludeGroupMembership) {
    $user1Groups = Get-UserGroups -Username $User1
    $user2Groups = Get-UserGroups -Username $User2

    Write-ColorOutput "  $User1 is in $($user1Groups.Count) groups" "White"
    Write-ColorOutput "  $User2 is in $($user2Groups.Count) groups" "White"

    # Compare group memberships
    $groupsOnlyInUser1 = $user1Groups | Where-Object { $_ -notin $user2Groups }
    $groupsOnlyInUser2 = $user2Groups | Where-Object { $_ -notin $user1Groups }

    if ($groupsOnlyInUser1) {
        Write-ColorOutput "`n  Groups only $User1 belongs to:" "Green"
        $groupsOnlyInUser1 | ForEach-Object { Write-ColorOutput "    - $_" "Gray" }
    }

    if ($groupsOnlyInUser2) {
        Write-ColorOutput "`n  Groups only $User2 belongs to:" "Red"
        $groupsOnlyInUser2 | ForEach-Object { Write-ColorOutput "    - $_" "Gray" }
    }

    if (-not $groupsOnlyInUser1 -and -not $groupsOnlyInUser2) {
        Write-ColorOutput "`n  Both users are in the same groups!" "Yellow"
        Write-ColorOutput "  (This means the issue is likely NOT group membership related)" "Yellow"
    }
}
else {
    Write-ColorOutput "  (Skipped - use -IncludeGroupMembership for detailed group analysis)" "Gray"
    Write-ColorOutput "  WARNING: Without group analysis, share permission comparison may be incomplete!" "Yellow"
}

# Get NTFS permissions
Write-ColorOutput "`nStep 2: Checking NTFS permissions..." "Yellow"

# First show ALL NTFS permissions
Write-ColorOutput "`n--- ALL NTFS Permissions on this folder ---" "Cyan"
$allNTFS = Get-AllNTFSPermissions -Path $Path
if ($allNTFS.Count -gt 0) {
    $allNTFS | ForEach-Object {
        $inherited = if ($_.IsInherited) { "(Inherited)" } else { "(Explicit)" }
        $color = if ($_.AccessControlType -eq "Deny") { "Red" } else { "White" }
        Write-ColorOutput "  $($_.IdentityReference): $($_.FileSystemRights) - $($_.AccessControlType) $inherited" $color
    }
}
else {
    Write-ColorOutput "  Could not retrieve NTFS permissions!" "Red"
}

# Now show user-specific permissions
$user1NTFS = Get-EffectiveNTFSPermissions -Path $Path -Username $User1 -UserGroups $user1Groups
$user2NTFS = Get-EffectiveNTFSPermissions -Path $Path -Username $User2 -UserGroups $user2Groups

Write-ColorOutput "`n--- Effective NTFS Permissions for $User1 ---" "Green"
if ($user1NTFS.Count -eq 0) {
    Write-ColorOutput "  No effective NTFS permissions found!" "Red"
    Write-ColorOutput "  (User might only have access through groups not detected)" "Yellow"
}
else {
    $user1NTFS | ForEach-Object {
        $inherited = if ($_.IsInherited) { "(Inherited)" } else { "(Explicit)" }
        Write-ColorOutput "  $($_.IdentityReference): $($_.FileSystemRights) - $($_.AccessControlType) $inherited" "White"
    }
}

Write-ColorOutput "`n--- Effective NTFS Permissions for $User2 ---" "Red"
if ($user2NTFS.Count -eq 0) {
    Write-ColorOutput "  No effective NTFS permissions found!" "Red"
    Write-ColorOutput "  *** THIS IS LIKELY THE PROBLEM! ***" "Red"
}
else {
    $user2NTFS | ForEach-Object {
        $inherited = if ($_.IsInherited) { "(Inherited)" } else { "(Explicit)" }
        Write-ColorOutput "  $($_.IdentityReference): $($_.FileSystemRights) - $($_.AccessControlType) $inherited" "White"
    }
}

# Analyze NTFS differences
Write-ColorOutput "`n--- NTFS Permission Analysis ---" "Cyan"
$user1Identities = $user1NTFS | ForEach-Object { $_.IdentityReference.Value } | Sort-Object -Unique
$user2Identities = $user2NTFS | ForEach-Object { $_.IdentityReference.Value } | Sort-Object -Unique

$identitiesOnlyInUser1 = $user1Identities | Where-Object { $_ -notin $user2Identities }
$identitiesOnlyInUser2 = $user2Identities | Where-Object { $_ -notin $user1Identities }

if ($identitiesOnlyInUser1) {
    Write-ColorOutput "  *** NTFS access granted to $User1 through these (NOT granted to User2): ***" "Yellow"
    $identitiesOnlyInUser1 | ForEach-Object {
        $perms = $user1NTFS | Where-Object { $_.IdentityReference.Value -eq $_ }
        foreach ($p in $perms) {
            Write-ColorOutput "    - $_`: $($p.FileSystemRights) ($($p.AccessControlType))" "Green"
        }
    }
    Write-ColorOutput "  ^^^ THIS IS LIKELY WHY USER2 CAN'T ACCESS! ^^^" "Red"
}

if ($identitiesOnlyInUser2) {
    Write-ColorOutput "`n  Access granted to $User2 through these (NOT granted to User1):" "Yellow"
    $identitiesOnlyInUser2 | ForEach-Object {
        $perms = $user2NTFS | Where-Object { $_.IdentityReference.Value -eq $_ }
        foreach ($p in $perms) {
            Write-ColorOutput "    - $_`: $($p.FileSystemRights) ($($p.AccessControlType))" "White"
        }
    }
}

# Check for explicit DENY rules (these override everything)
$user2Denies = $user2NTFS | Where-Object { $_.AccessControlType -eq "Deny" }
if ($user2Denies) {
    Write-ColorOutput "`n  *** CRITICAL: User2 has DENY permissions! ***" "Red"
    $user2Denies | ForEach-Object {
        Write-ColorOutput "    - DENY via $($_.IdentityReference): $($_.FileSystemRights)" "Red"
    }
    Write-ColorOutput "    DENY permissions override all ALLOW permissions!" "Red"
    Write-ColorOutput "    ^^^ THIS IS YOUR PROBLEM! REMOVE THE DENY! ^^^" "Red"
}

# Get share permissions
Write-ColorOutput "`nStep 3: Checking share permissions..." "Yellow"
$shareInfo = Get-AllSharePermissions -Path $Path -ServerName $ServerName

if ($shareInfo.ShareName) {
    Write-ColorOutput "  Share Name: $($shareInfo.ShareName)" "White"
    Write-ColorOutput "  Server: $($shareInfo.Server)" "White"
    Write-ColorOutput "  Method Used: $($shareInfo.Method)" "Gray"

    if ($shareInfo.AllPermissions.Count -gt 0) {
        Write-ColorOutput "`n--- ALL Share Permissions (Advanced Sharing > Permissions) ---" "Cyan"
        $shareInfo.AllPermissions | ForEach-Object {
            $color = if ($_.AccessControlType -eq "Deny") { "Red" } else { "White" }
            Write-ColorOutput "  $($_.AccountName): $($_.AccessRight) - $($_.AccessControlType)" $color
        }

        # Now filter for each user
        $user1SharePerms = Get-UserSharePermissions -AllSharePerms $shareInfo.AllPermissions -Username $User1 -UserGroups $user1Groups
        $user2SharePerms = Get-UserSharePermissions -AllSharePerms $shareInfo.AllPermissions -Username $User2 -UserGroups $user2Groups

        Write-ColorOutput "`n--- Effective Share Permissions for $User1 ---" "Green"
        if ($user1SharePerms.Count -eq 0) {
            Write-ColorOutput "  No effective share permissions found!" "Red"
        }
        else {
            $user1SharePerms | ForEach-Object {
                Write-ColorOutput "  Via $($_.AccountName): $($_.AccessRight) - $($_.AccessControlType)" "White"
            }
        }

        Write-ColorOutput "`n--- Effective Share Permissions for $User2 ---" "Red"
        if ($user2SharePerms.Count -eq 0) {
            Write-ColorOutput "  No effective share permissions found!" "Red"
            Write-ColorOutput "  *** THIS IS LIKELY THE PROBLEM! ***" "Red"
        }
        else {
            $user2SharePerms | ForEach-Object {
                Write-ColorOutput "  Via $($_.AccountName): $($_.AccessRight) - $($_.AccessControlType)" "White"
            }
        }

        # Analyze share permission differences
        Write-ColorOutput "`n--- Share Permission Analysis ---" "Cyan"
        $user1ShareIdentities = $user1SharePerms | ForEach-Object { $_.AccountName } | Sort-Object -Unique
        $user2ShareIdentities = $user2SharePerms | ForEach-Object { $_.AccountName } | Sort-Object -Unique

        $shareIdentitiesOnlyInUser1 = $user1ShareIdentities | Where-Object { $_ -notin $user2ShareIdentities }
        $shareIdentitiesOnlyInUser2 = $user2ShareIdentities | Where-Object { $_ -notin $user1ShareIdentities }

        if ($shareIdentitiesOnlyInUser1) {
            Write-ColorOutput "  *** Share access granted to $User1 via these (NOT to User2): ***" "Yellow"
            $shareIdentitiesOnlyInUser1 | ForEach-Object {
                $perm = $user1SharePerms | Where-Object { $_.AccountName -eq $_ } | Select-Object -First 1
                Write-ColorOutput "    - $_ ($($perm.AccessRight))" "Green"
            }
            Write-ColorOutput "  ^^^ THIS IS LIKELY WHY USER2 CAN'T ACCESS VIA NETWORK! ^^^" "Red"
        }

        if ($shareIdentitiesOnlyInUser2) {
            Write-ColorOutput "`n  Share access granted to $User2 via these (NOT to User1):" "Yellow"
            $shareIdentitiesOnlyInUser2 | ForEach-Object {
                $perm = $user2SharePerms | Where-Object { $_.AccountName -eq $_ } | Select-Object -First 1
                Write-ColorOutput "    - $_ ($($perm.AccessRight))" "White"
            }
        }

        if (-not $shareIdentitiesOnlyInUser1 -and -not $shareIdentitiesOnlyInUser2) {
            if ($user1SharePerms.Count -eq 0 -and $user2SharePerms.Count -eq 0) {
                Write-ColorOutput "  Neither user has share permissions!" "Red"
                Write-ColorOutput "  (They might both be blocked at the share level)" "Yellow"
            }
            else {
                Write-ColorOutput "  Both users have the same share permissions" "White"
                Write-ColorOutput "  (The issue is likely NTFS permissions, not share permissions)" "Yellow"
            }
        }

        # Check for share DENY
        $user2ShareDenies = $user2SharePerms | Where-Object { $_.AccessControlType -eq "Deny" }
        if ($user2ShareDenies) {
            Write-ColorOutput "`n  *** CRITICAL: User2 has share DENY permissions! ***" "Red"
            $user2ShareDenies | ForEach-Object {
                Write-ColorOutput "    - DENY via $($_.AccountName)" "Red"
            }
            Write-ColorOutput "    ^^^ THIS IS YOUR PROBLEM! REMOVE THE DENY! ^^^" "Red"
        }
    }
    else {
        Write-ColorOutput "  No share permissions found!" "Red"
        if ($shareInfo.Error) {
            Write-ColorOutput "  Error: $($shareInfo.Error)" "Red"
        }
    }
}
else {
    Write-ColorOutput "  This is not a shared folder or share could not be detected." "Yellow"
    if ($shareInfo.Error) {
        Write-ColorOutput "  Error: $($shareInfo.Error)" "Red"
    }
    Write-ColorOutput "`n  TIP: Make sure you're running this script ON the file server itself," "Yellow"
    Write-ColorOutput "       or specify -ServerName parameter if checking remotely." "Yellow"
}

# Summary
Write-ColorOutput "`n=== SUMMARY & RECOMMENDATIONS ===" "Cyan"
Write-ColorOutput "`nHow Windows permissions work:" "Yellow"
Write-ColorOutput "  - Local access: Only NTFS permissions apply" "White"
Write-ColorOutput "  - Network access: The MOST RESTRICTIVE of (Share permissions + NTFS permissions) wins" "White"
Write-ColorOutput "  - DENY permissions ALWAYS override ALLOW permissions" "White"
Write-ColorOutput "  - Permissions are evaluated: Deny > Allow, Explicit > Inherited" "White"

Write-ColorOutput "`nBased on the analysis above:" "Yellow"

# Give specific recommendations
$recommendations = @()

if ($user2Denies) {
    $recommendations += "1. REMOVE the DENY NTFS permission on User2 - this is blocking access!"
}

if ($user2SharePerms.Count -eq 0 -and $shareInfo.ShareName) {
    $recommendations += "2. User2 has NO share permissions - add User2 (or a group they're in) to Share Permissions"
}

if ($user2NTFS.Count -eq 0) {
    $recommendations += "3. User2 has NO NTFS permissions - add User2 (or a group they're in) to NTFS Security"
}

if ($identitiesOnlyInUser1 -and $user2NTFS.Count -eq 0) {
    $recommendations += "4. User1 has access via: $($identitiesOnlyInUser1 -join ', ')"
    $recommendations += "   Add User2 to one of these groups, OR add User2 directly to NTFS permissions"
}

if ($shareIdentitiesOnlyInUser1 -and $user2SharePerms.Count -eq 0) {
    $recommendations += "5. User1 has share access via: $($shareIdentitiesOnlyInUser1 -join ', ')"
    $recommendations += "   Add User2 to one of these groups, OR add User2 to Share permissions"
}

if (-not $IncludeGroupMembership) {
    $recommendations += "6. Re-run this script with -IncludeGroupMembership for complete analysis"
}

if ($recommendations.Count -eq 0) {
    Write-ColorOutput "  Unable to determine the specific issue from this analysis." "Yellow"
    Write-ColorOutput "  Both users appear to have similar permissions based on detected settings." "Yellow"
    Write-ColorOutput "`n  Additional things to check manually:" "Yellow"
    Write-ColorOutput "    - Is User2's account locked, disabled, or password expired?" "White"
    Write-ColorOutput "    - Are there parent folder permissions blocking inheritance?" "White"
    Write-ColorOutput "    - Is Access-Based Enumeration (ABE) enabled on the share?" "White"
    Write-ColorOutput "    - Are there any GPOs affecting User2's access?" "White"
    Write-ColorOutput "    - Try running: icacls `"$Path`" /verify" "White"
}
else {
    foreach ($rec in $recommendations) {
        Write-ColorOutput "  $rec" "White"
    }
}

Write-ColorOutput "`n=== MANUAL VERIFICATION COMMANDS ===" "Cyan"
Write-ColorOutput "Run these commands to verify/fix:" "Yellow"
Write-ColorOutput "  # View full NTFS ACL:" "White"
Write-ColorOutput "  icacls `"$Path`"" "Gray"
Write-ColorOutput "`n  # View share permissions (run on file server):" "White"
if ($shareInfo.ShareName) {
    Write-ColorOutput "  Get-SmbShareAccess -Name '$($shareInfo.ShareName)'" "Gray"
}
else {
    Write-ColorOutput "  Get-SmbShareAccess -Name 'SHARENAME'" "Gray"
}
Write-ColorOutput "`n  # Check if user can access (run as User2):" "White"
Write-ColorOutput "  Test-Path `"$Path`"" "Gray"
Write-ColorOutput "`n  # View effective permissions (GUI):" "White"
Write-ColorOutput "  Right-click folder > Properties > Security > Advanced > Effective Access" "Gray"

Write-ColorOutput "`nScript completed.`n" "Cyan"
