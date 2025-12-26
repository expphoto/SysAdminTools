#Requires -Modules VMware.PowerCLI

param(
    [Parameter(Mandatory = $true)]
    [string]$VCenterServer,
    
    [string[]]$DatastorePatterns = @("*Graveyard*", "*Archive*", "*Decommission*"),
    
    [string]$OutputPath = "C:\Reports\ZombieVMReport.csv",
    
    [switch]$PowerOffVMs,
    [int]$DaysThreshold = 30,
    
    [switch]$SendEmail,
    [string]$EmailFrom = "vcenter@yourdomain.com",
    [string]$EmailTo = "admin@yourdomain.com",
    [string]$SmtpServer = "smtp.yourdomain.com"
)

$ErrorActionPreference = "Stop"

function Connect-vCenter {
    param([string]$Server)
    
    Write-Output "Connecting to vCenter: $Server"
    try {
        $conn = Connect-VIServer -Server $Server -ErrorAction Stop
        Write-Output "Connected to vCenter: $($conn.Name)"
        return $conn
    } catch {
        Write-Error "Failed to connect to vCenter: $_"
        throw
    }
}

function Get-ZombieVMs {
    param(
        [string[]]$DatastorePatterns,
        [int]$DaysThreshold
    )
    
    Write-Output "Scanning for zombie VMs..."
    
    $targetDatastores = @()
    foreach ($pattern in $DatastorePatterns) {
        $ds = Get-Datastore | Where-Object { $_.Name -like $pattern }
        if ($ds) {
            $targetDatastores += $ds
            Write-Output "Found datastore matching '$pattern': $($ds.Name)"
        }
    }
    
    if (-not $targetDatastores) {
        Write-Warning "No datastores found matching patterns: $($DatastorePatterns -join ', ')"
        return @()
    }
    
    $zombieVMs = @()
    $cutoffDate = (Get-Date).AddDays(-$DaysThreshold)
    
    foreach ($datastore in $targetDatastores) {
        Write-Output "Checking datastore: $($datastore.Name)"
        
        $vms = Get-VM -Datastore $datastore -ErrorAction SilentlyContinue
        
        foreach ($vm in $vms) {
            if ($vm.PowerState -eq "PoweredOn") {
                $vmNotes = $vm.Notes
                $lastActivity = if ($vm.Notes -match "Last activity: (\d{4}-\d{2}-\d{2})") {
                    [DateTime]::ParseExact($matches[1], "yyyy-MM-dd", $null)
                } else {
                    $vm.ExtensionData.Runtime.BootTime
                }
                
                $isOlderThanThreshold = if ($lastActivity) {
                    $lastActivity -lt $cutoffDate
                } else {
                    $false
                }
                
                $zombieVMs += [PSCustomObject]@{
                    VMName = $vm.Name
                    Datastore = $datastore.Name
                    PowerState = $vm.PowerState
                    GuestOS = $vm.Guest.OSFullName
                    IPAddress = $vm.Guest.IPAddress[0]
                    LastActivity = $lastActivity
                    IsOlderThanThreshold = $isOlderThanThreshold
                    VMHost = $vm.VMHost.Name
                    Cluster = $vm.VMHost.Parent.Name
                    Notes = $vmNotes
                }
            }
        }
    }
    
    return $zombieVMs
}

function Export-ZombieVMReport {
    param(
        [array]$ZombieVMs,
        [string]$OutputPath
    )
    
    if ($ZombieVMs.Count -eq 0) {
        Write-Output "No zombie VMs found."
        return
    }
    
    $outputDir = Split-Path -Parent $OutputPath
    if (!(Test-Path $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }
    
    $ZombieVMs | Export-Csv -Path $OutputPath -NoTypeInformation -Force
    Write-Output "Report exported to: $OutputPath"
}

function Invoke-ZombieVMAction {
    param(
        [array]$ZombieVMs,
        [int]$DaysThreshold
    )
    
    if (-not $PowerOffVMs) {
        return
    }
    
    $vmsToPowerOff = $ZombieVMs | Where-Object { $_.IsOlderThanThreshold }
    
    if ($vmsToPowerOff.Count -eq 0) {
        Write-Output "No VMs meet the $DaysThreshold day threshold for auto-power-off."
        return
    }
    
    Write-Warning "Preparing to power off $($vmsToPowerOff.Count) VMs..."
    
    foreach ($vm in $vmsToPowerOff) {
        Write-Warning "Powering off VM: $($vm.VMName)"
        try {
            Stop-VM -VM $vm.VMName -Confirm:$false -RunAsync | Out-Null
            Write-Output "Initiated shutdown for VM: $($vm.VMName)"
        } catch {
            Write-Error "Failed to power off VM $($vm.VMName): $_"
        }
    }
}

function Send-ZombieVMReportEmail {
    param(
        [array]$ZombieVMs,
        [string]$SmtpServer,
        [string]$EmailFrom,
        [string]$EmailTo
    )
    
    $subject = "Zombie VM Audit Report - $($ZombieVMs.Count) VMs Found"
    
    $body = "Zombie VM Audit Report`n"
    $body += "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n"
    $body += "vCenter: $VCenterServer`n"
    $body += "=" * 50 + "`n`n"
    
    if ($ZombieVMs.Count -eq 0) {
        $body += "No zombie VMs found. Good job!`n"
    } else {
        $body += "Found $($ZombieVMs.Count) VMs running on decommissioned datastores:`n`n"
        
        foreach ($vm in $ZombieVMs) {
            $body += "VM: $($vm.VMName)`n"
            $body += "  Datastore: $($vm.Datastore)`n"
            $body += "  VMHost: $($vm.VMHost)`n"
            $body += "  Cluster: $($vm.Cluster)`n"
            $body += "  IP: $($vm.IPAddress)`n"
            $body += "  Guest OS: $($vm.GuestOS)`n"
            if ($vm.LastActivity) {
                $body += "  Last Activity: $($vm.LastActivity)`n"
            }
            if ($vm.IsOlderThanThreshold) {
                $body += "  [!] OLDER THAN $DaysThreshold DAYS - Candidate for power-off`n"
            }
            $body += "`n"
        }
        
        if ($PowerOffVMs) {
            $body += "`n[!] Auto-power-off is ENABLED. VMs older than $DaysThreshold days will be powered off.`n"
        }
    }
    
    try {
        Send-MailMessage -From $EmailFrom -To $EmailTo -Subject $subject -Body $body -SmtpServer $SmtpServer
        Write-Output "Email report sent to: $EmailTo"
    } catch {
        Write-Error "Failed to send email: $_"
    }
}

$vCenterConnection = $null

try {
    $vCenterConnection = Connect-vCenter -Server $VCenterServer
    
    $zombieVMs = Get-ZombieVMs -DatastorePatterns $DatastorePatterns -DaysThreshold $DaysThreshold
    
    if ($zombieVMs.Count -gt 0) {
        Export-ZombieVMReport -ZombieVMs $zombieVMs -OutputPath $OutputPath
    }
    
    Invoke-ZombieVMAction -ZombieVMs $zombieVMs -DaysThreshold $DaysThreshold
    
    if ($SendEmail) {
        Send-ZombieVMReportEmail -ZombieVMs $zombieVMs -SmtpServer $SmtpServer -EmailFrom $EmailFrom -EmailTo $EmailTo
    }
    
    Write-Output "`nAudit complete. Found $($zombieVMs.Count) zombie VM(s)."
    
    return $zombieVMs
    
} finally {
    if ($vCenterConnection) {
        Disconnect-VIServer -Server $vCenterConnection -Confirm:$false
        Write-Output "Disconnected from vCenter"
    }
}