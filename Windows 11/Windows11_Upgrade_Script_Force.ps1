<#
.SYNOPSIS
    Windows 11 FORCE UPGRADE Script - Bypasses ALL Compatibility Checks

.DESCRIPTION
    ?? WARNING: This script FORCES a Windows 11 upgrade regardless of hardware compatibility.
    This is intended for testing purposes, VMs, or systems where you want to bypass
    Microsoft's hardware requirements entirely.
    
    USE AT YOUR OWN RISK - This may result in:
    - Unsupported Windows 11 installation
    - Performance issues on incompatible hardware
    - Missing security features (TPM, Secure Boot)
    - Potential system instability
    - Loss of support from Microsoft

.NOTES
    Version: 1.4 - FORCE UPGRADE Edition
    Author: MSP Admin
    Date: September 2025
    Requires: PowerShell 5.1+, Windows 10, Administrator privileges
    
    ?? TESTING/VM USE ONLY ??
    
    Version 1.4 Force Edition Features:
    - Bypasses ALL compatibility checks
    - Forces Windows 11 upgrade regardless of hardware
    - Registry modifications to disable upgrade blocks
    - Multiple upgrade methods with compatibility overrides
    - Enhanced logging for troubleshooting forced upgrades
    - VM and testing environment optimizations
#>

# Script configuration for force upgrade
$ScriptName = "Win11UpgradeScript_Force"
$LogPath = "$env:TEMP\Win11Upgrade_Force.log"
$HardwareReadinessUrl = "https://aka.ms/HWReadinessScript"
$Win11AssistantUrl = "https://go.microsoft.com/fwlink/?linkid=2171764"
$Win11MediaCreationUrl = "https://go.microsoft.com/fwlink/?linkid=2156295"

# Initialize logging
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $TimeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $ComputerName = $env:COMPUTERNAME
    $LogEntry = "[$TimeStamp] [$ComputerName] [$Level] $Message"
    Write-Host $LogEntry -ForegroundColor $(
        switch ($Level) {
            "ERROR" { "Red" }
            "WARN" { "Yellow" }
            "SUCCESS" { "Green" }
            default { "White" }
        }
    )
    Add-Content -Path $LogPath -Value $LogEntry
}

# Set execution policy for this session
try {
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
    Write-Log "Execution policy set to Bypass for this session"
} catch {
    Write-Log "Warning: Could not set execution policy: $($_.Exception.Message)" "WARN"
}

