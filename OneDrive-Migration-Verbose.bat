@echo off
REM Standalone OneDrive Migration Script for ScreenConnect
REM Verbose version with comprehensive logging and OneDrive detection

echo ======================================================
echo   OneDrive Migration Tool - Verbose Version
echo ======================================================
echo Computer: %COMPUTERNAME%
echo User: %USERNAME%
echo Date/Time: %DATE% %TIME%
echo ======================================================

REM Simple log setup
set "LOG_DIR=%PUBLIC%\Documents\OneDriveMigration"
set "LOG_FILE=%LOG_DIR%\OneDriveMigration_%COMPUTERNAME%_%USERNAME%.log"

REM Create log directory
if not exist "%LOG_DIR%" (
    mkdir "%LOG_DIR%" 2>nul
    if errorlevel 1 (
        set "LOG_DIR=%TEMP%"
        set "LOG_FILE=%LOG_DIR%\OneDriveMigration_%COMPUTERNAME%_%USERNAME%.log"
        echo Using temp directory for logs: %LOG_DIR%
    )
)

echo Log file: %LOG_FILE%
echo.

REM Start comprehensive logging
echo ============================================================ > "%LOG_FILE%"
echo OneDrive Migration Script - Verbose Log >> "%LOG_FILE%"
echo ============================================================ >> "%LOG_FILE%"
echo [%DATE% %TIME%] OneDrive Migration Started >> "%LOG_FILE%"
echo [%DATE% %TIME%] Computer: %COMPUTERNAME%, User: %USERNAME% >> "%LOG_FILE%"
echo [%DATE% %TIME%] Current working directory: %CD% >> "%LOG_FILE%"
echo [%DATE% %TIME%] User Profile: %USERPROFILE% >> "%LOG_FILE%"
echo [%DATE% %TIME%] Local AppData: %LOCALAPPDATA% >> "%LOG_FILE%"
echo [%DATE% %TIME%] Home Share: %HOMESHARE% >> "%LOG_FILE%"
echo [%DATE% %TIME%] Home Path: %HOMEPATH% >> "%LOG_FILE%"
echo. >> "%LOG_FILE%"

REM ===== STEP 1: FOLDER REDIRECTION CLEANUP =====
echo Step 1: Cleaning up folder redirections...
echo [%DATE% %TIME%] ===== STEP 1: FOLDER REDIRECTION CLEANUP ===== >> "%LOG_FILE%"

REM Check current registry values before changing them
echo   - Checking current folder redirection settings...
echo [%DATE% %TIME%] Checking current User Shell Folders registry values: >> "%LOG_FILE%"

for /f "tokens=1,2,*" %%a in ('reg query "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" 2^>nul') do (
    if not "%%c"=="" (
        echo [%DATE% %TIME%] Current %%a = %%c >> "%LOG_FILE%"
    )
)

echo [%DATE% %TIME%] Checking current Shell Folders registry values: >> "%LOG_FILE%"
for /f "tokens=1,2,*" %%a in ('reg query "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders" 2^>nul') do (
    if not "%%c"=="" (
        echo [%DATE% %TIME%] Current %%a = %%c >> "%LOG_FILE%"
    )
)

REM Reset User Shell Folders
echo   - Resetting User Shell Folders...
echo [%DATE% %TIME%] Resetting User Shell Folders to local paths: >> "%LOG_FILE%"

echo     * Desktop folder redirection
reg add "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" /v Desktop /t REG_EXPAND_SZ /d "%%USERPROFILE%%\Desktop" /f >nul 2>&1
if %errorlevel% equ 0 (
    echo [%DATE% %TIME%] SUCCESS: Reset Desktop from redirected path to %%USERPROFILE%%\Desktop >> "%LOG_FILE%"
) else (
    echo [%DATE% %TIME%] ERROR: Failed to reset Desktop folder redirection >> "%LOG_FILE%"
)

echo     * Documents folder redirection
reg add "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" /v Personal /t REG_EXPAND_SZ /d "%%USERPROFILE%%\Documents" /f >nul 2>&1
if %errorlevel% equ 0 (
    echo [%DATE% %TIME%] SUCCESS: Reset Personal/Documents from redirected path to %%USERPROFILE%%\Documents >> "%LOG_FILE%"
) else (
    echo [%DATE% %TIME%] ERROR: Failed to reset Documents folder redirection >> "%LOG_FILE%"
)

