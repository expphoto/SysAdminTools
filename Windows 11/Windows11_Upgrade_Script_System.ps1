<#
.SYNOPSIS
    Windows 11 Compatibility Check and Upgrade Script - SYSTEM Version

.DESCRIPTION
    This script is designed to run as SYSTEM (via ScreenConnect or similar RMM tools) 
    and checks Windows 11 compatibility. It creates alerts for all logged-in users
    and sets up system-wide scheduled tasks for incompatible systems.

.NOTES
    Version: 1.3 - System Edition
    Author: MSP Admin
    Date: September 2025
    Requires: PowerShell 5.1+, Windows 10, SYSTEM privileges
    
    Version 1.3 System Edition Changes:
    - Designed for SYSTEM account execution via RMM tools
    - Multi-user notification system for all logged-in users
    - System-wide scheduled task creation
    - Enhanced logging for mass deployment scenarios
    - Automatic detection of running as SYSTEM
#>

# Script configuration for SYSTEM execution
$ScriptName = "Win11UpgradeScript_System"
$LogPath = "$env:ProgramData\Win11Upgrade_System.log"
$ScheduledTaskName = "Win11CompatibilityAlert_System"
$HardwareReadinessUrl = "https://aka.ms/HWReadinessScript"
$Win11AssistantUrl = "https://go.microsoft.com/fwlink/?linkid=2171764"
$Win11MediaCreationUrl = "https://go.microsoft.com/fwlink/?linkid=2156295"

# Initialize logging with system-wide location
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $TimeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $ComputerName = $env:COMPUTERNAME
    $LogEntry = "[$TimeStamp] [$ComputerName] [$Level] $Message"
    Write-Host $LogEntry
    try {
        Add-Content -Path $LogPath -Value $LogEntry -ErrorAction SilentlyContinue
    } catch {
        # Fallback to Windows Event Log if file logging fails
        Write-EventLog -LogName Application -Source "Windows" -EntryType Information -EventId 1001 -Message $LogEntry -ErrorAction SilentlyContinue
    }
}

# Set execution policy for this session
try {
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
    Write-Log "Execution policy set to Bypass for this session"
} catch {
    Write-Log "Warning: Could not set execution policy: $($_.Exception.Message)" "WARN"
}

# Function to check if running as SYSTEM
function Test-SystemAccount {
    $CurrentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    return $CurrentUser.Name -eq "NT AUTHORITY\SYSTEM"
}

# Function to get all logged-in users
function Get-LoggedInUsers {
    try {
        $LoggedUsers = @()
        $Sessions = quser 2>$null | Select-Object -Skip 1
        
        if ($Sessions) {
            foreach ($Session in $Sessions) {
                if ($Session -match '^\s*(\S+)\s+(\S+)\s+(\d+)\s+(\S+)\s+(.+)$') {
                    $Username = $Matches[1]
                    $SessionId = $Matches[3]
                    $State = $Matches[4]
                    
                    if ($State -eq "Active" -and $Username -ne "SYSTEM") {
                        $LoggedUsers += @{
                            Username = $Username
                            SessionId = $SessionId
                        }
                    }
                }
            }
        }
        
        return $LoggedUsers
    } catch {
        Write-Log "Error getting logged-in users: $($_.Exception.Message)" "WARN"
        return @()
    }
}

# Function to show notifications to all logged-in users
function Show-SystemNotification {
    param(
        [string]$Title,
        [string]$Message,
        [string]$Icon = "Information"
    )
    
    Write-Log "SYSTEM NOTIFICATION: [$Title] $Message"
    
    # Get all logged-in users
    $LoggedUsers = Get-LoggedInUsers
    
    if ($LoggedUsers.Count -eq 0) {
        Write-Log "No active user sessions found for notification display"
        return
    }
    
    # Create notification script for each user
    $NotificationScript = @"
Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.MessageBox]::Show('$Message', '$Title', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::$Icon)
"@
    
    $TempNotificationScript = "$env:TEMP\Win11Notification_$([System.Guid]::NewGuid().ToString()).ps1"
    $NotificationScript | Out-File -FilePath $TempNotificationScript -Encoding ASCII -Force
    
    # Send notification to each logged-in user
    foreach ($User in $LoggedUsers) {
        try {
            Write-Log "Sending notification to user: $($User.Username) (Session: $($User.SessionId))"
            
            # Use PsExec equivalent or direct session targeting
            $ProcessStartInfo = New-Object System.Diagnostics.ProcessStartInfo
            $ProcessStartInfo.FileName = "powershell.exe"
            $ProcessStartInfo.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$TempNotificationScript`""
            $ProcessStartInfo.UseShellExecute = $false
            $ProcessStartInfo.CreateNoWindow = $true
            
            # Try to run in user session
            Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Normal -Command `"& '$TempNotificationScript'`"" -NoNewWindow -ErrorAction SilentlyContinue
            
        } catch {
            Write-Log "Failed to send notification to $($User.Username): $($_.Exception.Message)" "WARN"
        }
    }
    
    # Clean up temp file after a delay
    Start-Sleep -Seconds 10
    Remove-Item $TempNotificationScript -Force -ErrorAction SilentlyContinue
}

