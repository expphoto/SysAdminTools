# Windows 11 Upgrade Scripts

This folder contains PowerShell scripts for checking Windows 11 compatibility and performing upgrades in different deployment scenarios.

## Scripts Overview

### 1. Windows11_Upgrade_Script_Fixed.ps1
**Standard Version** - For individual user execution or local administrative use.

- **Execution Context**: Local Administrator or User
- **Use Case**: Manual execution, individual computers
- **Features**:
  - Checks Windows 11 compatibility using Microsoft's official tools
  - Shows user notifications and prompts
  - Creates user-specific scheduled tasks
  - Logs to user temp directory

### 2. Windows11_Upgrade_Script_System.ps1
**System Version** - For mass deployment via RMM tools like ScreenConnect.

- **Execution Context**: SYSTEM account (via RMM tools)
- **Use Case**: Mass deployment, automated execution across multiple computers
- **Features**:
  - Designed for SYSTEM account execution
  - Multi-user notification system for all logged-in users
  - System-wide scheduled task creation
  - Enhanced logging for enterprise deployment
  - Automatic detection of logged-in users
  - Centralized logging to `$env:ProgramData`

### 3. Windows11_Upgrade_Script_Force.ps1
**⚠️ FORCE UPGRADE Version** - Bypasses ALL compatibility checks for testing/VMs.

- **Execution Context**: Local Administrator (REQUIRED)
- **Use Case**: Interactive testing, individual VMs, manual force upgrades
- **⚠️ WARNING**: This bypasses all hardware requirements and may result in unsupported installations
- **Features**:
  - **Bypasses ALL Windows 11 compatibility checks**
  - **Registry modifications to disable upgrade blocks**
  - **Interactive confirmations and warnings**
  - **Perfect for manual testing scenarios**

### 4. Windows11_Upgrade_Script_Force_RMM.ps1
**🤖 AUTOMATED FORCE UPGRADE** - Fully automated, no user interaction required.

- **Execution Context**: SYSTEM/Administrator via RMM tools
- **Use Case**: **Mass VM deployments, automated testing, your Synology VM scenario!**
- **⚠️ WARNING**: Completely automated - no confirmations, just forces the upgrade
- **Features**:
  - **Fully non-interactive for RMM deployment**
  - **Bypasses ALL Windows 11 compatibility checks automatically**
  - **No MessageBox errors when running via RMM tools**
  - **Enhanced logging for remote monitoring**
  - **Perfect for your 2GB RAM VM - just upload and run!**

## Deployment Guide

### For Individual Computers
```powershell
# Run as Administrator
.\Windows11_Upgrade_Script_Fixed.ps1
```

### For FORCE Upgrade (Interactive Testing)
```powershell
# Must run as Administrator - Interactive with confirmations
.\Windows11_Upgrade_Script_Force.ps1
```

### For AUTOMATED FORCE Upgrade (RMM/Mass Deployment)
```powershell
# Perfect for your Synology VM via RMM tools - NO user interaction!
.\Windows11_Upgrade_Script_Force_RMM.ps1
```
**🚀 The RMM version is what you want for your VM!** It:
- Runs completely automatically
- No dialog box errors in RMM environments
- Just uploads, runs, and forces Windows 11 upgrade

**⚠️ Both will bypass ALL compatibility checks including:**
- TPM 2.0 requirement
- Secure Boot requirement  
- CPU compatibility
- RAM requirements (perfect for 2-4GB systems!)
- Storage space checks
- UEFI requirements

## Batch Launchers

- `win11_check_normal.bat`: Runs `Windows11_Upgrade_Universal.ps1 -Silent` for a normal (non‑force) path.
- `win11_deploy.bat`: Runs `Windows11_Upgrade_Universal.ps1 -Force -Silent` to initiate a forced upgrade.
- `Force Run Paste.txt`: One‑liner to download and run the universal script with `-Force` from `%TEMP%`.

## Universal Script Force Mode (How it works)

`Windows11_Upgrade_Universal.ps1 -Force` applies registry bypasses and launches Microsoft’s Installation Assistant silently:

