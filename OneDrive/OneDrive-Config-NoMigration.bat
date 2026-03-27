@echo off
setlocal EnableExtensions EnableDelayedExpansion

REM ======================================================
REM OneDrive Configuration Script (NO DATA MIGRATION)
REM - Does NOT copy any files
REM - Does NOT unmap H: drive
REM - Resets shell folder redirection to local profile paths
REM - Applies OneDrive KFM policy directly in registry
REM ======================================================

echo ======================================================
echo   OneDrive Configuration Tool
echo   (No Data Migration / No H: Drive Removal)
echo ======================================================
echo Computer: %COMPUTERNAME%
echo User: %USERNAME%
echo Date/Time: %DATE% %TIME%
echo ======================================================

REM ===== LOG SETUP =====
set "LOG_DIR=%PUBLIC%\Documents\OneDriveMigration"
set "LOG_FILE=%LOG_DIR%\OneDriveConfig_%COMPUTERNAME%_%USERNAME%.log"
set "KFM_POLICY_WRITTEN=0"

if not exist "%LOG_DIR%" (
    mkdir "%LOG_DIR%" 2>nul || (
        set "LOG_DIR=%TEMP%"
        set "LOG_FILE=%LOG_DIR%\OneDriveConfig_%COMPUTERNAME%_%USERNAME%.log"
    )
)

echo Log file: %LOG_FILE%
echo.

echo ============================================================ > "%LOG_FILE%"
echo OneDrive Configuration Script >> "%LOG_FILE%"
echo ============================================================ >> "%LOG_FILE%"
echo [%DATE% %TIME%] Script started >> "%LOG_FILE%"
echo [%DATE% %TIME%] Computer: %COMPUTERNAME% >> "%LOG_FILE%"
echo [%DATE% %TIME%] User: %USERNAME% >> "%LOG_FILE%"
echo [%DATE% %TIME%] UserProfile: %USERPROFILE% >> "%LOG_FILE%"

REM ===== STEP 0: OPTIONAL ONEDRIVE KFM POLICY =====
echo Step 0: OneDrive KFM configuration...
echo [%DATE% %TIME%] STEP 0: KFM policy >> "%LOG_FILE%"

REM Set your tenant GUID below. Leave blank or use the placeholder to skip KFM.
set "TENANT_ID=<PASTE_TENANT_GUID_HERE>"

if "%TENANT_ID%"=="" (
    echo   - Tenant ID not set. Skipping KFM policy.
    echo [%DATE% %TIME%] KFM skipped: Tenant ID is blank >> "%LOG_FILE%"
) else if /I "%TENANT_ID%"=="<PASTE_TENANT_GUID_HERE>" (
    echo   - Tenant ID placeholder detected. Skipping KFM policy.
    echo [%DATE% %TIME%] KFM skipped: Tenant ID placeholder detected >> "%LOG_FILE%"
) else (
    echo   - Writing OneDrive KFM policy...
    echo [%DATE% %TIME%] Writing OneDrive KFM policy to HKLM\SOFTWARE\Policies\Microsoft\OneDrive >> "%LOG_FILE%"

    reg add "HKLM\SOFTWARE\Policies\Microsoft\OneDrive" /f >nul 2>&1
    reg add "HKLM\SOFTWARE\Policies\Microsoft\OneDrive" /v "KFMSilentOptIn" /t REG_SZ /d "%TENANT_ID%" /f >nul 2>&1
    if !errorlevel! equ 0 (
        set "KFM_POLICY_WRITTEN=1"
        echo [%DATE% %TIME%] SUCCESS: KFMSilentOptIn written for tenant %TENANT_ID% >> "%LOG_FILE%"
    ) else (
        echo   - WARNING: Failed to write KFMSilentOptIn. Elevation may be required.
        echo [%DATE% %TIME%] WARNING: Failed to write KFMSilentOptIn. Elevation may be required. >> "%LOG_FILE%"
    )

    reg add "HKLM\SOFTWARE\Policies\Microsoft\OneDrive" /v "KFMSilentOptInWithNotification" /t REG_DWORD /d 1 /f >nul 2>&1
    reg add "HKLM\SOFTWARE\Policies\Microsoft\OneDrive" /v "KFMBlockOptOut" /t REG_DWORD /d 1 /f >nul 2>&1
    reg add "HKLM\SOFTWARE\Policies\Microsoft\OneDrive" /v "SilentAccountConfig" /t REG_DWORD /d 1 /f >nul 2>&1
    reg add "HKLM\SOFTWARE\Policies\Microsoft\OneDrive" /v "FilesOnDemandEnabled" /t REG_DWORD /d 1 /f >nul 2>&1
)

