# Windows 11 Universal Upgrade Script - Works in RMM and ScreenConnect
# For MSP deployment - Supports both compatibility checking and force mode
# 
# Usage:
#   Normal mode: .\Windows11_Upgrade_Universal.ps1
#   Force mode:  .\Windows11_Upgrade_Universal.ps1 -Force

param(
    [switch]$Force = $false  # Add -Force parameter to bypass compatibility checks
)

Set-ExecutionPolicy -Scope Process -ExecutionPolicy RemoteSigned -Force

$ScriptName = "Win11UniversalUpgradeScript"
$LogPath = "$env:TEMP\Win11Upgrade.log"
$ScheduledTaskName = "Win11CompatibilityAlert"
$HardwareReadinessUrl = "https://aka.ms/HWReadinessScript"
$Win11AssistantUrl = "https://go.microsoft.com/fwlink/?linkid=2171764"

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $TimeStamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $LogEntry = "[$TimeStamp] [$Level] $Message"
    Write-Host $LogEntry
    Add-Content -Path $LogPath -Value $LogEntry -ErrorAction SilentlyContinue
}

function Show-UserNotification {
    param([string]$Title, [string]$Message, [string]$Icon = 'Information')
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        [System.Windows.Forms.MessageBox]::Show($Message, $Title, [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::$Icon) | Out-Null
    }
    catch {
        Write-Host "$Title - $Message" -ForegroundColor Yellow
    }
}

