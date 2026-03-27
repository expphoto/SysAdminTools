# Windows Server 2025 Readiness

This folder contains the current Windows Server 2025 upgrade-readiness toolkit for server assessment, workload discovery, break-test drills, and consolidated reporting.

The toolkit is no longer just a single readiness script. It now has five main pieces that are meant to work together:

1. `WS2025_ProductionReadiness.ps1`
2. `ServerDocumentation-Discovery.ps1`
3. `WS2025_CompatibilityDrill.ps1`
4. `Consolidated-UpgradeReport.ps1`
5. `Scan-ScheduledTaskScripts.ps1`

## What Each Script Does

### `WS2025_ProductionReadiness.ps1`

Primary readiness assessment script.

- Purpose:
  - Evaluate whether a Windows Server 2016/2019/2022 system is likely to encounter blockers or upgrade risk when moving to Windows Server 2025.
- Behavior:
  - Read-only by default.
  - Collects evidence from OS state, installed roles/features, event logs, crypto posture, SMB/TLS/auth signals, software patterns, clustering, Hyper-V, and other upgrade-sensitive areas.
  - Produces structured export files for downstream review and automation.
- Outputs:
  - `WS2025_ProductionReadiness_<server>_<timestamp>.json`
  - `WS2025_ProductionReadiness_<server>_<timestamp>.csv`
  - `WS2025_ProductionReadiness_<server>_<timestamp>_ChangeRequest.md`
- Best for:
  - First-pass upgrade readiness.
  - Management-ready evidence on blockers, warnings, and telemetry gaps.

### `ServerDocumentation-Discovery.ps1`

Read-only workload and usage discovery script.

- Purpose:
  - Determine what the server is actually doing in production so you can test and communicate the impact of an upgrade.
- Behavior:
  - Looks at roles, workloads, active usage signals, installed applications, network patterns, file activity, and related evidence.
  - Generates documentation-oriented output rather than only a pass/fail readiness decision.
- Best for:
  - Understanding business use before scheduling maintenance.
  - Building upgrade test plans and identifying what needs validation after cutover.

### `WS2025_CompatibilityDrill.ps1`

Temporary break-test / simulation script.

- Purpose:
  - Read the JSON output from the readiness script and simulate selected Windows Server 2025 compatibility-impacting changes before the real upgrade.
- Behavior:
  - Supports `Plan`, `Break`, `BreakEverything` / `Go` / `ScreamTest`, and `Revert` / `Undo` / `Restore`.
  - Can apply only confirmed-use items or include broader config-only items.
  - Saves state so the drill can be rolled back.
- Best for:
  - Controlled pre-upgrade testing.
  - Proving whether a server will break when specific legacy behaviors are removed or tightened.

### `Consolidated-UpgradeReport.ps1`

Change-ready report generator.

- Purpose:
  - Combine discovery, readiness, workloads, applications, and test-plan artifacts into per-server consolidated markdown reports plus a master summary.
- Behavior:
  - Scans an input folder for matching artifacts per server.
  - Produces one consolidated report per server.
  - Produces one environment-level master summary report.
- Best for:
  - CAB packets.
  - Upgrade waves and prioritization.
  - Hand-off documentation for engineers performing the upgrade.

### `Scan-ScheduledTaskScripts.ps1`

Scheduled-task PowerShell script scanner.

- Purpose:
  - Enumerate scheduled tasks, locate PowerShell scripts referenced by task actions, and scan those scripts for patterns that are deprecated, removed, or risky on Windows Server 2025.
- Behavior:
  - Read-only.
  - Focuses on task actions that launch `powershell.exe` or `pwsh`.
  - Flags patterns such as PowerShell 2.0 usage, `wmic`, `wuauclt /detectnow`, VBScript usage, WinRM.vbs, IIS6 legacy admin scripts, and similar modernization targets.
  - Exports a CSV report to the temp directory.
- Best for:
  - Finding scheduled-task automation debt before upgrade.
  - Catching compatibility risks that may not show up from installed software or feature inventory alone.

## Expected Workflow

Typical use now looks like this:

1. Run `ServerDocumentation-Discovery.ps1` on the server.
2. Run `WS2025_ProductionReadiness.ps1` on the same server.
3. Optionally run `WS2025_CompatibilityDrill.ps1` against the readiness JSON if you want a temporary break/revert test.
4. Run `Scan-ScheduledTaskScripts.ps1` if you want a targeted sweep of scheduled-task automation for Windows Server 2025 issues.
5. Collect all outputs for one or more servers in a report folder.
6. Run `Consolidated-UpgradeReport.ps1` against that folder to produce per-server and master consolidated reports.

