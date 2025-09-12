# Interactive Patching Automation

PowerShell tools for interactive patching, safe cleanup, and continuous remediation of Windows servers.

Primary script: `interactive-patching-automation.ps1`

## Highlights

- Interactive input (paste server list or “needs attention” text)
- Continuous remediation loop until clear (updates installed, no reboot pending, disk OK)
- Safe disk cleanup when space is low (temp/cache/logs + DISM component cleanup)
- Windows Update install via COM API with per‑update results and reboot handling; also nudges USO (Windows Update Orchestrator) so Settings UI reflects activity
- CSV reports and detailed log files for auditing

## Defaults (as of 2025‑09‑12)

- `RetryIntervalMinutes`: 5
- `MaxCycles`: 0 (run indefinitely until all reachable servers are clear)
- `RebootWaitMinutes`: 10 (poll for host to return after reboot)
- `TestMode`: off (set `-TestMode` to simulate installs/reboots)
- `QuickTest`: off (set `-QuickTest` to only run reachability tests)

Clear criteria per server: `UpdatesTotal = 0` AND `PendingReboot = $false` AND `DiskSpaceGB >= 10`.

## Quick Start

```powershell
pwsh -NoProfile -File .\interactive-patching-automation.ps1
```
## Sample Usage
```powershell
pwsh -NoProfile -File .\interactive-patching-automation.ps1 -Servers 192.168.0.56 -Username 'testdomain.local\johndoe' -Password 'Temp1234' -RepairWindowsUpdate
```
Paste servers/outputs when prompted. Press Enter on an empty line to start.

Connectivity only:
```powershell
pwsh -NoProfile -File .\interactive-patching-automation.ps1 -QuickTest
```

## Parameters

- `-RetryIntervalMinutes <int>`: Minutes to wait between cycles (default 5; TestMode uses 10 seconds)
- `-MaxCycles <int>`: 0 to run until clear; positive value caps cycles
- `-RebootWaitMinutes <int>`: Max minutes to poll for host to return after reboot (default 10)
- `-AutoFixWinRM`: When WinRM connection fails, attempt remote remediation via WMI to enable WinRM and open the firewall (default on)
- `-TestMode`: Simulate updates/reboots/cleanup; no changes on targets
- `-QuickTest`: Exit after reachability checks
- `-RepairWindowsUpdate`: If an install attempt fails, reset SoftwareDistribution and catroot2 on the target and retry once in the same cycle
- `-ForceSystemInstall`: Skip user-token COM path; use SYSTEM + USO scheduled task from the start (useful in WSUS/GPO environments).
- `-CleanupTasks`: Remove scheduled task and temp files after SYSTEM run (default on).
- `-SystemInstallTimeoutMinutes`: Max minutes to wait for SYSTEM install (default 60).
- `-MonitorSystemInstall`: Stream live heartbeat/events during SYSTEM install (default on).

## What It Does

1. Configures WinRM TrustedHosts for the target list.
2. Tests connectivity and gathers OS/domain/free‑space info.
3. For each server each cycle:
   - Runs system analysis (pending reboot, updates available, disk space).
   - If needed, performs safe disk cleanup (older than 7 days in well‑known temp/cache dirs, plus DISM StartComponentCleanup).
   - Installs Windows Updates (accept EULAs, download, install) and initiates reboot if required.
   - Marks the server complete only when update/reboot/disk criteria are all satisfied.
4. Repeats every `RetryIntervalMinutes` until all servers are clear (or `MaxCycles` reached). If a server reboots and returns early, the next cycle can start immediately. In WSUS/GPO environments, the script can switch to a SYSTEM/USO path and monitor progress live.

## Output

- Log: `Working-Patching-Log_YYYYMMDD_HHMMSS.log`
- Connectivity CSV: `Working-Connectivity-Results_YYYYMMDD_HHMMSS.csv`
- Final CSV: `Working-Interactive-Results_YYYYMMDD_HHMMSS.csv` (or `_ERROR.csv` on crash)
- SYSTEM heartbeat (transient): `C:\\ProgramData\\InteractivePatching\\WU-Heartbeat.txt` (removed when `-CleanupTasks` is on)

Files are written to the `Patching` folder by default.

## Prerequisites

- Management host: Windows 10/Server 2016+ with PowerShell 5.1+ or PowerShell 7+
- Targets: Windows Server 2012 R2+ with WinRM enabled (`Enable-PSRemoting -Force`)
- Creds: Account with local admin rights on targets

## Related Scripts

- `simple-patching-automation.ps1`: Minimal alternative for basic flows
- `needs-attention-fix.ps1`: Legacy workflow retained for compatibility
- `servers-example.txt`: Sample list format

## Ignore/Generated Files

Generated logs and CSVs are ignored via `.gitignore`. It is safe to delete these files.

## Notes

- Update install uses the Windows Update COM API; installs may complete during reboot.
- Cleanup is conservative (temp/cache/logs older than 7 days) and uses DISM StartComponentCleanup.
- For visible progress on the target's GUI, open Settings > Windows Update. The script also triggers USO (usoclient) to surface state changes in the UI and writes an Application event with source `InteractivePatchingAutomation`.
- During SYSTEM installs, a heartbeat file and Application events (ID 10011) are emitted so you can see scan/download/install progress without waiting blindly.

## Monitor Mode

- Enable live monitoring with `-MonitorSystemInstall` (on by default). When the SYSTEM path is used, the controller tails:
  - Heartbeat file at `C:\\ProgramData\\InteractivePatching\\WU-Heartbeat.txt` showing Scan/Download/Install phases.
  - Application log events (source `InteractivePatchingAutomation`, Event ID 10011).
- Artifacts are cleaned after completion when `-CleanupTasks` is left on (default). Set `-CleanupTasks:$false` to keep files for post‑mortem.

## WSUS/GPO Example

```powershell
pwsh -NoProfile -File .\interactive-patching-automation.ps1 `
  -Servers 192.168.0.56 `
  -Username 'testdomain.local\johndoe' `
  -Password 'Temp1234' `
  -ForceSystemInstall `
  -RepairWindowsUpdate `
  -SystemInstallTimeoutMinutes 90
```
- If you are not running your console as Administrator, the script will skip updating local WinRM TrustedHosts and log a warning. Elevate to configure TrustedHosts.

## Changelog

- 2025‑09‑12: Interactive script updated: 5‑minute default retries, infinite cycles by default, explicit clear criteria, safe cleanup, per‑update logging.
