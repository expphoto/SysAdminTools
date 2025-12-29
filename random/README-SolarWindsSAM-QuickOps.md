# SolarWinds SAM QuickOps - Interactive Manager

## Overview

SolarWinds SAM QuickOps is an interactive TUI (Text User Interface) application that provides a GUI-like experience for managing SolarWinds SAM without the web console. It enables quick access to common operations like node management, template deployment, alert management, and maintenance mode.

## Prerequisites

### Required Modules
- **SwisPowerShell** - SolarWinds Information Service PowerShell module
- Windows PowerShell 5.1 or higher

### Permissions
- SolarWinds SAM admin or equivalent
- Node management permissions
- Alert acknowledgment permissions
- Template management permissions

### Installation

```powershell
# Install SwisPowerShell module
Install-Module -Name SwisPowerShell -Force -Scope CurrentUser

# Or download from SolarWinds website:
# https://github.com/solarwinds/OrionSDK
```

## Quick Start

### Basic Usage

```powershell
# Run in interactive mode (prompts for server and credentials)
.\SolarWindsSAM-QuickOps.ps1

# Connect to specific server
.\SolarWindsSAM-QuickOps.ps1 -SwisServer "solarwinds.yourdomain.local"

# With credentials (avoid prompt)
$cred = Get-Credential
.\SolarWindsSAM-QuickOps.ps1 -SwisServer "solarwinds.yourdomain.local" -UserName $cred.UserName -Password $cred.Password
```

### Set Default Server

```powershell
# Set global variable in PowerShell profile ($PROFILE)
$global:SOLARWINDS_SERVER = "solarwinds.yourdomain.local"

# Now you can just run:
.\SolarWindsSAM-QuickOps.ps1
```

## Menu System

### Main Menu

```
╔══════════════════════════════════════════════════════════════════╗
║        SolarWinds SAM QuickOps - Interactive Manager                ║
╚══════════════════════════════════════════════════════════════════╝

DASHBOARD SUMMARY
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Nodes: 245 total | 230 Up (94%) | 12 Down | 3 Unmanaged
  Apps: 520 | 489 Available (94%) | 31 Warning | 0 Critical
  Alerts: 8 Critical | 15 Warning | 23 Total
  Maintenance: 3 nodes currently unmanaged

SELECT AN OPERATION
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  1. Node Management (Search, View, Bulk Actions)
  2. Template Management (List, Create, Assign)
  3. Application Monitors (View, Deploy, Configure)
  4. Alert Management (View, Acknowledge, Create)
  5. Maintenance Mode (Enter, Exit, Schedule)
  6. Dashboard & Statistics (Full detailed views)
  7. Quick Actions (Frequent operations)
  8. Settings & Connection
  0. Exit

QUICK SHORTCUTS: [N]ode Search  [T]emplates  [A]lerts  [M]aintenance  [R]efresh Dashboard

Your selection:
```

### Quick Shortcuts

Press these keys from main menu:
- `N` or `n` - Go directly to Node Search
- `T` or `t` - Go directly to Template Management
- `A` or `a` - Go directly to Alert Management
- `M` or `m` - Go directly to Maintenance Mode
- `R` or `r` - Refresh dashboard

## Features

### 1. Node Management

**Search Nodes:**
- Partial hostname/IP matching
- Search across NodeName, Caption, IP_Address
- Filter by status (Up/Down/Warning/Unmanaged)
- Results displayed as numbered list

**View Node Details:**
- Complete node information
- Performance metrics (CPU, response time)
- Maintenance status
- Custom properties (Site, Department, Contact)
- Applications assigned to the node

**Bulk Maintenance Mode:**
- Select multiple nodes
- Set uniform maintenance window
- Enter duration in hours
- Apply to all selected at once

### 2. Template Management

**List Templates:**
- All SAM templates with details
- Component count and assignment count
- Sort by name

**Create New Template Wizard:**
- Step-by-step template creation
- Pre-built templates:
  - SQL Server Monitor
  - IIS Web Monitor
  - Domain Controller Monitor
  - Custom
- Component selection from predefined list
- Preview before creation

**Assign Template to Nodes:**
- Select template
- Select target nodes (search or pick multiple)
- Preview assignment summary
- Bulk assignment with progress display

### 3. Application Monitor Management

**View Applications by Node:**
- List all SAM applications per node
- Show component status
- Display availability percentages

**Deploy New Monitor:**
- Select node(s)
- Select template
- Configure credentials (if needed)
- Deploy with confirmation

### 4. Alert Management

