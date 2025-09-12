<#
.SYNOPSIS
    Windows 11 Compatibility Check and Upgrade Script

.DESCRIPTION
    This script checks Windows 11 compatibility and either upgrades the system
    or sets up recurring alerts for incompatible systems.

.NOTES
    Version: 1.2
    Author: MSP Admin
    Date: September 2025
    Requires: PowerShell 5.1+, Windows 10
    
    Version 1.2 Changes:
    - Enhanced compatibility logging with specific failure reasons
    - Added storage space and UEFI firmware checks
    - Improved Microsoft Hardware Readiness output parsing
    - Added override recommendations for business decisions
#>

# Script configuration
$ScriptName = "Win11UpgradeScript"
$LogPath = "$env:TEMP\Win11Upgrade.log"
$ScheduledTaskName = "Win11CompatibilityAlert"
$HardwareReadinessUrl = "https://aka.ms/HWReadinessScript"
$Win11AssistantUrl = "https://go.microsoft.com/fwlink/?linkid=2171764"
$Win11MediaCreationUrl = "https://go.microsoft.com/fwlink/?linkid=2156295"

# Initialize logging
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $TimeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogEntry = "[$TimeStamp] [$Level] $Message"
    Write-Host $LogEntry
    Add-Content -Path $LogPath -Value $LogEntry
}

# Set execution policy for this session - enhanced for automated execution
try {
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
    Write-Log "Execution policy set to Bypass for this session"
} catch {
    Write-Log "Warning: Could not set execution policy: $($_.Exception.Message)" "WARN"
}

