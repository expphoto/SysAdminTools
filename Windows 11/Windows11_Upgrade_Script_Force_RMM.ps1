<#
.SYNOPSIS
    Windows 11 FORCE UPGRADE Script - RMM/Non-Interactive Version

.DESCRIPTION
    ?? WARNING: This script FORCES a Windows 11 upgrade regardless of hardware compatibility.
    This version is specifically designed for RMM tools and runs completely non-interactively.
    No user prompts or confirmations - it just goes for it!
    
    Perfect for: VMs, testing environments, automated deployments where you want to bypass ALL checks.
    
    USE AT YOUR OWN RISK - This may result in:
    - Unsupported Windows 11 installation
    - Performance issues on incompatible hardware  
    - Missing security features (TPM, Secure Boot)
    - Potential system instability
    - Loss of support from Microsoft

.PARAMETER AutoConfirm
    Automatically confirms the upgrade without user interaction (default: true)

.NOTES
    Version: 1.5 - RMM FORCE UPGRADE Edition
    Author: MSP Admin
    Date: September 2025
    Requires: PowerShell 5.1+, Windows 10, SYSTEM/Administrator privileges
    
    ?? FULLY AUTOMATED - NO USER PROMPTS ??
    
    Version 1.5 RMM Force Edition Features:
    - Completely non-interactive for RMM deployment
    - Bypasses ALL compatibility checks automatically
    - Forces Windows 11 upgrade without confirmations
    - Enhanced logging for remote monitoring
    - Automatic registry modifications
    - Multiple upgrade methods with fallbacks
    - Perfect for mass VM deployments
#>

param(
    [switch]$AutoConfirm = $true
)

# Script configuration for RMM force upgrade
$ScriptName = "Win11UpgradeScript_Force_RMM"
$LogPath = "$env:ProgramData\Win11Upgrade_Force_RMM.log"
$HardwareReadinessUrl = "https://aka.ms/HWReadinessScript"
$Win11AssistantUrl = "https://go.microsoft.com/fwlink/?linkid=2171764"
$Win11MediaCreationUrl = "https://go.microsoft.com/fwlink/?linkid=2156295"

# Initialize logging with enhanced RMM support
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $TimeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $ComputerName = $env:COMPUTERNAME
    $LogEntry = "[$TimeStamp] [$ComputerName] [$Level] $Message"
    
    # Console output with colors (if available)
    try {
        Write-Host $LogEntry -ForegroundColor $(
            switch ($Level) {
                "ERROR" { "Red" }
                "WARN" { "Yellow" }  
                "SUCCESS" { "Green" }
                default { "White" }
            }
        )
    } catch {
        Write-Host $LogEntry
    }
    
    # File logging with error handling
    try {
        Add-Content -Path $LogPath -Value $LogEntry
    } catch {
        try {
            # Fallback to temp location
            Add-Content -Path "$env:TEMP\Win11Upgrade_Force_RMM.log" -Value $LogEntry
        } catch {
            # Last resort - just continue without file logging
        }
    }
}

# Set execution policy for this session
try {
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
    Write-Log "Execution policy set to Bypass for this session"
} catch {
    Write-Log "Warning: Could not set execution policy: $($_.Exception.Message)" "WARN"
}

# Function to check execution context
function Test-ExecutionContext {
    $CurrentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal = New-Object Security.Principal.WindowsPrincipal($CurrentUser)
    $IsAdmin = $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $IsSystem = $CurrentUser.Name -eq "NT AUTHORITY\SYSTEM"
    $IsInteractive = [Environment]::UserInteractive
    
    Write-Log "Execution Context Analysis:"
    Write-Log "  - Current User: $($CurrentUser.Name)"
    Write-Log "  - Is Administrator: $IsAdmin"
    Write-Log "  - Is SYSTEM: $IsSystem"
    Write-Log "  - Is Interactive: $IsInteractive"
    
    return @{
        IsAdmin = $IsAdmin
        IsSystem = $IsSystem
        IsInteractive = $IsInteractive
        CurrentUser = $CurrentUser.Name
    }
}