echo     * Pictures folder redirection
reg add "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" /v "My Pictures" /t REG_EXPAND_SZ /d "%%USERPROFILE%%\Pictures" /f >nul 2>&1
if %errorlevel% equ 0 (
    echo [%DATE% %TIME%] SUCCESS: Reset My Pictures from redirected path to %%USERPROFILE%%\Pictures >> "%LOG_FILE%"
) else (
    echo [%DATE% %TIME%] ERROR: Failed to reset Pictures folder redirection >> "%LOG_FILE%"
)

echo     * Videos folder redirection
reg add "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" /v "My Video" /t REG_EXPAND_SZ /d "%%USERPROFILE%%\Videos" /f >nul 2>&1
if %errorlevel% equ 0 (
    echo [%DATE% %TIME%] SUCCESS: Reset My Video from redirected path to %%USERPROFILE%%\Videos >> "%LOG_FILE%"
) else (
    echo [%DATE% %TIME%] ERROR: Failed to reset Videos folder redirection >> "%LOG_FILE%"
)

echo     * Music folder redirection
reg add "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" /v "My Music" /t REG_EXPAND_SZ /d "%%USERPROFILE%%\Music" /f >nul 2>&1
if %errorlevel% equ 0 (
    echo [%DATE% %TIME%] SUCCESS: Reset My Music from redirected path to %%USERPROFILE%%\Music >> "%LOG_FILE%"
) else (
    echo [%DATE% %TIME%] ERROR: Failed to reset Music folder redirection >> "%LOG_FILE%"
)

echo     * Favorites folder redirection
reg add "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" /v Favorites /t REG_EXPAND_SZ /d "%%USERPROFILE%%\Favorites" /f >nul 2>&1
if %errorlevel% equ 0 (
    echo [%DATE% %TIME%] SUCCESS: Reset Favorites from redirected path to %%USERPROFILE%%\Favorites >> "%LOG_FILE%"
) else (
    echo [%DATE% %TIME%] ERROR: Failed to reset Favorites folder redirection >> "%LOG_FILE%"
)

REM Reset Shell Folders (not just User Shell Folders)
echo   - Resetting Shell Folders...
echo [%DATE% %TIME%] Resetting Shell Folders to local paths: >> "%LOG_FILE%"

reg add "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders" /v Desktop /t REG_SZ /d "%USERPROFILE%\Desktop" /f >nul 2>&1
if %errorlevel% equ 0 (
    echo [%DATE% %TIME%] SUCCESS: Reset Shell Folders Desktop to %USERPROFILE%\Desktop >> "%LOG_FILE%"
) else (
    echo [%DATE% %TIME%] ERROR: Failed to reset Shell Folders Desktop >> "%LOG_FILE%"
)

reg add "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders" /v Personal /t REG_SZ /d "%USERPROFILE%\Documents" /f >nul 2>&1
if %errorlevel% equ 0 (
    echo [%DATE% %TIME%] SUCCESS: Reset Shell Folders Personal to %USERPROFILE%\Documents >> "%LOG_FILE%"
) else (
    echo [%DATE% %TIME%] ERROR: Failed to reset Shell Folders Personal >> "%LOG_FILE%"
)

reg add "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders" /v "My Pictures" /t REG_SZ /d "%USERPROFILE%\Pictures" /f >nul 2>&1
if %errorlevel% equ 0 (
    echo [%DATE% %TIME%] SUCCESS: Reset Shell Folders My Pictures to %USERPROFILE%\Pictures >> "%LOG_FILE%"
) else (
    echo [%DATE% %TIME%] ERROR: Failed to reset Shell Folders My Pictures >> "%LOG_FILE%"
)

reg add "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders" /v "My Video" /t REG_SZ /d "%USERPROFILE%\Videos" /f >nul 2>&1
if %errorlevel% equ 0 (
    echo [%DATE% %TIME%] SUCCESS: Reset Shell Folders My Video to %USERPROFILE%\Videos >> "%LOG_FILE%"
) else (
    echo [%DATE% %TIME%] ERROR: Failed to reset Shell Folders My Video >> "%LOG_FILE%"
)

reg add "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders" /v "My Music" /t REG_SZ /d "%USERPROFILE%\Music" /f >nul 2>&1
if %errorlevel% equ 0 (
    echo [%DATE% %TIME%] SUCCESS: Reset Shell Folders My Music to %USERPROFILE%\Music >> "%LOG_FILE%"
) else (
    echo [%DATE% %TIME%] ERROR: Failed to reset Shell Folders My Music >> "%LOG_FILE%"
)

