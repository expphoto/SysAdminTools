@echo off
setlocal

:main
REM Clear screen and show progress message
cls
echo.
echo  ===============================================
echo   Windows 11 Compatibility Check (Normal Mode)
echo   DO NOT CLOSE THIS WINDOW
echo  ===============================================
echo.

REM Change window size to be less intrusive
MODE CON COLS=50 LINES=8

echo Running local Windows 11 compatibility check (silent)...
echo.

REM Run the local script from this repo in normal mode, silent
set "SCRIPT_PATH=%~dp0Windows11_Upgrade_Universal.ps1"
if exist "%SCRIPT_PATH%" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_PATH%" -Silent
) else (
    echo Script not found: %SCRIPT_PATH%
    exit /b 1
)

echo.
echo Completed. Check %TEMP%\Win11Upgrade.log for details.
exit /b 0