# Function to apply registry modifications to bypass Windows 11 compatibility checks
function Set-BypassCompatibilityChecks {
    Write-Log "?? Applying registry modifications to bypass Windows 11 compatibility checks" "WARN"
    
    try {
        # Registry modifications for Windows 11 bypass
        $RegModifications = @(
            @{
                Path = "HKLM:\SYSTEM\Setup\MoSetup"
                Name = "AllowUpgradesWithUnsupportedTPMOrCPU"
                Value = 1
                Type = "DWord"
                Description = "Bypass TPM/CPU checks"
            },
            @{
                Path = "HKLM:\SYSTEM\Setup\LabConfig"
                Name = "BypassTPMCheck"
                Value = 1
                Type = "DWord"  
                Description = "Bypass TPM requirement"
            },
            @{
                Path = "HKLM:\SYSTEM\Setup\LabConfig"
                Name = "BypassCPUCheck"
                Value = 1
                Type = "DWord"
                Description = "Bypass CPU compatibility"
            },
            @{
                Path = "HKLM:\SYSTEM\Setup\LabConfig"
                Name = "BypassRAMCheck" 
                Value = 1
                Type = "DWord"
                Description = "Bypass RAM requirement (perfect for 2-4GB VMs)"
            },
            @{
                Path = "HKLM:\SYSTEM\Setup\LabConfig"
                Name = "BypassSecureBootCheck"
                Value = 1
                Type = "DWord"
                Description = "Bypass Secure Boot requirement"
            },
            @{
                Path = "HKLM:\SYSTEM\Setup\LabConfig"
                Name = "BypassStorageCheck"
                Value = 1
                Type = "DWord"
                Description = "Bypass storage space requirement"
            }
        )
        
        foreach ($RegMod in $RegModifications) {
            try {
                # Create registry path if it doesn't exist
                if (-not (Test-Path $RegMod.Path)) {
                    New-Item -Path $RegMod.Path -Force | Out-Null
                    Write-Log "  Created registry path: $($RegMod.Path)"
                }
                
                # Set the registry value
                Set-ItemProperty -Path $RegMod.Path -Name $RegMod.Name -Value $RegMod.Value -Type $RegMod.Type -Force
                Write-Log "  ? $($RegMod.Description)" "SUCCESS"
                
            } catch {
                Write-Log "  ? Failed to set $($RegMod.Name): $($_.Exception.Message)" "ERROR"
            }
        }
        
        Write-Log "?? Registry modifications completed - Windows 11 compatibility blocks bypassed!" "SUCCESS"
        
    } catch {
        Write-Log "? Error during registry modifications: $($_.Exception.Message)" "ERROR"
        Write-Log "Continuing with upgrade attempt anyway..." "WARN"
    }
}

