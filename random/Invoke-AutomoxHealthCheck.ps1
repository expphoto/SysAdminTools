#Requires -Version 5.1

param(
    [string]$MinVersion = "1.43.0",
    [string]$ZscalerCAThumbprint = "",
    [string]$LogFile = "C:\Logs\AutomoxHealthCheck.log",
    [switch]$SendEmail,
    [string]$EmailFrom = "automox@yourdomain.com",
    [string]$EmailTo = "admin@yourdomain.com",
    [string]$SmtpServer = "smtp.yourdomain.com"
)

$ErrorActionPreference = "Stop"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"
    Write-Output $logEntry
    if ($LogFile) {
        try {
            $logDir = Split-Path -Parent $LogFile
            if (!(Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
            Add-Content -Path $LogFile -Value $logEntry
        } catch {
            Write-Warning "Could not write to log file: $_"
        }
    }
}

function Test-AutomoxAgent {
    Write-Log "Starting Automox Agent Health Check"
    
    $issues = @()
    
    $service = Get-Service -Name "amagent" -ErrorAction SilentlyContinue
    
    if (-not $service) {
        $issues += "Automox agent service not found"
        Write-Log "Automox agent service not found" "ERROR"
    } else {
        if ($service.Status -ne "Running") {
            $issues += "Automox agent service status: $($service.Status)"
            Write-Log "Automox agent service not running (Status: $($service.Status))" "ERROR"
            try {
                Start-Service -Name "amagent" -ErrorAction Stop
                $issues += "Attempted to start Automox agent service"
                Write-Log "Attempted to start Automox agent service" "WARNING"
            } catch {
                $issues += "Failed to start Automox agent service: $_"
                Write-Log "Failed to start Automox agent service: $_" "ERROR"
            }
        } else {
            Write-Log "Automox agent service is running"
        }
    }
    
    $agentVersion = try {
        $result = & "C:\Program Files\Automox\amagent.exe" --version 2>&1
        if ($result -match "(\d+\.\d+\.\d+)") {
            $matches[1]
        } else {
            $null
        }
    } catch {
        $null
    }
    
    if (-not $agentVersion) {
        $issues += "Could not determine Automox agent version"
        Write-Log "Could not determine Automox agent version" "ERROR"
    } else {
        Write-Log "Automox agent version: $agentVersion"
        if ([version]$agentVersion -lt [version]$MinVersion) {
            $issues += "Automox agent version $agentVersion is below minimum required $MinVersion"
            Write-Log "Automox agent version $agentVersion is below minimum required $MinVersion" "ERROR"
        }
    }
    
    if ($ZscalerCAThumbprint) {
        Write-Log "Checking for Zscaler root CA certificate"
        $cert = Get-ChildItem -Path "Cert:\LocalMachine\Root" -Recurse | Where-Object { $_.Thumbprint -eq $ZscalerCAThumbprint }
        
        if (-not $cert) {
            $issues += "Zscaler root CA certificate not found (Thumbprint: $ZscalerCAThumbprint)"
            Write-Log "Zscaler root CA certificate not found" "ERROR"
        } else {
            Write-Log "Zscaler root CA certificate found"
        }
    }
    
    $hostname = $env:COMPUTERNAME
    
    if ($issues.Count -gt 0) {
        $subject = "Automox Health Check FAILED on $hostname"
        $body = "Automox Health Check completed with issues on $hostname:`n`n"
        $body += ($issues | ForEach-Object { "- $_" }) -join "`n"
        $body += "`n`nCheck log file: $LogFile"
        Write-Log "Health check completed with $($issues.Count) issues" "ERROR"
    } else {
        $subject = "Automox Health Check PASSED on $hostname"
        $body = "Automox Health Check completed successfully on $hostname.`n`nAll checks passed."
        Write-Log "Health check completed successfully"
    }
    
    if ($SendEmail -and $SmtpServer) {
        try {
            Send-MailMessage -From $EmailFrom -To $EmailTo -Subject $subject -Body $body -SmtpServer $SmtpServer
            Write-Log "Email notification sent"
        } catch {
            Write-Log "Failed to send email: $_" "WARNING"
        }
    }
    
    return @{
        Success = ($issues.Count -eq 0)
        Issues = $issues
        Hostname = $hostname
        AgentVersion = $agentVersion
        ServiceStatus = if ($service) { $service.Status } else { "Not Found" }
    }
}

$result = Test-AutomoxAgent
return $result