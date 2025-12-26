# Infrastructure State Controller

Intent-based automation for HPE Nimble storage and VMware vSphere orchestration.

## Overview

The Infrastructure State Controller (`Invoke-InfraLifecycle`) is an "all-in-one" script that abstracts the complexity of storage and virtualization operations, allowing you to manage your environment based on **intent** rather than mechanics.

Instead of manually creating volumes, masking LUNs, rescanning HBAs, and formatting datastores, you simply state your intent: "I need a new SQL datastore" or "Clone this for Dev."

## Prerequisites

### Required Modules
- **VMware PowerCLI**: `Install-Module -Name VMware.PowerCLI`
- **HPE Nimble PowerShell Toolkit** (recommended) OR REST API access

### Required Permissions
- **Nimble Array**: Full volume management permissions
- **vCenter**: Datastore, LUN, and cluster management permissions
- **ESXi Hosts**: Administrator or delegated storage permissions

### Network Requirements
- WinRM/PowerShell Remoting enabled for ESXi hosts (via vCenter)
- Network connectivity to:
  - Nimble array management port (HTTPS, default 8080)
  - vCenter server (HTTPS, default 443)

### Environment Setup

```powershell
# Install required modules
Install-Module -Name VMware.PowerCLI -Force -Scope CurrentUser

# Set global variables (optional, can be passed as parameters)
$global:NIMBLE_SERVER = "nimble-array.domain.local"
$global:VCENTER_SERVER = "vcenter.domain.local"

# Test connectivity
Test-WSMan -ComputerName nimble-array.domain.local
Test-WSMan -ComputerName vcenter.domain.local
```

## Installation

1. Place `Invoke-InfraLifecycle.ps1` and `Invoke-InfraLifecycle-config.json` in your working directory
2. Optionally set global server variables (see above)
3. Configure the JSON config file for your environment

## Configuration

The `Invoke-InfraLifecycle-config.json` file contains:

- **NimbleServer/vCenterServer**: Default server FQDNs or IPs
- **DefaultPerformancePolicy**: Default Nimble performance policy
- **DefaultMaxSnapshotAgeDays**: Threshold for orphaned snapshot detection
- **Clusters**: Per-cluster settings including:
  - DatastoreCluster: Storage DRS cluster name
  - InitiatorGroupPattern: Regex pattern to match Nimble initiator groups
  - PerformancePolicy: Cluster-specific performance policy
- **PerformancePolicies**: Mapping of policy names to descriptions
- **NamingConventions**: Volume naming templates

## Usage

### Command Syntax

```powershell
.\Invoke-InfraLifecycle.ps1 -Intent <mode> [options]
```

### Available Intents (Modes)

#### 1. Provision - The "One-Click Datastore"

Creates a complete datastore end-to-end: volume on Nimble, ACLs, HBA rescan, VMFS format, and optional Storage DRS.

**Required Parameters:**
- `ClusterName` - vSphere cluster name
- `VolName` - Name for the new volume/datastore
- `SizeGB` - Size in GB

**Optional Parameters:**
- `PerformancePolicy` - Nimble performance policy (default: "VMware ESXi")
- `DatastoreCluster` - Storage DRS datastore cluster name

**Examples:**

```powershell
# Provision a 2TB datastore for SQL cluster
.\Invoke-InfraLifecycle.ps1 -Intent Provision -ClusterName "Prod-SQL-Cluster" -VolName "s-SQL-Prod-01" -SizeGB 2048 -DatastoreCluster "SQL-Storage"

# Provision for Dev cluster with custom performance policy
.\Invoke-InfraLifecycle.ps1 -Intent Provision -ClusterName "Dev-Cluster" -VolName "s-App-Dev-01" -SizeGB 512 -PerformancePolicy "Dev-Bronze"

# WhatIf mode - preview without making changes
.\Invoke-InfraLifecycle.ps1 -Intent Provision -ClusterName "Prod-SQL-Cluster" -VolName "s-SQL-Prod-01" -SizeGB 2048 -WhatIf
```

#### 2. Clone - The "DevOps Enabler"

Creates a zero-copy clone of an existing volume for dev/test environments. Handles VMFS resignaturing automatically.

**Required Parameters:**
- `ClusterName` - Target cluster name
- `SourceVolName` - Source volume to clone from
- `VolName` - Name for the new clone

