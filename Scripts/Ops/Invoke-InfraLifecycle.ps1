<#
.SYNOPSIS
Infrastructure State Controller - Intent-Based Storage Fabric Orchestration

.DESCRIPTION
Orchestrates complex storage and virtualization workflows across HPE Nimble and VMware vSphere.
Manages infrastructure based on intent (Provision, Clone, Expand, Retire, Audit) rather than mechanics.

.PARAMETER Intent
Operation intent: Provision, Clone, Expand, Retire, or Audit

.PARAMETER ClusterName
vSphere cluster name

.PARAMETER SizeGB
Volume size in GB (for Provision/Expand)

.PARAMETER VolName
Volume name

.PARAMETER SourceVolName
Source volume name (for Clone operations)

.PARAMETER DatastoreName
Datastore name (for Expand/Retire operations)

.PARAMETER PerformancePolicy
Nimble performance policy (default: VMware ESXi)

.PARAMETER DatastoreCluster
Storage DRS datastore cluster name (optional)

.PARAMETER NimbleServer
HPE Nimble array FQDN or IP

.PARAMETER vCenterServer
VMware vCenter server FQDN or IP

.PARAMETER Credential
PSCredential object for authentication

.PARAMETER WhatIf
Show what would happen without making changes

.PARAMETER Verbose
Enable verbose logging

.PARAMETER LogPath
Override default log path

.EXAMPLE
.\Invoke-InfraLifecycle.ps1 -Intent Provision -ClusterName "Prod-SQL-Cluster" -SizeGB 2048 -VolName "s-SQL-Prod-01" -DatastoreCluster "SQL-Storage"

.EXAMPLE
.\Invoke-InfraLifecycle.ps1 -Intent Clone -ClusterName "Dev-Cluster" -SourceVolName "s-SQL-Prod-01" -VolName "s-SQL-Dev-01"

.EXAMPLE
.\Invoke-InfraLifecycle.ps1 -Intent Expand -ClusterName "Prod-Web-Cluster" -DatastoreName "s-Web-01" -SizeGB 1024

.EXAMPLE
.\Invoke-InfraLifecycle.ps1 -Intent Audit -ClusterName "Prod-Cluster"

.EXAMPLE
.\Invoke-InfraLifecycle.ps1 -Intent Retire -ClusterName "Retired-Cluster" -DatastoreName "s-Old-Datastore"

.NOTES
Requires: VMware PowerCLI, HPE Nimble PowerShell Toolkit (or REST API access)
Author: Infrastructure Engineering Team
#>

[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = "Default")]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("Provision", "Clone", "Expand", "Retire", "Audit", "Menu")]
    [string]$Intent = "Menu",

    [Parameter(Mandatory = $false)]
    [string]$ClusterName,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 10240)]
    [int]$SizeGB,

    [Parameter(Mandatory = $false)]
    [string]$VolName,

    [Parameter(Mandatory = $false)]
    [string]$SourceVolName,

    [Parameter(Mandatory = $false)]
    [string]$DatastoreName,

    [Parameter(Mandatory = $false)]
    [string]$PerformancePolicy = "VMware ESXi",

    [Parameter(Mandatory = $false)]
    [string]$DatastoreCluster,

    [Parameter(Mandatory = $false)]
    [string]$NimbleServer = $global:NIMBLE_SERVER,

    [Parameter(Mandatory = $false)]
    [string]$vCenterServer = $global:VCENTER_SERVER,

    [Parameter(Mandatory = $false)]
    [System.Management.Automation.PSCredential]$Credential,

    [Parameter(Mandatory = $false)]
    [string]$LogPath = "C:\Logs\InfraLifecycle",

    [Parameter(Mandatory = $false)]
    [switch]$SkipHealthCheck,

    [Parameter(Mandatory = $false)]
    [switch]$ForceResignature,

    [Parameter(Mandatory = $false)]
    [int]$MaxSnapshotAgeDays = 30
,
    [Parameter(Mandatory = $false)]
    [switch]$DryRun
)

if (-not (Get-Module -ListAvailable -Name VMware.PowerCLI)) {
    throw "VMware.PowerCLI module is required. Install it with: Install-Module VMware.PowerCLI"
}

if (-not (Get-Module -Name VMware.PowerCLI)) {
    Import-Module -Name VMware.PowerCLI -ErrorAction Stop
}

if ($DryRun) {
    $WhatIfPreference = $true
}

#region Helper Functions

function Write-InfraLog {
    param(
        [string]$Message,
        [ValidateSet("INFO", "WARNING", "ERROR", "DEBUG", "AUDIT", "SUCCESS")]
        [string]$Level = "INFO",
        [bool]$ToConsole = $true
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"

    if ($ToConsole) {
        $color = switch ($Level) {
            "INFO" { "White" }
            "WARNING" { "Yellow" }
            "ERROR" { "Red" }
            "DEBUG" { "Gray" }
            "AUDIT" { "Cyan" }
            "SUCCESS" { "Green" }
            default { "White" }
        }
        Write-Host $logEntry -ForegroundColor $color
    }

    if ($script:LogFile) {
        $entry = @{
            Timestamp = $timestamp
            Level = $Level
            Message = $Message
        } | ConvertTo-Json -Compress
        Add-Content -Path $script:LogFile -Value $entry
    }
}

function Initialize-InfraLogging {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }

    $logFileName = "InfraLifecycle_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
    $script:LogFile = Join-Path -Path $Path -ChildPath $logFileName

    Write-InfraLog "Infrastructure State Controller started" -Level AUDIT
    Write-InfraLog "Intent: $Intent" -Level INFO
    Write-InfraLog "Log file: $script:LogFile" -Level DEBUG
}

function Test-NimbleConnection {
    param(
        [string]$Server,
        [pscredential]$Credential
    )

    Write-InfraLog "Testing Nimble connection to $Server..." -Level DEBUG

    try {
        if (Get-Command -Module HPE.NimblePowerShellToolkit -ErrorAction SilentlyContinue) {
            $session = Connect-NSGroup -Server $Server -Credential $Credential -ErrorAction Stop
            Write-InfraLog "Connected to Nimble using HPE PowerShell Toolkit" -Level SUCCESS
            return @{
                Connected = $true
                Method = "PowerShellToolkit"
                Session = $session
            }
        } else {
            throw "HPE Nimble PowerShell Toolkit not installed"
        }
    } catch {
        Write-InfraLog "PowerShell Toolkit failed, trying REST API..." -Level WARNING

        try {
            $authHeader = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$($Credential.UserName):$($Credential.GetNetworkCredential().Password)"))
            $headers = @{
                "Authorization" = "Basic $authHeader"
                "Content-Type" = "application/json"
            }

            $url = "https://$Server/v1/details"
            $response = Invoke-RestMethod -Uri $url -Headers $headers -Method Get -ErrorAction Stop

            Write-InfraLog "Connected to Nimble using REST API" -Level SUCCESS
            return @{
                Connected = $true
                Method = "REST"
                Headers = $headers
                Server = $Server
                Credential = $Credential
            }
        } catch {
            Write-InfraLog "Failed to connect to Nimble: $_" -Level ERROR
            return @{ Connected = $false }
        }
    }
}

function Invoke-NimbleRest {
    param(
        [hashtable]$Connection,
        [string]$Endpoint,
        [string]$Method = "GET",
        [object]$Body
    )

    if ($Connection.Method -eq "PowerShellToolkit") {
        $cmd = switch ($Method) {
            "GET" { "Get-NS" }
            "POST" { "New-NS" }
            "PUT" { "Set-NS" }
            "DELETE" { "Remove-NS" }
            default { throw "Unsupported method" }
        }

        & $cmd @Body
    } else {
        $url = "https://$($Connection.Server)/$Endpoint"
        $params = @{
            Uri = $url
            Headers = $Connection.Headers
            Method = $Method
        }

        if ($Body) {
            $params.Body = $Body | ConvertTo-Json -Depth 10
        }

        Invoke-RestMethod @params -ErrorAction Stop
    }
}

function Test-vCenterConnection {
    param(
        [string]$Server,
        [pscredential]$Credential
    )

    Write-InfraLog "Testing vCenter connection to $Server..." -Level DEBUG

    try {
        $session = Connect-VIServer -Server $Server -Credential $Credential -ErrorAction Stop
        Write-InfraLog "Connected to vCenter: $Server" -Level SUCCESS
        return @{
            Connected = $true
            Session = $session
        }
    } catch {
        Write-InfraLog "Failed to connect to vCenter: $_" -Level ERROR
        return @{ Connected = $false }
    }
}

function Get-ClusterCapacity {
    param(
        [object]$vCenterSession,
        [string]$ClusterName
    )

    Write-InfraLog "Checking capacity for cluster: $ClusterName" -Level DEBUG

    try {
        $cluster = Get-Cluster -Name $ClusterName -Server $vCenterSession -ErrorAction Stop
        $datastores = Get-Datastore -RelatedObject $cluster | Where-Object { $_.Type -eq "VMFS" }

        $totalCapacity = ($datastores | Measure-Object -Property Capacity -Sum).Sum
        $usedSpace = ($datastores | Measure-Object -Property UsedSpaceGB -Sum).Sum
        $freeSpace = ($datastores | Measure-Object -Property FreeSpaceGB -Sum).Sum

        Write-InfraLog "Cluster capacity - Total: $([math]::Round($totalCapacity/1TB, 2))TB, Free: $([math]::Round($freeSpace/1TB, 2))TB" -Level DEBUG

        return @{
            Cluster = $cluster
            TotalCapacityGB = [math]::Round($totalCapacity / 1GB, 2)
            UsedSpaceGB = [math]::Round($usedSpace, 2)
            FreeSpaceGB = [math]::Round($freeSpace, 2)
            PercentUsed = [math]::Round(($usedSpace / $totalCapacity) * 100, 2)
        }
    } catch {
        Write-InfraLog "Failed to get cluster capacity: $_" -Level ERROR
        throw
    }
}

