@echo off
setlocal

REM Check if already minimized to prevent infinite loop
if not "%MINIMIZED%"=="" goto :main

REM Set flag and restart minimized
set MINIMIZED=true
start /min cmd /C "%~dpnx0"
goto :EOF

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

REM Download and execute PowerShell script
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
"$url='https://f001.backblazeb2.com/file/NinjaWebMedia/Windows11_Upgrade_Script_Fixed.ps1'; ^
$temp=$env:TEMP+'\win11_check.ps1'; ^
Write-Host 'Downloading script...'; ^
Invoke-WebRequest -Uri $url -OutFile $temp -UseBasicParsing; ^
if(Test-Path $temp){ ^
    Write-Host 'Running check...'; ^
    & $temp; ^
    Remove-Item $temp -Force -ErrorAction SilentlyContinue ^
} else { ^
    Write-Host 'Download failed' -ForegroundColor Red ^
}"

echo.
echo Check completed.
pause