reg add "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders" /v Favorites /t REG_SZ /d "%USERPROFILE%\Favorites" /f >nul 2>&1
if %errorlevel% equ 0 (
    echo [%DATE% %TIME%] SUCCESS: Reset Shell Folders Favorites to %USERPROFILE%\Favorites >> "%LOG_FILE%"
) else (
    echo [%DATE% %TIME%] ERROR: Failed to reset Shell Folders Favorites >> "%LOG_FILE%"
)

echo   - Folder redirections reset completed
echo [%DATE% %TIME%] Folder redirection cleanup completed >> "%LOG_FILE%"

REM Refresh Explorer
echo   - Refreshing Explorer shell
echo [%DATE% %TIME%] Refreshing Explorer shell to apply registry changes >> "%LOG_FILE%"
tasklist | find /i "explorer.exe" >nul
if %errorlevel% equ 0 (
    echo [%DATE% %TIME%] Explorer is running, killing and restarting >> "%LOG_FILE%"
    taskkill /f /im explorer.exe >nul 2>&1
    timeout /t 2 /nobreak >nul
    start explorer.exe
    echo [%DATE% %TIME%] Explorer restarted successfully >> "%LOG_FILE%"
) else (
    echo [%DATE% %TIME%] Explorer was not running, starting it >> "%LOG_FILE%"
    start explorer.exe
)

REM ===== STEP 2: COMPREHENSIVE ONEDRIVE DETECTION =====
echo.
echo Step 2: Comprehensive OneDrive detection...
echo [%DATE% %TIME%] ===== STEP 2: COMPREHENSIVE ONEDRIVE DETECTION ===== >> "%LOG_FILE%"

REM Check multiple OneDrive locations
set "ONEDRIVE_FOUND=0"
set "ONEDRIVE_EXE="

echo   - Checking OneDrive installation locations...
echo [%DATE% %TIME%] Checking multiple OneDrive installation locations: >> "%LOG_FILE%"

REM Location 1: User LocalAppData
set "TEST_PATH=%LOCALAPPDATA%\Microsoft\OneDrive\OneDrive.exe"
echo [%DATE% %TIME%] Checking: %TEST_PATH% >> "%LOG_FILE%"
if exist "%TEST_PATH%" (
    set "ONEDRIVE_FOUND=1"
    set "ONEDRIVE_EXE=%TEST_PATH%"
    echo   - Found OneDrive at: %TEST_PATH%
    echo [%DATE% %TIME%] SUCCESS: OneDrive found at %TEST_PATH% >> "%LOG_FILE%"
) else (
    echo [%DATE% %TIME%] Not found at %TEST_PATH% >> "%LOG_FILE%"
)

REM Location 2: Program Files
if %ONEDRIVE_FOUND% equ 0 (
    set "TEST_PATH=%ProgramFiles%\Microsoft OneDrive\OneDrive.exe"
    echo [%DATE% %TIME%] Checking: %TEST_PATH% >> "%LOG_FILE%"
    if exist "%TEST_PATH%" (
        set "ONEDRIVE_FOUND=1"
        set "ONEDRIVE_EXE=%TEST_PATH%"
        echo   - Found OneDrive at: %TEST_PATH%
        echo [%DATE% %TIME%] SUCCESS: OneDrive found at %TEST_PATH% >> "%LOG_FILE%"
    ) else (
        echo [%DATE% %TIME%] Not found at %TEST_PATH% >> "%LOG_FILE%"
    )
)

REM Location 3: Program Files (x86)
if %ONEDRIVE_FOUND% equ 0 (
    set "TEST_PATH=%ProgramFiles(x86)%\Microsoft OneDrive\OneDrive.exe"
    echo [%DATE% %TIME%] Checking: %TEST_PATH% >> "%LOG_FILE%"
    if exist "%TEST_PATH%" (
        set "ONEDRIVE_FOUND=1"
        set "ONEDRIVE_EXE=%TEST_PATH%"
        echo   - Found OneDrive at: %TEST_PATH%
        echo [%DATE% %TIME%] SUCCESS: OneDrive found at %TEST_PATH% >> "%LOG_FILE%"
    ) else (
        echo [%DATE% %TIME%] Not found at %TEST_PATH% >> "%LOG_FILE%"
    )
)