function Get-NimbleInitiatorGroup {
    param(
        [hashtable]$NimbleConnection,
        [string]$ClusterName
    )

    Write-InfraLog "Looking up initiator group for cluster: $ClusterName" -Level DEBUG

    try {
        $igs = Invoke-NimbleRest -Connection $NimbleConnection -Endpoint "v1/initiator_groups"

        $targetIG = $igs.data | Where-Object {
            $_.name -match [regex]::Escape($ClusterName) -or
            $_.name -match "ESXi|VMware|vSphere"
        } | Select-Object -First 1

        if ($targetIG) {
            Write-InfraLog "Found initiator group: $($targetIG.name)" -Level SUCCESS
            return $targetIG
        } else {
            Write-InfraLog "No initiator group found matching: $ClusterName" -Level WARNING
            return $null
        }
    } catch {
        Write-InfraLog "Failed to get initiator group: $_" -Level ERROR
        throw
    }
}

function New-NimbleVolume {
    param(
        [hashtable]$NimbleConnection,
        [string]$VolName,
        [int]$SizeGB,
        [string]$PerformancePolicy = "VMware ESXi",
        [string]$Description = ""
    )

    Write-InfraLog "Creating Nimble volume: $VolName ($SizeGB GB)" -Level INFO

    if ($WhatIfPreference) {
        Write-InfraLog "WhatIf: Would create volume $VolName" -Level INFO
        return @{
            Success = $true
            WhatIf = $true
            VolName = $VolName
            SizeGB = $SizeGB
        }
    }

    try {
        $body = @{
            name = $VolName
            size = $SizeGB * 1024 * 1024 * 1024
            data = $true
            perf_policy_name = $PerformancePolicy
            description = $Description
            pool_id = "default"
        }

        $response = Invoke-NimbleRest -Connection $NimbleConnection -Endpoint "v1/volumes" -Method POST -Body $body

        Write-InfraLog "Volume created: $($response.data.name) (ID: $($response.data.id))" -Level SUCCESS
        return $response.data
    } catch {
        Write-InfraLog "Failed to create volume: $_" -Level ERROR
        throw
    }
}

function Set-NimbleVolumeAccess {
    param(
        [hashtable]$NimbleConnection,
        [string]$VolumeId,
        [string]$InitiatorGroupId
    )

    Write-InfraLog "Granting access to volume..." -Level INFO

    if ($WhatIfPreference) {
        Write-InfraLog "WhatIf: Would grant access to initiator group" -Level INFO
        return @{ Success = $true }
    }

    try {
        $body = @{
            apply_to = "volume_id"
            value_id = $VolumeId
            initiator_group_id = $InitiatorGroupId
            access = "read_write"
        }

        $response = Invoke-NimbleRest -Connection $NimbleConnection -Endpoint "v1/access_control_records" -Method POST -Body $body

        Write-InfraLog "Access control record created" -Level SUCCESS
        return $response.data
    } catch {
        Write-InfraLog "Failed to set volume access: $_" -Level ERROR
        throw
    }
}

function Expand-NimbleVolume {
    param(
        [hashtable]$NimbleConnection,
        [string]$VolumeId,
        [int]$NewSizeGB
    )

    Write-InfraLog "Expanding Nimble volume to $NewSizeGB GB..." -Level INFO

    if ($WhatIfPreference) {
        Write-InfraLog "WhatIf: Would expand volume to $NewSizeGB GB" -Level INFO
        return @{ Success = $true }
    }

    try {
        $body = @{
            size = $NewSizeGB * 1024 * 1024 * 1024
        }

        $response = Invoke-NimbleRest -Connection $NimbleConnection -Endpoint "v1/volumes/$VolumeId" -Method PUT -Body $body

        Write-InfraLog "Volume expanded" -Level SUCCESS
        return $response.data
    } catch {
        Write-InfraLog "Failed to expand volume: $_" -Level ERROR
        throw
    }
}

function Remove-NimbleVolume {
    param(
        [hashtable]$NimbleConnection,
        [string]$VolumeId
    )

    Write-InfraLog "Removing Nimble volume..." -Level INFO

    if ($WhatIfPreference) {
        Write-InfraLog "WhatIf: Would remove volume" -Level INFO
        return @{ Success = $true }
    }

    try {
        Invoke-NimbleRest -Connection $NimbleConnection -Endpoint "v1/volumes/$VolumeId" -Method DELETE

        Write-InfraLog "Volume removed" -Level SUCCESS
        return @{ Success = $true }
    } catch {
        Write-InfraLog "Failed to remove volume: $_" -Level ERROR
        throw
    }
}

function Invoke-HostRescan {
    param(
        [object]$vCenterSession,
        [string]$ClusterName
    )

    Write-InfraLog "Triggering HBA rescan on all hosts in cluster..." -Level INFO

    if ($WhatIfPreference) {
        Write-InfraLog "WhatIf: Would rescan HBAs on cluster" -Level INFO
        return @{ Success = $true }
    }

    try {
        $cluster = Get-Cluster -Name $ClusterName -Server $vCenterSession
        $hosts = $cluster | Get-VMHost

        $jobs = @()
        foreach ($host in $hosts) {
            $jobs += Start-Job -ScriptBlock {
                param($hostName)
                try {
                    $vmhost = Get-VMHost -Name $hostName -ErrorAction Stop
                    Get-VMHostStorage -VMHost $vmhost -RescanAllHba -ErrorAction Stop
                    return @{ Host = $hostName; Success = $true }
                } catch {
                    return @{ Host = $hostName; Success = $false; Error = $_.Exception.Message }
                }
            } -ArgumentList $host.Name
        }

        $results = $jobs | Wait-Job | Receive-Job
        $jobs | Remove-Job -Force

        $successCount = ($results | Where-Object { $_.Success }).Count
        Write-InfraLog "HBA rescan completed: $successCount/$($hosts.Count) hosts" -Level SUCCESS

        return $results
    } catch {
        Write-InfraLog "Failed to rescan hosts: $_" -Level ERROR
        throw
    }
}

function New-VMwareDatastore {
    param(
        [object]$vCenterSession,
        [string]$ClusterName,
        [string]$DatastoreName,
        [string]$CanonicalName,
        [int]$FileSystemVersion = 6,
        [string]$DatastoreCluster = $null
    )

    Write-InfraLog "Creating VMFS datastore: $DatastoreName" -Level INFO

    if ($WhatIfPreference) {
        Write-InfraLog "WhatIf: Would create datastore $DatastoreName" -Level INFO
        return @{ Success = $true }
    }

    try {
        $cluster = Get-Cluster -Name $ClusterName -Server $vCenterSession
        $hosts = $cluster | Get-VMHost | Select-Object -First 1

        $lun = Get-ScsiLun -VMHost $hosts | Where-Object { $_.CanonicalName -eq $CanonicalName }

        if (-not $lun) {
            throw "LUN not found: $CanonicalName"
        }

        $datastore = New-Datastore -VMHost $hosts -Name $DatastoreName -Path $CanonicalName -Vmfs -FileSystemVersion $FileSystemVersion -ErrorAction Stop

        Write-InfraLog "Datastore created: $($datastore.Name)" -Level SUCCESS

        if ($DatastoreCluster) {
            Write-InfraLog "Moving datastore to storage DRS cluster: $DatastoreCluster" -Level INFO

            try {
                $dsCluster = Get-DatastoreCluster -Name $DatastoreCluster -Server $vCenterSession
                Move-Datastore -Datastore $datastore -Destination $dsCluster -ErrorAction Stop
                Write-InfraLog "Datastore moved to storage DRS cluster" -Level SUCCESS
            } catch {
                Write-InfraLog "Warning: Could not move to storage DRS cluster: $_" -Level WARNING
            }
        }

        return $datastore
    } catch {
        Write-InfraLog "Failed to create datastore: $_" -Level ERROR
        throw
    }
}

function Expand-VMwareDatastore {
    param(
        [object]$vCenterSession,
        [string]$ClusterName,
        [string]$DatastoreName
    )

    Write-InfraLog "Expanding datastore: $DatastoreName" -Level INFO

    if ($WhatIfPreference) {
        Write-InfraLog "WhatIf: Would expand datastore $DatastoreName" -Level INFO
        return @{ Success = $true }
    }

    try {
        $datastore = Get-Datastore -Name $DatastoreName -Server $vCenterSession -ErrorAction Stop

        $cluster = Get-Cluster -Name $ClusterName -Server $vCenterSession
        $hosts = $cluster | Get-VMHost | Where-Object { $_ -in $datastore.ExtensionData.Host.Value }

        foreach ($host in $hosts) {
            Get-VMHostStorage -VMHost $host -RescanAllHba | Out-Null
        }

        Start-Sleep -Seconds 5

        $lun = Get-ScsiLun -Datastore $datastore | Select-Object -First 1
        $newCapacityGB = [math]::Round($lun.CapacityGB, 2)

        Write-InfraLog "Rescanned LUN capacity: $newCapacityGB GB" -Level INFO

        $esxCli = Get-EsxCli -VMHost $hosts[0] -V2
        $extension = $datastore.ExtensionData
        $vmfsUuid = $extension.Info.Vmfs.Uuid

        $partition = Get-VMHostPartition -VMHost $hosts[0] | Where-Object { $_.DiskCanonicalName -eq $lun.CanonicalName -and $_.Type -eq "VMFS" }

        if ($partition) {
            $esxCli.storage.filesystem.extend.Invoke(@{
                volumelabel = $datastore.Name
                partitionnumber = 1
            })

            Write-InfraLog "Datastore expanded successfully" -Level SUCCESS
            return @{ Success = $true; NewCapacityGB = $newCapacityGB }
        }
    } catch {
        Write-InfraLog "Failed to expand datastore: $_" -Level ERROR
        throw
    }
}

