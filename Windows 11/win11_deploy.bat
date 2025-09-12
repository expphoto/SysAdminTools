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

echo Running local Windows 11 upgrade (force, silent)...
echo.

REM Run the local script from this repo, force + silent, no UI popups
set "SCRIPT_PATH=%~dp0Windows11_Upgrade_Universal.ps1"
if exist "%SCRIPT_PATH%" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_PATH%" -Force -Silent
) else (
    echo Script not found: %SCRIPT_PATH%
    exit /b 1
)

echo.
echo Started. Check %TEMP%\Win11Upgrade.log for progress.
exit /b 0