REM ===== STEP 1: FOLDER REDIRECTION RESET FOR ALL USER PROFILES =====
echo Step 1: Resetting folder redirection for all user profiles...
echo [%DATE% %TIME%] STEP 1: All-profile folder redirection reset >> "%LOG_FILE%"

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
 "$logFile = '%LOG_FILE%';" ^
 "function Log([string]`$m) { Add-Content -Path `$logFile -Value ('[' + (Get-Date -Format 'MM/dd/yyyy HH:mm:ss') + '] ' + `$m) };" ^
 "function EnsureValue([string]`$path,[string]`$name,[object]`$value,[Microsoft.Win32.RegistryValueKind]`$kind) { if (-not (Test-Path `$path)) { New-Item -Path `$path -Force ^| Out-Null }; New-ItemProperty -Path `$path -Name `$name -Value `$value -PropertyType `$kind -Force ^| Out-Null };" ^
 "function RemoveValue([string]`$path,[string]`$name) { if (Test-Path `$path) { Remove-ItemProperty -Path `$path -Name `$name -ErrorAction SilentlyContinue } };" ^
 "`$skip = @('S-1-5-18','S-1-5-19','S-1-5-20');" ^
 "Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -ErrorAction SilentlyContinue ^| ForEach-Object {" ^
 "  `$sid = `$_.PSChildName; if (`$skip -contains `$sid) { return };" ^
 "  `$profilePath = (Get-ItemProperty -Path `$_.PSPath -Name ProfileImagePath -ErrorAction SilentlyContinue).ProfileImagePath;" ^
 "  if (-not `$profilePath) { return };" ^
 "  `$profilePath = [Environment]::ExpandEnvironmentVariables(`$profilePath);" ^
 "  `$ntUser = Join-Path `$profilePath 'NTUSER.DAT'; if (-not (Test-Path `$ntUser)) { Log ('Skipping profile without NTUSER.DAT: ' + `$profilePath); return };" ^
 "  `$loaded = Test-Path ('Registry::HKEY_USERS\' + `$sid); `$loadedHere = `$false;" ^
 "  try {" ^
 "    if (-not `$loaded) { & reg.exe load ('HKU\' + `$sid) `$ntUser ^| Out-Null; if (`$LASTEXITCODE -ne 0) { throw 'Failed to load hive' }; `$loadedHere = `$true; Log ('Loaded hive for ' + `$profilePath) };" ^
 "    `$root = 'Registry::HKEY_USERS\' + `$sid;" ^
 "    `$usf = Join-Path `$root 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders';" ^
 "    `$sf = Join-Path `$root 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders';" ^
 "    `$map = @{ 'Desktop'='Desktop'; 'Personal'='Documents'; 'My Pictures'='Pictures'; 'My Video'='Videos'; 'My Music'='Music'; 'Favorites'='Favorites' };" ^
 "    foreach (`$entry in `$map.GetEnumerator()) { `$resolved = Join-Path `$profilePath `$entry.Value; EnsureValue `$usf `$entry.Key ('%USERPROFILE%\\' + `$entry.Value) ExpandString; EnsureValue `$sf `$entry.Key `$resolved String; Log ('Reset ' + `$entry.Key + ' -> ' + `$resolved) };" ^
 "    `$accounts = Join-Path `$root 'SOFTWARE\Microsoft\OneDrive\Accounts'; if (Test-Path `$accounts) { Get-ChildItem `$accounts -ErrorAction SilentlyContinue ^| ForEach-Object { RemoveValue `$_.PSPath 'KfmIsDoneSilentOptIn'; RemoveValue `$_.PSPath 'SilentBusinessConfigCompleted'; Log ('Cleared KFM flags under ' + `$_.PSChildName) } };" ^
 "    `$odRoot = Join-Path `$root 'SOFTWARE\Microsoft\OneDrive'; RemoveValue `$odRoot 'SilentBusinessConfigCompleted'; RemoveValue `$odRoot 'ClientEverSignedIn'; RemoveValue `$odRoot 'PersonalUnlinkedTimeStamp'; RemoveValue `$odRoot 'OneAuthUnrecoverableTimestamp';" ^
 "    `$resetPending = Join-Path `$profilePath 'AppData\Local\Microsoft\OneDrive\settings\ResetPending'; if (Test-Path `$resetPending) { Remove-Item -Path `$resetPending -Force -ErrorAction SilentlyContinue; Log ('Removed ResetPending for ' + `$profilePath) };" ^
 "  } catch { Log ('WARNING: Failed to process profile ' + `$profilePath + ': ' + `$_.Exception.Message) } finally { if (`$loadedHere) { & reg.exe unload ('HKU\' + `$sid) ^| Out-Null } }" ^
 "}"

if errorlevel 1 (
    echo [%DATE% %TIME%] WARNING: All-profile registry reset reported an error >> "%LOG_FILE%"
) else (
    echo [%DATE% %TIME%] All-profile registry reset completed >> "%LOG_FILE%"
)

REM ===== STEP 2: ONEDRIVE DETECTION =====
echo Step 2: Detecting OneDrive...
echo [%DATE% %TIME%] STEP 2: OneDrive detection >> "%LOG_FILE%"

set "ONEDRIVE_EXE="