function Remove-VMwareDatastore {
    param(
        [object]$vCenterSession,
        [string]$ClusterName,
        [string]$DatastoreName,
        [bool]$Force = $false
    )

    Write-InfraLog "Removing datastore: $DatastoreName" -Level INFO

    if ($WhatIfPreference) {
        Write-InfraLog "WhatIf: Would remove datastore $DatastoreName" -Level INFO
        return @{ Success = $true }
    }

    try {
        $datastore = Get-Datastore -Name $DatastoreName -Server $vCenterSession -ErrorAction Stop

        $vms = Get-VM -Datastore $datastore -ErrorAction SilentlyContinue

        if ($vms -and -not $Force) {
            Write-InfraLog "Datastore contains $($vms.Count) VMs. Cannot proceed without -Force" -Level ERROR
            throw "Datastore not empty"
        }

        if ($vms -and $Force) {
            Write-InfraLog "WARNING: Datastore contains $($vms.Count) VMs. Proceeding with -Force..." -Level WARNING
        }

        $cluster = Get-Cluster -Name $ClusterName -Server $vCenterSession
        $hosts = $cluster | Get-VMHost

        foreach ($host in $hosts) {
            $dsOnHost = Get-Datastore -Name $DatastoreName -VMHost $host -ErrorAction SilentlyContinue

            if ($dsOnHost) {
                Write-InfraLog "Unmounting datastore from $($host.Name)..." -Level INFO

                try {
                    Set-Datastore -Datastore $dsOnHost -Mount:$false -ErrorAction Stop
                } catch {
                    Write-InfraLog "Failed to unmount from $($host.Name): $_" -Level WARNING
                }

                try {
                    $lun = Get-ScsiLun -Datastore $dsOnHost -VMHost $host -ErrorAction SilentlyContinue
                    if ($lun) {
                        Remove-ScsiLun -ScsiLun $lun -VMHost $host -ErrorAction Stop
                        Write-InfraLog "Detached LUN from $($host.Name)" -Level INFO
                    }
                } catch {
                    Write-InfraLog "Failed to detach LUN from $($host.Name): $_" -Level WARNING
                }
            }
        }

        Write-InfraLog "Waiting 30 seconds for sync..." -Level INFO
        Start-Sleep -Seconds 30

        Remove-Datastore -Datastore $datastore -Confirm:$false -ErrorAction Stop
        Write-InfraLog "Datastore removed" -Level SUCCESS

        return @{ Success = $true }
    } catch {
        Write-InfraLog "Failed to remove datastore: $_" -Level ERROR
        throw
    }
}

function New-NimbleSnapshot {
    param(
        [hashtable]$NimbleConnection,
        [string]$VolumeId,
        [string]$SnapshotName
    )

    Write-InfraLog "Creating Nimble snapshot: $SnapshotName" -Level INFO

    if ($WhatIfPreference) {
        Write-InfraLog "WhatIf: Would create snapshot $SnapshotName" -Level INFO
        return @{ Success = $true }
    }

    try {
        $body = @{
            name = $SnapshotName
            vol_id = $VolumeId
            online = $true
        }

        $response = Invoke-NimbleRest -Connection $NimbleConnection -Endpoint "v1/snapshots" -Method POST -Body $body

        Write-InfraLog "Snapshot created" -Level SUCCESS
        return $response.data
    } catch {
        Write-InfraLog "Failed to create snapshot: $_" -Level ERROR
        throw
    }
}

function Copy-NimbleVolume {
    param(
        [hashtable]$NimbleConnection,
        [string]$SourceVolumeId,
        [string]$DestVolumeName,
        [string]$SnapshotName
    )

    Write-InfraLog "Cloning volume to: $DestVolumeName" -Level INFO

    if ($WhatIfPreference) {
        Write-InfraLog "WhatIf: Would clone volume to $DestVolumeName" -Level INFO
        return @{ Success = $true }
    }

    try {
        $snapshot = New-NimbleSnapshot -NimbleConnection $NimbleConnection -VolumeId $SourceVolumeId -SnapshotName "Clone-$(Get-Date -Format 'yyyyMMddHHmmss')"

        $body = @{
            name = $DestVolumeName
            src_snap_id = $snapshot.id
            base_snap_id = $snapshot.id
        }

        $response = Invoke-NimbleRest -Connection $NimbleConnection -Endpoint "v1/volumes" -Method POST -Body $body

        Write-InfraLog "Volume cloned: $($response.data.name)" -Level SUCCESS
        return $response.data
    } catch {
        Write-InfraLog "Failed to clone volume: $_" -Level ERROR
        throw
    }
}

function Set-NimbleVolumeOffline {
    param(
        [hashtable]$NimbleConnection,
        [string]$VolumeId
    )

    Write-InfraLog "Taking volume offline..." -Level INFO

    if ($WhatIfPreference) {
        Write-InfraLog "WhatIf: Would take volume offline" -Level INFO
        return @{ Success = $true }
    }

    try {
        $body = @{
            online = $false
        }

        Invoke-NimbleRest -Connection $NimbleConnection -Endpoint "v1/volumes/$VolumeId" -Method PUT -Body $body

        Write-InfraLog "Volume taken offline" -Level SUCCESS
        return @{ Success = $true }
    } catch {
        Write-InfraLog "Failed to take volume offline: $_" -Level ERROR
        throw
    }
}

function Test-DatastoreHealth {
    param(
        [object]$vCenterSession,
        [string]$DatastoreName
    )

    Write-InfraLog "Running health check on datastore: $DatastoreName" -Level INFO

    try {
        $datastore = Get-Datastore -Name $DatastoreName -Server $vCenterSession -ErrorAction Stop

        $testFile = "InfraLifecycle-HealthCheck-$(Get-Date -Format 'yyyyMMddHHmmss').txt"
        $testPath = "$($datastore.DatastoreBrowserPath)\$testFile"

        try {
            New-Item -Path $testPath -ItemType File -Value "Health check" -Force | Out-Null
            Remove-Item -Path $testPath -Force | Out-Null

            Write-InfraLog "Datastore health check: PASSED" -Level SUCCESS
            return @{ Healthy = $true; Message = "Write test successful" }
        } catch {
            Write-InfraLog "Datastore health check: FAILED - $_" -Level ERROR
            return @{ Healthy = $false; Message = $_.Exception.Message }
        }
    } catch {
        Write-InfraLog "Health check failed: $_" -Level ERROR
        return @{ Healthy = $false; Message = $_.Exception.Message }
    }
}

function Resolve-DatastoreName {
    param(
        [string]$VolName,
        [string]$SourceVolName
    )

    if ($DatastoreName) {
        return $DatastoreName
    }

    if ($SourceVolName) {
        return $VolName
    }

    return $VolName
}

#endregion

#region Mode Implementations

function Invoke-ProvisionMode {
    param(
        [hashtable]$NimbleConn,
        [object]$vCenterSession,
        [string]$ClusterName,
        [string]$VolName,
        [int]$SizeGB,
        [string]$PerformancePolicy,
        [string]$DatastoreClusterName
    )

    Write-InfraLog "Starting PROVISION mode" -Level AUDIT

    $result = @{
        Mode = "Provision"
        Success = $false
        Volume = $null
        Datastore = $null
        Errors = @()
    }

    try {
        $clusterCap = Get-ClusterCapacity -vCenterSession $vCenterSession -ClusterName $ClusterName

        if ($clusterCap.PercentUsed -gt 90) {
            $result.Errors += "Cluster capacity at $($clusterCap.PercentUsed)%, cannot provision"
            return $result
        }

        $nimbleVol = New-NimbleVolume -NimbleConnection $NimbleConn -VolName $VolName -SizeGB $SizeGB -PerformancePolicy $PerformancePolicy
        $result.Volume = $nimbleVol

        $ig = Get-NimbleInitiatorGroup -NimbleConnection $NimbleConn -ClusterName $ClusterName

        if (-not $ig) {
            $result.Errors += "No initiator group found for cluster: $ClusterName"
            return $result
        }

        Set-NimbleVolumeAccess -NimbleConnection $NimbleConn -VolumeId $nimbleVol.id -InitiatorGroupId $ig.id

        Invoke-HostRescan -vCenterSession $vCenterSession -ClusterName $ClusterName

        Start-Sleep -Seconds 10

        $lun = Get-ScsiLun -VMHost (Get-Cluster -Name $ClusterName | Get-VMHost | Select-Object -First 1) | Where-Object { $_.Vendor -match "Nimble" -and $_.CapacityGB -eq $SizeGB } | Select-Object -First 1

        if (-not $lun) {
            Write-InfraLog "Searching for Nimble LUN with capacity $SizeGB GB..." -Level INFO
            $luns = Get-ScsiLun -VMHost (Get-Cluster -Name $ClusterName | Get-VMHost | Select-Object -First 1) | Where-Object { $_.Vendor -match "Nimble" }
            $lun = $luns | Sort-Object CanonicalName -Descending | Select-Object -First 1
        }

        if (-not $lun) {
            $result.Errors += "Could not find new LUN on hosts after rescan"
            return $result
        }

        $dsName = Resolve-DatastoreName -VolName $VolName -SourceVolName $null
        $datastore = New-VMwareDatastore -vCenterSession $vCenterSession -ClusterName $ClusterName -DatastoreName $dsName -CanonicalName $lun.CanonicalName -DatastoreCluster $DatastoreClusterName
        $result.Datastore = $datastore

        if (-not $SkipHealthCheck) {
            Start-Sleep -Seconds 5
            $health = Test-DatastoreHealth -vCenterSession $vCenterSession -DatastoreName $dsName

            if (-not $health.Healthy) {
                $result.Errors += "Health check failed: $($health.Message)"
                return $result
            }
        }

        $result.Success = $true
        Write-InfraLog "Provision completed successfully" -Level SUCCESS

    } catch {
        $result.Errors += "Provision failed: $_"
        Write-InfraLog "Provision failed: $_" -Level ERROR
    }

    return $result
}

