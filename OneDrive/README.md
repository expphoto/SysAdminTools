# OneDrive Tools

This folder contains OneDrive migration, redirection cleanup, and Known Folder Move (KFM) configuration scripts for a mix of interactive use, RMM deployment, and ScreenConnect-style remote execution.

## Script Guide

### `Complete-OneDrive-Migration.ps1`

Primary all-in-one PowerShell migration script.

- Purpose:
  - Reset legacy folder redirection.
  - Configure OneDrive KFM policy.
  - Optionally migrate data from `H:` or another home location.
  - Start OneDrive and validate the resulting state.
- Best for:
  - Technician-run migrations.
  - Controlled cutovers where data copy is part of the job.
  - Troubleshooting a single user in detail.
- Important behavior:
  - Uses richer detection and logging than the batch variants.
  - Can run cleanup only, skip migration, or run as a dry run.
  - Works best when run in the target user's context unless you deliberately adapt it for remote management.
- Parameters:
  - `-WhatIf`
  - `-LogPath <path>`
  - `-TenantID <GUID>`
  - `-CleanupOnly`
  - `-SkipDataMigration`

### `Clean up Home Directory Redirects.ps1`

Focused repair script for registry-based shell folder problems.

- Purpose:
  - Reset broken or legacy shell folder redirection back to local profile paths.
- Best for:
  - Systems where you do not want to touch OneDrive policy or copy data.
  - Fast remediation of `Desktop`, `Documents`, `Pictures`, and related path issues.
- Important behavior:
  - Targets user shell folder registry keys only.
  - Does not configure KFM, does not restart OneDrive, and does not move files.

### `Repair Shell Folders.ps1`

Shell-folder repair utility for targeted registry correction.

- Purpose:
  - Fix damaged or incorrect Windows shell folder values.
- Best for:
  - Registry repair and profile-path cleanup when OneDrive is not the main issue.
- Important behavior:
  - Typically narrower in scope than the migration or no-migration OneDrive scripts.

### `Local-OD-Migrate-ADSHARE`

Earlier and lighter migration variant.

- Purpose:
  - Provide a smaller-scope path for moving away from AD home-share redirection.
- Best for:
  - Older workflows already using this script.
  - Reference when comparing newer migration behavior against prior logic.
- Important behavior:
  - Less comprehensive than `Complete-OneDrive-Migration.ps1`.

### `OneDrive-Migration-Verbose.bat`

Verbose batch-based migration/configuration flow.

- Purpose:
  - Perform cleanup and migration steps from a batch-only entrypoint.
- Best for:
  - RMM jobs where a batch file is easier to deploy than PowerShell.
  - Troubleshooting with verbose text logging.
- Important behavior:
  - Uses extensive log output to `%PUBLIC%\Documents\OneDriveMigration`.
  - Includes OneDrive detection, redirection cleanup, and data migration behavior.
  - More suitable for staged or legacy automation than for new all-profile deployments.

### `OneDrive-Config-NoMigration.ps1`

Standard PowerShell no-migration configuration script for all local profiles.

- Purpose:
  - Configure OneDrive KFM policy without copying data.
  - Apply per-user shell folder and OneDrive cleanup to all real user profiles on the machine.
  - Restart Explorer and OneDrive only for users who are actively logged in.
- Best for:
  - RMM or admin deployments where you want to prep every profile in one run.
  - Machines that need KFM enabled without touching `H:` mappings or moving files immediately.
  - ManageEngine / Endpoint Central jobs where PowerShell can run in user context with administrative rights.
- Important behavior:
  - Writes OneDrive policy to `HKLM\SOFTWARE\Policies\Microsoft\OneDrive`.
  - Enumerates profiles from `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList`.
  - Loads `NTUSER.DAT` for unloaded profiles, writes the HKCU-equivalent registry changes, then unloads the hive.
  - Clears stale OneDrive flags such as `KfmIsDoneSilentOptIn` and `SilentBusinessConfigCompleted` for every processed profile.
  - Removes `ResetPending` markers when present.
  - Uses temporary scheduled tasks only to restart Explorer and OneDrive for active sessions, so offline users still get registry prep without a forced session action.
  - If run from RMM in the logged-in user's context and with admin rights, it will restart Explorer and OneDrive for that active user while still updating all other local profiles on the machine.
- Does not do:
  - No file copy.
  - No `H:` unmap.
  - No reboot.

### `OneDrive-Config-NoMigration.bat`

Batch entrypoint for the same no-migration all-profile workflow.

- Purpose:
  - Provide a `.bat` deployment option while still updating all local profiles.
- Best for:
  - RMM systems that prefer batch execution but still allow PowerShell to run inside the job.
  - ManageEngine-style deployments that prefer a `.bat` wrapper but can still invoke local PowerShell.
- Important behavior:
  - Writes HKLM OneDrive policy directly.
  - Calls embedded PowerShell blocks to enumerate profiles, load/unload user hives, and apply per-user registry changes across all profiles.
  - Restarts Explorer and OneDrive only for active user sessions.
  - If run from RMM in the logged-in user's context and with admin rights, it will restart Explorer and OneDrive for that active user while still updating all other local profiles on the machine.
- Does not do:
  - No data migration.
  - No drive unmapping.

### `ScreenConnect-OneDrive-Config-AllProfiles.ps1`

ScreenConnect-oriented PowerShell version with `#!ps` header.

- Purpose:
  - Run cleanly from ScreenConnect or similar remote tools that execute PowerShell directly.
  - Configure KFM and prep all local user profiles in a single run.
- Best for:
  - ScreenConnect toolbox or run-command deployments.
  - SYSTEM-context execution where profile-wide registry work is needed.
