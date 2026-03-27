# Windows Server 2025 Readiness Toolkit

This README is intended for a folder where this file sits in the same directory as the main scripts.

Expected files in the same folder:

- `WS2025_ProductionReadiness.ps1`
- `ServerDocumentation-Discovery.ps1`
- `WS2025_CompatibilityDrill.ps1`
- `Consolidated-UpgradeReport.ps1`
- `Scan-ScheduledTaskScripts.ps1`

## What Each Script Does

### `WS2025_ProductionReadiness.ps1`

Primary readiness assessment script.

- Purpose:
  - Evaluate likely upgrade blockers and risks before moving a server to Windows Server 2025.
- Behavior:
  - Read-only by default.
  - Reviews operating system state, installed roles/features, event-log evidence, auth/TLS/SMB posture, software signals, clustering, Hyper-V, and other upgrade-sensitive areas.
- Outputs:
  - `WS2025_ProductionReadiness_<server>_<timestamp>.json`
  - `WS2025_ProductionReadiness_<server>_<timestamp>.csv`
  - `WS2025_ProductionReadiness_<server>_<timestamp>_ChangeRequest.md`
- Best for:
  - First-pass upgrade readiness.
  - Evidence for CAB or management review.

### `ServerDocumentation-Discovery.ps1`

Read-only workload and usage discovery script.

- Purpose:
  - Document what the server is actually doing and what needs to be tested after upgrade.
- Behavior:
  - Looks at workloads, roles, application signals, usage evidence, and related operational clues.
- Best for:
  - Understanding business impact.
  - Building testing and validation plans.

### `WS2025_CompatibilityDrill.ps1`

Temporary break-test / simulation script.

- Purpose:
  - Use the readiness JSON to simulate selected Windows Server 2025 compatibility-impacting changes before the actual upgrade.
- Behavior:
  - Supports `Plan`, `Break`, `BreakEverything` / `Go` / `ScreamTest`, and `Revert` / `Undo` / `Restore`.
  - Saves state so applied drill changes can be rolled back.
- Best for:
  - Controlled pre-upgrade validation.
  - Proving whether a compatibility risk is real.

### `Consolidated-UpgradeReport.ps1`

Consolidated reporting script.

- Purpose:
  - Combine discovery, readiness, workloads, applications, and test-plan outputs into one per-server report plus one master summary.
- Behavior:
  - Scans a folder for matching artifacts by server name.
  - Produces change-ready markdown output.
- Best for:
  - CAB review.
  - Upgrade wave planning.
  - Engineer handoff documentation.

### `Scan-ScheduledTaskScripts.ps1`

Scheduled-task PowerShell script scanner.

- Purpose:
  - Enumerate scheduled tasks, find PowerShell scripts referenced by task actions, and scan those scripts for deprecated or risky Windows Server 2025 patterns.
- Behavior:
  - Read-only.
  - Focuses on scheduled tasks that launch `powershell.exe` or `pwsh`.
  - Flags patterns such as PowerShell 2.0, `wmic`, `wuauclt /detectnow`, VBScript usage, WinRM.vbs, and IIS6 legacy admin scripts.
  - Exports a CSV report to the temp directory.
- Best for:
  - Finding scheduled-task automation debt before upgrade.
  - Catching compatibility risks in task-driven scripts.

## Recommended Workflow

For each server:

1. Run `ServerDocumentation-Discovery.ps1`
2. Run `WS2025_ProductionReadiness.ps1`
3. Optionally run `WS2025_CompatibilityDrill.ps1` if you want a break/revert validation
4. Run `Scan-ScheduledTaskScripts.ps1` if you want a focused sweep of scheduled-task automation
5. Collect the outputs into one folder
6. Run `Consolidated-UpgradeReport.ps1` against that folder

## Quick Examples

### Run readiness assessment

```powershell
.\WS2025_ProductionReadiness.ps1
```

### Run discovery

```powershell
.\ServerDocumentation-Discovery.ps1 -DaysBack 14
```

### Run compatibility drill in plan mode

```powershell
.\WS2025_CompatibilityDrill.ps1 .\WS2025_ProductionReadiness_SERVER01_20260327_120000.json Plan
```

### Scan scheduled-task PowerShell scripts

```powershell
.\Scan-ScheduledTaskScripts.ps1
```

### Build consolidated reports from a report folder

```powershell
.\Consolidated-UpgradeReport.ps1 -InputDirectory C:\Reports\2025Readiness
```

## Consolidated Report Inputs

`Consolidated-UpgradeReport.ps1` expects file sets named roughly like this:

- `ServerDocumentation_<server>_<timestamp>.md`
- `Readiness_<server>_<timestamp>.md`
- `Workloads_<server>_<timestamp>.csv`
- `TestPlan_<server>_<timestamp>.csv`
- `Applications_<server>_<timestamp>.csv`

Optional files can be missing, but the more complete the set, the better the report.

## Safety Notes

- `WS2025_ProductionReadiness.ps1` is intended to be production-safe and read-only by default.
- `ServerDocumentation-Discovery.ps1` is also read-only.
- `Consolidated-UpgradeReport.ps1` only reads input files and writes markdown output.
- `Scan-ScheduledTaskScripts.ps1` is read-only and only inspects scheduled tasks plus referenced script files.
- `WS2025_CompatibilityDrill.ps1` can make temporary system changes in break/apply modes.

## Practical Guidance

- Run readiness, discovery, and scheduled-task scanning elevated when possible for better event-log, service, and task visibility.
- Treat missing telemetry as an evidence gap, not proof that a protocol or feature is unused.
- Use both discovery and readiness outputs if you want useful consolidated reports.
- Use the compatibility drill only when you explicitly want to simulate impact and you have a rollback plan.