# Function to perform FORCED Windows 11 upgrade (RMM version)
function Start-ForceWin11Upgrade {
    Write-Log "?????? STARTING FORCED WINDOWS 11 UPGRADE (RMM MODE) ??????" "WARN"
    Write-Log "This upgrade will proceed automatically without user confirmation" "WARN"

    try {
        # Apply registry bypasses first
        Set-BypassCompatibilityChecks
        
        Write-Log "?? Downloading Windows 11 upgrade tools..."
        $AssistantPath = "$env:TEMP\Windows11InstallationAssistant.exe"
        $DownloadSuccess = $false
        
        # Try primary download
        try {
            Write-Log "Attempting download from: $Win11AssistantUrl"
            Invoke-WebRequest -Uri $Win11AssistantUrl -OutFile $AssistantPath -UseBasicParsing -TimeoutSec 300
            Write-Log "? Windows 11 Installation Assistant downloaded successfully" "SUCCESS"
            $DownloadSuccess = $true
        } catch {
            Write-Log "? Installation Assistant download failed: $($_.Exception.Message)" "WARN"
            
            # Try Media Creation Tool as fallback
            try {
                Write-Log "Trying Media Creation Tool as fallback..."
                Invoke-WebRequest -Uri $Win11MediaCreationUrl -OutFile "$env:TEMP\MediaCreationToolW11.exe" -UseBasicParsing -TimeoutSec 300
                $AssistantPath = "$env:TEMP\MediaCreationToolW11.exe"
                Write-Log "? Media Creation Tool downloaded successfully" "SUCCESS"
                $DownloadSuccess = $true
            } catch {
                Write-Log "? Media Creation Tool download also failed: $($_.Exception.Message)" "ERROR"
            }
        }

        if (-not $DownloadSuccess -or -not (Test-Path $AssistantPath)) {
            throw "Failed to download any Windows 11 upgrade tools"
        }

        Write-Log "?? LAUNCHING FORCED WINDOWS 11 UPGRADE (NO CONFIRMATION REQUIRED) ??" "WARN"
        
        # Multiple upgrade command attempts
        $UpgradeCommands = @(
            @{
                Args = "/quietinstall /skipeula /auto upgrade /migratedrivers all /rescan /compat IgnoreWarning /NoRestartUI /copylogs `"$env:TEMP`""
                Description = "Silent install with driver migration and compatibility override"
            },
            @{
                Args = "/S /v/qn REBOOT=ReallySuppress /compat IgnoreWarning"
                Description = "Completely silent with reboot suppression"
            },
            @{
                Args = "/quiet /norestart /compat IgnoreWarning /migratedrivers all"
                Description = "Quiet mode with driver migration"  
            },
            @{
                Args = "/auto upgrade /quiet /compat IgnoreWarning"
                Description = "Auto upgrade quiet mode"
            },
            @{
                Args = "/quietinstall /skipeula"
                Description = "Basic quiet install"
            }
        )
        
        $UpgradeStarted = $false
        
        foreach ($Command in $UpgradeCommands) {
            try {
                Write-Log "?? Attempting upgrade: $($Command.Description)"
                Write-Log "   Command: $AssistantPath $($Command.Args)"
                
                $Process = Start-Process -FilePath $AssistantPath -ArgumentList $Command.Args -NoNewWindow -PassThru
                
                # Wait a few seconds to see if process starts successfully
                Start-Sleep -Seconds 5
                
                if ($Process -and -not $Process.HasExited) {
                    Write-Log "? FORCED UPGRADE LAUNCHED SUCCESSFULLY!" "SUCCESS"
                    Write-Log "   Process ID: $($Process.Id)"
                    Write-Log "   Process Name: $($Process.ProcessName)"
                    $UpgradeStarted = $true
                    break
                } else {
                    Write-Log "?? Process exited quickly, trying next method..." "WARN"
                }
                
            } catch {
                Write-Log "? Upgrade attempt failed: $($_.Exception.Message)" "WARN"
            }
        }
        
        if (-not $UpgradeStarted) {
            # Last resort - run without parameters
            Write-Log "?? All silent attempts failed, launching basic upgrade..." "WARN"
            try {
                Start-Process -FilePath $AssistantPath -NoNewWindow
                Write-Log "? Basic upgrade launched (may require manual interaction)"
                $UpgradeStarted = $true
            } catch {
                Write-Log "? Even basic launch failed: $($_.Exception.Message)" "ERROR"
            }
        }
        
        if ($UpgradeStarted) {
            Write-Log "?? Windows 11 FORCE upgrade initiated successfully!" "SUCCESS"
            Write-Log "?? Monitor progress with:"
            Write-Log "   - This log: $LogPath" 
            Write-Log "   - Windows Setup: C:\Windows\Panther\setupact.log"
            Write-Log "   - Process: Get-Process | Where-Object {`$_.ProcessName -like '*Windows11*' -or `$_.ProcessName -like '*setup*'}"
            Write-Log "?? The system will restart automatically when ready"
        } else {
            throw "All upgrade attempts failed"
        }

    } catch {
        Write-Log "? CRITICAL ERROR during force upgrade: $($_.Exception.Message)" "ERROR"
        Write-Log "?? Troubleshooting steps:" "WARN"
        Write-Log "   1. Check network connectivity"
        Write-Log "   2. Verify sufficient disk space (>32GB free)"
        Write-Log "   3. Ensure no other Windows updates are pending"
        Write-Log "   4. Try running Windows Update manually first"
        exit 1
    }
}

# Function to display current system info
function Show-SystemInfo {
    Write-Log "=== SYSTEM INFORMATION (PRE-UPGRADE) ==="
    
    try {
        $OSInfo = Get-WmiObject -Class Win32_OperatingSystem
        $CPU = Get-WmiObject -Class Win32_Processor | Select-Object -First 1
        $RAM = [math]::Round((Get-WmiObject -Class Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
        $TPM = Get-WmiObject -Namespace "Root\CIMv2\Security\MicrosoftTpm" -Class Win32_Tpm -ErrorAction SilentlyContinue
        
        Write-Log "?? Computer: $env:COMPUTERNAME"
        Write-Log "??? Current OS: $($OSInfo.Caption) (Build: $($OSInfo.BuildNumber))"
        Write-Log "?? CPU: $($CPU.Name)"
        Write-Log "?? RAM: ${RAM}GB $(if ($RAM -lt 4) { "(?? Below recommended 4GB)" } else { "(? Adequate)" })"
        Write-Log "?? TPM: $(if ($TPM) { "Present (Version: $($TPM.SpecVersion))" } else { "? Not detected (will be bypassed)" })"
        
        try {
            $SecureBoot = Confirm-SecureBootUEFI -ErrorAction SilentlyContinue
            Write-Log "??? Secure Boot: $(if ($SecureBoot) { "? Enabled" } else { "? Disabled (will be bypassed)" })"
        } catch {
            Write-Log "??? Secure Boot: ? Cannot determine (Legacy BIOS - will be bypassed)"
        }
        
        $SystemDrive = Get-WmiObject -Class Win32_LogicalDisk | Where-Object { $_.DeviceID -eq $env:SystemDrive }
        $FreeSpaceGB = [math]::Round($SystemDrive.FreeSpace / 1GB, 1)
        Write-Log "?? System Drive Free Space: ${FreeSpaceGB}GB $(if ($FreeSpaceGB -lt 32) { "(?? May be tight, but we'll try anyway!)" } else { "(? Sufficient)" })"
        
        Write-Log "=== END SYSTEM INFORMATION ==="
        
    } catch {
        Write-Log "? Error gathering system information: $($_.Exception.Message)" "WARN"
    }
}

# Main script execution
function Main {
    Write-Log "?????? WINDOWS 11 RMM FORCE UPGRADE SCRIPT STARTED ??????" "WARN"
    Write-Log "Script version: 1.5 - RMM FORCE UPGRADE Edition (?? FULLY AUTOMATED ??)" "WARN"
    
    # Check execution context
    $Context = Test-ExecutionContext
    
    if (-not $Context.IsAdmin -and -not $Context.IsSystem) {
        Write-Log "? INSUFFICIENT PRIVILEGES: This script requires Administrator or SYSTEM privileges" "ERROR"
        Write-Log "?? Run as Administrator or deploy via RMM with SYSTEM context" "ERROR"
        exit 1
    }
    
    # Display automated warning
    $AutoWarning = @"
?????? AUTOMATED FORCE UPGRADE MODE ACTIVE ??????

This script will automatically:
? Bypass ALL Windows 11 compatibility checks
? Modify registry to disable upgrade blocks  
? Force upgrade regardless of hardware limitations
? Proceed without user confirmation (RMM mode)

Perfect for:
??? Virtual Machines (like your 2GB RAM Synology VM!)
?? Testing environments
?? Mass deployments where compatibility is not a concern

?? This WILL result in an unsupported Windows 11 installation!
"@

    Write-Log $AutoWarning "WARN"
    
    # Show system info
    Show-SystemInfo
    
    # Check current Windows version
    $OSVersion = (Get-WmiObject -Class Win32_OperatingSystem).Caption
    $BuildNumber = (Get-WmiObject -Class Win32_OperatingSystem).BuildNumber
    Write-Log "?? Current OS: $OSVersion (Build: $BuildNumber)"
    
    # Check if already on Windows 11
    if ($BuildNumber -ge 22000) {
        Write-Log "? System is already running Windows 11 (Build $BuildNumber)" "SUCCESS"
        Write-Log "?? No upgrade needed - system is up to date"
        Write-Log "=== RMM FORCE UPGRADE SCRIPT COMPLETED (NO ACTION NEEDED) ==="
        exit 0
    }

    # Auto-confirm or check parameter
    if ($AutoConfirm) {
        Write-Log "?? AUTO-CONFIRM MODE: Proceeding with force upgrade automatically" "SUCCESS"
        Write-Log "?? Starting upgrade in 10 seconds..."
        Start-Sleep -Seconds 10
        Start-ForceWin11Upgrade
    } else {
        Write-Log "? Auto-confirm disabled but running in non-interactive mode" "ERROR"
        Write-Log "?? Use -AutoConfirm switch or run interactively for manual confirmation"
        exit 1
    }

    Write-Log "=== WINDOWS 11 RMM FORCE UPGRADE SCRIPT COMPLETED ==="
    Write-Log "?? Monitor the upgrade progress using the locations mentioned above"
    Write-Log "?? The system will restart automatically when the upgrade is ready"
}

# Execute main function
Main