# Function to create system-wide toast notification (Windows 10/11)
function Show-ToastNotification {
    param(
        [string]$Title,
        [string]$Message
    )
    
    try {
        $ToastXml = @"
<toast>
    <visual>
        <binding template="ToastGeneric">
            <text>$Title</text>
            <text>$Message</text>
        </binding>
    </visual>
    <actions>
        <action content="OK" arguments="ok" />
    </actions>
</toast>
"@
        
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
        
        $Template = [Windows.Data.Xml.Dom.XmlDocument]::new()
        $Template.loadXml($ToastXml)
        $Toast = [Windows.UI.Notifications.ToastNotification]::new($Template)
        $Notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("Windows 11 Upgrade Assistant")
        $Notifier.Show($Toast)
        
        Write-Log "Toast notification sent: $Title"
    } catch {
        Write-Log "Toast notification failed, falling back to message box: $($_.Exception.Message)" "WARN"
        Show-SystemNotification -Title $Title -Message $Message -Icon "Information"
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
        
        try {
            Invoke-WebRequest -Uri $HardwareReadinessUrl -OutFile $TempScript -UseBasicParsing
        }
        catch {
            Write-Log "Failed to download Microsoft script, falling back to basic check" "WARN"
            return Test-BasicWin11Requirements
        }
        
        if (-not (Test-Path $TempScript)) {
            Write-Log "Failed to download Microsoft script, falling back to basic check" "WARN"
            return Test-BasicWin11Requirements
        }

        # Run the compatibility check
        Write-Log "Executing HardwareReadiness.ps1 script"
        
        $Result = $null
        $ExitCode = $null
        
        try {
            $Result = & $TempScript 2>&1
            $ExitCode = $LASTEXITCODE
        }
        catch {
            Write-Log "Error executing HardwareReadiness.ps1: $($_.Exception.Message)" "ERROR"
            Write-Log "Falling back to basic compatibility check" "WARN"
            Remove-Item $TempScript -Force -ErrorAction SilentlyContinue
            return Test-BasicWin11Requirements
        }
        
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
        Write-Log "Error during compatibility check: $($_.Exception.Message)" "ERROR"
        Write-Log "Falling back to basic compatibility check" "WARN"
        return Test-BasicWin11Requirements
    }
}

# Function to perform Windows 11 upgrade (SYSTEM context)
function Start-Win11Upgrade {
    Write-Log "Starting Windows 11 upgrade process (SYSTEM context)"

    try {
        # Log upgrade start
        Write-Log "Starting Windows 11 upgrade - device is compatible"
        Show-SystemNotification -Title "Windows 11 Upgrade" -Message "Your device is compatible with Windows 11. Starting upgrade process. This may take some time and will require restarts."

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
            Show-SystemNotification -Title "Windows 11 Upgrade" -Message "Windows 11 upgrade has been initiated. Your computer will restart automatically when ready."
        }
        else {
            throw "Failed to download Installation Assistant"
        }
    } catch {
        Write-Log "Error during upgrade process: $($_.Exception.Message)" "ERROR"
        Show-SystemNotification -Title "Upgrade Error" -Message "Failed to start Windows 11 upgrade. Contact IT support for assistance." -Icon "Error"
    }
}

