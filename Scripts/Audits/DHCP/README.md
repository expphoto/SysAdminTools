# DHCP Lease Validation

Audits DHCP scopes and validates lease times against DNS scavenging settings.

## Purpose

This script helps ensure DHCP lease durations are properly configured relative to DNS scavenging settings. This is critical for preventing premature deletion of DNS records or accumulation of stale records.

## Best Practices

- **DHCP Lease Duration**: Should be less than DNS scavenging period
- **Recommended Configuration**:
  - DHCP lease: 8 days
  - DNS No-refresh interval: 7 days
  - DNS Refresh interval: 7 days
  - Total DNS scavenging period: 14 days
  - Buffer: 6 days (14 - 8 = 6)

## Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `DHCPServer` | DHCP server to query | Local computer |
| `ScopeId` | Specific scope to audit | All scopes |
| `DNSServer` | DNS server for scavenging settings | Same as DHCP server |
| `OutputPath` | Output directory | `C:\Reports\DHCP` |
| `IncludeInactive` | Include inactive scopes | False |
| `SkipDNSCheck` | Skip DNS scavenging alignment check | False |

## Usage Examples

```powershell
# Audit all scopes
.\Invoke-DHCPLeaseValidation.ps1 -DHCPServer "SERVER01"

# Audit specific scope
.\Invoke-DHCPLeaseValidation.ps1 -DHCPServer "SERVER01" -ScopeId "192.168.1.0"

# Include inactive scopes
.\Invoke-DHCPLeaseValidation.ps1 -DHCPServer "SERVER01" -IncludeInactive

# Custom output path
.\Invoke-DHCPLeaseValidation.ps1 -DHCPServer "SERVER01" -OutputPath "C:\Temp\Reports"

# Skip DNS check (if DNS module not available)
.\Invoke-DHCPLeaseValidation.ps1 -DHCPServer "SERVER01" -SkipDNSCheck
```

## Output Files

The script generates three reports:

1. **JSON** (`DHCPLeaveValidation-YYYYMMDD-HHMMSS.json`)
   - Detailed data for automation/scripting
   - Includes all scope details and alignment results

2. **HTML** (`DHCPLeaveValidation-YYYYMMDD-HHMMSS.html`)
   - Interactive web report
   - Color-coded status indicators
   - Recommendations and issues highlighted

3. **CSV** (`DHCPLeaveValidation-YYYYMMDD-HHMMSS.csv`)
   - Spreadsheet-compatible format
   - Easy for filtering and sorting
   - Separate alignment CSV if issues found

## Understanding the Reports

### Alignment Status

| Status | Meaning | Action |
|--------|---------|--------|
| **Valid** | DHCP lease is shorter than DNS scavenging period with sufficient buffer | No action needed |
| **Warning** | DHCP lease is close to DNS scavenging period (< 2 day buffer) | Monitor or adjust settings |
| **Critical** | DHCP lease >= DNS scavenging period | Immediate action required |

### Lease Duration Recommendations

| Lease Duration | Recommendation |
|----------------|----------------|
| < 1 day | Too short - may cause excessive DHCP renewals and DNS updates |
| 1-3 days | OK for high-churn environments (wireless, hot-desk) |
| 4-7 days | Standard - matches Microsoft best practices |
| 8-14 days | Acceptable - ensure DNS scavenging intervals are longer |
| > 14 days | Too long - stale records may accumulate in DNS |

## Common Issues and Solutions

### Issue: "Lease >= Scavenge period"

**Problem**: DNS records may be deleted before DHCP leases expire.

**Solution**: Increase DNS scavenging intervals or decrease DHCP lease duration.

```powershell
# Decrease DHCP lease to 8 days
Set-DhcpServerv4Scope -ScopeId "192.168.1.0" -LeaseDuration 8.00:00:00

# Increase DNS scavenging intervals
Set-DnsServerZoneAging -ZoneName "corp.example" -NoRefreshInterval 7.00:00:00 -RefreshInterval 7.00:00:00
```

### Issue: "Scavenging not enabled"

**Problem**: DNS records are never automatically cleaned up.

**Solution**: Enable DNS scavenging.

```powershell
# Enable server-level scavenging
Set-DnsServerScavenging -ScavengingState $true -ScavengingInterval 7.00:00:00

# Enable zone-level aging
Set-DnsServerZoneAging -ZoneName "corp.example" -Aging $true
```

## Integration with DNS Audit

Use this script alongside the DNS Age Audit script for comprehensive management:

```powershell
# Step 1: Validate DHCP/DNS alignment
.\Invoke-DHCPLeaseValidation.ps1 -DHCPServer "SERVER01"

# Step 2: Audit DNS record ages
.\Invoke-DNSAgeAudit.ps1 -DNSServer "SERVER01"

# Step 3: Clean up old records (with online check)
.\Invoke-DNSCleanup.ps1 -JSONPath "C:\Reports\DNS\DNSAgeAudit-*.json" -CheckOnline -SkipOnline
```

## Requirements

**Required:**
- Windows Server 2012 R2 or later (or Windows 10+ with RSAT)
- PowerShell 5.1 or later
- DHCP Server PowerShell module (included with DHCP role or RSAT)
- Domain Administrator or DHCP Administrator privileges

**Optional:**
- DNS Server PowerShell module (for DNS scavenging alignment check)
- Run as Administrator

**Install missing modules:**
```powershell
# Install RSAT for DHCP (on client/workstation)
Install-WindowsFeature RSAT-DHCP

# Install RSAT for DNS (for DNS alignment check)
Install-WindowsFeature RSAT-DNS-Server-Tools

# Install DHCP Server role (on server)
Install-WindowsFeature DHCP -IncludeManagementTools
```

## Troubleshooting

### "Failed to query DHCP scopes"

1. **Run PowerShell as Administrator**
2. Verify server name is correct: `Test-Connection -ComputerName "SERVER01"`
3. Ensure DHCP Server service is running on target
4. Install RSAT tools if querying remote server: `Install-WindowsFeature RSAT-DHCP`
5. Check permissions (DHCP Administrators or Domain Admins)
6. Test connectivity: `Test-NetConnection -ComputerName SERVER01 -Port 67`
7. Run diagnostic script: `.\Test-DHCPDiagnostics.ps1 -Server "SERVER01"`

**See detailed troubleshooting guide in `TROUBLESHOOTING.md`**

### "Failed to query DNS scavenging settings"

1. Verify DNS server is accessible
2. Install RSAT DNS tools: `Install-WindowsFeature RSAT-DNS-Server-Tools`
3. Check permissions (DNSAdmins group)
4. Test connectivity: `Test-NetConnection -ComputerName SERVER01 -Port 53`
5. Or skip DNS check: `.\Invoke-DHCPLeaseValidation.ps1 -SkipDNSCheck`

### "DnsServer module not available"

The script will automatically detect if the DnsServer module is missing and skip the DNS scavenging alignment check. You can also manually skip it with the `-SkipDNSCheck` parameter.

### No scopes found

1. Verify DHCP server has scopes configured
2. Use `-IncludeInactive` to see disabled scopes
3. Check for firewall blocking queries
4. Run diagnostic: `.\Test-DHCPDiagnostics.ps1`

## Quick Diagnostic

If you're having trouble, run the diagnostic script:

```powershell
.\Test-DHCPDiagnostics.ps1 -Server "SERVER01"
```

This will check:
- Module availability
- User permissions (Administrator)
- Server connectivity
- DHCP role installation
- DHCP scope query capability
- DNS scavenging query capability