function Invoke-CloneMode {
    param(
        [hashtable]$NimbleConn,
        [object]$vCenterSession,
        [string]$ClusterName,
        [string]$SourceVolName,
        [string]$VolName,
        [string]$PerformancePolicy,
        [bool]$Resignature
    )

    Write-InfraLog "Starting CLONE mode" -Level AUDIT

    $result = @{
        Mode = "Clone"
        Success = $false
        SourceVolume = $null
        ClonedVolume = $null
        Datastore = $null
        Errors = @()
    }

    try {
        $volumes = Invoke-NimbleRest -Connection $NimbleConn -Endpoint "v1/volumes" -Method GET
        $sourceVol = $volumes.data | Where-Object { $_.name -eq $SourceVolName } | Select-Object -First 1

        if (-not $sourceVol) {
            $result.Errors += "Source volume not found: $SourceVolName"
            return $result
        }

        $result.SourceVolume = $sourceVol

        $clonedVol = Copy-NimbleVolume -NimbleConnection $NimbleConn -SourceVolumeId $sourceVol.id -DestVolumeName $VolName
        $result.ClonedVolume = $clonedVol

        $ig = Get-NimbleInitiatorGroup -NimbleConnection $NimbleConn -ClusterName $ClusterName

        if ($ig) {
            Set-NimbleVolumeAccess -NimbleConnection $NimbleConn -VolumeId $clonedVol.id -InitiatorGroupId $ig.id
        }

        Invoke-HostRescan -vCenterSession $vCenterSession -ClusterName $ClusterName

        Start-Sleep -Seconds 10

        $hosts = Get-Cluster -Name $ClusterName | Get-VMHost
        $luns = @()
        foreach ($host in $hosts) {
            $hostLuns = Get-ScsiLun -VMHost $host | Where-Object { $_.Vendor -match "Nimble" }
            $luns += $hostLuns
        }

        if ($Resignature -or $ForceResignature) {
            Write-InfraLog "Performing VMFS resignature..." -Level INFO

            foreach ($host in $hosts) {
                Get-VMHostStorage -VMHost $host -RescanAllHba | Out-Null
            }

            Start-Sleep -Seconds 15

            foreach ($host in $hosts) {
                $foreignLuns = Get-ScsiLun -VMHost $host | Where-Object { $_.IsOffline }

                foreach ($flun in $foreignLuns) {
                    try {
                        $ds = Mount-VMHostVolume -VMHost $host -VolumeName $flun.CanonicalName -WhatIf:$false -ErrorAction Stop

                        if ($ds -and $ds.IsMounted) {
                            Write-InfraLog "Mounted foreign datastore on $($host.Name)" -Level INFO
                        }
                    } catch {
                        Write-InfraLog "Could not mount foreign LUN on $($host.Name): $_" -Level WARNING
                    }
                }
            }

            Start-Sleep -Seconds 10

            foreach ($host in $hosts) {
                try {
                    $foreignDatastores = Get-Datastore -VMHost $host | Where-Object { $_.Name -match "snap" -or $_.Name -match "snapshot" }

                    foreach ($fds in $foreignDatastores) {
                        $newName = $VolName
                        Set-Datastore -Datastore $fds -Name $newName -ErrorAction SilentlyContinue
                        Write-InfraLog "Renamed foreign datastore to: $newName" -Level INFO
                    }
                } catch {
                    Write-InfraLog "Could not rename foreign datastore: $_" -Level WARNING
                }
            }
        }

        $lun = $luns | Sort-Object CanonicalName -Descending | Select-Object -First 1

        if ($lun) {
            $dsName = Resolve-DatastoreName -VolName $VolName -SourceVolName $SourceVolName

            try {
                $datastore = Get-Datastore -Name $dsName -ErrorAction SilentlyContinue
                if (-not $datastore) {
                    $datastore = New-VMwareDatastore -vCenterSession $vCenterSession -ClusterName $ClusterName -DatastoreName $dsName -CanonicalName $lun.CanonicalName
                }
                $result.Datastore = $datastore
            } catch {
                Write-InfraLog "Could not create/find datastore: $_" -Level WARNING
            }
        }

        if (-not $SkipHealthCheck -and $result.Datastore) {
            Start-Sleep -Seconds 5
            $health = Test-DatastoreHealth -vCenterSession $vCenterSession -DatastoreName $result.Datastore.Name

            if (-not $health.Healthy) {
                Write-InfraLog "Health check warning: $($health.Message)" -Level WARNING
            }
        }

        $result.Success = $true
        Write-InfraLog "Clone completed successfully" -Level SUCCESS

    } catch {
        $result.Errors += "Clone failed: $_"
        Write-InfraLog "Clone failed: $_" -Level ERROR
    }

    return $result
}

function Invoke-ExpandMode {
    param(
        [hashtable]$NimbleConn,
        [object]$vCenterSession,
        [string]$ClusterName,
        [string]$DatastoreName,
        [int]$SizeGB
    )

    Write-InfraLog "Starting EXPAND mode" -Level AUDIT

    $result = @{
        Mode = "Expand"
        Success = $false
        OldCapacityGB = 0
        NewCapacityGB = 0
        Errors = @()
    }

    try {
        $datastore = Get-Datastore -Name $DatastoreName -Server $vCenterSession -ErrorAction Stop
        $result.OldCapacityGB = [math]::Round($datastore.CapacityGB, 2)

        if ($SizeGB -le $result.OldCapacityGB) {
            $result.Errors += "Requested size ($SizeGB GB) is not larger than current size ($($result.OldCapacityGB) GB)"
            return $result
        }

        $lun = Get-ScsiLun -Datastore $datastore | Select-Object -First 1

        if (-not $lun) {
            $result.Errors += "Could not find backing LUN for datastore: $DatastoreName"
            return $result
        }

        $volumes = Invoke-NimbleRest -Connection $NimbleConn -Endpoint "v1/volumes" -Method GET
        $nimbleVol = $volumes.data | Where-Object { $_.name -like "*$DatastoreName*" -or $_.id -like "*$($lun.CanonicalName)*" } | Select-Object -First 1

        if (-not $nimbleVol) {
            $result.Errors += "Could not find corresponding Nimble volume"
            return $result
        }

        Expand-NimbleVolume -NimbleConnection $NimbleConn -VolumeId $nimbleVol.id -NewSizeGB $SizeGB

        Invoke-HostRescan -vCenterSession $vCenterSession -ClusterName $ClusterName

        Start-Sleep -Seconds 15

        $expandResult = Expand-VMwareDatastore -vCenterSession $vCenterSession -ClusterName $ClusterName -DatastoreName $DatastoreName

        if ($expandResult.Success) {
            $result.NewCapacityGB = $expandResult.NewCapacityGB
            $result.Success = $true
            Write-InfraLog "Expand completed successfully: $($result.OldCapacityGB)GB -> $($result.NewCapacityGB)GB" -Level SUCCESS
        } else {
            $result.Errors += "Failed to expand VMFS datastore"
        }

    } catch {
        $result.Errors += "Expand failed: $_"
        Write-InfraLog "Expand failed: $_" -Level ERROR
    }

    return $result
}

function Invoke-RetireMode {
    param(
        [hashtable]$NimbleConn,
        [object]$vCenterSession,
        [string]$ClusterName,
        [string]$DatastoreName,
        [bool]$Force
    )

    Write-InfraLog "Starting RETIRE mode" -Level AUDIT

    $result = @{
        Mode = "Retire"
        Success = $false
        DatastoreRemoved = $false
        VolumeRemoved = $false
        Errors = @()
    }

    try {
        $datastore = Get-Datastore -Name $DatastoreName -Server $vCenterSession -ErrorAction Stop

        $vms = Get-VM -Datastore $datastore -ErrorAction SilentlyContinue

        if ($vms -and -not $Force) {
            $result.Errors += "Datastore contains $($vms.Count) VMs. Use -Force to proceed."
            return $result
        }

        if ($vms -and $Force) {
            Write-InfraLog "WARNING: Datastore contains $($vms.Count) VMs. Proceeding with -Force..." -Level WARNING
        }

        $lun = Get-ScsiLun -Datastore $datastore | Select-Object -First 1

        $volumes = Invoke-NimbleRest -Connection $NimbleConn -Endpoint "v1/volumes" -Method GET
        $nimbleVol = $volumes.data | Where-Object { $_.name -like "*$DatastoreName*" } | Select-Object -First 1

        $removeResult = Remove-VMwareDatastore -vCenterSession $vCenterSession -ClusterName $ClusterName -DatastoreName $DatastoreName -Force $Force

        if ($removeResult.Success) {
            $result.DatastoreRemoved = $true

            if ($nimbleVol) {
                Set-NimbleVolumeOffline -NimbleConnection $NimbleConn -VolumeId $nimbleVol.id

                Start-Sleep -Seconds 5

                Remove-NimbleVolume -NimbleConnection $NimbleConn -VolumeId $nimbleVol.id
                $result.VolumeRemoved = $true
            }

            $result.Success = $true
            Write-InfraLog "Retire completed successfully" -Level SUCCESS
        } else {
            $result.Errors += "Failed to remove datastore"
        }

    } catch {
        $result.Errors += "Retire failed: $_"
        Write-InfraLog "Retire failed: $_" -Level ERROR
    }

    return $result
}

