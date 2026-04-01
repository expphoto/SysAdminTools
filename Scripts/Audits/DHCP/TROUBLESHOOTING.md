# Troubleshooting Guide

## Error: "Failed to query DHCP scopes from [Server]"

### Quick Diagnostic

Run the diagnostic script first:

```powershell
.\Test-DHCPDiagnostics.ps1 -Server "SERVER01"
```

Or run PowerShell as Administrator and try:

```powershell
Get-DhcpServerv4Scope -ComputerName "SERVER01"
```

### Common Causes and Solutions

#### 1. DHCP Server Role Not Installed

**Symptom**: "The RPC server is unavailable" or "DHCP server is not running"

**Solution (Local Server)**:
```powershell
Install-WindowsFeature DHCP -IncludeManagementTools
Add-DhcpServerInDC -DnsName "server01.corp.example"
```

**Solution (Verify Installation)**:
```powershell
Get-WindowsFeature -Name DHCP
```

#### 2. Missing RSAT Tools (Remote Management)

**Symptom**: "The term 'Get-DhcpServerv4Scope' is not recognized"

**Solution**:
```powershell
Install-WindowsFeature RSAT-DHCP
```

Or install RSAT from Settings → Apps → Optional features → RSAT: DHCP Server Tools

#### 3. Insufficient Permissions

**Symptom**: "Access is denied" or "You do not have permissions"

**Solution**:
1. Ensure you're running PowerShell as **Administrator**
2. Verify your account is in one of these groups:
   - Domain Admins (recommended)
   - DHCP Administrators
   - Local Administrators

**Add user to DHCP Administrators**:
```powershell
Add-DhcpServerSecurityGroup -ComputerName "SERVER01"
# Then add your user to the "DHCP Administrators" group in AD
```

#### 4. WinRM/PowerShell Remoting Issues

**Symptom**: "WinRM cannot process the request" or "RPC server unavailable"

**Solution** (on target server SERVER01):
```powershell
# Enable WinRM
winrm quickconfig -force

# Test from your machine
Test-WSMan -ComputerName "SERVER01"

# Enable CredSSP (if needed)
winrm set winrm/config/client '@{TrustedHosts="SERVER01"}'
```

#### 5. Firewall Blocking

**Symptom**: Timeout or connection refused

**Solution** (on target server SERVER01):
```powershell
# Enable WinRM firewall rules
Enable-NetFirewallRule -DisplayGroup "Windows Remote Management"

# Or manually allow ports
New-NetFirewallRule -DisplayName "WinRM HTTP" -Direction Inbound -Protocol TCP -LocalPort 5985 -Action Allow
```

#### 6. Server Name Resolution

**Symptom**: "The network path was not found"

**Solution**:
```powershell
# Test DNS resolution
Test-NetConnection -ComputerName "SERVER01" -InformationLevel Detailed

# Use FQDN instead
.\Invoke-DHCPLeaseValidation.ps1 -DHCPServer "server01.corp.example"

# Use IP address (may cause Kerberos issues)
.\Invoke-DHCPLeaseValidation.ps1 -DHCPServer "192.168.1.10"
```

### Alternative: Run Script Without DNS Module

If the DnsServer module is not available, skip the DNS scavenging check:

```powershell
.\Invoke-DHCPLeaseValidation.ps1 -DHCPServer "SERVER01" -SkipDNSCheck
```

This will still audit DHCP scopes and lease times, just won't validate DNS alignment.

### Check Your Environment

Run these commands to diagnose:

```powershell
# 1. Are you running as admin?
([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# 2. Is DHCP module available?
Get-Module -ListAvailable -Name DHCPServer

# 3. Can you ping the server?
Test-Connection -ComputerName "SERVER01" -Count 1

# 4. Is WinRM working?
Test-WSMan -ComputerName "SERVER01"

# 5. Can you connect to DHCP?
Get-DhcpServerv4Scope -ComputerName "SERVER01" -ErrorAction Stop
```

### Common Workflows

#### Local Server (Server is your computer)

```powershell
# 1. Run as Administrator
# 2. Install DHCP role (if needed)
Install-WindowsFeature DHCP -IncludeManagementTools

# 3. Run script
.\Invoke-DHCPLeaseValidation.ps1
```

#### Remote Server (Different computer)

```powershell
# 1. Run as Administrator
# 2. Install RSAT
Install-WindowsFeature RSAT-DHCP

# 3. Enable WinRM on both computers
#    (on server) winrm quickconfig -force
#    (on client) winrm set winrm/config/client '@{TrustedHosts="*"}'

# 4. Run script
.\Invoke-DHCPLeaseValidation.ps1 -DHCPServer "SERVER01"
```

#### Managed Server (Domain joined, proper permissions)

```powershell
# 1. Ensure account is in DHCP Administrators or Domain Admins
# 2. Run as Administrator
# 3. Run script
.\Invoke-DHCPLeaseValidation.ps1 -DHCPServer "SERVER01"
```

### Still Having Issues?

1. **Check Windows Event Logs**:
   ```
   Event Viewer → Applications and Services Logs → Microsoft → Windows → DHCP-Server
   ```

2. **Check DHCP Server Service**:
   ```powershell
   Get-Service DHCPServer
   Start-Service DHCPServer
   ```

3. **Test with basic PowerShell**:
   ```powershell
   Enter-PSSession -ComputerName "SERVER01"
   Get-DhcpServerv4Scope
   Exit-PSSession
   ```

4. **Contact your network administrator** if you don't have:
   - Administrator privileges
   - Remote server access
   - RSAT tools installed