- Important behavior:
  - Starts with `#!ps` for ScreenConnect-style execution.
  - Writes HKLM policy once.
  - Loads and edits all real user hives found in `ProfileList`.
  - Tries to restart Explorer and OneDrive only for users who are actively logged in.

### `disable-onedrive-move-local.sh`

Shell script related to disabling or undoing local OneDrive move behavior.

- Purpose:
  - Support non-Windows or administrative workflow tasks tied to OneDrive path handling.
- Best for:
  - Reference or niche support use in mixed environments.

## Policy Values Used By Current KFM Config Scripts

The current no-migration PowerShell, batch, and ScreenConnect scripts write these OneDrive machine policies under `HKLM\SOFTWARE\Policies\Microsoft\OneDrive`:

- `KFMSilentOptIn`
- `KFMSilentOptInDesktop`
- `KFMSilentOptInDocuments`
- `KFMSilentOptInPictures`
- `KFMSilentOptInWithNotification`
- `KFMBlockOptOut`
- `SilentAccountConfig`
- `FilesOnDemandEnabled`

They also clear stale per-user OneDrive state when present, including:

- `KfmIsDoneSilentOptIn`
- `SilentBusinessConfigCompleted`
- Root-level OneDrive silent-config remnants
- `ResetPending`

## Choosing The Right Script

- Use `Complete-OneDrive-Migration.ps1` when you want a fuller migration workflow and may need to copy data.
- Use `OneDrive-Config-NoMigration.ps1` when you want one PowerShell script to prep all profiles without migrating files, especially from ManageEngine / Endpoint Central.
- Use `OneDrive-Config-NoMigration.bat` when your deployment tool prefers a batch wrapper but PowerShell is still available on the machine.
- Use `ScreenConnect-OneDrive-Config-AllProfiles.ps1` when running from ScreenConnect or another tool that accepts `#!ps` PowerShell scripts directly.
- Use the cleanup or repair scripts when you only need shell-folder remediation rather than KFM rollout.

## Quick Start

```powershell
# Full migration with data copy
.\Complete-OneDrive-Migration.ps1 -TenantID "<Your-Tenant-GUID>"

# Cleanup only
.\Complete-OneDrive-Migration.ps1 -CleanupOnly

# Configure KFM without file migration for all profiles
.\OneDrive-Config-NoMigration.ps1 -TenantID "<Your-Tenant-GUID>"

# ScreenConnect / #!ps all-profile deployment
.\ScreenConnect-OneDrive-Config-AllProfiles.ps1 -TenantID "<Your-Tenant-GUID>"
```

## Logging

- `Complete-OneDrive-Migration.ps1`
  - Default: `%TEMP%\OneDriveMigration.log` unless `-LogPath` is supplied.
- `OneDrive-Migration-Verbose.bat`
  - `%PUBLIC%\Documents\OneDriveMigration\OneDriveMigration_<COMPUTER>_<USER>.log`
- `OneDrive-Config-NoMigration.bat`
  - `%PUBLIC%\Documents\OneDriveMigration\OneDriveConfig_<COMPUTER>_<USER>.log`
- `OneDrive-Config-NoMigration.ps1`
  - `%PUBLIC%\Documents\OneDriveMigration\OneDriveConfig_<COMPUTER>.log`
- `ScreenConnect-OneDrive-Config-AllProfiles.ps1`
  - `%PUBLIC%\Documents\OneDriveMigration\ScreenConnect_OneDriveConfig_<COMPUTER>.log`

## Operational Notes

- The all-profile scripts assume they can write to `HKLM` and load user hives, so they should be run with administrative rights.
- The all-profile scripts intentionally limit Explorer and OneDrive restarts to active user sessions. Offline profiles are prepared in registry only and will pick up the changes when the user signs in later.
- Execution context matters:
  - `User context + admin/elevated rights` means the active logged-in user gets the Explorer/OneDrive restart, and all local profiles still get registry updates.
  - `SYSTEM` also works for the all-profile registry changes, but user-session restarts only happen for sessions the script can identify as active.
  - `User context without elevation` is not sufficient for the all-profile scripts because `HKLM` writes and loading other users' hives require admin rights.
- None of the no-migration scripts copy files or remove `H:` mappings.
- If OneDrive is not already signed into a work account, `SilentAccountConfig` still depends on the device and user sign-in state to complete silently.

## RMM Notes

### ManageEngine / Endpoint Central

- Recommended script:
  - `OneDrive-Config-NoMigration.ps1`
- Recommended run mode:
  - Logged-in user context with administrative rights, if your deployment configuration supports that combination.
- Expected behavior in that mode:
  - The active logged-in user gets Explorer and OneDrive restarted.
  - All other local profiles still receive the registry-based KFM and shell-folder updates.
- If run as plain user without elevation:
  - HKLM writes can fail.
  - Loading or editing other users' hives can fail.
  - Result: the job may only partially apply or fail to prep all users.
- If run as SYSTEM:
  - The all-profile registry updates still work well.
  - Active-session restarts depend on whether scheduled tasks can be created against the active user session.

### ScreenConnect

- Recommended script:
  - `ScreenConnect-OneDrive-Config-AllProfiles.ps1`
- Recommended run mode:
  - SYSTEM / elevated execution from ScreenConnect.
- Expected behavior in that mode:
  - HKLM policy writes succeed.
  - All real user profiles are updated by loading each user's hive from `ProfileList`.
  - Explorer and OneDrive restarts are attempted only for currently active logged-in sessions.
- Why this script exists separately:
  - It starts with `#!ps`, which is friendlier for ScreenConnect-style direct PowerShell execution.
  - It avoids relying on the operator to manually bridge user and admin context during the run.