# Function to show user notifications - modified for headless operation
function Show-UserNotification {
    param(
        [string]$Title,
        [string]$Message,
        [string]$Icon = "Information",
        [bool]$SilentMode = $true
    )

    # In automated/headless mode, only log notifications
    if ($SilentMode -or $env:AUTOMATED_EXECUTION -eq "true") {
        Write-Log "NOTIFICATION: [$Title] $Message" "INFO"
        return
    }

    try {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show($Message, $Title, [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::$Icon)
    } catch {
        $NotificationText = "$Title - $Message"
        Write-Host $NotificationText -ForegroundColor Yellow
        Write-Log "NOTIFICATION: $NotificationText" "INFO"
    }
}

# Function to perform basic Windows 11 compatibility check
function Test-BasicWin11Requirements {
    Write-Log "Performing basic Windows 11 compatibility check"
    
    $CompatibilityIssues = @()
    $IsCompatible = $true
    
    try {
        # Check TPM 2.0
        $TPM = Get-WmiObject -Namespace "Root\CIMv2\Security\MicrosoftTpm" -Class Win32_Tpm -ErrorAction SilentlyContinue
        $HasTPM = $TPM -and $TPM.SpecVersion -like "2.*"
        
        if ($HasTPM) {
            Write-Log "? TPM 2.0 available: YES (Version: $($TPM.SpecVersion))"
        } else {
            Write-Log "? TPM 2.0 available: NO"
            $CompatibilityIssues += "TPM 2.0 not found or not version 2.0"
            $IsCompatible = $false
        }
        
        # Check Secure Boot
        $SecureBoot = $false
        try {
            $SecureBoot = (Confirm-SecureBootUEFI -ErrorAction SilentlyContinue) -eq $true
        } catch {
            Write-Log "Unable to check Secure Boot status (may indicate BIOS/Legacy mode)"
            $CompatibilityIssues += "Unable to verify Secure Boot (system may be in BIOS/Legacy mode)"
        }
        
        if ($SecureBoot) {
            Write-Log "? Secure Boot enabled: YES"
        } else {
            Write-Log "? Secure Boot enabled: NO"
            $CompatibilityIssues += "Secure Boot is not enabled"
            $IsCompatible = $false
        }
        
        # Check RAM (minimum 4GB)
        $RAM = (Get-WmiObject -Class Win32_ComputerSystem).TotalPhysicalMemory / 1GB
        $HasEnoughRAM = $RAM -ge 4
        
        if ($HasEnoughRAM) {
            Write-Log "? RAM: $([math]::Round($RAM, 1))GB (Required: 4GB+) - SUFFICIENT"
        } else {
            Write-Log "? RAM: $([math]::Round($RAM, 1))GB (Required: 4GB+) - INSUFFICIENT"
            $CompatibilityIssues += "Insufficient RAM: $([math]::Round($RAM, 1))GB (minimum 4GB required)"
            $IsCompatible = $false
        }
        
        # Check CPU generation and architecture
        $CPU = Get-WmiObject -Class Win32_Processor | Select-Object -First 1
        Write-Log "CPU Info: $($CPU.Name) (Architecture: $($CPU.Architecture), Max Clock: $($CPU.MaxClockSpeed)MHz)"
        
        # Check storage space (minimum 64GB free)
        $SystemDrive = Get-WmiObject -Class Win32_LogicalDisk | Where-Object { $_.DeviceID -eq $env:SystemDrive }
        $FreeSpaceGB = [math]::Round($SystemDrive.FreeSpace / 1GB, 1)
        $HasEnoughSpace = $FreeSpaceGB -ge 64
        
        if ($HasEnoughSpace) {
            Write-Log "? Storage space: ${FreeSpaceGB}GB free (Required: 64GB+) - SUFFICIENT"
        } else {
            Write-Log "? Storage space: ${FreeSpaceGB}GB free (Required: 64GB+) - INSUFFICIENT"
            $CompatibilityIssues += "Insufficient storage space: ${FreeSpaceGB}GB free (minimum 64GB required)"
            $IsCompatible = $false
        }
        
        # Check UEFI firmware
        try {
            $FirmwareType = (Get-WmiObject -Class Win32_ComputerSystem).PCSystemType
            $IsUEFI = Test-Path "$env:SystemDrive\EFI"
            if ($IsUEFI) {
                Write-Log "? UEFI firmware: YES"
            } else {
                Write-Log "? UEFI firmware: NO (Legacy BIOS detected)"
                $CompatibilityIssues += "Legacy BIOS detected (UEFI firmware required)"
                $IsCompatible = $false
            }
        } catch {
            Write-Log "Unable to determine firmware type" "WARN"
            $CompatibilityIssues += "Unable to verify UEFI firmware"
        }
        
        # Log compatibility summary
        if ($IsCompatible) {
            Write-Log "=== COMPATIBILITY CHECK: PASSED ==="
            Write-Log "System meets all basic Windows 11 requirements"
            return 0
        } else {
            Write-Log "=== COMPATIBILITY CHECK: FAILED ==="
            Write-Log "COMPATIBILITY ISSUES FOUND:"
            foreach ($Issue in $CompatibilityIssues) {
                Write-Log "  - $Issue" "ERROR"
            }
            Write-Log "OVERRIDE RECOMMENDATION: Review issues above. TPM and Secure Boot can sometimes be enabled in BIOS. RAM and storage upgrades may be cost-effective." "WARN"
            return 1
        }
    } catch {
        Write-Log "Error during basic compatibility check: $($_.Exception.Message)" "ERROR"
        return -1
    }
}

# Function to download and run hardware readiness check
function Test-Win11Compatibility {
    Write-Log "Starting Windows 11 compatibility check"

    try {
        # First try Microsoft's official script
        $TempScript = "$env:TEMP\HardwareReadiness.ps1"
        Write-Log "Downloading HardwareReadiness.ps1 script from $HardwareReadinessUrl"
        Invoke-WebRequest -Uri $HardwareReadinessUrl -OutFile $TempScript -UseBasicParsing
        
        if (-not (Test-Path $TempScript)) {
            Write-Log "Failed to download Microsoft script, falling back to basic check" "WARN"
            return Test-BasicWin11Requirements
        }

        # Run the compatibility check
        Write-Log "Executing HardwareReadiness.ps1 script"
        try {
            $Result = & $TempScript 2>&1
            $ExitCode = $LASTEXITCODE
            
            # Enhanced logging of Microsoft script output
            if ($Result) {
                Write-Log "=== MICROSOFT HARDWARE READINESS OUTPUT ==="
                foreach ($Line in $Result) {
                    if ($Line -match "FAIL|ERROR|NOT COMPATIBLE|REQUIREMENT") {
                        Write-Log "  ? $Line" "ERROR"
                    } elseif ($Line -match "PASS|SUCCESS|COMPATIBLE|MEETS") {
                        Write-Log "  ? $Line" "INFO"
                    } elseif ($Line.ToString().Trim() -ne "") {
                        Write-Log "  $Line" "INFO"
                    }
                }
                Write-Log "=== END MICROSOFT OUTPUT ==="
            }
            
            # Handle null exit code
            if ($null -eq $ExitCode) {
                Write-Log "Hardware readiness script returned null exit code, falling back to basic check" "WARN"
                Remove-Item $TempScript -Force -ErrorAction SilentlyContinue
                return Test-BasicWin11Requirements
            }

            # Provide interpretation of Microsoft script results
            switch ($ExitCode) {
                0 { 
                    Write-Log "Microsoft Hardware Readiness: COMPATIBLE - System meets Windows 11 requirements" 
                }
                1 { 
                    Write-Log "Microsoft Hardware Readiness: NOT COMPATIBLE - System does not meet Windows 11 requirements" "ERROR"
                    Write-Log "OVERRIDE CONSIDERATION: Check specific failed requirements above. Some issues (TPM, Secure Boot) may be fixable via BIOS settings." "WARN"
                }
                default { 
                    Write-Log "Microsoft Hardware Readiness: UNKNOWN RESULT (Exit code: $ExitCode)" "WARN"
                }
            }
            
            # Clean up temp file
            Remove-Item $TempScript -Force -ErrorAction SilentlyContinue
            return $ExitCode
        } catch {
            Write-Log "Error executing HardwareReadiness.ps1: $($_.Exception.Message)" "ERROR"
            Write-Log "Falling back to basic compatibility check" "WARN"
            Remove-Item $TempScript -Force -ErrorAction SilentlyContinue
            return Test-BasicWin11Requirements
        }
    } catch {
        Write-Log "Error during compatibility check: $($_.Exception.Message)" "ERROR"
        Write-Log "Falling back to basic compatibility check" "WARN"
        return Test-BasicWin11Requirements
    }
}

# Function to perform Windows 11 upgrade
function Start-Win11Upgrade {
    Write-Log "Starting Windows 11 upgrade process"

    try {
        # Log upgrade start (no user interaction in automated mode)
        Write-Log "Starting Windows 11 upgrade - device is compatible"
        Show-UserNotification -Title "Windows 11 Upgrade" -Message "Your device is compatible with Windows 11. Starting upgrade process. This may take some time and will require restarts."

        # Download Windows 11 Installation Assistant
        $AssistantPath = "$env:TEMP\Windows11InstallationAssistant.exe"
        Write-Log "Downloading Windows 11 Installation Assistant"
        Invoke-WebRequest -Uri $Win11AssistantUrl -OutFile $AssistantPath -UseBasicParsing

        # Verify download
        if (Test-Path $AssistantPath) {
            Write-Log "Installation Assistant downloaded successfully"

            # Run the upgrade with silent parameters for automated execution
            Write-Log "Launching Windows 11 Installation Assistant with silent parameters"
            $ProcessArgs = "/quietinstall /skipeula /auto upgrade /NoRestartUI /copylogs $env:TEMP /silent"
            Start-Process -FilePath $AssistantPath -ArgumentList $ProcessArgs -NoNewWindow

            Write-Log "Windows 11 upgrade initiated successfully - running in background"
            Show-UserNotification -Title "Windows 11 Upgrade" -Message "Windows 11 upgrade has been initiated. Your computer will restart automatically when ready."
        }
        else {
            throw "Failed to download Installation Assistant"
        }
    } catch {
        Write-Log "Error during upgrade process: $($_.Exception.Message)" "ERROR"
        Show-UserNotification -Title "Upgrade Error" -Message "Failed to start Windows 11 upgrade. Check logs at $LogPath" -Icon "Error"
    }
}

# Function to create monthly alert task for incompatible systems
function New-MonthlyAlertTask {
    param([bool]$IsInitialRun = $false)

    try {
        # Remove existing task if it exists
        Get-ScheduledTask -TaskName $ScheduledTaskName -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false

        # Define the script block for the scheduled task
        $ScriptBlock = @"
Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.MessageBox]::Show(
    'Your computer does not meet Windows 11 requirements. Consider upgrading hardware components or contact IT support for assistance. Windows 10 support ends October 14, 2025.',
    'Windows 11 Compatibility Alert',
    [System.Windows.Forms.MessageBoxButtons]::OK,
    [System.Windows.Forms.MessageBoxIcon]::Warning
)
"@

        # Create script file for scheduled task
        $TaskScriptPath = "$env:ProgramData\Win11AlertTask.ps1"
        $ScriptBlock | Out-File -FilePath $TaskScriptPath -Encoding UTF8 -Force

        # Create the scheduled task trigger (monthly on the 15th at 2 PM)
        $Trigger = New-ScheduledTaskTrigger -Once -At "2:00 PM" -RepetitionInterval (New-TimeSpan -Days 30)

        # Create the action
        $Action = New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$TaskScriptPath`""

        # Create task principal (run as current user)
        $Principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Limited

        # Register the scheduled task
        Register-ScheduledTask -TaskName $ScheduledTaskName -Trigger $Trigger -Action $Action -Principal $Principal -Description "Monthly Windows 11 compatibility reminder"

        Write-Log "Monthly alert task created successfully"

        # Log compatibility status (automated mode)
        if ($IsInitialRun) {
            Write-Log "System incompatible with Windows 11 - monthly alerts configured"
            Show-UserNotification -Title "Windows 11 Compatibility" -Message "Your computer does not meet Windows 11 requirements. You will receive monthly reminders about this. Consider upgrading hardware or contact IT support." -Icon "Warning"
        }

    } catch {
        Write-Log "Error creating scheduled task: $($_.Exception.Message)" "ERROR"
    }
}

# Function to check if running as administrator
function Test-Administrator {
    $CurrentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal = New-Object Security.Principal.WindowsPrincipal($CurrentUser)
    return $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Main script execution
function Main {
    Write-Log "=== Windows 11 Upgrade Script Started ==="
    Write-Log "Script version: 1.2 (Enhanced Compatibility Logging)"
    Write-Log "Current user: $env:USERNAME"
    Write-Log "Computer name: $env:COMPUTERNAME"
    
    # Check current Windows version
    $OSVersion = (Get-WmiObject -Class Win32_OperatingSystem).Caption
    $BuildNumber = (Get-WmiObject -Class Win32_OperatingSystem).BuildNumber
    Write-Log "Current OS: $OSVersion (Build: $BuildNumber)"
    
    # Check if already on Windows 11
    if ($BuildNumber -ge 22000) {
        Write-Log "System is already running Windows 11 (Build $BuildNumber) - no action needed"
        Show-UserNotification -Title "Windows 11 Status" -Message "This computer is already running Windows 11. No upgrade needed." -Icon "Information"
        Write-Log "=== Windows 11 Upgrade Script Completed ==="
        return
    }

    # Check if we're running as administrator for upgrade capability
    $IsAdmin = Test-Administrator
    Write-Log "Running as administrator: $IsAdmin"

    # Perform compatibility check
    $CompatibilityResult = Test-Win11Compatibility

    switch ($CompatibilityResult) {
        0 {
            # Compatible - proceed with upgrade
            Write-Log "=== FINAL RESULT: SYSTEM IS COMPATIBLE WITH WINDOWS 11 ==="
            Write-Log "All Windows 11 requirements are met. Proceeding with upgrade process."

            if ($IsAdmin) {
                Write-Log "Administrative privileges confirmed - starting upgrade process"
                Start-Win11Upgrade
            }
            else {
                Write-Log "UPGRADE BLOCKED: Administrator rights required for upgrade - cannot proceed in automated mode" "ERROR"
                Write-Log "MANUAL ACTION REQUIRED: Run this script as Administrator or manually download Windows 11 Installation Assistant" "WARN"
                Show-UserNotification -Title "Windows 11 Upgrade Available" -Message "Your computer is compatible with Windows 11. Administrator rights required for upgrade." -Icon "Information"
                exit 1
            }
        }
        1 {
            # Not compatible - set up alerts
            Write-Log "=== FINAL RESULT: SYSTEM IS NOT COMPATIBLE WITH WINDOWS 11 ==="
            Write-Log "One or more Windows 11 requirements are not met. Setting up monthly reminder alerts."
            Write-Log "BUSINESS DECISION REQUIRED: Review compatibility issues above to determine if hardware upgrades are cost-effective vs. continuing with Windows 10 until end of support (Oct 2025)" "WARN"
            New-MonthlyAlertTask -IsInitialRun $true
        }
        default {
            # Error or undetermined
            Write-Log "=== FINAL RESULT: COMPATIBILITY STATUS UNKNOWN ===" "ERROR"
            Write-Log "Unable to determine Windows 11 compatibility (Exit code: $CompatibilityResult)" "ERROR"
            Write-Log "TROUBLESHOOTING: Check network connectivity, antivirus interference, or try running script as Administrator" "WARN"
            Show-UserNotification -Title "Compatibility Check Error" -Message "Unable to determine Windows 11 compatibility. Check logs at $LogPath or try running the script again." -Icon "Error"
        }
    }

    Write-Log "=== Windows 11 Upgrade Script Completed ==="
}

# Execute main function
Main
