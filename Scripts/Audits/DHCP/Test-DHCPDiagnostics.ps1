#Requires -Modules DHCPServer

<#
.SYNOPSIS
    Diagnostic script for DHCP module and connectivity issues.

.DESCRIPTION
    This script helps diagnose common issues when running Invoke-DHCPLeaseValidation.ps1.
    It checks for module availability, permissions, and DHCP server connectivity.

.EXAMPLE
    .\Test-DHCPDiagnostics.ps1 -Server "SERVER01"
#>

param(
    [string]$Server = $env:COMPUTERNAME
)

Write-Host "DHCP Diagnostics for server: $Server" -ForegroundColor Cyan
Write-Host "=" * 60

# 1. Check if DHCP module is available
Write-Host "`n[1] Checking for DHCPServer module..." -ForegroundColor Yellow
try {
    $module = Get-Module -ListAvailable -Name DHCPServer
    if ($module) {
        Write-Host "    DHCPServer module found: $($module.Version)" -ForegroundColor Green
    } else {
        Write-Host "    DHCPServer module NOT found" -ForegroundColor Red
        Write-Host "    Install RSAT tools or DHCP Server role" -ForegroundColor Yellow
    }
} catch {
    Write-Host "    Error checking module: $_" -ForegroundColor Red
}

# 2. Check if DNS module is available
Write-Host "`n[2] Checking for DnsServer module..." -ForegroundColor Yellow
try {
    $module = Get-Module -ListAvailable -Name DnsServer
    if ($module) {
        Write-Host "    DnsServer module found: $($module.Version)" -ForegroundColor Green
    } else {
        Write-Host "    DnsServer module NOT found" -ForegroundColor Red
        Write-Host "    Install RSAT tools or DNS Server role" -ForegroundColor Yellow
        Write-Host "    DHCP validation can run without DNS module (skip alignment check)" -ForegroundColor Yellow
    }
} catch {
    Write-Host "    Error checking module: $_" -ForegroundColor Red
}

# 3. Check current user permissions
Write-Host "`n[3] Checking user permissions..." -ForegroundColor Yellow
$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)

Write-Host "    Current user: $($currentUser.Name)" -ForegroundColor Cyan
if ($isAdmin) {
    Write-Host "    Running as Administrator: YES" -ForegroundColor Green
} else {
    Write-Host "    Running as Administrator: NO" -ForegroundColor Red
    Write-Host "    Restart PowerShell as Administrator" -ForegroundColor Yellow
}

# 4. Test connectivity to DHCP server
Write-Host "`n[4] Testing connectivity to DHCP server..." -ForegroundColor Yellow
try {
    $ping = Test-Connection -ComputerName $Server -Count 1 -Quiet -ErrorAction SilentlyContinue
    if ($ping) {
        Write-Host "    Ping response: SUCCESS" -ForegroundColor Green
    } else {
        Write-Host "    Ping response: FAILED" -ForegroundColor Red
    }

    $dhcpPort = Test-NetConnection -ComputerName $Server -Port 67 -InformationLevel Quiet -WarningAction SilentlyContinue
    if ($dhcpPort) {
        Write-Host "    DHCP port 67: OPEN" -ForegroundColor Green
    } else {
        Write-Host "    DHCP port 67: CLOSED or filtered" -ForegroundColor Red
    }
} catch {
    Write-Host "    Error testing connectivity: $_" -ForegroundColor Red
}

# 5. Check if DHCP server role is installed on target
Write-Host "`n[5] Checking DHCP Server role..." -ForegroundColor Yellow
try {
    if ($Server -eq $env:COMPUTERNAME -or $Server -eq "localhost") {
        $feature = Get-WindowsFeature -Name DHCP -ErrorAction SilentlyContinue
        if ($feature) {
            if ($feature.Installed) {
                Write-Host "    DHCP Server role: INSTALLED" -ForegroundColor Green
            } else {
                Write-Host "    DHCP Server role: NOT INSTALLED" -ForegroundColor Red
                Write-Host "    Install: Install-WindowsFeature DHCP -IncludeManagementTools" -ForegroundColor Yellow
            }
        } else {
            Write-Host "    Unable to check (server OS required)" -ForegroundColor Yellow
        }
    } else {
        Write-Host "    Skipping (remote server - requires RSAT)" -ForegroundColor Yellow
    }
} catch {
    Write-Host "    Error checking DHCP role: $_" -ForegroundColor Red
}

# 6. Try to query DHCP scopes
Write-Host "`n[6] Testing DHCP scope query..." -ForegroundColor Yellow
try {
    $scopes = Get-DhcpServerv4Scope -ComputerName $Server -ErrorAction Stop
    if ($scopes) {
        Write-Host "    Successfully queried $($scopes.Count) scope(s)" -ForegroundColor Green
        foreach ($s in $scopes | Select-Object -First 3) {
            Write-Host "      - $($s.ScopeId) ($($s.Name))" -ForegroundColor Cyan
        }
        if ($scopes.Count -gt 3) {
            Write-Host "      ... and $($scopes.Count - 3) more" -ForegroundColor Cyan
        }
    } else {
        Write-Host "    No scopes found (DHCP may not have scopes configured)" -ForegroundColor Yellow
    }
} catch {
    Write-Host "    FAILED to query DHCP scopes" -ForegroundColor Red
    Write-Host "    Error: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "`n    Possible solutions:" -ForegroundColor Yellow
    Write-Host "      1. Verify server name: '$Server'" -ForegroundColor Yellow
    Write-Host "      2. Run PowerShell as Administrator" -ForegroundColor Yellow
    Write-Host "      3. Install RSAT: Install-WindowsFeature RSAT-DHCP" -ForegroundColor Yellow
    Write-Host "      4. Check WinRM: Test-WSMan -ComputerName $Server" -ForegroundColor Yellow
    Write-Host "      5. Verify user is in 'DHCP Administrators' group" -ForegroundColor Yellow
}

# 7. Test DNS query if module available
Write-Host "`n[7] Testing DNS scavenging query..." -ForegroundColor Yellow
try {
    $module = Get-Module -ListAvailable -Name DnsServer
    if ($module) {
        $zones = Get-DnsServerZone -ComputerName $Server -ErrorAction Stop | Where-Object { 
            $_.IsAutoCreated -eq $false -and $_.ZoneType -eq "Primary" 
        }
        if ($zones) {
            Write-Host "    Successfully queried $($zones.Count) zone(s)" -ForegroundColor Green
        } else {
            Write-Host "    No zones found" -ForegroundColor Yellow
        }
    } else {
        Write-Host "    Skipped (DnsServer module not available)" -ForegroundColor Yellow
    }
} catch {
    Write-Host "    Failed to query DNS zones: $_" -ForegroundColor Red
    Write-Host "    DNS alignment check will be skipped" -ForegroundColor Yellow
}

Write-Host "`n" + "=" * 60
Write-Host "Diagnostics complete!" -ForegroundColor Cyan
Write-Host "`nIf DHCP query failed, try running PowerShell as Administrator" -ForegroundColor Yellow