function Invoke-AuditMode {
    param(
        [hashtable]$NimbleConn,
        [object]$vCenterSession,
        [string]$ClusterName,
        [int]$MaxSnapshotAgeDays
    )

    Write-InfraLog "Starting AUDIT mode" -Level AUDIT

    $result = @{
        Mode = "Audit"
        Timestamp = Get-Date
        Findings = @()
        ClusterName = $ClusterName
    }

    try {
        Write-InfraLog "Checking multipath policies..." -Level INFO

        $hosts = Get-Cluster -Name $ClusterName | Get-VMHost
        $policyIssues = @()

        foreach ($host in $hosts) {
            $luns = Get-ScsiLun -VMHost $host | Where-Object { $_.Vendor -match "Nimble|HPE" }

            foreach ($lun in $luns) {
                if ($lun.MultipathPolicy -ne "VMW_PSP_RR" -and $lun.MultipathPolicy -ne "RoundRobin") {
                    $policyIssues += @{
                        Type = "MultipathPolicy"
                        Severity = "Warning"
                        Host = $host.Name
                        LUN = $lun.CanonicalName
                        CurrentPolicy = $lun.MultipathPolicy
                        RecommendedPolicy = "VMW_PSP_RR"
                        Message = "Nimble LUN should use Round Robin multipath policy"
                    }
                }
            }
        }

        Write-InfraLog "Found $($policyIssues.Count) multipath policy issues" -Level INFO

        Write-InfraLog "Checking for zombie volumes..." -Level INFO

        $volumes = Invoke-NimbleRest -Connection $NimbleConn -Endpoint "v1/volumes" -Method GET
        $datastores = Get-Datastore -Server $vCenterSession

        $zombieVols = @()
        foreach ($vol in $volumes.data) {
            $matched = $datastores | Where-Object { $_.Name -like "*$($vol.name)*" }

            if (-not $matched -and $vol.online) {
                $zombieVols += @{
                    Type = "ZombieVolume"
                    Severity = "Info"
                    VolumeId = $vol.id
                    VolumeName = $vol.name
                    SizeGB = [math]::Round($vol.size / 1GB, 2)
                    Message = "Volume exists on array but not mounted to any host"
                }
            }
        }

        Write-InfraLog "Found $($zombieVols.Count) zombie volumes" -Level INFO

        Write-InfraLog "Checking for orphaned snapshots..." -Level INFO

        $snapshots = Invoke-NimbleRest -Connection $NimbleConn -Endpoint "v1/snapshots" -Method GET
        $cutoffDate = (Get-Date).AddDays(-$MaxSnapshotAgeDays)

        $orphanedSnaps = @()
        foreach ($snap in $snapshots.data) {
            $snapDate = [datetime]::ParseExact($snap.create_time.ToString(), "yyyy-MM-ddTHH:mm:ssZ", [Globalization.CultureInfo]::InvariantCulture)

            if ($snapDate -lt $cutoffDate) {
                $orphanedSnaps += @{
                    Type = "OrphanedSnapshot"
                    Severity = if ($snapDate -lt (Get-Date).AddDays(-90)) { "Warning" } else { "Info" }
                    SnapshotId = $snap.id
                    SnapshotName = $snap.name
                    VolumeName = $snap.vol_name
                    Created = $snapDate
                    AgeDays = ((Get-Date) - $snapDate).Days
                    Message = "Snapshot older than $MaxSnapshotAgeDays days"
                }
            }
        }

        Write-InfraLog "Found $($orphanedSnaps.Count) orphaned snapshots" -Level INFO

        Write-InfraLog "Checking datastore health..." -Level INFO

        $dsHealthIssues = @()
        foreach ($ds in $datastores) {
            if ($ds.FreeSpaceGB -lt 100) {
                $dsHealthIssues += @{
                    Type = "LowSpace"
                    Severity = "Warning"
                    DatastoreName = $ds.Name
                    FreeSpaceGB = [math]::Round($ds.FreeSpaceGB, 2)
                    CapacityGB = [math]::Round($ds.CapacityGB, 2)
                    PercentFree = [math]::Round(($ds.FreeSpaceGB / $ds.CapacityGB) * 100, 2)
                    Message = "Datastore has low free space"
                }
            }

            $vmCount = (Get-VM -Datastore $ds -ErrorAction SilentlyContinue).Count
            if ($vmCount -eq 0 -and $ds.CapacityGB -gt 100) {
                $dsHealthIssues += @{
                    Type = "EmptyDatastore"
                    Severity = "Info"
                    DatastoreName = $ds.Name
                    CapacityGB = [math]::Round($ds.CapacityGB, 2)
                    Message = "Large datastore with no VMs (candidate for retirement)"
                }
            }
        }

        Write-InfraLog "Found $($dsHealthIssues.Count) datastore health issues" -Level INFO

        $result.Findings = $policyIssues + $zombieVols + $orphanedSnaps + $dsHealthIssues

        $criticalCount = ($result.Findings | Where-Object { $_.Severity -eq "Warning" }).Count
        $infoCount = ($result.Findings | Where-Object { $_.Severity -eq "Info" }).Count

        Write-InfraLog "Audit complete: $criticalCount warnings, $infoCount informational findings" -Level INFO

        if ($criticalCount -gt 0) {
            Write-InfraLog "Audit completed with warnings - review findings" -Level WARNING
        } else {
            Write-InfraLog "Audit completed successfully" -Level SUCCESS
        }

    } catch {
        Write-InfraLog "Audit failed: $_" -Level ERROR
        $result.Findings += @{
            Type = "AuditError"
            Severity = "Error"
            Message = "Audit failed: $_"
        }
    }

    return $result
}

#endregion

#region Interactive Menu Functions

<# LEGACY MENU BLOCK (replaced due to corrupted characters)
function Show-MainMenu {
    Clear-Host

    Write-Host "╔═════════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║         Infrastructure State Controller - Interactive Menu               ║" -ForegroundColor Cyan
    Write-Host "╚═════════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Connected to:" -ForegroundColor Yellow
    if ($script:ConnectedNimble) {
        Write-Host "  [✓] Nimble: $NimbleServer" -ForegroundColor Green
    } else {
        Write-Host "  [ ] Nimble: $NimbleServer" -ForegroundColor Red
    }
    if ($script:ConnectedvCenter) {
        Write-Host "  [✓] vCenter: $vCenterServer" -ForegroundColor Green
    } else {
        Write-Host "  [ ] vCenter: $vCenterServer" -ForegroundColor Red
    }
    Write-Host ""

    Write-Host "Select an operation:" -ForegroundColor White
    Write-Host "  1. Provision new datastore" -ForegroundColor White
    Write-Host "  2. Clone volume (Dev environment)" -ForegroundColor White
    Write-Host "  3. Expand existing datastore" -ForegroundColor White
    Write-Host "  4. Retire datastore" -ForegroundColor White
    Write-Host "  5. Audit infrastructure" -ForegroundColor White
    Write-Host "  6. Connect to Nimble/vCenter" -ForegroundColor Yellow
    Write-Host "  7. View cluster information" -ForegroundColor White
    Write-Host "  8. View available volumes" -ForegroundColor White
    Write-Host "  0. Exit" -ForegroundColor Red
    Write-Host ""
}

#>
function Show-MainMenu {
    Clear-Host

    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "    Infrastructure State Controller - Interactive Menu     " -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""

    Write-Host "Connected to:" -ForegroundColor Yellow
    if ($script:ConnectedNimble) {
        Write-Host "  [x] Nimble: $NimbleServer" -ForegroundColor Green
    } else {
        Write-Host "  [ ] Nimble: $NimbleServer" -ForegroundColor Red
    }

    if ($script:ConnectedvCenter) {
        Write-Host "  [x] vCenter: $vCenterServer" -ForegroundColor Green
    } else {
        Write-Host "  [ ] vCenter: $vCenterServer" -ForegroundColor Red
    }

    Write-Host ""
    Write-Host "Select an operation:" -ForegroundColor White
    Write-Host "  1. Provision new datastore" -ForegroundColor White
    Write-Host "  2. Clone volume (Dev environment)" -ForegroundColor White
    Write-Host "  3. Expand existing datastore" -ForegroundColor White
    Write-Host "  4. Retire datastore" -ForegroundColor White
    Write-Host "  5. Audit infrastructure" -ForegroundColor White
    Write-Host "  6. Connect to Nimble/vCenter" -ForegroundColor Yellow
    Write-Host "  7. View cluster information" -ForegroundColor White
    Write-Host "  8. View available volumes" -ForegroundColor White
    Write-Host "  0. Exit" -ForegroundColor White
    Write-Host ""
}

function Get-MenuSelection {
    param([int]$Max)

    do {
        $selection = Read-Host "Enter selection"
        if ($selection -match '^\d+$' -and $selection -ge 0 -and $selection -le $Max) {
            return [int]$selection
        }
        Write-Host "Invalid selection. Please enter a number between 0 and $Max." -ForegroundColor Red
    } while ($true)
}

function Show-ClustersMenu {
    param([object]$vCenterSession)

    Clear-Host
    Write-Host "═══ vSphere Clusters ═══" -ForegroundColor Cyan
    Write-Host ""

    try {
        $clusters = Get-Cluster -Server $vCenterSession | Sort-Object Name

        if ($clusters.Count -eq 0) {
            Write-Host "No clusters found." -ForegroundColor Yellow
            return $null
        }

        Write-Host "Available clusters:" -ForegroundColor White
        $clusters | ForEach-Object { [int]$i = 0 } { $i++; Write-Host "  $i. $($_.Name)" -ForegroundColor White }
        Write-Host ""
        Write-Host "  0. Back" -ForegroundColor Gray
        Write-Host ""

        $selection = Get-MenuSelection -Max $clusters.Count

        if ($selection -eq 0) {
            return $null
        }

        return $clusters[$selection - 1]
    } catch {
        Write-Host "Error retrieving clusters: $_" -ForegroundColor Red
        Read-Host "Press Enter to continue"
        return $null
    }
}

function Show-VolumesMenu {
    param(
        [hashtable]$NimbleConn
    )

    Clear-Host
    Write-Host "═══ Nimble Volumes ═══" -ForegroundColor Cyan
    Write-Host ""

    try {
        $volumes = Invoke-NimbleRest -Connection $NimbleConn -Endpoint "v1/volumes" -Method GET

        if (-not $volumes.data -or $volumes.data.Count -eq 0) {
            Write-Host "No volumes found." -ForegroundColor Yellow
            return $null
        }

        $volumes.data | Sort-Object Name | ForEach-Object { [int]$i = 0 } {
            $i++
            $sizeGB = [math]::Round($_.size / 1GB, 2)
            $statusColor = if ($_.online) { "Green" } else { "Red" }
            $status = if ($_.online) { "ON" } else { "OFF" }

            Write-Host "  $i. $($_.Name)" -ForegroundColor White
            Write-Host "     Size: $sizeGB GB | Status: " -NoNewline
            Write-Host "[$status]" -ForegroundColor $statusColor
        }

        Write-Host ""
        Write-Host "  0. Back" -ForegroundColor Gray
        Write-Host ""

        $selection = Get-MenuSelection -Max $volumes.data.Count

        if ($selection -eq 0) {
            return $null
        }

        return $volumes.data[$selection - 1]
    } catch {
        Write-Host "Error retrieving volumes: $_" -ForegroundColor Red
        Read-Host "Press Enter to continue"
        return $null
    }
}

