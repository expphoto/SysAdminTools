## DR Auto-Start Orchestrator — Comprehensive Plan

Generated on: 2025-09-12

This plan synthesizes recommendations from three parallel LLM planners (Claude, Gemini, Codex/Code). It converges on a safe, idempotent, config-driven PowerShell solution to discover AD-joined Windows servers, validate reachability, detect roles (SQL, SAP, IIS, DC, File/Print, generic), start the appropriate services in correct order, and emit auditable reports. The repository is currently empty, so this document also seeds a proposed structure and contracts.

---

### Cross‑Model Consensus Themes

- PowerShell-first architecture with PS7+ preferred; maintain PS5.1 compatibility.
- Config over code: JSON settings for discovery, policies, timeouts, mappings.
- Bounded concurrency with backpressure; retries with exponential backoff and jitter.
- Dynamic role detection (SQL, SAP, IIS, DC, File/Print, generic) using services, registry, features, filesystem, and WMI.
- Cluster/DC guardrails; never force unsafe starts; prefer cluster-group operations.
- Idempotency and safety: DryRun/WhatIf, MaxServers canary, no startup-type changes by default.
- Multi-format reporting (CSV, JSON, HTML) with clear exit codes for automation.
- Security: Kerberos SSO by default, `Get-Credential` optional, optional JEA.
- Testing: Pester with mocks; CI on Windows runners; no live remoting in CI.

---

### Proposed Repository Structure

```
powershell/
  Invoke-DR-AutoStart.ps1           # Entrypoint orchestrator
  modules/
    ADDiscovery.psm1               # AD queries, filters, snapshots
    RemoteExec.psm1                # Connectivity, sessions, concurrency helpers
    RoleDetection.psm1             # SQL/SAP/IIS/DC/File-Print/generic detection
    ServiceActions.psm1            # Plan + start/verify with dependency ordering
    Reporting.psm1                 # CSV/JSON/HTML, console summary, exit codes
config/
  settings.json                    # Timeouts, throttles, filters, policies
  service-mappings.json            # Role→services and custom overrides
reports/                            # Timestamped run artifacts
snapshots/                          # Discovery snapshots
tests/                              # Pester unit tests and mocks
docs/
  USAGE.md                         # Usage, RBAC/JEA, rollout, troubleshooting
```

---

### Final Implementation Plan (Steps + Rationale)

1) Foundations and Config
- Define JSON schemas: discovery filters, concurrency/timeouts, cluster policy, reporting options, service mappings.
- Establish versioned report schema for JSON outputs to enable reruns (OnlyPreviouslyFailed) and audits.
- Rationale: Moves environment specifics out of code; enables safe, repeatable runs.

2) AD Discovery (ADDiscovery.psm1)
- Query AD for `OperatingSystem -like "Windows Server*"`; scope by OU and regex allow/deny; optional tags via Description/extension attributes.
- Emit snapshot to `snapshots/` for each run.
- Rationale: Dynamic inventory; auditability; reproducibility.

3) Connectivity + Sessions (RemoteExec.psm1)
- `Test-Connection` (ICMP) + `Test-WSMan` + optional `Test-NetConnection` 135/445; per-host timeouts and retries with jitter.
- Create/reuse `PSSession` per reachable host; SSO or `-Credential`; optional `-ConfigurationName` for JEA.
- Provide `Invoke-Concurrent` abstraction (PS7 parallel or PS5.1 runspace pool) with `-ThrottleLimit` and a global circuit breaker.
- Rationale: Bounded, observable concurrency; resilience.

4) Role Detection (RoleDetection.psm1)
- Layered checks (services, registry, features, filesystem, WMI) to infer roles.
- Specializations:
  - SQL: registry `HKLM:\...\Instance Names\SQL`, services `MSSQL*`/`SQLAgent*`, capture instances.
  - SAP: services `SAPHostControl`, `SAPService<SID>`, `SAP<SID>_*`; filesystem `C:\usr\sap\*`; SID discovery.
  - IIS: feature `Web-Server`, services `WAS`, `W3SVC`.
  - File/Print: features `FS-FileServer`, `Print-Services`; services `LanmanServer`, `Spooler`.
  - DC: role `AD-Domain-Services`, services `NTDS`, `DNS` (if installed); guard DSRM/restore.
  - Generic: `Automatic` but not `Running` filtered by allow/deny.
- Rationale: Dynamic, environment-agnostic behavior.