if exist "%LOCALAPPDATA%\Microsoft\OneDrive\OneDrive.exe" (
    set "ONEDRIVE_EXE=%LOCALAPPDATA%\Microsoft\OneDrive\OneDrive.exe"
) else if exist "%ProgramFiles%\Microsoft OneDrive\OneDrive.exe" (
    set "ONEDRIVE_EXE=%ProgramFiles%\Microsoft OneDrive\OneDrive.exe"
) else if exist "%ProgramFiles(x86)%\Microsoft OneDrive\OneDrive.exe" (
    set "ONEDRIVE_EXE=%ProgramFiles(x86)%\Microsoft OneDrive\OneDrive.exe"
)

if not defined ONEDRIVE_EXE (
    echo OneDrive not found.
    echo [%DATE% %TIME%] ERROR: OneDrive not found >> "%LOG_FILE%"
    goto :ERROR_EXIT
)

echo [%DATE% %TIME%] OneDrive found at %ONEDRIVE_EXE% >> "%LOG_FILE%"

REM ===== STEP 2.5: ACTIVE USER SESSION REFRESH =====
echo Step 2.5: Refreshing Explorer and OneDrive for active user sessions...
echo [%DATE% %TIME%] STEP 2.5: Active session refresh >> "%LOG_FILE%"

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
 "$logFile = '%LOG_FILE%';" ^
 "function Log([string]`$m) { Add-Content -Path `$logFile -Value ('[' + (Get-Date -Format 'MM/dd/yyyy HH:mm:ss') + '] ' + `$m) };" ^
 "try {" ^
 "  `$lines = quser 2>`$null; `$users = @();" ^
 "  foreach (`$line in (`$lines ^| Select-Object -Skip 1)) { `$normalized = (`$line -replace '^>', '').Trim(); if (-not `$normalized) { continue }; `$parts = `$normalized -split '\s+'; if (`$parts.Length -ge 3 -and `$parts[2] -eq 'Active') { `$users += `$parts[0] } };" ^
 "  `$users = `$users ^| Select-Object -Unique; if (-not `$users) { Log 'INFO: No active sessions found for Explorer/OneDrive restart'; exit 0 };" ^
 "  foreach (`$username in `$users) {" ^
 "    `$taskName = 'OD_UserCtx_' + [guid]::NewGuid().ToString('N');" ^
 "    `$cmd = '$ErrorActionPreference = ''SilentlyContinue''; Stop-Process -Name explorer -Force; Start-Sleep -Seconds 2; Start-Process explorer.exe; Get-Process OneDrive ^| Stop-Process -Force; Get-Process OneDriveStandaloneUpdater ^| Stop-Process -Force; Start-Sleep -Seconds 8; `$odExe = @(\"$env:LOCALAPPDATA\\Microsoft\\OneDrive\\OneDrive.exe\",\"$env:ProgramFiles\\Microsoft OneDrive\\OneDrive.exe\",\"$env:ProgramFiles(x86)\\Microsoft OneDrive\\OneDrive.exe\") ^| Where-Object { Test-Path `$_ } ^| Select-Object -First 1; if (`$odExe) { Start-Process -FilePath `$odExe }';" ^
 "    `$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command ' + [Management.Automation.Language.CodeGeneration]::QuoteArgument(`$cmd));" ^
 "    `$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(5);" ^
 "    `$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 5);" ^
 "    `$principal = New-ScheduledTaskPrincipal -UserId `$username -LogonType Interactive -RunLevel Limited;" ^
 "    try { Register-ScheduledTask -TaskName `$taskName -Action `$action -Trigger `$trigger -Settings `$settings -Principal `$principal -Force ^| Out-Null; Start-ScheduledTask -TaskName `$taskName; Log ('Triggered Explorer/OneDrive restart for active user ' + `$username); Start-Sleep -Seconds 20 } catch { Log ('WARNING: Failed to restart Explorer/OneDrive for ' + `$username + ': ' + `$_.Exception.Message) } finally { Unregister-ScheduledTask -TaskName `$taskName -Confirm:`$false -ErrorAction SilentlyContinue }" ^
 "  }" ^
 "} catch { Log ('WARNING: Active session refresh failed: ' + `$_.Exception.Message); exit 1 }"

if errorlevel 1 (
    echo [%DATE% %TIME%] WARNING: Active session refresh reported an error >> "%LOG_FILE%"
) else (
    echo [%DATE% %TIME%] Active session refresh completed >> "%LOG_FILE%"
)

REM ===== STEP 3: SUMMARY =====
echo Step 3: Completed all-profile registry updates and active-user refresh.
echo [%DATE% %TIME%] STEP 3: Completed all-profile configuration flow >> "%LOG_FILE%"

REM ===== COMPLETION =====
echo.
echo ======================================================
echo       CONFIGURATION COMPLETED SUCCESSFULLY
echo ======================================================

echo [%DATE% %TIME%] Script completed successfully >> "%LOG_FILE%"
echo Logs saved to: %LOG_FILE%
exit /b 0

:ERROR_EXIT
echo [%DATE% %TIME%] Script failed >> "%LOG_FILE%"
exit /b 1