REM Location 4: Check if running and get path from process
if %ONEDRIVE_FOUND% equ 0 (
    echo [%DATE% %TIME%] Checking if OneDrive process is running to get path >> "%LOG_FILE%"
    for /f "tokens=2" %%i in ('tasklist /fi "imagename eq OneDrive.exe" /fo csv /nh 2^>nul') do (
        if not "%%i"=="INFO:" (
            echo [%DATE% %TIME%] OneDrive process found running >> "%LOG_FILE%"
            REM Try to get executable path from WMIC
            for /f "skip=1 tokens=*" %%j in ('wmic process where "name='OneDrive.exe'" get ExecutablePath /format:list 2^>nul ^| find "="') do (
                for /f "tokens=2 delims==" %%k in ("%%j") do (
                    if exist "%%k" (
                        set "ONEDRIVE_FOUND=1"
                        set "ONEDRIVE_EXE=%%k"
                        echo   - Found running OneDrive at: %%k
                        echo [%DATE% %TIME%] SUCCESS: Found running OneDrive at %%k >> "%LOG_FILE%"
                        goto :OneDriveFound
                    )
                )
            )
        )
    )
)

:OneDriveFound
if %ONEDRIVE_FOUND% equ 0 (
    echo   ERROR: OneDrive not found in any standard location
    echo [%DATE% %TIME%] ERROR: OneDrive executable not found in any location >> "%LOG_FILE%"
    echo   Please install OneDrive before running this script
    goto :ERROR_EXIT
)

echo   - OneDrive installation confirmed at: %ONEDRIVE_EXE%
echo [%DATE% %TIME%] OneDrive installation confirmed at: %ONEDRIVE_EXE% >> "%LOG_FILE%"

REM ===== STEP 3: ONEDRIVE PROCESS MANAGEMENT =====
echo.
echo Step 3: Managing OneDrive process...
echo [%DATE% %TIME%] ===== STEP 3: ONEDRIVE PROCESS MANAGEMENT ===== >> "%LOG_FILE%"

REM Check if OneDrive is already running
echo [%DATE% %TIME%] Checking if OneDrive process is currently running >> "%LOG_FILE%"
tasklist /fi "imagename eq OneDrive.exe" 2>nul | find /i "OneDrive.exe" >nul
if %errorlevel% equ 0 (
    echo   - OneDrive is already running
    echo [%DATE% %TIME%] OneDrive process is already running >> "%LOG_FILE%"
    
    REM Get process details
    for /f "tokens=2,5" %%a in ('tasklist /fi "imagename eq OneDrive.exe" /fo table /nh 2^>nul') do (
        echo [%DATE% %TIME%] OneDrive PID: %%a, Memory: %%b >> "%LOG_FILE%"
    )
) else (
    echo   - Starting OneDrive process...
    echo [%DATE% %TIME%] OneDrive not running, starting process >> "%LOG_FILE%"
    start "" "%ONEDRIVE_EXE%"
    echo [%DATE% %TIME%] OneDrive start command executed >> "%LOG_FILE%"
    timeout /t 10 /nobreak >nul
    
    REM Verify it started
    tasklist /fi "imagename eq OneDrive.exe" 2>nul | find /i "OneDrive.exe" >nul
    if %errorlevel% equ 0 (
        echo   - OneDrive started successfully
        echo [%DATE% %TIME%] OneDrive process started successfully >> "%LOG_FILE%"
        for /f "tokens=2,5" %%a in ('tasklist /fi "imagename eq OneDrive.exe" /fo table /nh 2^>nul') do (
            echo [%DATE% %TIME%] New OneDrive PID: %%a, Memory: %%b >> "%LOG_FILE%"
        )
    ) else (
        echo   - WARNING: OneDrive may not have started properly
        echo [%DATE% %TIME%] WARNING: OneDrive process start verification failed >> "%LOG_FILE%"
    )
)

REM ===== STEP 4: COMPREHENSIVE DATA MIGRATION =====
echo.
echo Step 4: Comprehensive data migration from H: drive...
echo [%DATE% %TIME%] ===== STEP 4: COMPREHENSIVE DATA MIGRATION ===== >> "%LOG_FILE%"

REM Check multiple data source locations
set "DATA_SOURCE_FOUND=0"
set "SOURCE_PATH="