5) Service Plan + Ordering (ServiceActions.psm1)
- Transform roles → service plan; deduplicate; augment with `RequiredServices`; perform topological sort.
- Enforce order rules: SQL engine → Agent; IIS: WAS → W3SVC; SAP: HostCtrl → SAPService<SID> → SAP instance services.
- Respect cluster/DC policy; avoid starting passive-node resources directly; prefer `Start-ClusterGroup`.
- Rationale: Correctness and safety across complex dependencies.

6) Execution and Verification (ServiceActions.psm1)
- Start services with per-service timeout and retries; verify `Status -eq Running`; capture failure reasons (disabled, access denied, dependency, logon failure).
- Idempotent: skip already-running; never change startup type unless `-FixStartupType`.
- Rationale: Reliable convergence to desired state.

7) Reporting (Reporting.psm1)
- Aggregate per-host results (connectivity, roles, actions, durations, errors) → CSV, JSON, HTML (via PSWriteHTML if available).
- Console summary; exit codes: 0 all green; 1 partial failures; 2 systemic discovery/connectivity errors.
- Rationale: Operator visibility, machine-readability, audit trail.

8) Security & RBAC
- Kerberos SSO by default; optional `-Credential` (in-memory only); optional JEA endpoint.
- Redact sensitive data; document minimal privileges; avoid CredSSP unless required.
- Rationale: Least privilege with operational convenience.

9) Testing & CI
- Pester unit tests with mocks for AD, WSMan, services, registry; golden JSON vectors.
- GitHub Actions (windows-latest) to run tests and publish sample reports as artifacts.
- Rationale: Confidence without touching real infrastructure.

10) Rollout & Ops
- Stage: DryRun → Canary (`-MaxServers`, small OU) → Full → Scheduled task.
- Keep all snapshots and reports; monitor trends; tune timeouts and filters as estate scales.
- Rationale: Minimize blast radius; iterate safely.

---

### Module and Function Map (Contracts)

- ADDiscovery.psm1
  - `Get-ADServers -OU <string[]> -Filter <string> -Include <string[]> -Exclude <string[]> -SnapshotPath <string> -MaxServers <int>`
  - `Save-DiscoverySnapshot -Servers <object[]> -Path <string>`
  - `Load-PreviousRun -ReportPath <string> -OnlyPreviouslyFailed`

- RemoteExec.psm1
  - `Test-ServerConnectivity -ComputerName <string> -TimeoutSec <int> [-RpcCheck]`
  - `New-Session -ComputerName <string> -Credential <PSCredential> -JEAEndpoint <string>`
  - `Invoke-Remote -Session <PSSession> -ScriptBlock <scriptblock> -Args <object[]> -TimeoutSec <int>`
  - `Invoke-Concurrent -Input <object[]> -ScriptBlock <scriptblock> -ThrottleLimit <int> -CircuitPolicy <hashtable>`

- RoleDetection.psm1
  - `Get-ServerRoles -ComputerName <string> -Credential <PSCredential> -Session <PSSession>`
  - Helpers: `Test-RoleSql`, `Test-RoleSap`, `Test-RoleIis`, `Test-RoleDc`, `Test-RoleFilePrint`, `Test-RoleGeneric`

- ServiceActions.psm1
  - `Get-RoleServicePlan -Roles <string[]> -Config <hashtable>`
  - `Resolve-ServiceDependencies -Services <string[]> -Session <PSSession>`
  - `Start-ServicesPlan -ComputerName <string> -Services <string[]> -Order <string[][]> -TimeoutSec <int> -Retries <int> -WhatIf`
  - `Start-ClusterWorkloads -ComputerName <string> -Policy <string>`

- Reporting.psm1
  - `Write-RunReport -Results <object[]> -OutCsv <string> -OutJson <string> -OutHtml <string>`
  - `Write-ConsoleSummary -Results <object[]>`
  - `Get-ExitCode -Results <object[]>`

---

### Execution Flow Diagram (Text)

```
[ Start ]
  |
  v
[ Parse Params + Load JSON Config ]
  |
  v
[ AD Discovery ] -> snapshot.json
  |
  v
[ Parallel Per-Host Pipeline (bounded) ]
  ├─ Connectivity (ICMP/WSMan/RPC) → skip or continue
  ├─ Session (SSO or Credential/JEA)
  ├─ Role Detection (SQL/SAP/IIS/DC/FP/Generic)
  ├─ Service Plan (order & deps; cluster/DC guards)
  ├─ Execute Starts (or DryRun) with verification
  └─ Collect per-service results + timings
  |
  v
[ Aggregate Results ] → CSV/JSON/HTML + console summary
  |
  v
[ Exit Code 0/1/2 ]
```