**View Active Alerts:**
- All currently active alerts
- Filter by severity
- Show acknowledge status
- Display trigger time

**View Unacknowledged Alerts:**
- Only show alerts needing attention
- Quick acknowledge multiple alerts
- Add acknowledgment notes

**Acknowledge Alerts:**
- Select multiple alerts
- Add notes
- Bulk acknowledgment

**Create New Alert:**
- Wizard-based alert creation
- Define trigger conditions
- Set severity and actions

### 5. Maintenance Mode Management

**Single Node Maintenance:**
- Enter time (hours or specific end time)
- Optional note/reason
- Immediate unmanage

**Bulk Maintenance Wizard:**
- Select multiple nodes
- Set uniform maintenance window
- Individual maintenance windows per node
- Preview before execution

**Resume from Maintenance:**
- List nodes in maintenance
- Resume individual or all
- Resume expired maintenance windows

### 6. Dashboard & Statistics

**Node Health Dashboard:**
- Total nodes, % up
- Average CPU, memory, response time
- Nodes by vendor/type breakdown
- Top 5 CPU consumers
- Top 5 warning/critical nodes

**Application Monitor Dashboard:**
- Total applications, % available
- Applications by template type
- Top 5 problematic applications
- Monitor coverage statistics

**Alert Center:**
- Active alerts by severity
- Unacknowledged count
- Top alert sources
- Recent alert history (last 24h)

**Maintenance Status:**
- Currently unmanaged nodes
- Maintenance windows expiring soon
- Visual timeline

### 7. Quick Actions

Fast access to frequently used operations:
- Quick node search
- Quick template assignment
- Quick maintenance entry
- Dashboard refresh

### 8. Settings & Connection

- Display current connection status
- Switch to different SolarWinds server
- Reconnect with new credentials
- View server information

## Common Workflows

### Quickly Put Nodes in Maintenance

1. Run script
2. Press `M` to go to Maintenance Mode
3. Select "2. Enter Maintenance Mode"
4. Search for nodes or select from list
5. Enter duration (e.g., 2 hours)
6. Confirm

### Assign Template to Multiple Nodes

1. Run script
2. Select "2. Template Management"
3. Select "3. Assign Template to Node(s)"
4. Choose template
5. Select nodes (search or browse)
6. Confirm

### Search for a Node and View Details

1. Run script
2. Press `N` to search
3. Enter partial name/IP
4. Select node from results
5. View complete details

### Acknowledge All Critical Alerts

1. Run script
2. Press `A` to go to Alert Management
3. Select "2. View Unacknowledged Alerts"
4. Select "all" to acknowledge all
5. Enter note (optional)
6. Confirm

### Create a New SQL Server Template

1. Run script
2. Select "2. Template Management"
3. Select "2. Create New Template"
4. Enter template name
5. Select "1. Windows Service" component type
6. Add MSSQLSERVER service
7. Add SQLAgent$MSSQLSERVER service
8. Finish when done

## SWQL Query Examples

### Find Nodes by Custom Property

```swql
SELECT NodeID, Caption, IP_Address
FROM Orion.Nodes n
JOIN Orion.NodesCustomProperties cp ON n.NodeID = cp.NodeID
WHERE cp.Site = 'Austin' OR cp.Department = 'Production'
```

### Find Applications Down for More Than 1 Hour

```swql
SELECT a.ApplicationID, a.Name, a.Status, a.Availability,
       a.NodeID, n.Caption AS NodeName
FROM Orion.APM.Application a
JOIN Orion.Nodes n ON a.NodeID = n.NodeID
WHERE a.Status = 2
ORDER BY a.Availability DESC
```

### Get Alerts Triggered Today

```swql
SELECT aa.AlertActiveID, ao.EntityCaption, ao.EntityType,
       ac.Name AS AlertName, ac.Severity,
       aa.TriggeredDateTime
FROM Orion.AlertActive aa
JOIN Orion.AlertObjects ao ON aa.AlertObjectID = ao.AlertObjectID
JOIN Orion.AlertConfigurations ac ON ao.AlertID = ac.AlertID
WHERE aa.TriggeredDateTime >= GetUtcDate()
ORDER BY aa.TriggeredDateTime DESC
```

## Troubleshooting

### Connection Issues

**Problem:** Cannot connect to SolarWinds

**Solutions:**
```powershell
# Test connectivity
Test-NetConnection -ComputerName solarwinds-server -Port 17778

# Test SWIS API
$cred = Get-Credential
Connect-Swis -Hostname "solarwinds-server" -Credential $cred

# Check if module is loaded
Get-Module -ListAvailable -Name SwisPowerShell
```