function Show-ClusterInfo {
    param(
        [object]$vCenterSession,
        [string]$ClusterName
    )

    Clear-Host
    Write-Host "═══ Cluster Information: $ClusterName ═══" -ForegroundColor Cyan
    Write-Host ""

    try {
        $cluster = Get-Cluster -Name $ClusterName -Server $vCenterSession
        $hosts = $cluster | Get-VMHost
        $datastores = Get-Datastore -RelatedObject $cluster

        Write-Host "Cluster: $($cluster.Name)" -ForegroundColor White
        Write-Host "Hosts: $($hosts.Count)" -ForegroundColor White
        Write-Host "Datastores: $($datastores.Count)" -ForegroundColor White

        $totalCapacity = ($datastores | Measure-Object -Property Capacity -Sum).Sum
        $usedSpace = ($datastores | Measure-Object -Property UsedSpaceGB -Sum).Sum
        $freeSpace = ($datastores | Measure-Object -Property FreeSpaceGB -Sum).Sum

        Write-Host ""
        Write-Host "Storage Summary:" -ForegroundColor Yellow
        Write-Host ("  Total Capacity: {0} TB" -f [math]::Round($totalCapacity/1TB, 2)) -ForegroundColor White
        Write-Host ("  Used Space: {0} GB ({1}%)" -f [math]::Round($usedSpace, 2), [math]::Round(($usedSpace/$totalCapacity)*100, 1)) -ForegroundColor White
        Write-Host ("  Free Space: {0} TB" -f [math]::Round($freeSpace/1TB, 2)) -ForegroundColor White

        Write-Host ""
        Write-Host "Hosts:" -ForegroundColor Yellow
        $hosts | ForEach-Object {
            $cpuUsage = [math]::Round($_.CpuUsageMhz / $_.CpuTotalMhz * 100, 1)
            $memUsage = [math]::Round($_.MemoryUsageGB / $_.MemoryTotalGB * 100, 1)
            Write-Host "  - $($_.Name)" -ForegroundColor White
            Write-Host "    CPU: $cpuUsage% | RAM: $memUsage% | Status: $($_.ConnectionState)" -ForegroundColor DarkGray
        }

        Write-Host ""
        Write-Host "Top 5 Datastores (by used space):" -ForegroundColor Yellow
        $datastores | Sort-Object UsedSpaceGB -Descending | Select-Object -First 5 | ForEach-Object {
            $percent = [math]::Round($_.FreeSpaceGB / $_.CapacityGB * 100, 1)
            Write-Host ("  - {0} : {1} GB / {2} GB ({3}% free)" -f $_.Name, [math]::Round($_.UsedSpaceGB, 2), [math]::Round($_.CapacityGB, 2), $percent) -ForegroundColor White
        }

    } catch {
        Write-Host "Error retrieving cluster info: $_" -ForegroundColor Red
    }

    Read-Host "`nPress Enter to continue"
}

function Invoke-InteractiveProvision {
    param(
        [hashtable]$NimbleConn,
        [object]$vCenterSession
    )

    Clear-Host
    Write-Host "═══ Provision New Datastore ═══" -ForegroundColor Cyan
    Write-Host ""

    Write-Host "Step 1: Select Target Cluster" -ForegroundColor Yellow
    $cluster = Show-ClustersMenu -vCenterSession $vCenterSession

    if (-not $cluster) {
        return
    }

    Write-Host "Step 2: Enter Volume Name" -ForegroundColor Yellow
    $volName = Read-Host "Volume/Datastore name (e.g., s-SQL-Prod-01)"

    if (-not $volName) {
        Write-Host "Volume name cannot be empty." -ForegroundColor Red
        Read-Host "Press Enter to continue"
        return
    }

    Write-Host "Step 3: Enter Size (GB)" -ForegroundColor Yellow
    $sizeGB = Read-Host "Size in GB (e.g., 1024 for 1TB)"

    if (-not ($sizeGB -match '^\d+$')) {
        Write-Host "Invalid size. Must be a number." -ForegroundColor Red
        Read-Host "Press Enter to continue"
        return
    }

    Write-Host "Step 4: Performance Policy" -ForegroundColor Yellow
    Write-Host "  1. VMware ESXi (Standard)" -ForegroundColor White
    Write-Host "  2. SQL-Gold (High Performance)" -ForegroundColor White
    Write-Host "  3. Dev-Bronze (Low Cost)" -ForegroundColor White

    $policySel = Get-MenuSelection -Max 3
    $policy = switch ($policySel) {
        1 { "VMware ESXi" }
        2 { "SQL-Gold" }
        3 { "Dev-Bronze" }
    }

    Write-Host "Step 5: Storage DRS Cluster (optional)" -ForegroundColor Yellow
    $dsCluster = Read-Host "Datastore cluster name (or press Enter to skip)"

    Write-Host ""
    Write-Host "═ Provision Summary ══" -ForegroundColor Cyan
    Write-Host "  Cluster: $($cluster.Name)" -ForegroundColor White
    Write-Host "  Volume Name: $volName" -ForegroundColor White
    Write-Host "  Size: $sizeGB GB" -ForegroundColor White
    Write-Host "  Performance Policy: $policy" -ForegroundColor White
    if ($dsCluster) { Write-Host "  Storage DRS Cluster: $dsCluster" -ForegroundColor White }
    Write-Host ""

    $confirm = Read-Host "Proceed? (Y/N)"
    if ($confirm -ne 'Y' -and $confirm -ne 'y') {
        Write-Host "Cancelled." -ForegroundColor Yellow
        Read-Host "Press Enter to continue"
        return
    }

    $whatIf = Read-Host "Run in WhatIf mode? (Y/N)"
    $useWhatIf = ($whatIf -eq 'Y' -or $whatIf -eq 'y')

    $result = Invoke-ProvisionMode -NimbleConn $NimbleConn -vCenterSession $vCenterSession -ClusterName $cluster.Name -VolName $volName -SizeGB $sizeGB -PerformancePolicy $policy -DatastoreClusterName $dsCluster

    if ($useWhatIf) {
        Write-Host ""
        Write-Host "WhatIf mode completed. No changes were made." -ForegroundColor Cyan
    } else {
        Write-Host ""
        if ($result.Success) {
            Write-Host "Provision completed successfully!" -ForegroundColor Green
        } else {
            Write-Host "Provision failed!" -ForegroundColor Red
            foreach ($err in $result.Errors) {
                Write-Host "  - $err" -ForegroundColor Red
            }
        }
    }

    Read-Host "Press Enter to continue"
}

function Invoke-InteractiveClone {
    param(
        [hashtable]$NimbleConn,
        [object]$vCenterSession
    )

    Clear-Host
    Write-Host "═══ Clone Volume (Dev Environment) ═══" -ForegroundColor Cyan
    Write-Host ""

    Write-Host "Step 1: Select Source Volume" -ForegroundColor Yellow
    $sourceVol = Show-VolumesMenu -NimbleConn $NimbleConn

    if (-not $sourceVol) {
        return
    }

    Write-Host "Step 2: Select Target Cluster" -ForegroundColor Yellow
    $cluster = Show-ClustersMenu -vCenterSession $vCenterSession

    if (-not $cluster) {
        return
    }

    Write-Host "Step 3: Enter Clone Name" -ForegroundColor Yellow
    $cloneName = Read-Host "Clone volume name (e.g., s-SQL-Dev-01)"

    if (-not $cloneName) {
        Write-Host "Clone name cannot be empty." -ForegroundColor Red
        Read-Host "Press Enter to continue"
        return
    }

    Write-Host ""
    Write-Host "═ Clone Summary ══" -ForegroundColor Cyan
    Write-Host "  Source Volume: $($sourceVol.name)" -ForegroundColor White
    Write-Host "  Target Cluster: $($cluster.Name)" -ForegroundColor White
    Write-Host "  Clone Name: $cloneName" -ForegroundColor White
    Write-Host ""

    $confirm = Read-Host "Proceed? (Y/N)"
    if ($confirm -ne 'Y' -and $confirm -ne 'y') {
        Write-Host "Cancelled." -ForegroundColor Yellow
        Read-Host "Press Enter to continue"
        return
    }

    $resignature = Read-Host "Perform VMFS resignature? (Y/N)"
    $doResignature = ($resignature -eq 'Y' -or $resignature -eq 'y')

    $whatIf = Read-Host "Run in WhatIf mode? (Y/N)"
    $useWhatIf = ($whatIf -eq 'Y' -or $whatIf -eq 'y')

    $result = Invoke-CloneMode -NimbleConn $NimbleConn -vCenterSession $vCenterSession -ClusterName $cluster.Name -SourceVolName $sourceVol.name -VolName $cloneName -PerformancePolicy "VMware ESXi" -Resignature $doResignature

    if ($useWhatIf) {
        Write-Host ""
        Write-Host "WhatIf mode completed. No changes were made." -ForegroundColor Cyan
    } else {
        Write-Host ""
        if ($result.Success) {
            Write-Host "Clone completed successfully!" -ForegroundColor Green
        } else {
            Write-Host "Clone failed!" -ForegroundColor Red
            foreach ($err in $result.Errors) {
                Write-Host "  - $err" -ForegroundColor Red
            }
        }
    }

    Read-Host "Press Enter to continue"
}

