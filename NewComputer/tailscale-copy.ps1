<#
.SYNOPSIS
    Interactive PC-to-PC User Profile Migration Tool.
.DESCRIPTION
    Automates the transfer of user profiles, applications, and settings.
    Fully interactive. Supports multiple user selection.
#>

#Requires -RunAsAdministrator

#region Helper Functions

function Write-Log {
    param ([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"
    
    $color = switch ($Level) { 
        "ERROR" { "Red" } 
        "WARN" { "Yellow" } 
        "SUCCESS" { "Green" }
        default { "Cyan" } 
    }
    
    Write-Host $logEntry -ForegroundColor $color
    Add-Content -Path $Global:LogPath -Value $logEntry
}

function Get-TailscaleKey {
    Write-Host "`n------------------------------------------------" -ForegroundColor Yellow
    Write-Host "TAILSCALE AUTH KEY REQUIRED" -ForegroundColor Yellow
    Write-Host "------------------------------------------------" -ForegroundColor Yellow
    Write-Host "1. Open your Tailscale Admin Console:" -ForegroundColor White
    Write-Host "   https://login.tailscale.com/admin/settings/keys" -ForegroundColor Cyan
    Write-Host "2. Generate a 'Reusable' Auth Key." -ForegroundColor White
    Write-Host "3. Paste it below." -ForegroundColor White
    Write-Host "------------------------------------------------" -ForegroundColor Yellow
    
    $key = Read-Host "Paste Auth Key"
    return $key.Trim()
}

function Invoke-TailscaleSetup {
    param ([string]$AuthKey)
    
    Write-Log "Checking for Tailscale..."
    $tsPath = "$env:ProgramFiles\Tailscale\Tailscale.exe"
    
    if (-not (Test-Path $tsPath)) {
        Write-Log "Tailscale not found. Installing via Chocolatey..."
        if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
            Write-Log "Installing Chocolatey..."
            Set-ExecutionPolicy Bypass -Scope Process -Force
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
            Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
        }
        choco install tailscale -y --force
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
        $tsPath = "$env:ProgramFiles\Tailscale\Tailscale.exe"
    }

    Write-Log "Connecting Tailscale VPN..."
    $status = & $tsPath status --json 2>$null | ConvertFrom-Json
    
    if ($status.BackendState -ne "Running") {
        if ([string]::IsNullOrWhiteSpace($AuthKey)) {
            Write-Log "No Key provided. Attempting interactive login..." -Level "WARN"
            & $tsPath up
        } else {
            & $tsPath up --authkey $AuthKey --unattended
        }
        Start-Sleep -Seconds 5
    }

    $status = & $tsPath status --json 2>$null | ConvertFrom-Json
    $ip = ($status.TailscaleIPs | Where-Object { $_ -match "^100\." })[0]
    
    if (-not $ip) { Write-Log "Failed to get VPN IP." -Level "ERROR"; return $null }
    
    Write-Log "VPN IP Acquired: $ip" -Level "SUCCESS"
    return $ip
}

function Get-UsmtPath {
    $arch = "amd64"
    $searchPaths = @(
        "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\User State Migration Tool\$arch",
        "${env:ProgramFiles}\Windows Kits\10\Assessment and Deployment Kit\User State Migration Tool\$arch"
    )
    foreach ($p in $searchPaths) { if (Test-Path "$p\scanstate.exe") { return $p } }
    return $null
}

function New-TempUser {
    param ([string]$User, [string]$Pass)
    Write-Log "Creating temporary transfer user: $User"
    try {
        $secPass = ConvertTo-SecureString $Pass -AsPlainText -Force
        New-LocalUser -Name $User -Password $secPass -Description "Temp Migration User" -ErrorAction Stop
        Add-LocalGroupMember -Group "Administrators" -Member $User -ErrorAction Stop
        return $true
    }
    catch {
        try { Set-LocalUser -Name $User -Password $secPass; return $true } catch { return $false }
    }
}

function Get-UserSelection {
    Write-Log "Scanning for User Profiles..."
    $userProfiles = Get-ChildItem "C:\Users" -Directory | Where-Object { 
        $_.Name -notin @("Public", "Default", "Default User", "All Users") -and 
        $_.Name -notlike "ADMINI~*" -and 
        $_.Name -ne "Administrator" 
    }

    $list = foreach ($up in $userProfiles) {
        $size = (Get-ChildItem $up.FullName -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        [PSCustomObject]@{
            Select = $false
            User = $up.Name
            Path = $up.FullName
            SizeGB = [math]::Round($size / 1GB, 2)
        }
    }

    if ($list.Count -eq 0) { Write-Log "No user profiles found!" -Level "ERROR"; exit }
    
    Write-Host "`nSelect User Profile(s) to Migrate:" -ForegroundColor Cyan
    return $list | Out-GridView -Title "Select Users" -OutputMode Multiple
}

function Get-AppDataSelection {
    param([string[]]$UserPaths)
    
    Write-Log "Scanning AppData folders for selected users..."
    $exclusions = @("Microsoft", "Packages", "Windows", "Temp", "Cache", "Low", "D3DSCache", "IconCache", "Microsoft Windows", "Intel", "NVIDIA")
    
    $allFolders = @()
    foreach ($path in $UserPaths) {
        $roaming = Join-Path $path "AppData\Roaming"
        $local = Join-Path $path "AppData\Local"
        
        if (Test-Path $roaming) { $allFolders += Get-ChildItem $roaming -Directory -ErrorAction SilentlyContinue }
        if (Test-Path $local) { $allFolders += Get-ChildItem $local -Directory -ErrorAction SilentlyContinue }
    }

    $uniqueFolders = $allFolders | Where-Object { 
        $isExcluded = $false
        foreach ($ex in $exclusions) { if ($_.Name -eq $ex -or $_.Name -like "*Cache*") { $isExcluded = $true; break } }
        -not $isExcluded
    } | Sort-Object Name -Unique

    $folderList = foreach ($folder in $uniqueFolders) {
        $size = (Get-ChildItem $folder.FullName -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        [PSCustomObject]@{
            Select = $true
            Name = $folder.Name
            Path = $folder.FullName
            SizeMB = [math]::Round($size / 1MB, 2)
        }
    }

    Write-Host "`nSelect AppData Folders to Include:" -ForegroundColor Cyan
    return $folderList | Out-GridView -Title "Select App Data" -OutputMode Multiple
}

#endregion

#region Main Execution

 $Global:LogPath = "$PSScriptRoot\Migration_$(Get-Date -Format 'yyyyMMdd_HHmm').log"
 $WorkDir = "$env:SystemDrive\MigWork"

if (-not (Test-Path $WorkDir)) { New-Item -Path $WorkDir -ItemType Directory -Force -ErrorAction Stop | Out-Null }

Clear-Host
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "    PC-to-PC Migration Tool                " -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan

# 1. Interactive Mode Selection
Write-Host "What is this machine?" -ForegroundColor Yellow
Write-Host "[1] SOURCE (Old PC - Send Data)"
Write-Host "[2] DESTINATION (New PC - Receive Data)"
 $choice = Read-Host "Enter selection (1 or 2)"

if ($choice -eq "1") { $Mode = "Source" }
elseif ($choice -eq "2") { $Mode = "Destination" }
else { Write-Host "Invalid selection." -Level "ERROR"; exit }

# 2. Interactive Key Input
 $tsKey = Get-TailscaleKey

# 3. VPN Setup
 $myIP = Invoke-TailscaleSetup -AuthKey $tsKey
if (-not $myIP) { 
    Read-Host "Press Enter to exit"
    exit 
}

#endregion

#region SOURCE Mode
if ($Mode -eq "Source") {
    
    Write-Host "`n[!] IMPORTANT: Close all Browsers (Chrome/Edge) now!" -ForegroundColor Yellow
    Pause

    # User Selection
    $selectedUsers = Get-UserSelection
    if ($selectedUsers.Count -eq 0) { Write-Log "No users selected. Exiting." -Level "ERROR"; exit }
    
    $userPaths = $selectedUsers.Path
    $userNames = $selectedUsers.User
    
    # Save User Manifest
    $userManifest = "$WorkDir\UserManifest.txt"
    $userNames -join "," | Out-File $userManifest -Encoding UTF8

    # App Selection
    $selectedFolders = Get-AppDataSelection -UserPaths $userPaths
    if ($selectedFolders.Count -eq 0) { Write-Log "No folders selected. Exiting." -Level "WARN"; exit }

    # Save Folder Manifest
    $manifestFile = "$WorkDir\Manifest.txt"
    $selectedFolders.Path | Out-File $manifestFile -Encoding UTF8

    # Winget Export
    Write-Log "Exporting application list..."
    winget export -o "$WorkDir\apps.json" --include-versions --accept-source-agreements

    # USMT ScanState
    $usmtPath = Get-UsmtPath
    if ($usmtPath) {
        Write-Log "Running USMT ScanState for selected users..."
        $usmtUserArgs = ""
        foreach ($u in $userNames) { $usmtUserArgs += " /ui:*\$u" }
        
        $scanArgs = "$WorkDir\USMT_Store /o /c /r:3 /w:5 /l $WorkDir\ScanState.log $usmtUserArgs"
        Start-Process -FilePath "$usmtPath\scanstate.exe" -ArgumentList $scanArgs -NoNewWindow -Wait
        Write-Log "ScanState complete."
    }
    else {
        Write-Log "USMT not found. Skipping registry/profile state capture." -Level "WARN"
    }

    # SMB Setup
    $SharePass = -join ((65..90) + (97..122) + (48..57) | Get-Random -Count 12 | ForEach-Object {[char]$_})
    $ShareUser = "MigUser"
    
    New-TempUser -User $ShareUser -Pass $SharePass
    Get-SmbShare -Name "MigShare$" -ErrorAction SilentlyContinue | Remove-SmbShare -Force
    New-SmbShare -Name "MigShare$" -Path $WorkDir -FullAccess $ShareUser

    # Output Summary
    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "   SOURCE READY" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "VPN IP Address : $myIP" -ForegroundColor Cyan
    Write-Host "Username       : $ShareUser" -ForegroundColor Cyan
    Write-Host "Password       : $SharePass" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "Switch to Destination machine now." -ForegroundColor Yellow
    Write-Log "Source setup complete. Waiting for connection..."
    Pause
}

#endregion

#region DESTINATION Mode
if ($Mode -eq "Destination") {
    
    $SourceIP = Read-Host "Enter Source Machine VPN IP"
    
    # Credentials
    $ShareUser = Read-Host "Enter Share Username (Default: MigUser)"
    if ([string]::IsNullOrWhiteSpace($ShareUser)) { $ShareUser = "MigUser" }
    
    $secPass = Read-Host "Enter Share Password" -AsSecureString
    $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secPass)
    $SharePass = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($ptr)

    # Mount
    $remoteShare = "\\$SourceIP\MigShare$"
    $localMount = "Z:"
    Write-Log "Connecting to $remoteShare..."
    net use $localMount /delete 2>$null
    net use $localMount $remoteShare /user:$ShareUser $SharePass
    
    if ($LASTEXITCODE -ne 0) { Write-Log "Failed to connect. Check password/IP." -Level "ERROR"; pause; exit }

    # Winget Import
    if (Test-Path "$localMount\apps.json") {
        Write-Log "Installing applications..."
        winget import -i "$localMount\apps.json" --accept-package-agreements --accept-source-agreements --ignore-unavailable
    }

    # User Mapping
    $userManifest = "$localMount\UserManifest.txt"
    $sourceUsers = Get-Content $userManifest -Raw -ErrorAction SilentlyContinue
    if (-not $sourceUsers) {
        Write-Log "User manifest not found. Assuming current user transfer." -Level "WARN"
        $sourceUsers = @($env:USERNAME)
    } else {
        $sourceUsers = $sourceUsers.Split(',')
    }

    # Robocopy Loop
    $folderManifest = "$localMount\Manifest.txt"
    if (Test-Path $folderManifest) {
        $paths = Get-Content $folderManifest
        
        foreach ($remPath in $paths) {
            # Map source user path to destination user path
            $destTarget = $null
            
            foreach ($sUser in $sourceUsers) {
                if ($remPath -match "\\Users\\$sUser\\") {
                    $destTarget = $remPath -replace "\\Users\\$sUser\\", "\Users\$env:USERNAME\"
                    break
                }
            }
            
            if (-not $destTarget) { $destTarget = $remPath }

            Write-Log "Copying $remPath -> $destTarget"
            
            $logFile = "$WorkDir\Robocopy_$(Split-Path $remPath -Leaf).log"
            
            if (-not (Test-Path $destTarget)) { New-Item -Path $destTarget -ItemType Directory -Force | Out-Null }
            
            robocopy $remPath $destTarget /E /ZB /COPY:DAT /R:3 /W:5 /MT:8 /NP /LOG:$logFile
        }
    }

    # USMT LoadState
    $usmtPath = Get-UsmtPath
    if ($usmtPath -and (Test-Path "$localMount\USMT_Store")) {
        Write-Log "Running USMT LoadState..."
        
        # Map users: Source User -> Destination User
        $muArgs = ""
        foreach ($sUser in $sourceUsers) {
            if ($sUser -ne $env:USERNAME) {
                 $muArgs += " /mu:$sUser:$env:USERNAME"
            }
        }
        
        $loadArgs = "$localMount\USMT_Store /c /r:3 /w:5 /l $WorkDir\LoadState.log $muArgs"
        Start-Process -FilePath "$usmtPath\loadstate.exe" -ArgumentList $loadArgs -NoNewWindow -Wait
    }

    net use $localMount /delete
    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "   MIGRATION COMPLETE" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "Please restart your computer." -ForegroundColor Yellow
    Pause
}
#endregion