---

### Risks and Mitigations

- AD discovery gaps or overreach: OU scoping, include/deny regex, manual allowlist, snapshots for audit.
- WinRM blocked/unstable: Pre-flight WSMan/TCP checks; retries/backoff; `-SkipUnreachable`; exit code 2.
- Insufficient RBAC/JEA rights: Detect access denied; document required roles; prompt for alternate creds; JEA endpoints.
- Cluster mis-handling: Detect cluster; prefer `Start-ClusterGroup`; default skip passive-node service starts.
- DC restore hazards: Detect DSRM/restore; require explicit opt-in to start NTDS.
- Service dependency cycles: Build graph from `RequiredServices`; topological sort; break/flag cycles in report.
- SAP complexity variance: Configurable per-SID mappings and overrides; dry-run validation first.
- SQL multi-instance nuances: Registry-driven instance discovery; agent after engine.
- Performance overload: Throttle, batch targets, per-host timeouts, global circuit breaker.
- Credential exposure/lockouts: No persistence; secure prompting; capped retries with jitter.
- Idempotency gaps: Check state before change; WhatIf/DryRun; never change startup type unless explicit.
- Reporting omissions: Structured JSON as source of truth; CSV/HTML as views; schema versioning.

---

### Milestones & Deliverables (Indicative)

- M0 (Week 1): Scaffolding + config schema + docs outline.
- M1 (Week 2): AD discovery + filters + snapshot.
- M2 (Week 3): Connectivity + session + concurrency helper.
- M3 (Week 4): Role detection baseline (SQL/IIS/Generic).
- M4 (Week 5): Service orchestration + ordering + verification.
- M5 (Week 6): Cluster/DC guardrails + SAP role.
- M6 (Week 7): Reporting (CSV/JSON/HTML) + exit codes + console summary.
- M7 (Week 8): Entrypoint orchestrator, DryRun/WhatIf, rerun modes.
- M8 (Week 9): Pester coverage, CI, docs.
- M9 (Week 10): Pilot canary + tuning.
- M10 (Week 11): Full rollout + runbook.

---

### Two Key Starter Artifacts (illustrative snippets)

1) `config/settings.json` (example)

```json
{
  "Concurrency": { "ThrottleLimit": 30, "PerHostTimeoutSec": 120, "ServiceTimeoutSec": 90 },
  "Discovery": { "OUs": ["OU=Servers,DC=corp,DC=local"], "Include": [], "Exclude": ["^LAB-"], "Filter": "Enabled -eq $true", "MaxServers": 0 },
  "Connectivity": { "RpcCheck": true, "Backoff": { "InitialMs": 500, "MaxMs": 8000, "Retries": 3 } },
  "Policies": { "SkipUnreachable": true, "ClusterPolicy": "PreferClusterOps", "FixStartupType": false },
  "Reporting": { "Html": true }
}
```

2) `powershell/Invoke-DR-AutoStart.ps1` (skeleton)

```powershell
param(
  [string[]]$OUs,
  [string[]]$Include,
  [string[]]$Exclude,
  [string]$Filter,
  [int]$ThrottleLimit = 30,
  [switch]$DryRun,
  [switch]$OnlyPreviouslyFailed,
  [int]$MaxServers = 0,
  [Parameter()] [System.Management.Automation.PSCredential] $Credential,
  [string]$JEAEndpoint,
  [string]$SettingsPath = "config/settings.json",
  [string]$ServiceMappingsPath = "config/service-mappings.json",
  [string]$OutDir = "reports"
)
# Import modules, load config, run pipeline (Discover → Test → Detect → Plan → Act → Report)
```

---

### Notes on Tradeoffs (PS5.1 vs PS7+)

- PS7+: `ForEach-Object -Parallel`, faster JSON, cross-plat; import AD module via WindowsCompatibility.
- PS5.1: Native AD module; requires runspace pool for concurrency.
- Abstract concurrency in `RemoteExec.Invoke-Concurrent` to keep orchestrator identical across versions.

---

### Next Steps

- Confirm OU scope, canary hosts, and initial throttle.
- Approve config schema and report formats.
- Begin M0 scaffolding and Pester test skeletons.