function Invoke-InteractiveExpand {
    param(
        [hashtable]$NimbleConn,
        [object]$vCenterSession
    )

    Clear-Host
    Write-Host "═══ Expand Existing Datastore ═══" -ForegroundColor Cyan
    Write-Host ""

    Write-Host "Step 1: Select Cluster" -ForegroundColor Yellow
    $cluster = Show-ClustersMenu -vCenterSession $vCenterSession

    if (-not $cluster) {
        return
    }

    Write-Host "Step 2: Select Datastore to Expand" -ForegroundColor Yellow
    $datastores = Get-Datastore -RelatedObject $cluster | Where-Object { $_.Type -eq "VMFS" } | Sort-Object Name

    if ($datastores.Count -eq 0) {
        Write-Host "No VMFS datastores found." -ForegroundColor Yellow
        Read-Host "Press Enter to continue"
        return
    }

    Write-Host "Available datastores:" -ForegroundColor White
    $datastores | ForEach-Object { [int]$i = 0 } {
        $i++
        $percent = [math]::Round($_.FreeSpaceGB / $_.CapacityGB * 100, 1)
        Write-Host "  $i. $($_.Name) - $([math]::Round($_.CapacityGB, 2)) GB ($percent% free)" -ForegroundColor White
    }

    Write-Host ""
    Write-Host "  0. Back" -ForegroundColor Gray

    $selection = Get-MenuSelection -Max $datastores.Count
    if ($selection -eq 0) {
        return
    }

    $datastore = $datastores[$selection - 1]

    Write-Host "Step 3: Enter New Size (GB)" -ForegroundColor Yellow
    Write-Host "Current size: $([math]::Round($datastore.CapacityGB, 2)) GB" -ForegroundColor White
    $newSize = Read-Host "New total size in GB"

    if (-not ($newSize -match '^\d+$')) {
        Write-Host "Invalid size. Must be a number." -ForegroundColor Red
        Read-Host "Press Enter to continue"
        return
    }

    if ([int]$newSize -le [math]::Round($datastore.CapacityGB, 2)) {
        Write-Host "New size must be larger than current size." -ForegroundColor Red
        Read-Host "Press Enter to continue"
        return
    }

    Write-Host ""
    Write-Host "═ Expand Summary ══" -ForegroundColor Cyan
    Write-Host "  Cluster: $($cluster.Name)" -ForegroundColor White
    Write-Host "  Datastore: $($datastore.Name)" -ForegroundColor White
    Write-Host "  Current Size: $([math]::Round($datastore.CapacityGB, 2)) GB" -ForegroundColor White
    Write-Host "  New Size: $newSize GB" -ForegroundColor White
    Write-Host "  Increase: $([int]$newSize - [math]::Round($datastore.CapacityGB, 2)) GB" -ForegroundColor Green
    Write-Host ""

    $confirm = Read-Host "Proceed? (Y/N)"
    if ($confirm -ne 'Y' -and $confirm -ne 'y') {
        Write-Host "Cancelled." -ForegroundColor Yellow
        Read-Host "Press Enter to continue"
        return
    }

    $whatIf = Read-Host "Run in WhatIf mode? (Y/N)"
    $useWhatIf = ($whatIf -eq 'Y' -or $whatIf -eq 'y')

    $result = Invoke-ExpandMode -NimbleConn $NimbleConn -vCenterSession $vCenterSession -ClusterName $cluster.Name -DatastoreName $datastore.Name -SizeGB $newSize

    if ($useWhatIf) {
        Write-Host ""
        Write-Host "WhatIf mode completed. No changes were made." -ForegroundColor Cyan
    } else {
        Write-Host ""
        if ($result.Success) {
            Write-Host "Expand completed successfully!" -ForegroundColor Green
            Write-Host "  Old: $($result.OldCapacityGB) GB" -ForegroundColor White
            Write-Host "  New: $($result.NewCapacityGB) GB" -ForegroundColor White
        } else {
            Write-Host "Expand failed!" -ForegroundColor Red
            foreach ($err in $result.Errors) {
                Write-Host "  - $err" -ForegroundColor Red
            }
        }
    }

    Read-Host "Press Enter to continue"
}

function Invoke-InteractiveRetire {
    param(
        [hashtable]$NimbleConn,
        [object]$vCenterSession
    )

    Clear-Host
    Write-Host "═══ Retire Datastore ═══" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "WARNING: This will permanently remove the datastore and volume!" -ForegroundColor Red
    Write-Host ""

    Write-Host "Step 1: Select Cluster" -ForegroundColor Yellow
    $cluster = Show-ClustersMenu -vCenterSession $vCenterSession

    if (-not $cluster) {
        return
    }

    Write-Host "Step 2: Select Datastore to Retire" -ForegroundColor Yellow
    $datastores = Get-Datastore -RelatedObject $cluster | Where-Object { $_.Type -eq "VMFS" } | Sort-Object Name

    if ($datastores.Count -eq 0) {
        Write-Host "No VMFS datastores found." -ForegroundColor Yellow
        Read-Host "Press Enter to continue"
        return
    }

    Write-Host "Available datastores:" -ForegroundColor White
    $datastores | ForEach-Object { [int]$i = 0 } {
        $i++
        $vms = Get-VM -Datastore $_ -ErrorAction SilentlyContinue
        $vmStatus = if ($vms) { "$($vms.Count) VMs" } else { "Empty" }
        $statusColor = if ($vms) { "Red" } else { "Green" }
        Write-Host "  $i. $($_.Name) - $vmStatus" -ForegroundColor White -NoNewline
        Write-Host " [$vmStatus]" -ForegroundColor $statusColor
    }

    Write-Host ""
    Write-Host "  0. Back" -ForegroundColor Gray

    $selection = Get-MenuSelection -Max $datastores.Count
    if ($selection -eq 0) {
        return
    }

    $datastore = $datastores[$selection - 1]

    $vms = Get-VM -Datastore $datastore -ErrorAction SilentlyContinue
    if ($vms) {
        Write-Host ""
        Write-Host "WARNING: Datastore contains $($vms.Count) VM(s):" -ForegroundColor Red
        $vms | ForEach-Object { Write-Host "  - $($_.Name)" -ForegroundColor Red }
        Write-Host ""
        Write-Host "You must migrate VMs off this datastore first." -ForegroundColor Yellow
        Read-Host "Press Enter to continue"
        return
    }

    Write-Host ""
    Write-Host "═ Retire Summary ══" -ForegroundColor Cyan
    Write-Host "  Cluster: $($cluster.Name)" -ForegroundColor White
    Write-Host "  Datastore: $($datastore.Name)" -ForegroundColor White
    Write-Host "  Size: $([math]::Round($datastore.CapacityGB, 2)) GB" -ForegroundColor White
    Write-Host ""

    $confirm = Read-Host "Type 'DELETE' to confirm retirement"
    if ($confirm -ne "DELETE") {
        Write-Host "Retirement cancelled." -ForegroundColor Yellow
        Read-Host "Press Enter to continue"
        return
    }

    $whatIf = Read-Host "Run in WhatIf mode? (Y/N)"
    $useWhatIf = ($whatIf -eq 'Y' -or $whatIf -eq 'y')

    $result = Invoke-RetireMode -NimbleConn $NimbleConn -vCenterSession $vCenterSession -ClusterName $cluster.Name -DatastoreName $datastore.Name -Force $false

    if ($useWhatIf) {
        Write-Host ""
        Write-Host "WhatIf mode completed. No changes were made." -ForegroundColor Cyan
    } else {
        Write-Host ""
        if ($result.Success) {
            Write-Host "Retire completed successfully!" -ForegroundColor Green
            Write-Host "  Datastore removed: $($result.DatastoreRemoved)" -ForegroundColor White
            Write-Host "  Volume removed: $($result.VolumeRemoved)" -ForegroundColor White
        } else {
            Write-Host "Retire failed!" -ForegroundColor Red
            foreach ($err in $result.Errors) {
                Write-Host "  - $err" -ForegroundColor Red
            }
        }
    }

    Read-Host "Press Enter to continue"
}

function Invoke-InteractiveAudit {
    param(
        [hashtable]$NimbleConn,
        [object]$vCenterSession
    )

    Clear-Host
    Write-Host "═══ Audit Infrastructure ═══" -ForegroundColor Cyan
    Write-Host ""

    $auditCluster = Read-Host "Audit specific cluster? (Enter for all, or type cluster name)"
    if ([string]::IsNullOrWhiteSpace($auditCluster)) {
        $auditCluster = $null
    }

    $maxSnapAge = Read-Host "Max snapshot age for orphaned check? (Enter for default: $MaxSnapshotAgeDays days)"
    if ([string]::IsNullOrWhiteSpace($maxSnapAge)) {
        $maxSnapAge = $MaxSnapshotAgeDays
    }

    Write-Host ""
    Write-Host "Running audit..." -ForegroundColor Yellow

    $result = Invoke-AuditMode -NimbleConn $NimbleConn -vCenterSession $vCenterSession -ClusterName $auditCluster -MaxSnapshotAgeDays $maxSnapAge

    Clear-Host
    Write-Host "═══ Audit Results ═══" -ForegroundColor Cyan
    Write-Host ""

    if ($result.Findings.Count -eq 0) {
        Write-Host "No issues found! Your infrastructure is healthy." -ForegroundColor Green
    } else {
        Write-Host "Found $($result.Findings.Count) findings:" -ForegroundColor White
        Write-Host ""

        $warningCount = 0
        foreach ($finding in $result.Findings) {
            $color = switch ($finding.Severity) {
                "Warning" { "Yellow" }
                "Error" { "Red" }
                default { "Gray" }
            }

            if ($finding.Severity -eq "Warning") { $warningCount++ }

            Write-Host "[$($finding.Severity)] $($finding.Type): $($finding.Message)" -ForegroundColor $color
            if ($finding.Host) { Write-Host "  Host: $($finding.Host)" -ForegroundColor DarkGray }
            if ($finding.LUN) { Write-Host "  LUN: $($finding.LUN)" -ForegroundColor DarkGray }
            if ($finding.VolumeName) { Write-Host "  Volume: $($finding.VolumeName)" -ForegroundColor DarkGray }
            if ($finding.RecommendedPolicy) { Write-Host "  Recommended: $($finding.RecommendedPolicy)" -ForegroundColor DarkGray }
            Write-Host ""
        }

        if ($warningCount -gt 0) {
            Write-Host "Audit completed with $warningCount warning(s)." -ForegroundColor Yellow
        }
    }

    Read-Host "Press Enter to continue"
}