**Optional Parameters:**
- `PerformancePolicy` - Nimble performance policy
- `ForceResignature` - Force VMFS resignature

**Examples:**

```powershell
# Clone production SQL volume to Dev
.\Invoke-InfraLifecycle.ps1 -Intent Clone -ClusterName "Dev-Cluster" -SourceVolName "s-SQL-Prod-01" -VolName "s-SQL-Dev-01"

# Clone with forced resignature
.\Invoke-InfraLifecycle.ps1 -Intent Clone -ClusterName "Dev-Cluster" -SourceVolName "s-Web-Prod-01" -VolName "s-Web-Dev-01" -ForceResignature

# WhatIf mode
.\Invoke-InfraLifecycle.ps1 -Intent Clone -ClusterName "Dev-Cluster" -SourceVolName "s-SQL-Prod-01" -VolName "s-SQL-Dev-01" -WhatIf
```

#### 3. Expand - The "Capacity Saver"

Grows an existing volume and VMFS datastore without downtime.

**Required Parameters:**
- `ClusterName` - vSphere cluster name
- `DatastoreName` - Name of existing datastore
- `SizeGB` - New total size in GB

**Examples:**

```powershell
# Expand datastore to 3TB
.\Invoke-InfraLifecycle.ps1 -Intent Expand -ClusterName "Prod-Web-Cluster" -DatastoreName "s-Web-01" -SizeGB 3072

# WhatIf mode
.\Invoke-InfraLifecycle.ps1 -Intent Expand -ClusterName "Prod-Web-Cluster" -DatastoreName "s-Web-01" -SizeGB 3072 -WhatIf
```

#### 4. Audit - The "Drift Detector"

Runs compliance checks and generates findings for infrastructure health.

**Optional Parameters:**
- `ClusterName` - Specific cluster to audit (all if not specified)
- `MaxSnapshotAgeDays` - Snapshot age threshold (default: 30 days)

**Checks Performed:**
- Multipath policy compliance (Nimble LUNs should use Round Robin)
- Zombie volumes (volumes on array not mounted to any host)
- Orphaned snapshots (snapshots older than threshold)
- Datastore health (low space, empty large datastores)

**Examples:**

```powershell
# Audit all clusters
.\Invoke-InfraLifecycle.ps1 -Intent Audit

# Audit specific cluster
.\Invoke-InfraLifecycle.ps1 -Intent Audit -ClusterName "Prod-SQL-Cluster"

# Audit with custom snapshot age threshold
.\Invoke-InfraLifecycle.ps1 -Intent Audit -MaxSnapshotAgeDays 60
```

#### 5. Retire - The "Clean Exit"

Safely decommission datastores and volumes to prevent APD (All Paths Down) errors.

**Required Parameters:**
- `ClusterName` - vSphere cluster name
- `DatastoreName` - Name of datastore to retire

**Safety:**
- Requires "DELETE" confirmation
- Verifies datastore is empty (unless forced)
- Proper unmount sequence to prevent APD

**Examples:**

```powershell
# Retire datastore
.\Invoke-InfraLifecycle.ps1 -Intent Retire -ClusterName "Retired-Cluster" -DatastoreName "s-Old-Datastore"

# WhatIf mode - show what would happen
.\Invoke-InfraLifecycle.ps1 -Intent Retire -ClusterName "Retired-Cluster" -DatastoreName "s-Old-Datastore" -WhatIf
```

### Common Parameters

All modes support these parameters:

- `NimbleServer` - Override default Nimble server
- `vCenterServer` - Override default vCenter server
- `Credential` - PSCredential object for authentication
- `WhatIf` - Preview changes without executing
- `Verbose` - Enable detailed logging
- `LogPath` - Override default log path

### Credential Management

```powershell
# Prompt for credentials (recommended)
.\Invoke-InfraLifecycle.ps1 -Intent Provision -ClusterName "Prod-Cluster" -VolName "s-Test-01" -SizeGB 512

# Use stored credential
$cred = Get-Credential
.\Invoke-InfraLifecycle.ps1 -Intent Provision -ClusterName "Prod-Cluster" -VolName "s-Test-01" -SizeGB 512 -Credential $cred
```

## Common Workflows

### Complete New Datastore Provisioning

