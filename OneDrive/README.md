# OneDrive Migration Tools

This folder contains scripts to clean up legacy folder redirections and migrate user data from H: (or other network homes) to OneDrive with Known Folder Move (KFM).

## Scripts

- `Complete-OneDrive-Migration.ps1` (recommended)
  - All‑in‑one: redirection cleanup, OneDrive/KFM policy, optional data copy, and validation.
  - Parameters:
    - `-WhatIf`: Preview actions without changing the system.
    - `-LogPath <path>`: Log file (default `%TEMP%\OneDriveMigration.log`).
    - `-TenantID <GUID>`: Your Microsoft 365 tenant ID for KFM silent opt‑in.
    - `-CleanupOnly`: Only reset redirections; skip OneDrive and data copy.
    - `-SkipDataMigration`: Configure OneDrive/KFM but skip copying H: data.
  - Behavior highlights:
    - Detects OneDrive install via multiple signals (exe/process/registry/service).
    - Resets HKCU shell folders to local paths; fixes GUID entries and malformed values.
    - Sets KFM policies under `HKCU\SOFTWARE\Policies\Microsoft\OneDrive` (Desktop/Documents/Pictures; block opt‑out).
    - Robocopy‑style data transfer (if enabled) with logging and basic retry.

- `Clean up Home Directory Redirects.ps1`
  - Focused utility to reset user shell folders from UNC paths or malformed entries back to `%USERPROFILE%` locations.
  - Touches keys:
    - `HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders`
    - `HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders`

- `Local-OD-Migrate-ADSHARE`
  - Earlier, lighter variant of the migration script; includes KFM setup and redirection reset with a smaller scope.

- `OneDrive-Migration-Verbose.bat`
  - Batch‑only flow designed for RMM/remote use; verbose logging to `%PUBLIC%\Documents\OneDriveMigration` (falls back to `%TEMP%`).
  - Resets key user shell folders and echoes progress + registry snapshots for auditing.

## Quick Start

```powershell
# Recommended: full migration with KFM (run as user)
.\Complete-OneDrive-Migration.ps1 -TenantID "<Your-Tenant-GUID>"

# Cleanup only
.\Complete-OneDrive-Migration.ps1 -CleanupOnly

# Configure KFM but skip bulk copy
.\Complete-OneDrive-Migration.ps1 -TenantID "<Your-Tenant-GUID>" -SkipDataMigration

# Dry run
.\Complete-OneDrive-Migration.ps1 -WhatIf
```

## Notes

- Run in the user context whose profile you are fixing (HKCU changes are per‑user).
- KFM policy takes effect when OneDrive signs in; ensure user signs into OneDrive after configuration.
- If you use RMM, prefer `Complete-OneDrive-Migration.ps1` (richer logging) or adapt the batch for initial cleanup.
- Always verify sufficient local disk space before copying large H: profiles.

## Logs

- PowerShell: `%TEMP%\OneDriveMigration.log` (or the path you provide)
- Batch (verbose): `%PUBLIC%\Documents\OneDriveMigration\OneDriveMigration_<COMPUTER>_<USER>.log`