# Function to create system-wide monthly alert task for incompatible systems
function New-SystemMonthlyAlertTask {
    param([bool]$IsInitialRun = $false)

    try {
        # Remove existing task if it exists
        Get-ScheduledTask -TaskName $ScheduledTaskName -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false

        # Define the script block for the scheduled task (multi-user alert)
        $ScriptBlock = @"
# Multi-user alert script for Windows 11 compatibility
`$LoggedUsers = @()
`$Sessions = quser 2>`$null | Select-Object -Skip 1

if (`$Sessions) {
    foreach (`$Session in `$Sessions) {
        if (`$Session -match '^\s*(\S+)\s+(\S+)\s+(\d+)\s+(\S+)\s+(.+)`$') {
            `$Username = `$Matches[1]
            `$SessionId = `$Matches[3]
            `$State = `$Matches[4]
            
            if (`$State -eq "Active" -and `$Username -ne "SYSTEM") {
                try {
                    Add-Type -AssemblyName System.Windows.Forms
                    [System.Windows.Forms.MessageBox]::Show(
                        'Your computer does not meet Windows 11 requirements. Consider upgrading hardware components or contact IT support for assistance. Windows 10 support ends October 14, 2025.',
                        'Windows 11 Compatibility Alert - $env:COMPUTERNAME',
                        [System.Windows.Forms.MessageBoxButtons]::OK,
                        [System.Windows.Forms.MessageBoxIcon]::Warning
                    )
                } catch {
                    # Fallback notification method
                    msg `$Username "Windows 11 Compatibility Alert: Your computer does not meet Windows 11 requirements. Contact IT support for assistance."
                }
            }
        }
    }
}
"@

        # Create script file for scheduled task in system location
        $TaskScriptPath = "$env:ProgramData\Win11AlertTask_System.ps1"
        $ScriptBlock | Out-File -FilePath $TaskScriptPath -Encoding ASCII -Force

        # Create the scheduled task trigger (monthly on the 15th at 2 PM)
        $Trigger = New-ScheduledTaskTrigger -Once -At "2:00 PM" -RepetitionInterval (New-TimeSpan -Days 30)

        # Create the action (run as SYSTEM)
        $Action = New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$TaskScriptPath`""

        # Create task principal (run as SYSTEM with highest privileges)
        $Principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest

        # Register the scheduled task
        Register-ScheduledTask -TaskName $ScheduledTaskName -Trigger $Trigger -Action $Action -Principal $Principal -Description "Monthly Windows 11 compatibility reminder for all users"

        Write-Log "System-wide monthly alert task created successfully"

        # Log compatibility status and send immediate notification
        if ($IsInitialRun) {
            Write-Log "System incompatible with Windows 11 - system-wide monthly alerts configured"
            Show-SystemNotification -Title "Windows 11 Compatibility Alert" -Message "This computer does not meet Windows 11 requirements. You will receive monthly reminders about this. Please contact IT support for assistance with hardware upgrades." -Icon "Warning"
        }

    } catch {
        Write-Log "Error creating system scheduled task: $($_.Exception.Message)" "ERROR"
    }
}

# Main script execution
function Main {
    Write-Log "=== Windows 11 System Upgrade Script Started ==="
    Write-Log "Script version: 1.3 - System Edition (Mass Deployment)"
    
    # Verify running as SYSTEM
    $IsSystemAccount = Test-SystemAccount
    Write-Log "Running as SYSTEM account: $IsSystemAccount"
    
    if (-not $IsSystemAccount) {
        Write-Log "WARNING: This script is designed to run as SYSTEM account. Current context may limit functionality." "WARN"
    }
    
    Write-Log "Computer name: $env:COMPUTERNAME"
    
    # Get logged-in users for reporting
    $LoggedUsers = Get-LoggedInUsers
    if ($LoggedUsers.Count -gt 0) {
        Write-Log "Active user sessions found: $($LoggedUsers.Count)"
        foreach ($User in $LoggedUsers) {
            Write-Log "  - User: $($User.Username) (Session: $($User.SessionId))"
        }
    } else {
        Write-Log "No active user sessions detected"
    }
    
    # Check current Windows version
    $OSVersion = (Get-WmiObject -Class Win32_OperatingSystem).Caption
    $BuildNumber = (Get-WmiObject -Class Win32_OperatingSystem).BuildNumber
    Write-Log "Current OS: $OSVersion (Build: $BuildNumber)"
    
    # Check if already on Windows 11
    if ($BuildNumber -ge 22000) {
        Write-Log "System is already running Windows 11 (Build $BuildNumber) - no action needed"
        Show-SystemNotification -Title "Windows 11 Status" -Message "This computer is already running Windows 11. No upgrade needed."
        Write-Log "=== Windows 11 System Upgrade Script Completed ==="
        return
    }

    # Perform compatibility check
    $CompatibilityResult = Test-Win11Compatibility

    switch ($CompatibilityResult) {
        0 {
            # Compatible - proceed with upgrade
            Write-Log "=== FINAL RESULT: SYSTEM IS COMPATIBLE WITH WINDOWS 11 ==="
            Write-Log "All Windows 11 requirements are met. Proceeding with upgrade process."

            Write-Log "SYSTEM privileges confirmed - starting upgrade process"
            Start-Win11Upgrade
        }
        1 {
            # Not compatible - set up system-wide alerts
            Write-Log "=== FINAL RESULT: SYSTEM IS NOT COMPATIBLE WITH WINDOWS 11 ==="
            Write-Log "One or more Windows 11 requirements are not met. Setting up system-wide monthly reminder alerts."
            Write-Log "BUSINESS DECISION REQUIRED: Review compatibility issues above to determine if hardware upgrades are cost-effective vs. continuing with Windows 10 until end of support (Oct 2025)" "WARN"
            New-SystemMonthlyAlertTask -IsInitialRun $true
        }
        default {
            # Error or undetermined
            Write-Log "=== FINAL RESULT: COMPATIBILITY STATUS UNKNOWN ===" "ERROR"
            Write-Log "Unable to determine Windows 11 compatibility (Exit code: $CompatibilityResult)" "ERROR"
            Write-Log "TROUBLESHOOTING: Check network connectivity, antivirus interference, or hardware compatibility" "WARN"
            Show-SystemNotification -Title "Compatibility Check Error" -Message "Unable to determine Windows 11 compatibility. Please contact IT support for manual assessment." -Icon "Error"
        }
    }

    Write-Log "=== Windows 11 System Upgrade Script Completed ==="
}

# Execute main function
Main