- `HKLM\\SYSTEM\\Setup\\LabConfig` → `BypassTPMCheck=1`, `BypassSecureBootCheck=1`, `BypassRAMCheck=1`, `BypassCPUCheck=1`, `BypassStorageCheck=1`
- `HKLM\\SYSTEM\\Setup\\MoSetup` → `AllowUpgradesWithUnsupportedTPMOrCPU=1`
- Clears `AppCompatFlags` markers; sets helpful signals (e.g., `HKCU\\Software\\Microsoft\\PCHC\\UpgradeEligibility=1`)
- Starts Installation Assistant with `/quietinstall /skipeula /auto upgrade /NoRestartUI /copylogs %TEMP%`

Notes: `-Force` requires Administrator. Disk space/BitLocker/firmware realities still apply. This path does not rely on WSUS approval.

## Quick Commands

```bat
:: Normal check
win11_check_normal.bat

:: Force upgrade silently
win11_deploy.bat

:: Paste into remote CMD (from Force Run Paste.txt)
@echo off & powershell -NoP -EP Bypass -Command "iwr 'https://f001.backblazeb2.com/file/NinjaWebMedia/Windows11_Upgrade_Universal.ps1' -OutFile \"$env:TEMP\win11_universal.ps1\" -UseBasicParsing" ^& if exist "%TEMP%\win11_universal.ps1" (powershell -NoP -EP Bypass -File "%TEMP%\win11_universal.ps1" -Force ^& del "%TEMP%\win11_universal.ps1")
```

### For Mass Deployment via ScreenConnect/RMM
1. Upload `Windows11_Upgrade_Script_System.ps1` to your RMM tool
2. Deploy as a script that runs with SYSTEM privileges
3. The script will:
   - Automatically detect all logged-in users
   - Send notifications to each active user session
   - Create system-wide scheduled tasks for ongoing alerts
   - Log all activities centrally

#### ScreenConnect Command Example:
```powershell
powershell.exe -ExecutionPolicy Bypass -File "C:\Path\To\Windows11_Upgrade_Script_System.ps1"
```

## Script Behavior

### Compatible Systems
- **Action**: Downloads and runs Windows 11 Installation Assistant
- **Notifications**: Informs users that upgrade is starting
- **Logging**: Records successful initiation of upgrade process

### Incompatible Systems
- **Action**: Creates monthly reminder alerts
- **Notifications**: Warns users about compatibility issues
- **Scheduled Task**: Creates recurring monthly alerts for all users
- **Logging**: Details specific compatibility failures and recommendations

### Already Windows 11 Systems
- **Action**: No action required
- **Notifications**: Confirms system is already up to date
- **Logging**: Records current build number and completion

## Logging

### Standard Version
- **Log Location**: `$env:TEMP\Win11Upgrade.log`
- **Format**: `[Timestamp] [Level] Message`

### System Version
- **Log Location**: `$env:ProgramData\Win11Upgrade_System.log`
- **Format**: `[Timestamp] [ComputerName] [Level] Message`
- **Fallback**: Windows Event Log if file logging fails

## Requirements

- **PowerShell**: 5.1 or later
- **Operating System**: Windows 10 (for upgrades) or Windows 11
- **Privileges**: 
  - Standard version: Local Administrator recommended
  - System version: SYSTEM account (automatically provided by RMM tools)
- **Network**: Internet access for downloading Microsoft tools

## Troubleshooting

### Common Issues
1. **Execution Policy**: Scripts automatically set bypass for current session
2. **Network Issues**: Scripts fall back to basic compatibility checks
3. **Notification Failures**: System version has multiple fallback methods
4. **Logging Failures**: System version falls back to Windows Event Log

### Error Codes
- **0**: Compatible, upgrade initiated successfully
- **1**: Not compatible, alerts configured
- **-1**: Error during compatibility check

## Version History

- **v1.2**: Enhanced compatibility logging, added UEFI and storage checks
- **v1.3**: System edition for mass deployment via RMM tools

## Support

For issues or questions:
1. Check logs at specified locations
2. Verify network connectivity
3. Ensure proper execution privileges
4. Contact IT support for enterprise deployments
