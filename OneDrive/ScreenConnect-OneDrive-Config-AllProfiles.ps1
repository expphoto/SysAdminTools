#!ps
param(
    [string]$TenantID = '<PASTE_TENANT_GUID_HERE>'
)

$ErrorActionPreference = 'Stop'

$logDir = Join-Path $env:PUBLIC 'Documents\OneDriveMigration'
$logFile = Join-Path $logDir ("ScreenConnect_OneDriveConfig_{0}.log" -f $env:COMPUTERNAME)

if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

function Log {
    param([string]$Message)

    $line = '[{0}] {1}' -f (Get-Date -Format 'MM/dd/yyyy HH:mm:ss'), $Message
    Add-Content -Path $logFile -Value $line
    Write-Output $line
}

function Ensure-RegistryValue {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [object]$Value,
        [Parameter(Mandatory)] [Microsoft.Win32.RegistryValueKind]$Type
    )

    if (-not (Test-Path $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }

    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

function Remove-RegistryValueIfPresent {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Name
    )

    if (Test-Path $Path) {
        Remove-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
    }
}

function Test-HiveLoaded {
    param([Parameter(Mandatory)] [string]$Sid)

    return Test-Path ("Registry::HKEY_USERS\{0}" -f $Sid)
}

function Get-ProfileList {
    $profileRoot = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
    $specialPrefixes = @('S-1-5-18', 'S-1-5-19', 'S-1-5-20')

    foreach ($item in Get-ChildItem $profileRoot -ErrorAction SilentlyContinue) {
        $sid = $item.PSChildName
        if ($specialPrefixes -contains $sid) {
            continue
        }

        $profilePath = (Get-ItemProperty -Path $item.PSPath -Name ProfileImagePath -ErrorAction SilentlyContinue).ProfileImagePath
        if (-not $profilePath) {
            continue
        }

        $expandedPath = [Environment]::ExpandEnvironmentVariables($profilePath)
        [PSCustomObject]@{
            Sid         = $sid
            ProfilePath = $expandedPath
            NtUserDat   = Join-Path $expandedPath 'NTUSER.DAT'
            IsLoaded    = Test-HiveLoaded -Sid $sid
        }
    }
}

function Invoke-UserHiveWork {
    param(
        [Parameter(Mandatory)] [string]$RegistryRoot,
        [Parameter(Mandatory)] [string]$ProfilePath,
        [Parameter(Mandatory)] [string]$Sid
    )

    Log ("Applying HKCU-equivalent changes for {0} ({1})" -f $ProfilePath, $Sid)

    $userShellFolders = Join-Path $RegistryRoot 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
    $shellFolders = Join-Path $RegistryRoot 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders'
    $folderMap = @{
        Desktop       = 'Desktop'
        Personal      = 'Documents'
        'My Pictures' = 'Pictures'
        'My Video'    = 'Videos'
        'My Music'    = 'Music'
        Favorites     = 'Favorites'
    }

    foreach ($entry in $folderMap.GetEnumerator()) {
        $resolvedPath = Join-Path $ProfilePath $entry.Value
        $expandPath = ('%USERPROFILE%\{0}' -f $entry.Value)

        Ensure-RegistryValue -Path $userShellFolders -Name $entry.Key -Value $expandPath -Type ExpandString
        Ensure-RegistryValue -Path $shellFolders -Name $entry.Key -Value $resolvedPath -Type String
    }

    $oneDriveAccounts = Join-Path $RegistryRoot 'SOFTWARE\Microsoft\OneDrive\Accounts'
    if (Test-Path $oneDriveAccounts) {
        Get-ChildItem -Path $oneDriveAccounts -ErrorAction SilentlyContinue | ForEach-Object {
            Remove-RegistryValueIfPresent -Path $_.PSPath -Name 'KfmIsDoneSilentOptIn'
            Remove-RegistryValueIfPresent -Path $_.PSPath -Name 'SilentBusinessConfigCompleted'
            Log ("Cleared OneDrive KFM state under {0}" -f $_.PSChildName)
        }
    }

    $oneDriveRoot = Join-Path $RegistryRoot 'SOFTWARE\Microsoft\OneDrive'
    Remove-RegistryValueIfPresent -Path $oneDriveRoot -Name 'SilentBusinessConfigCompleted'
    Remove-RegistryValueIfPresent -Path $oneDriveRoot -Name 'ClientEverSignedIn'
    Remove-RegistryValueIfPresent -Path $oneDriveRoot -Name 'PersonalUnlinkedTimeStamp'
    Remove-RegistryValueIfPresent -Path $oneDriveRoot -Name 'OneAuthUnrecoverableTimestamp'

    $resetPending = Join-Path $ProfilePath 'AppData\Local\Microsoft\OneDrive\settings\ResetPending'
    if (Test-Path $resetPending) {
        Remove-Item -Path $resetPending -Force -ErrorAction SilentlyContinue
        Log ("Removed ResetPending marker for {0}" -f $ProfilePath)
    }
}

function Mount-UserHive {
    param(
        [Parameter(Mandatory)] [string]$Sid,
        [Parameter(Mandatory)] [string]$NtUserDat
    )

    & reg.exe load ("HKU\{0}" -f $Sid) $NtUserDat | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to load user hive $Sid from $NtUserDat"
    }
}