## Canonical Layout

The canonical script set lives under:

- `Scripts/Readiness/WS2025_ProductionReadiness.ps1`
- `Scripts/Readiness/ServerDocumentation-Discovery.ps1`
- `Scripts/Readiness/WS2025_CompatibilityDrill.ps1`
- `Scripts/Readiness/Consolidated-UpgradeReport.ps1`
- `Scripts/Readiness/Scan-ScheduledTaskScripts.ps1`

There is also a top-level convenience copy of `WS2025_ProductionReadiness.ps1` in this folder. Treat the `Scripts/Readiness/` folder as the primary location when reviewing or updating the toolkit.

## Folder Hygiene

This folder contains a mix of production scripts, supporting docs, and sample/test artifacts.

- Canonical scripts:
  - `Scripts/Readiness/`
- Top-level convenience entrypoint:
  - `WS2025_ProductionReadiness.ps1`
- Supporting docs:
  - `QUICK_START.md`
  - `REFERENCE_CARD.txt`
  - `TESTING.md`
  - `IMPLEMENTATION_ANALYSIS.md`
  - `IMPLEMENTATION_SUMMARY.md`
  - `DESIGN_RATIONALE.md`
- Sample/test outputs:
  - `TEST/`
  - `output_test/`

If something looks duplicated, prefer the script copies under `Scripts/Readiness/` and the documentation in this README as the current index.

## Consolidated Report Inputs

`Consolidated-UpgradeReport.ps1` expects a folder that contains one or more matching sets of files per server, typically named like:

- `ServerDocumentation_<server>_<timestamp>.md`
- `Readiness_<server>_<timestamp>.md`
- `Workloads_<server>_<timestamp>.csv`
- `TestPlan_<server>_<timestamp>.csv`
- `Applications_<server>_<timestamp>.csv`

Not every optional file has to exist, but the more complete the set, the better the consolidated output.

## Safety Notes

### Read-only by default

These scripts are not all the same from a safety standpoint:

- `WS2025_ProductionReadiness.ps1` is intended to be production-safe and read-only by default.
- `ServerDocumentation-Discovery.ps1` is also read-only.
- `Consolidated-UpgradeReport.ps1` only reads existing files and writes markdown output.
- `Scan-ScheduledTaskScripts.ps1` is read-only and only inspects scheduled tasks plus referenced script files.
- `WS2025_CompatibilityDrill.ps1` is the exception: it can make temporary system changes when you use a break/apply mode.

### Compatibility drill caution

Use the drill script only when you explicitly want to simulate upgrade-impacting behavior changes and you have a rollback plan.

## Quick Examples

### Readiness assessment

```powershell
.\Scripts\Readiness\WS2025_ProductionReadiness.ps1
```

### Discovery run

```powershell
.\Scripts\Readiness\ServerDocumentation-Discovery.ps1 -DaysBack 14
```

### Compatibility drill plan only

```powershell
.\Scripts\Readiness\WS2025_CompatibilityDrill.ps1 C:\Reports\WS2025_ProductionReadiness_SERVER01.json Plan
```

### Scan scheduled-task PowerShell scripts for WS2025 issues

```powershell
.\Scripts\Readiness\Scan-ScheduledTaskScripts.ps1
```

### Build consolidated reports from a folder of collected outputs

```powershell
.\Scripts\Readiness\Consolidated-UpgradeReport.ps1 -InputDirectory C:\Reports\2025Readiness
```

## Current Supporting Docs

This folder also includes supporting documentation and reference material:

- `QUICK_START.md`
- `REFERENCE_CARD.txt`
- `TESTING.md`
- `IMPLEMENTATION_ANALYSIS.md`
- `IMPLEMENTATION_SUMMARY.md`
- `DESIGN_RATIONALE.md`

## Output Notes

- Readiness exports in this repo currently appear under folders like `output_test/`.
- Sample/test artifacts also exist under `TEST/`.
- Consolidated reports are written to the output folder you specify, or to a default `ConsolidatedReports` folder under the script directory.

## Practical Guidance

- Run the readiness and discovery scripts elevated when possible so event-log and role visibility are better.
- Run the scheduled-task scanner elevated as well, so task enumeration is as complete as possible.
- Treat missing telemetry as an evidence gap, not proof that a protocol or feature is unused.
- Use discovery plus readiness together if you want the best consolidated reports.
- Use the consolidated report script only after the upstream artifacts are present and named consistently.