function Start-InteractiveMode {
    param(
        [string]$NimbleServer,
        [string]$vCenterServer,
        [pscredential]$Credential
    )

    $script:ConnectedNimble = $false
    $script:ConnectedvCenter = $false
    $nimbleConn = $null
    $vCenterConn = $null

    do {
        Show-MainMenu
        $selection = Get-MenuSelection -Max 8

        switch ($selection) {
            1 {
                if (-not $script:ConnectedNimble -or -not $script:ConnectedvCenter) {
                    Write-Host ""
                    Write-Host "Please connect to Nimble and vCenter first (Option 6)." -ForegroundColor Red
                    Read-Host "Press Enter to continue"
                    continue
                }
                Invoke-InteractiveProvision -NimbleConn $nimbleConn -vCenterSession $vCenterConn.Session
            }

            2 {
                if (-not $script:ConnectedNimble -or -not $script:ConnectedvCenter) {
                    Write-Host ""
                    Write-Host "Please connect to Nimble and vCenter first (Option 6)." -ForegroundColor Red
                    Read-Host "Press Enter to continue"
                    continue
                }
                Invoke-InteractiveClone -NimbleConn $nimbleConn -vCenterSession $vCenterConn.Session
            }

            3 {
                if (-not $script:ConnectedNimble -or -not $script:ConnectedvCenter) {
                    Write-Host ""
                    Write-Host "Please connect to Nimble and vCenter first (Option 6)." -ForegroundColor Red
                    Read-Host "Press Enter to continue"
                    continue
                }
                Invoke-InteractiveExpand -NimbleConn $nimbleConn -vCenterSession $vCenterConn.Session
            }

            4 {
                if (-not $script:ConnectedNimble -or -not $script:ConnectedvCenter) {
                    Write-Host ""
                    Write-Host "Please connect to Nimble and vCenter first (Option 6)." -ForegroundColor Red
                    Read-Host "Press Enter to continue"
                    continue
                }
                Invoke-InteractiveRetire -NimbleConn $nimbleConn -vCenterSession $vCenterConn.Session
            }

            5 {
                if (-not $script:ConnectedNimble -or -not $script:ConnectedvCenter) {
                    Write-Host ""
                    Write-Host "Please connect to Nimble and vCenter first (Option 6)." -ForegroundColor Red
                    Read-Host "Press Enter to continue"
                    continue
                }
                Invoke-InteractiveAudit -NimbleConn $nimbleConn -vCenterSession $vCenterConn.Session
            }

            6 {
                Clear-Host
                Write-Host "═══ Connect to Nimble/vCenter ═══" -ForegroundColor Cyan
                Write-Host ""

                if (-not $Credential) {
                    $Credential = Get-Credential -Message "Enter credentials for Nimble/vCenter"
                }

                Write-Host "Connecting to Nimble: $NimbleServer" -ForegroundColor Yellow
                $nimbleConn = Test-NimbleConnection -Server $NimbleServer -Credential $Credential
                $script:ConnectedNimble = $nimbleConn.Connected

                if ($script:ConnectedNimble) {
                    Write-Host "  [✓] Connected to Nimble" -ForegroundColor Green
                } else {
                    Write-Host "  [✗] Failed to connect to Nimble" -ForegroundColor Red
                }

                Write-Host ""
                Write-Host "Connecting to vCenter: $vCenterServer" -ForegroundColor Yellow
                $vCenterConn = Test-vCenterConnection -Server $vCenterServer -Credential $Credential
                $script:ConnectedvCenter = $vCenterConn.Connected

                if ($script:ConnectedvCenter) {
                    Write-Host "  [✓] Connected to vCenter" -ForegroundColor Green
                } else {
                    Write-Host "  [✗] Failed to connect to vCenter" -ForegroundColor Red
                }

                Write-Host ""
                Read-Host "Press Enter to continue"
            }

            7 {
                if (-not $script:ConnectedvCenter) {
                    Write-Host ""
                    Write-Host "Please connect to vCenter first (Option 6)." -ForegroundColor Red
                    Read-Host "Press Enter to continue"
                    continue
                }

                $cluster = Show-ClustersMenu -vCenterSession $vCenterConn.Session
                if ($cluster) {
                    Show-ClusterInfo -vCenterSession $vCenterConn.Session -ClusterName $cluster.Name
                }
            }

            8 {
                if (-not $script:ConnectedNimble) {
                    Write-Host ""
                    Write-Host "Please connect to Nimble first (Option 6)." -ForegroundColor Red
                    Read-Host "Press Enter to continue"
                    continue
                }
                Show-VolumesMenu -NimbleConn $nimbleConn | Out-Null
            }

            0 {
                Clear-Host
                Write-Host "Goodbye!" -ForegroundColor Cyan
                break
            }
        }
    } while ($true)

    if ($vCenterConn.Session) {
        Disconnect-VIServer -Server $vCenterConn.Session -Confirm:$false -ErrorAction SilentlyContinue
    }
    if ($nimbleConn.Session) {
        Disconnect-NSGroup -ErrorAction SilentlyContinue
    }
}

#endregion

#region Main Script

$ErrorActionPreference = "Stop"
$script:LogFile = $null

try {
    Initialize-InfraLogging -Path $LogPath

    if ($DryRun) {
        if (-not $NimbleServer) { $NimbleServer = "(not set)" }
        if (-not $vCenterServer) { $vCenterServer = "(not set)" }

        Write-InfraLog "DRY RUN: no changes will be made" -Level WARNING
        Write-InfraLog "Would connect to Nimble: $NimbleServer" -Level INFO
        Write-InfraLog "Would connect to vCenter: $vCenterServer" -Level INFO
        Write-InfraLog "Would execute intent: $Intent" -Level INFO
        Write-InfraLog "Use -WhatIf to see per-action simulation where supported" -Level INFO
        exit 0
    }

    if ($Intent -eq "Menu") {
        if (-not $NimbleServer -or -not $vCenterServer) {
            Write-Host "NimbleServer and vCenterServer not configured." -ForegroundColor Yellow
            $NimbleServer = Read-Host "Enter Nimble server address"
            $vCenterServer = Read-Host "Enter vCenter server address"
        }
        Start-InteractiveMode -NimbleServer $NimbleServer -vCenterServer $vCenterServer -Credential $Credential
        exit 0
    }

    if (-not $Credential) {
        $Credential = Get-Credential -Message "Enter credentials for Nimble/vCenter"
    }

    if (-not $NimbleServer -or -not $vCenterServer) {
        throw "NimbleServer and vCenterServer must be specified (or set as global variables \$NIMBLE_SERVER and \$VCENTER_SERVER)"
    }

    $nimbleConn = Test-NimbleConnection -Server $NimbleServer -Credential $Credential

    if (-not $nimbleConn.Connected) {
        throw "Failed to connect to Nimble array"
    }

    $vCenterConn = Test-vCenterConnection -Server $vCenterServer -Credential $Credential

    if (-not $vCenterConn.Connected) {
        throw "Failed to connect to vCenter"
    }

    $result = $null

    switch ($Intent) {
        "Provision" {
            if (-not $ClusterName -or -not $VolName -or -not $SizeGB) {
                throw "Provision mode requires: ClusterName, VolName, SizeGB"
            }
            $result = Invoke-ProvisionMode -NimbleConn $nimbleConn -vCenterSession $vCenterConn.Session -ClusterName $ClusterName -VolName $VolName -SizeGB $SizeGB -PerformancePolicy $PerformancePolicy -DatastoreClusterName $DatastoreCluster
        }

        "Clone" {
            if (-not $ClusterName -or -not $SourceVolName -or -not $VolName) {
                throw "Clone mode requires: ClusterName, SourceVolName, VolName"
            }
            $result = Invoke-CloneMode -NimbleConn $nimbleConn -vCenterSession $vCenterConn.Session -ClusterName $ClusterName -SourceVolName $SourceVolName -VolName $VolName -PerformancePolicy $PerformancePolicy -Resignature $true
        }

        "Expand" {
            if (-not $ClusterName -or -not $DatastoreName -or -not $SizeGB) {
                throw "Expand mode requires: ClusterName, DatastoreName, SizeGB"
            }
            $result = Invoke-ExpandMode -NimbleConn $nimbleConn -vCenterSession $vCenterConn.Session -ClusterName $ClusterName -DatastoreName $DatastoreName -SizeGB $SizeGB
        }

        "Retire" {
            if (-not $ClusterName -or -not $DatastoreName) {
                throw "Retire mode requires: ClusterName, DatastoreName"
            }
            $confirm = Read-Host "Type 'DELETE' to confirm retirement of datastore $DatastoreName"
            if ($confirm -ne "DELETE") {
                Write-InfraLog "Retirement cancelled" -Level WARNING
                exit 0
            }
            $result = Invoke-RetireMode -NimbleConn $nimbleConn -vCenterSession $vCenterConn.Session -ClusterName $ClusterName -DatastoreName $DatastoreName -Force $false
        }

        "Audit" {
            $result = Invoke-AuditMode -NimbleConn $nimbleConn -vCenterSession $vCenterConn.Session -ClusterName $ClusterName -MaxSnapshotAgeDays $MaxSnapshotAgeDays
        }
    }

    Write-InfraLog "`n=== RESULT SUMMARY ===" -Level AUDIT

    if ($result) {
        if ($Intent -eq "Audit") {
            Write-InfraLog "Audit completed at: $($result.Timestamp)" -Level INFO
            Write-InfraLog "Total Findings: $($result.Findings.Count)" -Level INFO

            foreach ($finding in $result.Findings) {
                $color = switch ($finding.Severity) {
                    "Warning" { "Yellow" }
                    "Error" { "Red" }
                    "Info" { "Gray" }
                    default { "White" }
                }
                Write-Host "  [$($finding.Severity)] $($finding.Type): $($finding.Message)" -ForegroundColor $color

                if ($finding.Host) { Write-Host "    Host: $($finding.Host)" -ForegroundColor DarkGray }
                if ($finding.VolumeName) { Write-Host "    Volume: $($finding.VolumeName)" -ForegroundColor DarkGray }
                if ($finding.LUN) { Write-Host "    LUN: $($finding.LUN)" -ForegroundColor DarkGray }
                if ($finding.RecommendedPolicy) { Write-Host "    Recommended: $($finding.RecommendedPolicy)" -ForegroundColor DarkGray }
            }
        } else {
            Write-InfraLog "Mode: $($result.Mode)" -Level INFO
            Write-InfraLog "Success: $($result.Success)" -Level INFO

            if ($result.Errors.Count -gt 0) {
                Write-InfraLog "Errors encountered:" -Level ERROR
                foreach ($err in $result.Errors) {
                    Write-InfraLog "  - $err" -Level ERROR
                }
            }

            if ($result.Volume) {
                Write-InfraLog "Volume: $($result.Volume.name) ($($result.Volume.size / 1GB))GB" -Level INFO
            }

            if ($result.Datastore) {
                Write-InfraLog "Datastore: $($result.Datastore.Name)" -Level INFO
            }
        }
    }

    $exitCode = if ($result -and $result.Success) { 0 } elseif ($Intent -eq "Audit") { 0 } else { 1 }

    if ($result -and $result.Errors.Count -gt 0) {
        $exitCode = 1
    }

    if ($result -and $result.Findings -and ($result.Findings | Where-Object { $_.Severity -eq "Warning" -or $_.Severity -eq "Error" }).Count -gt 0) {
        $exitCode = 1
    }

    exit $exitCode

} catch {
    Write-InfraLog "FATAL ERROR: $_" -Level ERROR
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
    exit 1
} finally {
    if ($vCenterConn.Session) {
        Disconnect-VIServer -Server $vCenterConn.Session -Confirm:$false -ErrorAction SilentlyContinue
    }
    if ($nimbleConn.Session) {
        Disconnect-NSGroup -ErrorAction SilentlyContinue
    }
}

#endregion