### "Not Found" Errors

**Problem:** Node, template, or application not found

**Solutions:**
- Check search term spelling
- Use partial matching (first few characters)
- Try searching by IP instead of hostname
- Verify object exists in web console

### Permission Denied

**Problem:** Cannot perform operations (maintenance, assign template)

**Solutions:**
- Verify account has SAM admin permissions
- Check SolarWinds role assignments
- Confirm user has permission to target nodes/templates

### SWQL Query Errors

**Problem:** Queries fail or return no results

**Solutions:**
- Validate SWQL syntax
- Check entity names are correct (Orion.Nodes, Orion.APM.Application)
- Use parameterized queries to avoid SQL injection
- Test query in SolarWinds Query Builder first

### Bulk Operation Failures

**Problem:** Some operations fail in bulk mode

**Solutions:**
- Operations are processed individually, failures won't stop batch
- Review log for failed operations
- Retry failed operations individually
- Check for specific node issues causing failures

## Advanced Features

### Multi-Selection Interface

- Press `SPACE` to select/deselect items
- Press `ENTER` to confirm selection
- Press `A` to select all visible items
- Press `N` to deselect all
- Visual indicators for selected items

### Maintenance Calendar View

- Shows all current and upcoming maintenance
- Color-coded by status
- Quick resume/extend options

### Search History

- Remembers last 10 searches
- Arrow key navigation through history
- Quick repeat of common searches

### Real-Time Dashboard Updates

- Auto-refresh option (configurable interval)
- Manual refresh with `R` key
- Changes since last refresh indicator

## Configuration File

Edit `SolarWindsSAM-QuickOps-config.json` to customize:

- **Default Server**: Set default SolarWinds server
- **Default Maintenance Hours**: Default duration for maintenance
- **Alert Severity Colors**: Custom color scheme
- **Pre-Built Templates**: Customize template definitions
- **Quick Actions**: Define favorite quick actions

## Tips & Best Practices

1. **Use Search Before Operations** - Always verify node exists before actions
2. **Preview Before Bulk Actions** - Review selected items before executing
3. **Set Appropriate Maintenance Durations** - Use the minimum time needed
4. **Acknowledge Promptly** - Keep unacknowledged alert count low
5. **Use Templates for Consistency** - Reuse templates instead of creating individual monitors
6. **Review Dashboard Regularly** - Quick way to spot issues early
7. **Keep Credentials Secure** - Use Windows Credential Manager instead of saving in scripts
8. **Test in Non-Prod First** - Always test template deployments on dev nodes

## Keyboard Shortcuts Reference

- `N` - Node Search (from main menu)
- `T` - Templates (from main menu)
- `A` - Alerts (from main menu)
- `M` - Maintenance (from main menu)
- `R` - Refresh Dashboard (from main menu)
- `0` - Exit / Back (from any menu)
- `SPACE` - Select/Deselect item (in selection lists)
- `ENTER` - Confirm selection
- `A` - Select All (in selection lists)
- `N` - Deselect All (in selection lists)

## Integration with Other Tools

### With CertDeploy

```powershell
# 1. Use SolarWinds to find nodes needing certificate renewal
# 2. Note the nodes and use CertDeploy to deploy
.\CertDeploy.ps1 -Command verify -Server $serverName
```

### With Automox

```powershell
# 1. Check Automox compliance before maintenance
.\Invoke-AutomoxHealthCheck.ps1
# 2. Use SolarWindsSAM-QuickOps to enter maintenance
```

### With vCenter Integration

```powershell
# 1. Correlate SolarWinds node names with VM names
# 2. Use both tools together for comprehensive monitoring
```

## Reporting

### Export Node List

Not currently implemented - use SolarWinds web console or SWQL queries to export to CSV.

### Generate Audit Trail

All operations are logged to console. To save a log:

```powershell
# Save session output to file
.\SolarWindsSAM-QuickOps.ps1 | Tee-Object -FilePath "SolarWindsOps_$(Get-Date -Format 'yyyyMMdd').log"
```

## Support

For issues, questions, or contributions, please refer to your internal documentation or contact the Infrastructure Engineering team.

## Version History

- **v1.0** - Initial release with core features
  - Interactive menu system
  - Node search and management
  - Template creation and assignment
  - Maintenance mode
  - Alert acknowledgment
  - Dashboard statistics

## License

Internal tool - licensed for use within your organization.
