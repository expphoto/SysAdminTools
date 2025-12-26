# Interactive menu for Invoke-InfraLifecycle is now enabled!

To use the interactive menu mode, simply run:

```powershell
.\Invoke-InfraLifecycle.ps1
```

This will launch the interactive TUI menu with the following options:

## Menu Options

1. **Provision new datastore** - Create a complete datastore end-to-end
2. **Clone volume (Dev environment)** - Create zero-copy dev/test environments
3. **Expand existing datastore** - Grow storage without downtime
4. **Retire datastore** - Cleanly decommission datastores
5. **Audit infrastructure** - Run compliance checks
6. **Connect to Nimble/vCenter** - Establish connections
7. **View cluster information** - See cluster health and details
8. **View available volumes** - Browse Nimble volumes
0. **Exit** - Exit the tool

## Getting Started

1. Run the script without parameters to enter interactive mode
2. Select option 6 to connect to Nimble and vCenter (or set global variables)
3. Navigate through the menu to perform operations

## Example Interactive Workflow

```
$ .\Invoke-InfraLifecycle.ps1

╔═══════════════════════════════════════════════════════════════════╗
║         Infrastructure State Controller - Interactive Menu               ║
╚═══════════════════════════════════════════════════════════════════╝

Connected to:
  [ ] Nimble: nimble.domain.local
  [ ] vCenter: vcenter.domain.local

Select an operation:
  1. Provision new datastore
  2. Clone volume (Dev environment)
  3. Expand existing datastore
  4. Retire datastore
  5. Audit infrastructure
  6. Connect to Nimble/vCenter
  7. View cluster information
  8. View available volumes
  0. Exit

Enter selection: 6
```

## Non-Interactive Mode Still Available

You can still run commands directly without the interactive menu:

```powershell
# Provision directly
.\Invoke-InfraLifecycle.ps1 -Intent Provision -ClusterName "Prod-SQL" -VolName "s-SQL-01" -SizeGB 2048

# Audit directly
.\Invoke-InfraLifecycle.ps1 -Intent Audit
```

## Configuration

Set global variables in your PowerShell profile to avoid entering them:

```powershell
$global:NIMBLE_SERVER = "nimble-array.domain.local"
$global:VCENTER_SERVER = "vcenter.domain.local"
```

Then run:

```powershell
.\Invoke-InfraLifecycle.ps1
```

## Features

- **Color-coded output** for easy reading
- **Connection status** displayed in main menu
- **Step-by-step wizards** for complex operations
- **Summary screens** before execution
- **WhatIf mode** available in all operations
- **Safe confirmations** for destructive actions
- **VM count checks** before retiring datastores
- **Health checks** after provisioning
- **Browse volumes and clusters** interactively