```powershell
# 1. Audit current state
.\Invoke-InfraLifecycle.ps1 -Intent Audit -ClusterName "Prod-SQL-Cluster"

# 2. Provision the datastore
.\Invoke-InfraLifecycle.ps1 -Intent Provision -ClusterName "Prod-SQL-Cluster" -VolName "s-SQL-Prod-01" -SizeGB 2048 -DatastoreCluster "SQL-Storage"

# 3. Verify the datastore appears and is healthy
.\Invoke-InfraLifecycle.ps1 -Intent Audit -ClusterName "Prod-SQL-Cluster"
```

### Dev Environment Refresh

```powershell
# 1. Take snapshot/clone for Dev
.\Invoke-InfraLifecycle.ps1 -Intent Clone -ClusterName "Dev-Cluster" -SourceVolName "s-SQL-Prod-01" -VolName "s-SQL-Dev-01"

# 2. Verify clone
.\Invoke-InfraLifecycle.ps1 -Intent Audit -ClusterName "Dev-Cluster"

# 3. Register/renovate VMs on the new datastore (manual step or via PowerCLI)
```

### Capacity Planning & Expansion

```powershell
# 1. Audit to identify space constraints
.\Invoke-InfraLifecycle.ps1 -Intent Audit -ClusterName "Prod-Web-Cluster"

# 2. Expand constrained datastores
.\Invoke-InfraLifecycle.ps1 -Intent Expand -ClusterName "Prod-Web-Cluster" -DatastoreName "s-Web-01" -SizeGB 3072

# 3. Re-audit to confirm expansion
.\Invoke-InfraLifecycle.ps1 -Intent Audit -ClusterName "Prod-Web-Cluster"
```

### Clean Decommissioning

```powershell
# 1. Audit to verify no VMs on datastore
.\Invoke-InfraLifecycle.ps1 -Intent Audit -ClusterName "Retired-Cluster"

# 2. Verify VMs are migrated off (manual)

# 3. Retire the datastore
.\Invoke-InfraLifecycle.ps1 -Intent Retire -ClusterName "Retired-Cluster" -DatastoreName "s-Old-Datastore"

# 4. Final audit to confirm cleanup
.\Invoke-InfraLifecycle.ps1 -Intent Audit -ClusterName "Retired-Cluster"
```

## Logging

Logs are written to `C:\Logs\InfraLifecycle\` by default (configurable via `-LogPath`).

Log format:
```
[2025-01-15 14:30:45] [AUDIT] Infrastructure State Controller started
[2025-01-15 14:30:46] [INFO] Starting PROVISION mode
[2025-01-15 14:30:47] [SUCCESS] Volume created: s-SQL-Prod-01 (ID: 12345)
```

Log levels:
- **AUDIT**: Major state changes
- **INFO**: Normal operations
- **WARNING**: Non-critical issues
- **ERROR**: Failures requiring attention
- **DEBUG**: Detailed diagnostic information
- **SUCCESS**: Successful operations

## Exit Codes

| Exit Code | Meaning |
|-----------|---------|
| 0 | Success |
| 1 | Error occurred or warnings present (Audit mode) |

## Troubleshooting

### Connection Issues

**Problem:** Cannot connect to Nimble or vCenter

**Solutions:**
```powershell
# Test Nimble connectivity
Test-WSMan -ComputerName nimble-array.domain.local

# Test vCenter connectivity
Connect-VIServer -Server vcenter.domain.local

# Check credentials
$cred = Get-Credential
Test-WSMan -ComputerName nimble-array.domain.local -Credential $cred
```

### Initiator Group Not Found

**Problem:** "No initiator group found for cluster"

**Solutions:**
1. Verify the initiator group exists on the Nimble array
2. Check that the name matches the pattern in the config
3. Review the initiator group name with `Get-NSInitiatorGroup` (if using PowerShell Toolkit)

### LUN Not Found After Rescan

**Problem:** "Could not find new LUN on hosts after rescan"

**Solutions:**
1. Wait longer after rescan (add `Start-Sleep 30`)
2. Check Nimble access control records
3. Verify ESXi host iSCSI/FC initiator connectivity
4. Manually rescan on a single host: `Get-VMHostStorage -RescanAllHba`

### Datastore Creation Failed

**Problem:** "Failed to create datastore"

**Solutions:**
```powershell
# Manually check for LUNs
Get-Cluster "Prod-Cluster" | Get-VMHost | Get-ScsiLun | Where-Object { $_.Vendor -match "Nimble" }