function Set-Win11RegistryBypass {
    Write-Log "=== APPLYING COMPREHENSIVE WINDOWS 11 REGISTRY BYPASSES ==="
    
    try {
        # Step 1: Clear upgrade failure records
        Write-Log "Clearing previous upgrade failure records..."
        Remove-Item "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\CompatMarkers" -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Shared" -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\TargetVersionUpgradeExperienceIndicators" -Recurse -Force -ErrorAction SilentlyContinue
        
        # Step 2: Create LabConfig bypass keys (for setup)
        Write-Log "Setting up LabConfig bypass registry keys..."
        if (-not (Test-Path "HKLM:\SYSTEM\Setup\LabConfig")) {
            New-Item -Path "HKLM:\SYSTEM\Setup\LabConfig" -Force | Out-Null
        }
        Set-ItemProperty -Path "HKLM:\SYSTEM\Setup\LabConfig" -Name "BypassTPMCheck" -Value 1 -Type DWord
        Set-ItemProperty -Path "HKLM:\SYSTEM\Setup\LabConfig" -Name "BypassSecureBootCheck" -Value 1 -Type DWord
        Set-ItemProperty -Path "HKLM:\SYSTEM\Setup\LabConfig" -Name "BypassRAMCheck" -Value 1 -Type DWord
        Set-ItemProperty -Path "HKLM:\SYSTEM\Setup\LabConfig" -Name "BypassCPUCheck" -Value 1 -Type DWord
        Set-ItemProperty -Path "HKLM:\SYSTEM\Setup\LabConfig" -Name "BypassStorageCheck" -Value 1 -Type DWord
        Write-Log "✓ LabConfig bypass keys created"
        
        # Step 3: Microsoft's official MoSetup bypass
        Write-Log "Setting Microsoft's official MoSetup bypass..."
        if (-not (Test-Path "HKLM:\SYSTEM\Setup\MoSetup")) {
            New-Item -Path "HKLM:\SYSTEM\Setup\MoSetup" -Force | Out-Null
        }
        Set-ItemProperty -Path "HKLM:\SYSTEM\Setup\MoSetup" -Name "AllowUpgradesWithUnsupportedTPMOrCPU" -Value 1 -Type DWord
        Write-Log "✓ MoSetup bypass enabled"
        
        # Step 4: Hardware compatibility simulation
        Write-Log "Creating hardware compatibility simulation..."
        if (-not (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\HwReqChk")) {
            New-Item -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\HwReqChk" -Force | Out-Null
        }
        $HwReqChkVars = @(
            "SQ_SecureBootCapable=TRUE",
            "SQ_SecureBootEnabled=TRUE",
            "SQ_TpmVersion=2",
            "SQ_RamMB=8192"
        )
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\HwReqChk" -Name "HwReqChkVars" -Value $HwReqChkVars -Type MultiString
        Write-Log "✓ Hardware compatibility simulation active"
        
        # Step 5: User-level upgrade eligibility
        Write-Log "Setting user upgrade eligibility..."
        if (-not (Test-Path "HKCU:\Software\Microsoft\PCHC")) {
            New-Item -Path "HKCU:\Software\Microsoft\PCHC" -Force | Out-Null
        }
        Set-ItemProperty -Path "HKCU:\Software\Microsoft\PCHC" -Name "UpgradeEligibility" -Value 1 -Type DWord
        Write-Log "✓ User upgrade eligibility set"
        
        # Step 6: Additional compatibility flags for Windows Update
        Write-Log "Setting additional Windows Update compatibility flags..."
        try {
            if (-not (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update")) {
                New-Item -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update" -Force | Out-Null
            }
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update" -Name "AllowOSUpgrade" -Value 1 -Type DWord -ErrorAction SilentlyContinue
        } catch {
            Write-Log "Note: Windows Update registry setting skipped (may not be supported on this version)" "WARN"
        }
        
        Write-Log "=== ALL REGISTRY BYPASSES SUCCESSFULLY APPLIED ==="
        return $true
    }
    catch {
        Write-Log "Error applying registry bypasses: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

function Test-BasicWin11Requirements {
    $ForceText = if ($Force) { " (WILL BE BYPASSED IN FORCE MODE)" } else { "" }
    Write-Log "Performing Windows 11 compatibility assessment..."
    
    try {
        # Check TPM 2.0
        $TPM = Get-WmiObject -Namespace "Root\CIMv2\Security\MicrosoftTpm" -Class Win32_Tpm -ErrorAction SilentlyContinue
        $HasTPM = $TPM -and $TPM.SpecVersion -like "2.*"
        Write-Log "✓ TPM 2.0 available: $HasTPM$(if(-not $HasTPM -and $Force){' (WILL BE BYPASSED)'})"
        
        # Check Secure Boot
        $SecureBoot = $false
        try {
            $SecureBoot = (Confirm-SecureBootUEFI -ErrorAction SilentlyContinue) -eq $true
        } catch {
            Write-Log "Unable to check Secure Boot status (may indicate BIOS/Legacy mode)"
        }
        Write-Log "✓ Secure Boot enabled: $SecureBoot$(if(-not $SecureBoot -and $Force){' (WILL BE BYPASSED)'})"
        
        # Check RAM
        $RAM = (Get-WmiObject -Class Win32_ComputerSystem).TotalPhysicalMemory / 1GB
        $HasEnoughRAM = $RAM -ge 4
        Write-Log "✓ RAM: $([math]::Round($RAM, 1))GB (Required: 4GB+) - $HasEnoughRAM$(if(-not $HasEnoughRAM -and $Force){' (WILL BE BYPASSED)'})"
        
        # Check Storage
        $SystemDrive = Get-WmiObject -Class Win32_LogicalDisk | Where-Object { $_.DeviceID -eq $env:SystemDrive }
        $FreeSpaceGB = $SystemDrive.FreeSpace / 1GB
        $HasEnoughStorage = $FreeSpaceGB -ge 64
        Write-Log "✓ Storage space: $([math]::Round($FreeSpaceGB, 1))GB free (Required: 64GB+) - $HasEnoughStorage$(if(-not $HasEnoughStorage -and $Force){' (WILL BE BYPASSED)'})"
        
        # Check CPU
        $CPU = Get-WmiObject -Class Win32_Processor | Select-Object -First 1
        $CPUArch = $CPU.Architecture
        $CPUMaxClock = $CPU.MaxClockSpeed
        Write-Log "✓ CPU: $($CPU.Name) (Arch: $CPUArch, Max: $CPUMaxClock MHz)"
        
        # Check UEFI vs BIOS
        try {
            $IsUEFI = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control" -Name "PEFirmwareType" -ErrorAction SilentlyContinue).PEFirmwareType -eq 2
        } catch {
            $IsUEFI = $false
        }
        Write-Log "✓ UEFI firmware: $IsUEFI$(if(-not $IsUEFI -and $Force){' (WILL BE BYPASSED)'})"
        
        # Determine overall compatibility
        $FailureReasons = @()
        if (-not $HasTPM) { $FailureReasons += "TPM 2.0 not available" }
        if (-not $SecureBoot) { $FailureReasons += "Secure Boot not enabled" }
        if (-not $HasEnoughRAM) { $FailureReasons += "Insufficient RAM" }
        if (-not $HasEnoughStorage) { $FailureReasons += "Insufficient storage" }
        if (-not $IsUEFI) { $FailureReasons += "Legacy BIOS (UEFI preferred)" }
        
        if ($FailureReasons.Count -gt 0) {
            Write-Log "=== COMPATIBILITY ISSUES FOUND ===" "WARN"
            foreach ($reason in $FailureReasons) {
                Write-Log "  ❌ $reason" "ERROR"
            }
            
            if ($Force) {
                Write-Log "=== FORCE MODE: ALL ISSUES WILL BE BYPASSED ===" "WARN"
                return 0  # Return compatible in force mode
            } else {
                Write-Log "=== SYSTEM NOT COMPATIBLE WITH WINDOWS 11 ===" "ERROR"
                return 1  # Return incompatible in normal mode
            }
        } else {
            Write-Log "=== ✅ SYSTEM IS COMPATIBLE WITH WINDOWS 11 ===" 
            return 0
        }
    }
    catch {
        Write-Log "Error during compatibility check: $($_.Exception.Message)" "ERROR"
        if ($Force) {
            Write-Log "FORCE MODE: Continuing despite error" "WARN"
            return 0
        }
        return -1
    }
}

function Test-Win11Compatibility {
    $ModeText = if ($Force) { "FORCE MODE - Will bypass compatibility issues" } else { "Standard compatibility check" }
    Write-Log "Starting Windows 11 compatibility check ($ModeText)"

    try {
        # Try Microsoft's official script first
        $TempScript = "$env:TEMP\HardwareReadiness.ps1"
        Write-Log "Attempting to download Microsoft's HardwareReadiness.ps1..."
        
        try {
            Invoke-WebRequest -Uri $HardwareReadinessUrl -OutFile $TempScript -UseBasicParsing -TimeoutSec 30
        } catch {
            Write-Log "Failed to download Microsoft script: $($_.Exception.Message)" "WARN"
            Write-Log "Using built-in compatibility check instead"
            return Test-BasicWin11Requirements
        }
        
        if (-not (Test-Path $TempScript)) {
            Write-Log "Microsoft script not found, using built-in check" "WARN"
            return Test-BasicWin11Requirements
        }

        Write-Log "Executing Microsoft's HardwareReadiness.ps1..."
        try {
            $Result = & $TempScript 2>&1
            $ExitCode = $LASTEXITCODE
            
            if ($Result) {
                Write-Log "Microsoft script output: $($Result -join '; ')"
            }
            
            if ($null -eq $ExitCode) {
                Write-Log "Microsoft script returned null exit code, using built-in check" "WARN"
                Remove-Item $TempScript -Force -ErrorAction SilentlyContinue
                return Test-BasicWin11Requirements
            }

            Write-Log "Microsoft compatibility check result: $ExitCode"
            Remove-Item $TempScript -Force -ErrorAction SilentlyContinue
            
            # In force mode, override incompatible results
            if ($Force -and $ExitCode -ne 0) {
                Write-Log "FORCE MODE: Overriding incompatible result from Microsoft script" "WARN"
                # Still run our basic check for detailed logging
                Test-BasicWin11Requirements | Out-Null
                return 0
            }
            
            return $ExitCode
        }
        catch {
            Write-Log "Error executing Microsoft script: $($_.Exception.Message)" "ERROR"
            Write-Log "Falling back to built-in compatibility check"
            Remove-Item $TempScript -Force -ErrorAction SilentlyContinue
            return Test-BasicWin11Requirements
        }
    }
    catch {
        Write-Log "Error during compatibility check: $($_.Exception.Message)" "ERROR"
        if ($Force) {
            Write-Log "FORCE MODE: Continuing despite error" "WARN"
            return 0
        }
        return -1
    }
}

function Start-Win11Upgrade {
    $ModeText = if ($Force) { "FORCE UPGRADE (with registry bypasses)" } else { "standard upgrade" }
    Write-Log "=== STARTING WINDOWS 11 $($ModeText.ToUpper()) ==="
    
    try {
        # Apply registry bypasses in force mode
        if ($Force) {
            Write-Log "Force mode enabled - applying registry bypasses..."
            $BypassResult = Set-Win11RegistryBypass
            if (-not $BypassResult) {
                Write-Log "Warning: Some registry bypasses may have failed, continuing anyway" "WARN"
            }
            Show-UserNotification -Title "Windows 11 Force Upgrade" -Message "Starting forced Windows 11 upgrade with compatibility bypasses enabled."
        } else {
            Show-UserNotification -Title "Windows 11 Upgrade" -Message "Your device is compatible with Windows 11. Starting upgrade process."
        }
        
        # Download Installation Assistant
        $AssistantPath = "$env:TEMP\Windows11InstallationAssistant.exe"
        Write-Log "Downloading Windows 11 Installation Assistant..."
        
        try {
            Invoke-WebRequest -Uri $Win11AssistantUrl -OutFile $AssistantPath -UseBasicParsing -TimeoutSec 300
        } catch {
            throw "Failed to download Installation Assistant: $($_.Exception.Message)"
        }
        
        if (-not (Test-Path $AssistantPath)) {
            throw "Installation Assistant not found after download"
        }
        
        Write-Log "Installation Assistant downloaded successfully (Size: $([math]::Round((Get-Item $AssistantPath).Length / 1MB, 1))MB)"
        
        # Launch Installation Assistant
        Write-Log "Launching Windows 11 Installation Assistant..."
        $ProcessArgs = @(
            '/quietinstall',
            '/skipeula', 
            '/auto',
            'upgrade',
            '/NoRestartUI',
            '/copylogs',
            $env:TEMP
        )
        
        Write-Log "Process arguments: $($ProcessArgs -join ' ')"
        
        try {
            $Process = Start-Process -FilePath $AssistantPath -ArgumentList $ProcessArgs -PassThru
            Start-Sleep -Seconds 3
            
            if ($Process -and !$Process.HasExited) {
                Write-Log "✅ Installation Assistant launched successfully (PID: $($Process.Id))"
                $SuccessMessage = if ($Force) {
                    "Windows 11 force upgrade initiated with compatibility bypasses. System will restart when ready."
                } else {
                    "Windows 11 upgrade initiated. System will restart when ready."
                }
                Write-Log $SuccessMessage
                Show-UserNotification -Title "Windows 11 Upgrade Started" -Message $SuccessMessage
            } else {
                Write-Log "Installation Assistant process completed or exited quickly" "WARN"
            }
        } catch {
            throw "Failed to start Installation Assistant: $($_.Exception.Message)"
        }
    }
    catch {
        Write-Log "Error during upgrade process: $($_.Exception.Message)" "ERROR"
        $ErrorMessage = if ($Force) {
            "Failed to start Windows 11 force upgrade. Check logs at $LogPath"
        } else {
            "Failed to start Windows 11 upgrade. Check logs at $LogPath"
        }
        Show-UserNotification -Title "Upgrade Error" -Message $ErrorMessage -Icon "Error"
    }
}

function New-MonthlyAlertTask {
    param([bool]$IsInitialRun = $false)
    
    try {
        Write-Log "Setting up monthly compatibility reminder..."
        
        # Remove existing task
        Get-ScheduledTask -TaskName $ScheduledTaskName -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false
        
        # Create alert script
        $ScriptBlock = @'
Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.MessageBox]::Show(
    'Your computer does not meet Windows 11 requirements. Consider upgrading hardware or contact IT support. Windows 10 support ends October 14, 2025.',
    'Windows 11 Compatibility Alert',
    [System.Windows.Forms.MessageBoxButtons]::OK,
    [System.Windows.Forms.MessageBoxIcon]::Warning
)
'@
        
        $TaskScriptPath = "$env:ProgramData\Win11AlertTask.ps1"
        $ScriptBlock | Out-File -FilePath $TaskScriptPath -Encoding UTF8 -Force
        
        # Create scheduled task
        $Trigger = New-ScheduledTaskTrigger -Monthly -DaysOfMonth 15 -At "2:00 PM"
        $Action = New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$TaskScriptPath`""
        
        try {
            $Principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Limited
            Register-ScheduledTask -TaskName $ScheduledTaskName -Trigger $Trigger -Action $Action -Principal $Principal -Description "Monthly Windows 11 compatibility reminder"
            Write-Log "✅ Monthly alert task created successfully"
        } catch {
            Write-Log "Warning: Could not create scheduled task: $($_.Exception.Message)" "WARN"
        }
        
        if ($IsInitialRun) {
            Show-UserNotification -Title "Windows 11 Compatibility" -Message "Your computer does not meet Windows 11 requirements. You will receive monthly reminders. Consider hardware upgrades or contact IT support." -Icon "Warning"
        }
    }
    catch {
        Write-Log "Error setting up monthly alerts: $($_.Exception.Message)" "ERROR"
    }
}

function Test-Administrator {
    $CurrentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal = New-Object Security.Principal.WindowsPrincipal($CurrentUser)
    return $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Main execution
function Main {
    $ModeText = if ($Force) { "FORCE MODE - Will bypass compatibility checks" } else { "Standard mode - Respects compatibility requirements" }
    Write-Log "=== Windows 11 Universal Upgrade Script Started ==="
    Write-Log "Script version: 3.0 (Universal - RMM & ScreenConnect compatible)"
    Write-Log "Mode: $ModeText"
    Write-Log "Current user: $env:USERNAME"
    Write-Log "Computer name: $env:COMPUTERNAME"
    Write-Log "Command line args: $($PSBoundParameters | ConvertTo-Json -Compress)"
    
    # Check current Windows version
    $OSVersion = (Get-WmiObject -Class Win32_OperatingSystem).Caption
    $BuildNumber = (Get-WmiObject -Class Win32_OperatingSystem).BuildNumber
    Write-Log "Current OS: $OSVersion (Build: $BuildNumber)"
    
    # Check if already on Windows 11
    if ($BuildNumber -ge 22000) {
        Write-Log "System is already running Windows 11 (Build $BuildNumber)"
        Show-UserNotification -Title "Windows 11 Status" -Message "This computer is already running Windows 11. No upgrade needed." -Icon "Information"
        Write-Log "=== Script completed - No action needed ==="
        return
    }
    
    # Check administrator rights for force mode
    $IsAdmin = Test-Administrator
    Write-Log "Running as administrator: $IsAdmin"
    
    if ($Force -and -not $IsAdmin) {
        Write-Log "FORCE MODE requires administrator privileges" "ERROR"
        Show-UserNotification -Title "Administrator Required" -Message "Force upgrade mode requires administrator privileges. Please run as administrator or use standard mode." -Icon "Error"
        return
    }
    
    # Perform compatibility check
    Write-Log "Performing compatibility assessment..."
    $CompatibilityResult = Test-Win11Compatibility
    
    # Handle results based on mode and compatibility
    switch ($CompatibilityResult) {
        0 {
            # Compatible - proceed with upgrade
            Write-Log "✅ System is compatible with Windows 11"
            if ($IsAdmin) {
                Start-Win11Upgrade
            } else {
                Write-Log "Administrator rights recommended for upgrade" "WARN"
                $Message = if ($Force) {
                    "System is ready for forced Windows 11 upgrade. Please run as administrator to proceed."
                } else {
                    "System is compatible with Windows 11. Please run as administrator to upgrade."
                }
                Show-UserNotification -Title "Windows 11 Upgrade Available" -Message $Message -Icon "Information"
            }
        }
        1 {
            # Not compatible
            if ($Force) {
                Write-Log "❌ System incompatible, but FORCE MODE will override" "WARN"
                if ($IsAdmin) {
                    Start-Win11Upgrade
                } else {
                    Show-UserNotification -Title "Force Upgrade Available" -Message "System is incompatible but can be force-upgraded. Run as administrator to proceed." -Icon "Warning"
                }
            } else {
                Write-Log "❌ System is not compatible with Windows 11"
                New-MonthlyAlertTask -IsInitialRun $true
            }
        }
        default {
            # Error or undetermined
            Write-Log "⚠️ Unable to determine Windows 11 compatibility (Exit code: $CompatibilityResult)" "ERROR"
            if ($Force) {
                Write-Log "FORCE MODE: Attempting upgrade despite compatibility check failure" "WARN"
                if ($IsAdmin) {
                    Start-Win11Upgrade
                } else {
                    Show-UserNotification -Title "Force Upgrade" -Message "Compatibility check failed but force upgrade is available. Run as administrator to proceed." -Icon "Warning"
                }
            } else {
                Show-UserNotification -Title "Compatibility Check Error" -Message "Unable to determine Windows 11 compatibility. Check logs at $LogPath or try force mode." -Icon "Error"
            }
        }
    }
    
    Write-Log "=== Windows 11 Universal Upgrade Script Completed ==="
}

# Execute main function
Main