function Unmount-UserHive {
    param([Parameter(Mandatory)] [string]$Sid)

    & reg.exe unload ("HKU\{0}" -f $Sid) | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Log ("WARNING: Failed to unload hive {0}" -f $Sid)
    }
}

function Get-ActiveUserSessions {
    $sessions = @()

    try {
        $lines = quser 2>$null
        foreach ($line in $lines | Select-Object -Skip 1) {
            $normalized = ($line -replace '^>', '').Trim()
            if (-not $normalized) {
                continue
            }

            $parts = $normalized -split '\s+'
            if ($parts.Length -lt 3) {
                continue
            }

            $username = $parts[0]
            $state = $parts[2]
            if ($state -eq 'Active') {
                $sessions += $username
            }
        }
    } catch {
        Log 'INFO: Unable to query active sessions with quser'
    }

    return $sessions | Select-Object -Unique
}

function Restart-ProcessesForActiveUsers {
    $activeUsers = Get-ActiveUserSessions
    if (-not $activeUsers) {
        Log 'INFO: No active user sessions found for Explorer/OneDrive restart'
        return
    }

    foreach ($username in $activeUsers) {
        Log ("Attempting Explorer/OneDrive restart for active session user {0}" -f $username)

        $taskName = 'OD_SC_' + ([guid]::NewGuid().ToString('N'))
        $escapedScript = @'
$ErrorActionPreference = "SilentlyContinue"
Stop-Process -Name explorer -Force
Start-Sleep -Seconds 2
Start-Process explorer.exe
Get-Process OneDrive | Stop-Process -Force
Get-Process OneDriveStandaloneUpdater | Stop-Process -Force
Start-Sleep -Seconds 8
$odExe = @(
    "$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe",
    "$env:ProgramFiles\Microsoft OneDrive\OneDrive.exe",
    "$env:ProgramFiles(x86)\Microsoft OneDrive\OneDrive.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($odExe) { Start-Process -FilePath $odExe }
'@

        try {
            $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ("-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command {0}" -f ([Management.Automation.Language.CodeGeneration]::QuoteArgument($escapedScript)))
            $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(5)
            $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
            $principal = New-ScheduledTaskPrincipal -UserId $username -LogonType Interactive -RunLevel Limited

            Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
            Start-ScheduledTask -TaskName $taskName
            Start-Sleep -Seconds 20
        } catch {
            Log ("WARNING: Failed to restart OneDrive for {0}: {1}" -f $username, $_.Exception.Message)
        } finally {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        }
    }
}

Log '=== ScreenConnect OneDrive Config (All Profiles) ==='
Log ("Running as {0}" -f [System.Security.Principal.WindowsIdentity]::GetCurrent().Name)

$oneDrivePolicyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\OneDrive'
Ensure-RegistryValue -Path $oneDrivePolicyPath -Name 'KFMSilentOptIn' -Value $TenantID -Type String
Ensure-RegistryValue -Path $oneDrivePolicyPath -Name 'KFMSilentOptInDesktop' -Value 1 -Type DWord
Ensure-RegistryValue -Path $oneDrivePolicyPath -Name 'KFMSilentOptInDocuments' -Value 1 -Type DWord
Ensure-RegistryValue -Path $oneDrivePolicyPath -Name 'KFMSilentOptInPictures' -Value 1 -Type DWord
Ensure-RegistryValue -Path $oneDrivePolicyPath -Name 'KFMSilentOptInWithNotification' -Value 1 -Type DWord
Ensure-RegistryValue -Path $oneDrivePolicyPath -Name 'KFMBlockOptOut' -Value 1 -Type DWord
Ensure-RegistryValue -Path $oneDrivePolicyPath -Name 'SilentAccountConfig' -Value 1 -Type DWord
Ensure-RegistryValue -Path $oneDrivePolicyPath -Name 'FilesOnDemandEnabled' -Value 1 -Type DWord
Log ("Wrote HKLM OneDrive policy for tenant {0}" -f $TenantID)

$profiles = Get-ProfileList
foreach ($profile in $profiles) {
    if (-not (Test-Path $profile.NtUserDat)) {
        Log ("Skipping profile without NTUSER.DAT: {0}" -f $profile.ProfilePath)
        continue
    }

    $loadedHere = $false
    try {
        if (-not $profile.IsLoaded) {
            Mount-UserHive -Sid $profile.Sid -NtUserDat $profile.NtUserDat
            $loadedHere = $true
            Log ("Loaded hive for {0}" -f $profile.ProfilePath)
        }

        $registryRoot = "Registry::HKEY_USERS\{0}" -f $profile.Sid
        Invoke-UserHiveWork -RegistryRoot $registryRoot -ProfilePath $profile.ProfilePath -Sid $profile.Sid
    } catch {
        Log ("WARNING: Failed to process profile {0}: {1}" -f $profile.ProfilePath, $_.Exception.Message)
    } finally {
        if ($loadedHere) {
            Unmount-UserHive -Sid $profile.Sid
        }
    }
}

Restart-ProcessesForActiveUsers

Log '=== Script complete ==='
