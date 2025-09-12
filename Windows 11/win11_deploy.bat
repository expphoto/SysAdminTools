@echo off
setlocal

:main
REM Clear screen and show progress message
cls
echo.
echo  ===============================================
echo   System Compatibility Check in Progress
echo   DO NOT CLOSE THIS WINDOW
echo  ===============================================
echo.

REM Change window size to be less intrusive
MODE CON COLS=50 LINES=8

echo Downloading and running Windows 11 compatibility check...
echo.

REM Download PowerShell script
set "SCRIPT_URL=https://f001.backblazeb2.com/file/NinjaWebMedia/Windows11_Upgrade_Universal.ps1"
set "TEMP_SCRIPT=%TEMP%\win11_universal.ps1"

echo Downloading Windows 11 upgrade script...
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-WebRequest -Uri '%SCRIPT_URL%' -OutFile '%TEMP_SCRIPT%' -UseBasicParsing"

REM Check if download was successful and run with -Force parameter
if exist "%TEMP_SCRIPT%" (
    echo Running Windows 11 upgrade check with force mode...
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%TEMP_SCRIPT%" -Force
    del "%TEMP_SCRIPT%" >nul 2>&1
) else (
    echo Download failed
)

echo.
echo Check completed.
pause