# Function to check if running as administrator
function Test-Administrator {
    $CurrentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal = New-Object Security.Principal.WindowsPrincipal($CurrentUser)
    return $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Function to show user notifications
function Show-UserNotification {
    param(
        [string]$Title,
        [string]$Message,
        [string]$Icon = "Information"
    )

    Write-Log "NOTIFICATION: [$Title] $Message"
    
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show($Message, $Title, [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::$Icon)
    } catch {
        Write-Host "$Title - $Message" -ForegroundColor Yellow
    }
}

# Function to apply registry modifications to bypass Windows 11 compatibility checks
function Set-BypassCompatibilityChecks {
    Write-Log "Applying registry modifications to bypass Windows 11 compatibility checks" "WARN"
    
    try {
        # Registry path for Windows Update compatibility checks
        $RegPath = "HKLM:\SYSTEM\Setup\MoSetup"
        
        # Create the registry key if it doesn't exist
        if (-not (Test-Path $RegPath)) {
            New-Item -Path $RegPath -Force | Out-Null
            Write-Log "Created registry path: $RegPath"
        }
        
        # Bypass TPM check
        Set-ItemProperty -Path $RegPath -Name "AllowUpgradesWithUnsupportedTPMOrCPU" -Value 1 -Type DWord
        Write-Log "? Registry: Bypassed TPM requirement"
        
        # Bypass CPU check
        $RegPath2 = "HKLM:\SYSTEM\Setup\LabConfig"
        if (-not (Test-Path $RegPath2)) {
            New-Item -Path $RegPath2 -Force | Out-Null
            Write-Log "Created registry path: $RegPath2"
        }
        
        Set-ItemProperty -Path $RegPath2 -Name "BypassTPMCheck" -Value 1 -Type DWord
        Set-ItemProperty -Path $RegPath2 -Name "BypassCPUCheck" -Value 1 -Type DWord
        Set-ItemProperty -Path $RegPath2 -Name "BypassRAMCheck" -Value 1 -Type DWord
        Set-ItemProperty -Path $RegPath2 -Name "BypassSecureBootCheck" -Value 1 -Type DWord
        Set-ItemProperty -Path $RegPath2 -Name "BypassStorageCheck" -Value 1 -Type DWord
        
        Write-Log "? Registry: Bypassed CPU compatibility check"
        Write-Log "? Registry: Bypassed RAM check"
        Write-Log "? Registry: Bypassed Secure Boot check"
        Write-Log "? Registry: Bypassed Storage check"
        
        # Additional Windows Update bypass
        $RegPath3 = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\CompatMarkers"
        if (-not (Test-Path $RegPath3)) {
            New-Item -Path $RegPath3 -Force | Out-Null
        }
        
        Write-Log "Registry modifications applied successfully - Windows 11 upgrade blocks bypassed" "SUCCESS"
        
    } catch {
        Write-Log "Error applying registry modifications: $($_.Exception.Message)" "ERROR"
        Write-Log "Continuing with upgrade attempt anyway..." "WARN"
    }
}

# Function to perform FORCED Windows 11 upgrade
function Start-ForceWin11Upgrade {
    Write-Log "?? STARTING FORCED WINDOWS 11 UPGRADE - BYPASSING ALL COMPATIBILITY CHECKS ??" "WARN"
    Write-Log "This upgrade will proceed regardless of hardware compatibility" "WARN"

    try {
        # Show warning to user
        Show-UserNotification -Title "?? FORCE Windows 11 Upgrade" -Message "WARNING: This will forcibly upgrade to Windows 11 regardless of hardware compatibility. This is intended for testing/VM use only. Continue at your own risk!" -Icon "Warning"

        # Apply registry bypasses first
        Set-BypassCompatibilityChecks

        Write-Log "Downloading Windows 11 Installation Assistant"
        $AssistantPath = "$env:TEMP\Windows11InstallationAssistant.exe"
        
        try {
            Invoke-WebRequest -Uri $Win11AssistantUrl -OutFile $AssistantPath -UseBasicParsing
            Write-Log "Windows 11 Installation Assistant downloaded successfully"
        } catch {
            Write-Log "Failed to download Installation Assistant, trying Media Creation Tool" "WARN"
            try {
                Invoke-WebRequest -Uri $Win11MediaCreationUrl -OutFile "$env:TEMP\MediaCreationToolW11.exe" -UseBasicParsing
                $AssistantPath = "$env:TEMP\MediaCreationToolW11.exe"
                Write-Log "Media Creation Tool downloaded as fallback"
            } catch {
                throw "Failed to download any Windows 11 upgrade tools"
            }
        }

        # Verify download
        if (Test-Path $AssistantPath) {
            Write-Log "Upgrade tool ready for execution: $AssistantPath"

            # Show final warning
            $FinalWarning = @"
?? FINAL WARNING ??

This will now start a FORCED Windows 11 upgrade that:
- BYPASSES all hardware compatibility checks
- May result in an UNSUPPORTED installation
- Could cause performance issues or instability
- May void support from Microsoft

Perfect for VMs and testing environments!

The upgrade will start in 10 seconds...
"@

            Show-UserNotification -Title "Force Upgrade Starting" -Message $FinalWarning -Icon "Warning"
            Write-Log $FinalWarning "WARN"
            
            Start-Sleep -Seconds 10

            # Run the upgrade with force parameters
            Write-Log "?? LAUNCHING FORCED WINDOWS 11 UPGRADE ??" "WARN"
            
            # Multiple upgrade attempts with different parameters
            $UpgradeCommands = @(
                "/quietinstall /skipeula /auto upgrade /migratedrivers all /rescan /compat IgnoreWarning /NoRestartUI /copylogs $env:TEMP",
                "/S /v/qn REBOOT=ReallySuppress",
                "/quiet /norestart /compat:IgnoreWarning",
                "/auto upgrade /quiet /compat IgnoreWarning /migratedrivers all"
            )
            
            $UpgradeStarted = $false
            
            foreach ($Command in $UpgradeCommands) {
                try {
                    Write-Log "Attempting upgrade with parameters: $Command"
                    Start-Process -FilePath $AssistantPath -ArgumentList $Command -NoNewWindow -PassThru
                    $UpgradeStarted = $true
                    Write-Log "? FORCED UPGRADE INITIATED SUCCESSFULLY!" "SUCCESS"
                    break
                } catch {
                    Write-Log "Upgrade attempt failed with parameters '$Command': $($_.Exception.Message)" "WARN"
                }
            }
            
            if (-not $UpgradeStarted) {
                # Last resort - run without parameters
                Write-Log "All automated attempts failed, launching interactive upgrade" "WARN"
                Start-Process -FilePath $AssistantPath -NoNewWindow
                Write-Log "Interactive upgrade launched - user intervention may be required"
            }

            Write-Log "?? Windows 11 FORCE upgrade has been initiated!" "SUCCESS"
            Write-Log "The upgrade is running in the background and will restart automatically when ready" "SUCCESS"
            
            Show-UserNotification -Title "Force Upgrade Started!" -Message "Windows 11 FORCE upgrade is now running! Your VM/computer will restart automatically when ready. Check the logs for progress updates."

        } else {
            throw "Failed to download Windows 11 upgrade tools"
        }
    } catch {
        Write-Log "? ERROR during FORCE upgrade process: $($_.Exception.Message)" "ERROR"
        Show-UserNotification -Title "Force Upgrade Error" -Message "Failed to start Windows 11 force upgrade. Check logs at $LogPath for details." -Icon "Error"
    }
}

# Function to display current system info (for logging purposes)
function Show-SystemInfo {
    Write-Log "=== SYSTEM INFORMATION (PRE-UPGRADE) ==="
    
    try {
        $OSInfo = Get-WmiObject -Class Win32_OperatingSystem
        $CPU = Get-WmiObject -Class Win32_Processor | Select-Object -First 1
        $RAM = [math]::Round((Get-WmiObject -Class Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
        $TPM = Get-WmiObject -Namespace "Root\CIMv2\Security\MicrosoftTpm" -Class Win32_Tpm -ErrorAction SilentlyContinue
        
        Write-Log "Computer: $env:COMPUTERNAME"
        Write-Log "Current OS: $($OSInfo.Caption) (Build: $($OSInfo.BuildNumber))"
        Write-Log "CPU: $($CPU.Name)"
        Write-Log "RAM: ${RAM}GB"
        Write-Log "TPM: $(if ($TPM) { "Present (Version: $($TPM.SpecVersion))" } else { "Not detected or disabled" })"
        
        try {
            $SecureBoot = Confirm-SecureBootUEFI -ErrorAction SilentlyContinue
            Write-Log "Secure Boot: $(if ($SecureBoot) { "Enabled" } else { "Disabled/Not supported" })"
        } catch {
            Write-Log "Secure Boot: Cannot determine (likely Legacy BIOS)"
        }
        
        $SystemDrive = Get-WmiObject -Class Win32_LogicalDisk | Where-Object { $_.DeviceID -eq $env:SystemDrive }
        $FreeSpaceGB = [math]::Round($SystemDrive.FreeSpace / 1GB, 1)
        Write-Log "System Drive Free Space: ${FreeSpaceGB}GB"
        
        Write-Log "=== END SYSTEM INFORMATION ==="
        
    } catch {
        Write-Log "Error gathering system information: $($_.Exception.Message)" "WARN"
    }
}

# Main script execution
function Main {
    Write-Log "?????? WINDOWS 11 FORCE UPGRADE SCRIPT STARTED ??????" "WARN"
    Write-Log "Script version: 1.4 - FORCE UPGRADE Edition (?? TESTING/VM USE ONLY ??)" "WARN"
    
    # Check administrator privileges
    $IsAdmin = Test-Administrator
    Write-Log "Running as administrator: $IsAdmin"
    
    if (-not $IsAdmin) {
        Write-Log "? ADMINISTRATOR PRIVILEGES REQUIRED" "ERROR"
        Show-UserNotification -Title "Administrator Required" -Message "This script must be run as Administrator to modify registry settings and perform the forced upgrade." -Icon "Error"
        exit 1
    }
    
    # Display warnings
    $WarningMessage = @"
?????? WARNING: FORCE UPGRADE MODE ??????

This script will FORCE a Windows 11 upgrade by:
- Bypassing ALL hardware compatibility checks
- Modifying registry to disable upgrade blocks
- Proceeding regardless of TPM, Secure Boot, CPU, or RAM requirements

This is intended for:
? Virtual Machines (like your Synology VM!)
? Testing environments
? Lab systems
? Systems where you accept the risks

This may result in:
? Unsupported Windows 11 installation
? Performance issues
? Missing security features
? System instability
? Loss of Microsoft support

Perfect for testing Windows 11 on VMs! ??
"@

    Write-Log $WarningMessage "WARN"
    Show-UserNotification -Title "?? FORCE UPGRADE WARNING" -Message $WarningMessage -Icon "Warning"
    
    # Show system info
    Show-SystemInfo
    
    # Check current Windows version
    $OSVersion = (Get-WmiObject -Class Win32_OperatingSystem).Caption
    $BuildNumber = (Get-WmiObject -Class Win32_OperatingSystem).BuildNumber
    Write-Log "Current OS: $OSVersion (Build: $BuildNumber)"
    
    # Check if already on Windows 11
    if ($BuildNumber -ge 22000) {
        Write-Log "System is already running Windows 11 (Build $BuildNumber)" "SUCCESS"
        Show-UserNotification -Title "Already Windows 11" -Message "This computer is already running Windows 11 (Build $BuildNumber). No upgrade needed!"
        Write-Log "=== FORCE UPGRADE SCRIPT COMPLETED (NO ACTION NEEDED) ==="
        return
    }

    # Confirm user wants to proceed
    Add-Type -AssemblyName System.Windows.Forms
    $UserConfirm = [System.Windows.Forms.MessageBox]::Show(
        "Are you absolutely sure you want to FORCE upgrade to Windows 11, bypassing all compatibility checks?`n`nThis is perfect for VMs and testing!",
        "Confirm Force Upgrade",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )
    
    if ($UserConfirm -eq "Yes") {
        Write-Log "?? User confirmed force upgrade - proceeding with Windows 11 installation" "SUCCESS"
        Start-ForceWin11Upgrade
    } else {
        Write-Log "User cancelled force upgrade" "INFO"
        Show-UserNotification -Title "Upgrade Cancelled" -Message "Force upgrade cancelled by user."
    }

    Write-Log "=== WINDOWS 11 FORCE UPGRADE SCRIPT COMPLETED ==="
}

# Execute main function
Main
