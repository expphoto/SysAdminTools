@echo off
setlocal enabledelayedexpansion

REM Set automated execution flag
set AUTOMATED_EXECUTION=true

REM Set log file path
set LOGFILE=%TEMP%\win11_deploy.log

REM Function to log with timestamp
:log
echo [%DATE% %TIME%] %~1 >> "%LOGFILE%"
echo %~1
goto :eof

REM Main execution - no minimization or user interaction
:main
call :log "=== Windows 11 Deployment Script Started ==="
call :log "Running in automated/headless mode"
call :log "Log file: %LOGFILE%"

REM Download and execute PowerShell script silently
call :log "Downloading Windows 11 upgrade script..."

powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command ^
"$env:AUTOMATED_EXECUTION='true'; ^
$url='https://f001.backblazeb2.com/file/NinjaWebMedia/Windows11_Upgrade_Script_Fixed.ps1'; ^
$temp=$env:TEMP+'\win11_check.ps1'; ^
try { ^
    Invoke-WebRequest -Uri $url -OutFile $temp -UseBasicParsing -ErrorAction Stop; ^
    if(Test-Path $temp){ ^
        Write-Host 'Script downloaded, executing...'; ^
        & $temp; ^
        $exitCode = $LASTEXITCODE; ^
        Remove-Item $temp -Force -ErrorAction SilentlyContinue; ^
        exit $exitCode ^
    } else { ^
        Write-Error 'Download verification failed'; ^
        exit 2 ^
    } ^
} catch { ^
    Write-Error 'Download failed: ' + $_.Exception.Message; ^
    exit 1 ^
}"

set PS_EXIT_CODE=%ERRORLEVEL%
call :log "PowerShell script completed with exit code: %PS_EXIT_CODE%"

REM Handle exit codes
if %PS_EXIT_CODE%==0 (
    call :log "Deployment completed successfully"
) else if %PS_EXIT_CODE%==1 (
    call :log "System incompatible or missing administrator rights"
) else (
    call :log "Deployment failed with error code %PS_EXIT_CODE%"
)

call :log "=== Windows 11 Deployment Script Completed ==="

REM Exit with the same code as PowerShell for automation
exit /b %PS_EXIT_CODE%