REM Check H: drive first
echo [%DATE% %TIME%] Checking for H: drive >> "%LOG_FILE%"
if exist "H:\" (
    set "DATA_SOURCE_FOUND=1"
    set "SOURCE_PATH=H:\"
    echo   - Found H: drive at H:\
    echo [%DATE% %TIME%] H: drive detected at H:\ >> "%LOG_FILE%"
    
    REM Log what's in the H drive
    echo [%DATE% %TIME%] Contents of H: drive: >> "%LOG_FILE%"
    dir "H:\" /b >> "%LOG_FILE%" 2>&1
) else (
    echo [%DATE% %TIME%] H: drive not found >> "%LOG_FILE%"
)

REM Check network home path if H: not found
if %DATA_SOURCE_FOUND% equ 0 (
    if defined HOMESHARE if defined HOMEPATH (
        set "NETWORK_HOME=%HOMESHARE%%HOMEPATH%"
        echo [%DATE% %TIME%] Checking network home path: !NETWORK_HOME! >> "%LOG_FILE%"
        if exist "!NETWORK_HOME!" (
            set "DATA_SOURCE_FOUND=1"
            set "SOURCE_PATH=!NETWORK_HOME!"
            echo   - Found network home at: !NETWORK_HOME!
            echo [%DATE% %TIME%] Network home path detected: !NETWORK_HOME! >> "%LOG_FILE%"
            
            REM Log what's in the network home
            echo [%DATE% %TIME%] Contents of network home: >> "%LOG_FILE%"
            dir "!NETWORK_HOME!" /b >> "%LOG_FILE%" 2>&1
        ) else (
            echo [%DATE% %TIME%] Network home path not accessible: !NETWORK_HOME! >> "%LOG_FILE%"
        )
    ) else (
        echo [%DATE% %TIME%] No HOMESHARE or HOMEPATH environment variables >> "%LOG_FILE%"
    )
)

if %DATA_SOURCE_FOUND% equ 0 (
    echo   - No data source found, skipping data migration
    echo [%DATE% %TIME%] No data source found, skipping migration >> "%LOG_FILE%"
    goto :STEP5
)

echo   - Found source data at: %SOURCE_PATH%
echo [%DATE% %TIME%] Source data confirmed at: %SOURCE_PATH% >> "%LOG_FILE%"

REM Create local folders if they don't exist
echo   - Creating local destination folders...
echo [%DATE% %TIME%] Creating local destination folders: >> "%LOG_FILE%"

if not exist "%USERPROFILE%\Documents" (
    mkdir "%USERPROFILE%\Documents" >nul 2>&1
    echo [%DATE% %TIME%] Created Documents folder >> "%LOG_FILE%"
) else (
    echo [%DATE% %TIME%] Documents folder already exists >> "%LOG_FILE%"
)

if not exist "%USERPROFILE%\Pictures" (
    mkdir "%USERPROFILE%\Pictures" >nul 2>&1
    echo [%DATE% %TIME%] Created Pictures folder >> "%LOG_FILE%"
) else (
    echo [%DATE% %TIME%] Pictures folder already exists >> "%LOG_FILE%"
)

if not exist "%USERPROFILE%\Videos" (
    mkdir "%USERPROFILE%\Videos" >nul 2>&1
    echo [%DATE% %TIME%] Created Videos folder >> "%LOG_FILE%"
) else (
    echo [%DATE% %TIME%] Videos folder already exists >> "%LOG_FILE%"
)

if not exist "%USERPROFILE%\Music" (
    mkdir "%USERPROFILE%\Music" >nul 2>&1
    echo [%DATE% %TIME%] Created Music folder >> "%LOG_FILE%"
) else (
    echo [%DATE% %TIME%] Music folder already exists >> "%LOG_FILE%"
)

REM Robocopy with verbose logging - Main files to Documents
echo   - Copying main files to Documents (excluding special folders)...
echo [%DATE% %TIME%] Starting robocopy: Main files from "%SOURCE_PATH%" to "%USERPROFILE%\Documents" >> "%LOG_FILE%"
echo [%DATE% %TIME%] Robocopy command: robocopy "%SOURCE_PATH%" "%USERPROFILE%\Documents" *.* /E /Z /V /R:3 /W:5 /XD "Pictures" "Videos" "Music" /TEE /LOG+:"%LOG_DIR%\robocopy_main.log" >> "%LOG_FILE%"