# Check LUN capacity and canonical name
Get-ScsiLun -VMHost (Get-VMHost | Select-Object -First 1) | Select-Object CanonicalName, CapacityGB, Vendor
```

### Clone/Resignature Issues

**Problem:** Cloned datastore not accessible or shows as foreign

**Solutions:**
1. Use `-ForceResignature` flag
2. Manually resignature via vCenter UI to verify
3. Check that source volume has no locks
4. Verify snapshot completed on Nimble before clone

### Health Check Failed

**Problem:** "Health check failed: Write test failed"

**Solutions:**
1. Check datastore accessibility
2. Verify VMFS mount status on all hosts
3. Check for datastore locks or maintenance mode
4. Use `-SkipHealthCheck` to bypass (with caution)

### Retire Fails with "Datastore not empty"

**Problem:** "Datastore contains X VMs. Use -Force to proceed"

**Solutions:**
1. Migrate VMs off the datastore first
2. Verify with `Get-VM -Datastore "s-Old-Datastore"`
3. Only use Force after confirming VM migration

### Multipath Policy Warnings

**Problem:** Audit shows incorrect multipath policies

**Solutions:**
```powershell
# Manually fix multipath policy
Get-Cluster "Prod-Cluster" | Get-VMHost | Get-ScsiLun | Where-Object { $_.Vendor -match "Nimble" } | Set-ScsiLun -MultipathPolicy "VMW_PSP_RR"

# Verify
Get-ScsiLun | Where-Object { $_.Vendor -match "Nimble" } | Select-Object CanonicalName, MultipathPolicy
```

## Best Practices

1. **Always run Audit first** before any changes
2. **Use WhatIf mode** to preview changes
3. **Test in Dev cluster** before production changes
4. **Monitor logs** after each operation
5. **Schedule regular audits** via scheduled tasks
6. **Clean up orphaned snapshots** regularly
7. **Follow naming conventions** for consistency
8. **Verify with Audit** after provisioning/cloning/expanding

## Scheduled Task Examples

```powershell
# Daily audit scheduled at 6 AM
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-File 'C:\Scripts\Invoke-InfraLifecycle.ps1' -Intent Audit -LogPath 'C:\Logs\InfraLifecycle'"
$trigger = New-ScheduledTaskTrigger -Daily -At 6am
Register-ScheduledTask -TaskName "InfraLifecycle-DailyAudit" -Action $action -Trigger $trigger -Description "Daily infrastructure audit"

# Weekly snapshot cleanup check
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-File 'C:\Scripts\Invoke-InfraLifecycle.ps1' -Intent Audit -MaxSnapshotAgeDays 14 -LogPath 'C:\Logs\InfraLifecycle'"
$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At 2am
Register-ScheduledTask -TaskName "InfraLifecycle-WeeklySnapshotAudit" -Action $action -Trigger $trigger -Description "Weekly snapshot age audit"
```

## Integration Examples

### With Certificate Renewal

```powershell
# After CertDeploy renews SQL cluster certificates
.\CertDeploy.ps1 -Command deploy -FriendlyName "sql-cluster" -WhatIf

# Verify cluster health before provisioning new storage
.\Invoke-InfraLifecycle.ps1 -Intent Audit -ClusterName "Prod-SQL-Cluster"
```

### With SolarWinds Monitoring

```powershell
# After provisioning, ensure SolarWinds monitors new storage
.\Invoke-SolarWindsServiceMonitor.ps1 -Command deploy -ClusterName "Prod-SQL-Cluster" -WhatIf
```

### With Automox Compliance

```powershell
# Verify patch compliance on hosts before maintenance
.\Invoke-AutomoxHealthCheck.ps1 -WhatIf

# Proceed with storage expansion if compliant
.\Invoke-InfraLifecycle.ps1 -Intent Expand -ClusterName "Prod-Cluster" -DatastoreName "s-App-01" -SizeGB 2048
```

## Support

For issues, questions, or contributions, please refer to your internal documentation or contact the Infrastructure Engineering team.

## License

Internal tool - licensed for use within your organization.