robocopy "%SOURCE_PATH%" "%USERPROFILE%\Documents" *.* /E /Z /V /R:3 /W:5 /XD "Pictures" "Videos" "Music" /TEE /LOG+:"%LOG_DIR%\robocopy_main.log"
set "ROBOCOPY_EXIT=%errorlevel%"
echo [%DATE% %TIME%] Robocopy main files exit code: %ROBOCOPY_EXIT% >> "%LOG_FILE%"

if %ROBOCOPY_EXIT% lss 8 (
    echo [%DATE% %TIME%] SUCCESS: Main files copied successfully >> "%LOG_FILE%"
) else (
    echo [%DATE% %TIME%] WARNING: Main files copy completed with errors (exit code %ROBOCOPY_EXIT%) >> "%LOG_FILE%"
)

REM Copy specific folders if they exist
if exist "%SOURCE_PATH%\Pictures" (
    echo   - Copying Pictures folder...
    echo [%DATE% %TIME%] Starting robocopy: Pictures from "%SOURCE_PATH%\Pictures" to "%USERPROFILE%\Pictures" >> "%LOG_FILE%"
    robocopy "%SOURCE_PATH%\Pictures" "%USERPROFILE%\Pictures" *.* /E /Z /V /R:3 /W:5 /TEE /LOG+:"%LOG_DIR%\robocopy_pictures.log"
    set "ROBOCOPY_EXIT=%errorlevel%"
    echo [%DATE% %TIME%] Robocopy Pictures exit code: %ROBOCOPY_EXIT% >> "%LOG_FILE%"
    if %ROBOCOPY_EXIT% lss 8 (
        echo [%DATE% %TIME%] SUCCESS: Pictures copied successfully >> "%LOG_FILE%"
    ) else (
        echo [%DATE% %TIME%] WARNING: Pictures copy completed with errors (exit code %ROBOCOPY_EXIT%) >> "%LOG_FILE%"
    )
) else (
    echo [%DATE% %TIME%] No Pictures folder found in source >> "%LOG_FILE%"
)

if exist "%SOURCE_PATH%\Videos" (
    echo   - Copying Videos folder...
    echo [%DATE% %TIME%] Starting robocopy: Videos from "%SOURCE_PATH%\Videos" to "%USERPROFILE%\Videos" >> "%LOG_FILE%"
    robocopy "%SOURCE_PATH%\Videos" "%USERPROFILE%\Videos" *.* /E /Z /V /R:3 /W:5 /TEE /LOG+:"%LOG_DIR%\robocopy_videos.log"
    set "ROBOCOPY_EXIT=%errorlevel%"
    echo [%DATE% %TIME%] Robocopy Videos exit code: %ROBOCOPY_EXIT% >> "%LOG_FILE%"
    if %ROBOCOPY_EXIT% lss 8 (
        echo [%DATE% %TIME%] SUCCESS: Videos copied successfully >> "%LOG_FILE%"
    ) else (
        echo [%DATE% %TIME%] WARNING: Videos copy completed with errors (exit code %ROBOCOPY_EXIT%) >> "%LOG_FILE%"
    )
) else (
    echo [%DATE% %TIME%] No Videos folder found in source >> "%LOG_FILE%"
)

if exist "%SOURCE_PATH%\Music" (
    echo   - Copying Music folder...
    echo [%DATE% %TIME%] Starting robocopy: Music from "%SOURCE_PATH%\Music" to "%USERPROFILE%\Music" >> "%LOG_FILE%"
    robocopy "%SOURCE_PATH%\Music" "%USERPROFILE%\Music" *.* /E /Z /V /R:3 /W:5 /TEE /LOG+:"%LOG_DIR%\robocopy_music.log"
    set "ROBOCOPY_EXIT=%errorlevel%"
    echo [%DATE% %TIME%] Robocopy Music exit code: %ROBOCOPY_EXIT% >> "%LOG_FILE%"
    if %ROBOCOPY_EXIT% lss 8 (
        echo [%DATE% %TIME%] SUCCESS: Music copied successfully >> "%LOG_FILE%"
    ) else (
        echo [%DATE% %TIME%] WARNING: Music copy completed with errors (exit code %ROBOCOPY_EXIT%) >> "%LOG_FILE%"
    )
) else (
    echo [%DATE% %TIME%] No Music folder found in source >> "%LOG_FILE%"
)

echo [%DATE% %TIME%] All data migration operations completed >> "%LOG_FILE%"

REM ===== STEP 5: FINAL ONEDRIVE RESTART =====
:STEP5
echo.
echo Step 5: Final OneDrive restart...
echo [%DATE% %TIME%] ===== STEP 5: FINAL ONEDRIVE RESTART ===== >> "%LOG_FILE%"

REM Stop OneDrive gracefully
echo [%DATE% %TIME%] Stopping OneDrive processes >> "%LOG_FILE%"
tasklist /fi "imagename eq OneDrive.exe" 2>nul | find /i "OneDrive.exe" >nul
if %errorlevel% equ 0 (
    echo [%DATE% %TIME%] OneDrive is running, stopping it >> "%LOG_FILE%"
    taskkill /im OneDrive.exe /f >nul 2>&1
    if %errorlevel% equ 0 (
        echo [%DATE% %TIME%] OneDrive stopped successfully >> "%LOG_FILE%"
    ) else (
        echo [%DATE% %TIME%] WARNING: Failed to stop OneDrive process >> "%LOG_FILE%"
    )
) else (
    echo [%DATE% %TIME%] OneDrive was not running >> "%LOG_FILE%"
)

timeout /t 5 /nobreak >nul

REM Start OneDrive again
echo   - Restarting OneDrive to apply changes...
echo [%DATE% %TIME%] Restarting OneDrive from: %ONEDRIVE_EXE% >> "%LOG_FILE%"
start "" "%ONEDRIVE_EXE%"
timeout /t 5 /nobreak >nul

REM Verify restart
tasklist /fi "imagename eq OneDrive.exe" 2>nul | find /i "OneDrive.exe" >nul
if %errorlevel% equ 0 (
    echo [%DATE% %TIME%] OneDrive restarted successfully >> "%LOG_FILE%"
    for /f "tokens=2,5" %%a in ('tasklist /fi "imagename eq OneDrive.exe" /fo table /nh 2^>nul') do (
        echo [%DATE% %TIME%] Restarted OneDrive PID: %%a, Memory: %%b >> "%LOG_FILE%"
    )
) else (
    echo [%DATE% %TIME%] WARNING: OneDrive restart verification failed >> "%LOG_FILE%"
)

REM ===== COMPLETION =====
echo.
echo ======================================================
echo             MIGRATION COMPLETED SUCCESSFULLY!
echo ======================================================
echo [%DATE% %TIME%] ============================================================ >> "%LOG_FILE%"
echo [%DATE% %TIME%] MIGRATION COMPLETED SUCCESSFULLY >> "%LOG_FILE%"
echo [%DATE% %TIME%] ============================================================ >> "%LOG_FILE%"

echo.
echo NEXT STEPS FOR USER:
echo 1. Sign into OneDrive if not already signed in
echo 2. Verify Known Folder Move is working
echo 3. Wait for initial sync to complete
echo 4. Verify all data is accessible through OneDrive

echo [%DATE% %TIME%] Next steps for user: >> "%LOG_FILE%"
echo [%DATE% %TIME%] 1. Sign into OneDrive if not already signed in >> "%LOG_FILE%"
echo [%DATE% %TIME%] 2. Verify Known Folder Move is working >> "%LOG_FILE%"
echo [%DATE% %TIME%] 3. Wait for initial sync to complete >> "%LOG_FILE%"
echo [%DATE% %TIME%] 4. Verify all data is accessible through OneDrive >> "%LOG_FILE%"

echo.
echo Log files saved to: %LOG_DIR%
echo Main log: %LOG_FILE%
echo Robocopy logs: %LOG_DIR%\robocopy_*.log

echo [%DATE% %TIME%] All log files saved to: %LOG_DIR% >> "%LOG_FILE%"

REM Open log folder
choice /C YN /M "Open log folder for review" /T 10 /D N
if %errorlevel% equ 1 (
    explorer "%LOG_DIR%"
)

echo.
echo Press any key to exit...
pause >nul
exit /b 0

REM ===== ERROR EXIT =====
:ERROR_EXIT
echo.
echo ======================================================
echo              MIGRATION FAILED
echo ======================================================
echo [%DATE% %TIME%] ============================================================ >> "%LOG_FILE%"
echo [%DATE% %TIME%] MIGRATION FAILED >> "%LOG_FILE%"
echo [%DATE% %TIME%] ============================================================ >> "%LOG_FILE%"
echo Check the log file for details: %LOG_FILE%
echo.
echo Press any key to exit...
pause >nul
exit /b 1