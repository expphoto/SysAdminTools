#Requires -Modules VMware.PowerCLI
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [switch]$Live,
    [ValidateSet('AZ01', 'AZ99')]
    [string]$Site,
    [string]$VMName,
    [ValidateSet('ScreamTest', 'Full')]
    [string]$DecommissionType
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Config = @{
    vCenterAZ01      = 'az01-vc01'
    vCenterAZ99      = 'az99-vc'
    DnsServer        = 'az01-dc02'
    DecommOU         = 'OU=Decomission,OU=Member Servers,OU=NPLCC,DC=nplcc,DC=com'
    InternalDnsZones = @('nplcc.com', 'nplcc.local')
}

$script:SiteMap = @{
    AZ01 = @{
        DatacenterName   = 'AZ01'
        ClusterName      = 'AZ01-PRD01'
        ResourcePoolName = 'Do_Not_Power_On'
        DatastoreName    = 'AZ01-NMB01-GRVYRD01'
        FolderParent     = '_01 Powered Off'
        FolderName       = 'Archive'
    }
    AZ99 = @{
        DatacenterName   = 'AZ99'
        ClusterName      = 'AZ99 Cluster'
        RPParentName     = 'Archive'
        ResourcePoolName = 'AZ99 - Archive'
        DatastoreName    = 'AZ99-GRVYRD'
        FolderParent     = '_01 Powered Off'
        FolderName       = 'Archive'
    }
}

$script:DryRun = -not $Live
$script:LogDir = Join-Path $env:USERPROFILE 'DecommLogs'
$script:LogFile = $null
$script:ResultFile = $null
$script:TranscriptStarted = $false
$script:viSession = $null
$script:ExitCode = 1
$script:IsScreamTestExit = $false

$script:Execution = [ordered]@{
    SiteLabel         = $null
    SiteConf          = $null
    vCenter           = $null
    RequestedName     = $null
    OriginalName      = $null
    ArchiveName       = $null
    DecommissionType  = $null
    Vm                = $null
    VmId              = $null
    DestinationRP     = $null
    DestinationDS     = $null
    DestinationFolder = $null
    DnsARecords       = @()
    DnsPtrRecords     = @()
    AdComputerDN      = $null
    AdComputerName    = $null
    AdSearchCount     = 0
}

$script:ScriptResult = [ordered]@{
    Timestamp            = $null
    Mode                 = if ($script:DryRun) { 'DRY RUN' } else { 'LIVE' }
    DryRun               = $script:DryRun
    Site                 = $null
    vCenter              = $null
    RequestedName        = $null
    OriginalName         = $null
    ArchiveName          = $null
    DecommType           = $null
    PreflightPassed      = $false
    ScreamTestExit       = $false
    Phase1Succeeded      = $false
    DnsPhaseSucceeded    = $false
    AdPhaseSucceeded     = $false
    DnsRecordsFound      = 0
    DnsARecordsRemoved   = 0
    DnsPtrRecordsRemoved = 0
    AdObjectFound        = $false
    AdObjectDisabled     = $false
    AdObjectMoved        = $false
    LogFile              = $null
    ResultFile           = $null
    Notes                = @()
}

function Write-Step {
    param([string]$Message)
    Write-Host "`n[STEP] $Message" -ForegroundColor Cyan
}

function Write-OK {
    param([string]$Message)
    Write-Host "  [OK] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-Info {
    param([string]$Message)
    Write-Host "  [INFO] $Message" -ForegroundColor Gray
}

function Write-DryRun {
    param([string]$Message)
    Write-Host "  [DRY RUN] Would: $Message" -ForegroundColor DarkYellow
}

function Add-ResultNote {
    param([string]$Message)
    $script:ScriptResult.Notes += $Message
}

function Initialize-Logging {
    if (-not (Test-Path -LiteralPath $script:LogDir)) {
        New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
    }

    $script:LogFile = Join-Path $script:LogDir ("Decomm_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    Start-Transcript -Path $script:LogFile -Append -ErrorAction Stop | Out-Null
    $script:TranscriptStarted = $true
    $script:ScriptResult.LogFile = $script:LogFile
    Write-Host "Transcript: $script:LogFile" -ForegroundColor DarkGray
}

function Disconnect-CurrentVIServer {
    if ($null -eq $script:viSession) {
        return
    }

    try {
        Disconnect-VIServer -Server $script:viSession -Confirm:$false | Out-Null
        Write-Info 'Disconnected from vCenter.'
    } catch {
        Write-Warn "vCenter disconnect reported an error: $($_.Exception.Message)"
        Add-ResultNote "vCenter disconnect reported an error: $($_.Exception.Message)"
    } finally {
        $script:viSession = $null
    }
}

function Stop-Safely {
    Disconnect-CurrentVIServer

    if ($script:TranscriptStarted) {
        try {
            Stop-Transcript | Out-Null
        } catch {
        }
        $script:TranscriptStarted = $false
    }
}

function Invoke-WithRetry {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock,
        [Parameter(Mandatory = $true)]
        [string]$ActionName,
        [int]$MaxAttempts = 2,
        [int]$DelaySeconds = 30
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            return & $ScriptBlock
        } catch {
            if ($attempt -ge $MaxAttempts) {
                throw
            }

            Write-Warn (("{0} failed on attempt {1}/{2}: {3}" -f $ActionName, $attempt, $MaxAttempts, $_.Exception.Message))
            Write-Info "Retrying in $DelaySeconds seconds..."
            Start-Sleep -Seconds $DelaySeconds
        }
    }
}

function Escape-LdapFilterValue {
    param([string]$Value)

    $escaped = $Value.Replace('\', '\5c')
    $escaped = $escaped.Replace('*', '\2a')
    $escaped = $escaped.Replace('(', '\28')
    $escaped = $escaped.Replace(')', '\29')
    # Force string overload; avoids char-conversion errors in some PowerShell runtimes.
    $escaped = $escaped.Replace([string][char]0, '\00')
    return $escaped
}

function Refresh-TargetVM {
    if ($script:DryRun -or [string]::IsNullOrWhiteSpace($script:Execution.VmId)) {
        return $script:Execution.Vm
    }

    $script:Execution.Vm = Get-VM -Id $script:Execution.VmId -ErrorAction Stop
    return $script:Execution.Vm
}

function Get-VmwareToolsState {
    param([Parameter(Mandatory = $true)]$VM)

    try {
        $view = $VM | Get-View -ErrorAction Stop
        return [string]$view.Guest.ToolsStatus
    } catch {
        Add-ResultNote "Could not query VMware Tools state: $($_.Exception.Message)"
        return 'unknown'
    }
}

function Resolve-DestinationObjects {
    $dcResult = @(Get-Datacenter -Name $script:Execution.SiteConf.DatacenterName -ErrorAction Stop)
    if ($dcResult.Count -ne 1) {
        throw "Expected 1 datacenter '$($script:Execution.SiteConf.DatacenterName)'. Found $($dcResult.Count)."
    }
    $datacenter = $dcResult[0]

    $clusterResult = @(Get-Cluster -Name $script:Execution.SiteConf.ClusterName -ErrorAction Stop)
    if ($clusterResult.Count -ne 1) {
        throw "Expected 1 cluster '$($script:Execution.SiteConf.ClusterName)'. Found $($clusterResult.Count)."
    }
    $cluster = $clusterResult[0]

    if ($script:Execution.SiteLabel -eq 'AZ01') {
        $rpResult = @(Get-ResourcePool -Name $script:Execution.SiteConf.ResourcePoolName -Location $cluster -ErrorAction Stop)
    } else {
        $parentRP = @(Get-ResourcePool -Name $script:Execution.SiteConf.RPParentName -Location $cluster -ErrorAction Stop)
        if ($parentRP.Count -ne 1) {
            throw "Expected 1 parent resource pool '$($script:Execution.SiteConf.RPParentName)'. Found $($parentRP.Count)."
        }
        $rpResult = @(Get-ResourcePool -Name $script:Execution.SiteConf.ResourcePoolName -Location $parentRP[0] -ErrorAction Stop)
    }
    if ($rpResult.Count -ne 1) {
        throw "Expected 1 resource pool '$($script:Execution.SiteConf.ResourcePoolName)'. Found $($rpResult.Count)."
    }

    $dsResult = @(Get-Datastore -Name $script:Execution.SiteConf.DatastoreName -ErrorAction Stop)
    if ($dsResult.Count -ne 1) {
        throw "Expected 1 datastore '$($script:Execution.SiteConf.DatastoreName)'. Found $($dsResult.Count)."
    }

    $folderResult = @(
        Get-Folder -Type VM -Location $datacenter -Name $script:Execution.SiteConf.FolderName -ErrorAction Stop |
            Where-Object { $_.Parent.Name -ceq $script:Execution.SiteConf.FolderParent }
    )
    if ($folderResult.Count -ne 1) {
        throw "Expected 1 folder '$($script:Execution.SiteConf.FolderParent) > $($script:Execution.SiteConf.FolderName)'. Found $($folderResult.Count)."
    }

    $script:Execution.DestinationRP = $rpResult[0]
    $script:Execution.DestinationDS = $dsResult[0]
    $script:Execution.DestinationFolder = $folderResult[0]
}

function Get-ReverseLookupTargets {
    param([Parameter(Mandatory = $true)][string]$IPAddress)

    $octets = $IPAddress.Split('.')
    if ($octets.Count -ne 4) {
        throw "'$IPAddress' is not a valid IPv4 address."
    }

    return [pscustomobject]@{
        Zone24  = "{0}.{1}.{2}.in-addr.arpa" -f $octets[2], $octets[1], $octets[0]
        Owner24 = "{0}.{1}.{2}.{3}.in-addr.arpa" -f $octets[3], $octets[2], $octets[1], $octets[0]
        Zone16  = "{0}.{1}.in-addr.arpa" -f $octets[1], $octets[0]
        Owner16 = "{0}.{1}.{2}.{3}.in-addr.arpa" -f $octets[3], $octets[2], $octets[1], $octets[0]
    }
}

function Get-RelevantPtrRecords {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$ARecords,
        [Parameter(Mandatory = $true)]
        [string]$DnsServer
    )

    $ptrRecords = New-Object System.Collections.Generic.List[object]

    foreach ($record in $ARecords) {
        $lookup = Get-ReverseLookupTargets -IPAddress $record.IPAddress
        $expectedFqdn = $record.OwnerName.TrimEnd('.').ToLowerInvariant()
        $filters = @(
            "ContainerName='$($lookup.Zone24)' AND OwnerName='$($lookup.Owner24)'",
            "ContainerName='$($lookup.Zone16)' AND OwnerName='$($lookup.Owner16)'"
        )

        foreach ($filter in $filters) {
            try {
                $matches = @(
                    Get-CimInstance -ComputerName $DnsServer -Namespace 'root\MicrosoftDNS' -ClassName 'MicrosoftDNS_PTRType' -Filter $filter -ErrorAction Stop
                )

                foreach ($match in $matches) {
                    $targetFqdn = $match.PTRDomainName.TrimEnd('.').ToLowerInvariant()
                    if ($targetFqdn -eq $expectedFqdn) {
                        $ptrRecords.Add($match) | Out-Null
                    }
                }
            } catch {
                Write-Info "PTR lookup did not return records for filter [$filter]."
            }
        }
    }

    return @($ptrRecords | Group-Object OwnerName, PTRDomainName | ForEach-Object { $_.Group[0] })
}

function Disable-AdComputerAccount {
    param([Parameter(Mandatory = $true)][string]$DistinguishedName)

    $entry = [adsi]("LDAP://{0}" -f $DistinguishedName)
    $uac = [int]($entry.Properties['userAccountControl'][0])

    if (($uac -band 0x2) -eq 0x2) {
        Write-Info 'AD computer account already disabled.'
        return $false
    }

    $entry.Properties['userAccountControl'][0] = ($uac -bor 0x2)
    $entry.SetInfo()
    return $true
}

function Move-AdObjectToOu {
    param(
        [Parameter(Mandatory = $true)][string]$DistinguishedName,
        [Parameter(Mandatory = $true)][string]$TargetOU
    )

    if ($DistinguishedName -match "^[^,]+,(.+)$" -and $Matches[1] -ceq $TargetOU) {
        Write-Info 'AD computer object is already in the decommission OU.'
        return $false
    }

    $entry = [adsi]("LDAP://{0}" -f $DistinguishedName)
    $destOU = [adsi]("LDAP://{0}" -f $TargetOU)
    $entry.MoveTo($destOU)
    return $true
}

try {
    Initialize-Logging

    Clear-Host
    Write-Host '============================================' -ForegroundColor White
    Write-Host '    VM Decommission Tool  |  Hardened v5    ' -ForegroundColor White
    if ($script:DryRun) {
        Write-Host '   *** DRY RUN - NO CHANGES WILL BE MADE ***' -ForegroundColor DarkYellow
    } else {
        Write-Host '   *** LIVE MODE - CHANGES WILL BE EXECUTED ***' -ForegroundColor Red
    }
    Write-Host '============================================' -ForegroundColor White

    Write-Step 'Pre-flight checks'
    foreach ($key in @('vCenterAZ01', 'vCenterAZ99', 'DnsServer', 'DecommOU')) {
        if ([string]::IsNullOrWhiteSpace($script:Config[$key])) {
            throw "Config value '$key' is blank."
        }
    }
    Write-OK 'Config values are populated.'

    if (-not (Get-Module -ListAvailable -Name VMware.PowerCLI)) {
        throw 'VMware.PowerCLI is not installed. Run Install-Module VMware.PowerCLI -Scope CurrentUser -Force.'
    }
    Import-Module VMware.PowerCLI -ErrorAction Stop
    Write-OK 'VMware.PowerCLI loaded.'

    if (-not (Test-Connection -ComputerName $script:Config.DnsServer -Count 1 -Quiet -ErrorAction SilentlyContinue)) {
        throw "DNS server '$($script:Config.DnsServer)' is not reachable."
    }
    Write-OK "DNS server reachable: $($script:Config.DnsServer)"

    try {
        $ouTest = [adsi]("LDAP://{0}" -f $script:Config.DecommOU)
        if ([string]::IsNullOrWhiteSpace([string]$ouTest.distinguishedName)) {
            throw 'Resolved OU distinguishedName was empty.'
        }
        Write-OK "Decommission OU resolves: $($script:Config.DecommOU)"
    } catch {
        throw "Decommission OU '$($script:Config.DecommOU)' could not be resolved: $($_.Exception.Message)"
    }

    Write-Step 'Site selection'
    if (-not $Site) {
        $choice = $null
        while ($choice -notin @('1', '2')) {
            Write-Host '  Select Site:'
            Write-Host '    [1] AZ01'
            Write-Host '    [2] AZ99'
            $choice = Read-Host '  Choice'
        }
        $Site = if ($choice -eq '1') { 'AZ01' } else { 'AZ99' }
    }

    $script:Execution.SiteLabel = $Site
    $script:Execution.SiteConf = $script:SiteMap[$Site]
    $script:Execution.vCenter = if ($Site -eq 'AZ01') { $script:Config.vCenterAZ01 } else { $script:Config.vCenterAZ99 }
    $script:ScriptResult.Site = $script:Execution.SiteLabel
    $script:ScriptResult.vCenter = $script:Execution.vCenter
    Write-OK "Selected site: $($script:Execution.SiteLabel)"

    Write-Step 'VM identification (exact and case-sensitive)'
    if ([string]::IsNullOrWhiteSpace($VMName)) {
        $firstEntry = (Read-Host '  Enter exact VM name').Trim()
        $secondEntry = (Read-Host '  Re-enter exact VM name to confirm').Trim()
        if ($firstEntry -cne $secondEntry) {
            throw 'VM name confirmation mismatch.'
        }
        $VMName = $firstEntry
    } else {
        $confirmed = (Read-Host ("  Type the VM name '{0}' to confirm" -f $VMName)).Trim()
        if ($confirmed -cne $VMName) {
            throw 'VM name confirmation failed for parameterized VMName.'
        }
    }

    if ([string]::IsNullOrWhiteSpace($VMName)) {
        throw 'VM name cannot be blank.'
    }

    $script:Execution.RequestedName = $VMName
    $script:Execution.ArchiveName = "$VMName | Archive"
    $script:ScriptResult.RequestedName = $script:Execution.RequestedName
    $script:ScriptResult.ArchiveName = $script:Execution.ArchiveName

    Write-Step "Connecting to vCenter: $($script:Execution.vCenter)"
    if ($script:DryRun) {
        Write-DryRun "Connect-VIServer -Server $($script:Execution.vCenter)"
        $script:Execution.OriginalName = $script:Execution.RequestedName
        $script:ScriptResult.OriginalName = $script:Execution.OriginalName
    } else {
        $script:viSession = Connect-VIServer -Server $script:Execution.vCenter -ErrorAction Stop
        Write-OK 'Connected to vCenter.'

        $vmMatches = @(Get-VM | Where-Object { $_.Name -ceq $script:Execution.RequestedName })
        if ($vmMatches.Count -ne 1) {
            throw "Expected exactly one VM named '$($script:Execution.RequestedName)'. Found $($vmMatches.Count)."
        }

        $archiveCollision = @(Get-VM | Where-Object { $_.Name -ceq $script:Execution.ArchiveName })
        if ($archiveCollision.Count -gt 0) {
            throw "Archive target '$($script:Execution.ArchiveName)' already exists."
        }

        $script:Execution.Vm = $vmMatches[0]
        $script:Execution.VmId = $script:Execution.Vm.Id
        $script:Execution.OriginalName = $script:Execution.Vm.Name
        $script:ScriptResult.OriginalName = $script:Execution.OriginalName

        Resolve-DestinationObjects

        Write-OK "VM resolved: $($script:Execution.OriginalName)"
        Write-OK "Destination RP: $($script:Execution.DestinationRP.Name)"
        Write-OK "Destination DS: $($script:Execution.DestinationDS.Name)"
        Write-OK "Destination Folder: $($script:Execution.SiteConf.FolderParent) > $($script:Execution.DestinationFolder.Name)"
    }

    Write-Step 'DNS preflight discovery (configured internal zones only)'
    $dnsRecords = @()
    foreach ($zone in $script:Config.InternalDnsZones) {
        if ($script:DryRun) {
            Write-DryRun "Query A record in zone '$zone' with OwnerName='$($script:Execution.RequestedName).$zone'"
            continue
        }

        $ownerName = "$($script:Execution.OriginalName).$zone"
        try {
            $zoneRecords = @(
                Get-CimInstance -ComputerName $script:Config.DnsServer -Namespace 'root\MicrosoftDNS' -ClassName 'MicrosoftDNS_AType' -Filter "ContainerName='$zone' AND OwnerName='$ownerName'" -ErrorAction Stop
            ) | Where-Object { $_.IPAddress -match '^\d{1,3}(\.\d{1,3}){3}$' }
            $dnsRecords += $zoneRecords
        } catch {
            Write-Warn "Could not query zone '$zone': $($_.Exception.Message)"
            Add-ResultNote "DNS preflight query failed for zone '$zone': $($_.Exception.Message)"
        }
    }

    $script:Execution.DnsARecords = @($dnsRecords)
    $script:ScriptResult.DnsRecordsFound = $script:Execution.DnsARecords.Count

    if (-not $script:DryRun -and $script:Execution.DnsARecords.Count -gt 0) {
        foreach ($rec in $script:Execution.DnsARecords) {
            Write-Info "A: $($rec.OwnerName.TrimEnd('.')) -> $($rec.IPAddress) [zone: $($rec.ContainerName)]"
        }
        $script:Execution.DnsPtrRecords = @(Get-RelevantPtrRecords -ARecords $script:Execution.DnsARecords -DnsServer $script:Config.DnsServer)
        foreach ($ptr in $script:Execution.DnsPtrRecords) {
            Write-Info "PTR: $($ptr.OwnerName.TrimEnd('.')) -> $($ptr.PTRDomainName.TrimEnd('.'))"
        }
    }

    Write-Step 'AD preflight discovery'
    if ($script:DryRun) {
        Write-DryRun "Search ADSI for exact computer object '$($script:Execution.RequestedName)'"
    } else {
        $escapedName = Escape-LdapFilterValue -Value $script:Execution.OriginalName
        $searcher = [adsisearcher]("(&(objectCategory=computer)(name=$escapedName))")
        $searcher.PageSize = 10
        $searcher.SizeLimit = 10
        [void]$searcher.PropertiesToLoad.Add('distinguishedName')
        [void]$searcher.PropertiesToLoad.Add('name')
        [void]$searcher.PropertiesToLoad.Add('userAccountControl')
        $results = $searcher.FindAll()
        try {
            $script:Execution.AdSearchCount = $results.Count
            if ($results.Count -eq 1) {
                $script:Execution.AdComputerDN = [string]$results[0].Properties['distinguishedname'][0]
                $script:Execution.AdComputerName = [string]$results[0].Properties['name'][0]
                $script:ScriptResult.AdObjectFound = $true
                Write-OK "AD object identified: $($script:Execution.AdComputerDN)"
            } elseif ($results.Count -eq 0) {
                Write-Warn 'No AD computer object found. AD phase will be skipped.'
                Add-ResultNote "No AD computer object found for '$($script:Execution.OriginalName)'."
            } else {
                Write-Warn "AD ambiguity detected ($($results.Count) matches). AD phase will be skipped."
                Add-ResultNote "AD search returned $($results.Count) objects; AD phase will be skipped to avoid ambiguity."
            }
        } finally {
            $results.Dispose()
        }
    }

    Write-Host "`n============================================" -ForegroundColor White
    Write-Host 'PREFLIGHT SUMMARY' -ForegroundColor White
    Write-Host '============================================' -ForegroundColor White
    Write-Host "  VM         : $($script:Execution.RequestedName)" -ForegroundColor White
    Write-Host "  Archive As : $($script:Execution.ArchiveName)" -ForegroundColor White
    Write-Host "  Site       : $($script:Execution.SiteLabel)" -ForegroundColor White
    Write-Host "  vCenter    : $($script:Execution.vCenter)" -ForegroundColor White
    Write-Host "  Type       : $(if ($DecommissionType) { $DecommissionType } else { 'interactive' })" -ForegroundColor White
    Write-Host "  DNS Zones  : $($script:Config.InternalDnsZones -join ', ')" -ForegroundColor White
    Write-Host "  AD OU      : $($script:Config.DecommOU)" -ForegroundColor White
    Write-Host "  Mode       : $($script:ScriptResult.Mode)" -ForegroundColor $(if ($script:DryRun) { 'DarkYellow' } else { 'Red' })

    if (-not $script:DryRun) {
        Write-Host "  Power      : $($script:Execution.Vm.PowerState)" -ForegroundColor White
        Write-Host "  Host       : $($script:Execution.Vm.VMHost)" -ForegroundColor White
        Write-Host "  RP         : $($script:Execution.DestinationRP.Name)" -ForegroundColor White
        Write-Host "  Datastore  : $($script:Execution.DestinationDS.Name)" -ForegroundColor White
        Write-Host "  Folder     : $($script:Execution.SiteConf.FolderParent) > $($script:Execution.DestinationFolder.Name)" -ForegroundColor White
        Write-Host "  DNS A      : $($script:Execution.DnsARecords.Count) found" -ForegroundColor White
        Write-Host "  DNS PTR    : $($script:Execution.DnsPtrRecords.Count) validated" -ForegroundColor White
        Write-Host "  AD Matches : $($script:Execution.AdSearchCount)" -ForegroundColor White
    }

    if (-not $DecommissionType) {
        $typeChoice = $null
        while ($typeChoice -notin @('1', '2')) {
            Write-Host "`n  Decommission Type:" -ForegroundColor White
            Write-Host '    [1] Scream Test (disconnect NICs only, keep powered on)' -ForegroundColor White
            Write-Host '    [2] Full Decommission' -ForegroundColor White
            $typeChoice = Read-Host '  Choice'
        }
        $DecommissionType = if ($typeChoice -eq '1') { 'ScreamTest' } else { 'Full' }
    }

    $script:Execution.DecommissionType = $DecommissionType
    $script:ScriptResult.DecommType = $DecommissionType

    if ($script:DryRun) {
        Read-Host "`n[DRY RUN] Press ENTER to simulate execution"
    } else {
        $finalAck = (Read-Host ("`nType DECOMMISSION {0} to proceed" -f $script:Execution.OriginalName)).Trim()
        if ($finalAck -cne ("DECOMMISSION {0}" -f $script:Execution.OriginalName)) {
            throw 'Final confirmation failed.'
        }
    }

    $script:ScriptResult.PreflightPassed = $true

    Write-Step 'Phase 1 - vCenter operations'
    try {
        if ($script:DryRun) {
            Write-DryRun "Disconnect all NICs on '$($script:Execution.RequestedName)'"
        } else {
            $script:Execution.Vm = Refresh-TargetVM
            $nics = @(Get-NetworkAdapter -VM $script:Execution.Vm -ErrorAction Stop)
            foreach ($nic in $nics) {
                if ($PSCmdlet.ShouldProcess($script:Execution.OriginalName, "Disconnect NIC '$($nic.Name)'")) {
                    if ($script:Execution.Vm.PowerState -eq 'PoweredOn') {
                        Set-NetworkAdapter -NetworkAdapter $nic -Connected:$false -StartConnected:$false -Confirm:$false | Out-Null
                        Write-OK "Disconnected NIC and cleared connect-at-power-on: $($nic.Name)"
                    } else {
                        # Powered off VMs cannot toggle live Connected state; set boot-time behavior only.
                        Set-NetworkAdapter -NetworkAdapter $nic -StartConnected:$false -Confirm:$false | Out-Null
                        Write-OK "VM is powered off; cleared connect-at-power-on: $($nic.Name)"
                    }
                }
            }
        }

        if ($script:Execution.DecommissionType -eq 'ScreamTest') {
            $script:IsScreamTestExit = $true
            $script:ScriptResult.ScreamTestExit = $true
            $script:ScriptResult.Phase1Succeeded = $true
            Add-ResultNote 'Scream test selected: NICs disconnected, no rename/shutdown/migration performed.'
            Write-OK 'Scream test path complete.'
        } else {
            if ($script:DryRun) {
                Write-DryRun "Rename '$($script:Execution.RequestedName)' -> '$($script:Execution.ArchiveName)'"
                Write-DryRun "Attempt graceful guest shutdown and verify PoweredOff"
                Write-DryRun "Move VM to RP '$($script:Execution.SiteConf.ResourcePoolName)' and DS '$($script:Execution.SiteConf.DatastoreName)'"
                Write-DryRun "Move VM to folder '$($script:Execution.SiteConf.FolderParent) > $($script:Execution.SiteConf.FolderName)'"
            } else {
                if ($PSCmdlet.ShouldProcess($script:Execution.OriginalName, "Rename VM to '$($script:Execution.ArchiveName)'")) {
                    Set-VM -VM $script:Execution.Vm -Name $script:Execution.ArchiveName -Confirm:$false | Out-Null
                    $script:Execution.Vm = Refresh-TargetVM
                    Write-OK "Renamed VM to '$($script:Execution.ArchiveName)'"
                }

                $toolsState = Get-VmwareToolsState -VM $script:Execution.Vm
                if ($script:Execution.Vm.PowerState -eq 'PoweredOn' -and $toolsState -eq 'guestToolsRunning') {
                    if ($PSCmdlet.ShouldProcess($script:Execution.ArchiveName, 'Shut down guest OS')) {
                        Stop-VMGuest -VM $script:Execution.Vm -Confirm:$false | Out-Null
                        $elapsed = 0
                        while ($elapsed -lt 300) {
                            Start-Sleep -Seconds 10
                            $elapsed += 10
                            $script:Execution.Vm = Refresh-TargetVM
                            if ($script:Execution.Vm.PowerState -eq 'PoweredOff') {
                                break
                            }
                        }
                    }
                } elseif ($script:Execution.Vm.PowerState -eq 'PoweredOn') {
                    Add-ResultNote "VMware Tools not running ($toolsState). Graceful shutdown skipped; force power off will be required."
                }

                $script:Execution.Vm = Refresh-TargetVM
                if ($script:Execution.Vm.PowerState -ne 'PoweredOff') {
                    if ($PSCmdlet.ShouldProcess($script:Execution.ArchiveName, 'Force power off VM')) {
                        Stop-VM -VM $script:Execution.Vm -Confirm:$false -Kill:$false | Out-Null
                        Start-Sleep -Seconds 5
                    }
                    $script:Execution.Vm = Refresh-TargetVM
                    if ($script:Execution.Vm.PowerState -ne 'PoweredOff') {
                        throw "VM '$($script:Execution.ArchiveName)' is still powered on."
                    }
                }
                Write-OK 'VM is powered off.'

                if ($PSCmdlet.ShouldProcess($script:Execution.ArchiveName, "Move VM to RP '$($script:Execution.DestinationRP.Name)' and DS '$($script:Execution.DestinationDS.Name)'")) {
                    Invoke-WithRetry -ActionName 'Move-VM to archive RP/datastore' -MaxAttempts 2 -DelaySeconds 30 -ScriptBlock {
                        Move-VM -VM $script:Execution.Vm -Destination $script:Execution.DestinationRP -Datastore $script:Execution.DestinationDS -Confirm:$false -ErrorAction Stop | Out-Null
                    }
                }
                $script:Execution.Vm = Refresh-TargetVM
                Write-OK 'Migrated VM to archive RP/datastore.'

                if ($PSCmdlet.ShouldProcess($script:Execution.ArchiveName, "Move VM to folder '$($script:Execution.SiteConf.FolderParent) > $($script:Execution.DestinationFolder.Name)'")) {
                    Invoke-WithRetry -ActionName 'Move-VM to archive folder' -MaxAttempts 2 -DelaySeconds 30 -ScriptBlock {
                        Move-VM -VM $script:Execution.Vm -InventoryLocation $script:Execution.DestinationFolder -Confirm:$false -ErrorAction Stop | Out-Null
                    }
                }
                $script:Execution.Vm = Refresh-TargetVM
                Write-OK 'Moved VM to archive folder.'
            }

            $script:ScriptResult.Phase1Succeeded = $true
            Write-OK 'Phase 1 complete.'
        }
    } catch {
        $message = "Phase 1 (vCenter) failed: $($_.Exception.Message)"
        Write-Warn $message
        Add-ResultNote $message
        Add-ResultNote 'DNS and AD phases intentionally blocked after vCenter failure.'
    }

    if (-not $script:IsScreamTestExit) {
        Write-Step 'Phase 2 - DNS cleanup'
        if (-not $script:ScriptResult.Phase1Succeeded) {
            Write-Warn 'Skipping DNS phase because vCenter phase did not complete successfully.'
        } else {
            try {
                if ($script:Execution.DnsARecords.Count -eq 0) {
                    Write-Info 'No matching DNS A records found in configured internal zones.'
                }

                foreach ($record in $script:Execution.DnsARecords) {
                    $display = "$($record.OwnerName.TrimEnd('.')) -> $($record.IPAddress)"
                    if ($script:DryRun) {
                        Write-DryRun "Remove DNS A record: $display"
                    } else {
                        if ($PSCmdlet.ShouldProcess($display, 'Remove DNS A record')) {
                            Remove-CimInstance -CimInstance $record -ErrorAction Stop
                            $script:ScriptResult.DnsARecordsRemoved++
                            Write-OK "Removed DNS A: $display"
                        }
                    }
                }

                foreach ($ptr in $script:Execution.DnsPtrRecords) {
                    $display = "$($ptr.OwnerName.TrimEnd('.')) -> $($ptr.PTRDomainName.TrimEnd('.'))"
                    if ($script:DryRun) {
                        Write-DryRun "Remove DNS PTR record: $display"
                    } else {
                        if ($PSCmdlet.ShouldProcess($display, 'Remove DNS PTR record')) {
                            Remove-CimInstance -CimInstance $ptr -ErrorAction Stop
                            $script:ScriptResult.DnsPtrRecordsRemoved++
                            Write-OK "Removed DNS PTR: $display"
                        }
                    }
                }

                $script:ScriptResult.DnsPhaseSucceeded = $true
                Write-OK 'Phase 2 complete.'
            } catch {
                $message = "DNS phase failed: $($_.Exception.Message)"
                Write-Warn $message
                Add-ResultNote $message
            }
        }

        Write-Step 'Phase 3 - Active Directory'
        if (-not $script:ScriptResult.Phase1Succeeded) {
            Write-Warn 'Skipping AD phase because vCenter phase did not complete successfully.'
        } else {
            try {
                if ([string]::IsNullOrWhiteSpace($script:Execution.AdComputerDN) -or $script:Execution.AdSearchCount -ne 1) {
                    Write-Warn 'Skipping AD phase because preflight did not identify exactly one AD object.'
                    Add-ResultNote 'AD phase skipped due to missing or ambiguous AD object.'
                } else {
                    if ($script:DryRun) {
                        Write-DryRun "Disable AD computer account '$($script:Execution.AdComputerDN)'"
                        Write-DryRun "Move AD computer object to '$($script:Config.DecommOU)'"
                    } else {
                        if ($PSCmdlet.ShouldProcess($script:Execution.AdComputerDN, 'Disable AD computer account')) {
                            $changed = Disable-AdComputerAccount -DistinguishedName $script:Execution.AdComputerDN
                            $script:ScriptResult.AdObjectDisabled = $true
                            if ($changed) {
                                Write-OK 'AD computer account disabled.'
                            }
                        }

                        if ($PSCmdlet.ShouldProcess($script:Execution.AdComputerDN, "Move AD computer object to '$($script:Config.DecommOU)'")) {
                            $moved = Move-AdObjectToOu -DistinguishedName $script:Execution.AdComputerDN -TargetOU $script:Config.DecommOU
                            $script:ScriptResult.AdObjectMoved = $true
                            if ($moved) {
                                Write-OK 'AD computer object moved to decommission OU.'
                            }
                        }
                    }

                    $script:ScriptResult.AdPhaseSucceeded = $true
                    Write-OK 'Phase 3 complete.'
                }
            } catch {
                $message = "AD phase failed: $($_.Exception.Message)"
                Write-Warn $message
                Add-ResultNote $message
            }
        }
    } else {
        Add-ResultNote 'DNS and AD phases intentionally skipped for scream test path.'
    }

    Write-Host "`n============================================" -ForegroundColor Green
    Write-Host 'FINAL SUMMARY' -ForegroundColor Green
    Write-Host '============================================' -ForegroundColor Green
    Write-Host "  VM Name           : $($script:ScriptResult.OriginalName)" -ForegroundColor White
    Write-Host "  Archive Name      : $($script:ScriptResult.ArchiveName)" -ForegroundColor White
    Write-Host "  Site              : $($script:ScriptResult.Site)" -ForegroundColor White
    Write-Host "  Mode              : $($script:ScriptResult.Mode)" -ForegroundColor White
    Write-Host "  Type              : $($script:ScriptResult.DecommType)" -ForegroundColor White
    Write-Host "  Preflight Passed  : $($script:ScriptResult.PreflightPassed)" -ForegroundColor White
    Write-Host "  vCenter Succeeded : $($script:ScriptResult.Phase1Succeeded)" -ForegroundColor White
    Write-Host "  DNS Succeeded     : $($script:ScriptResult.DnsPhaseSucceeded)" -ForegroundColor White
    Write-Host "  AD Succeeded      : $($script:ScriptResult.AdPhaseSucceeded)" -ForegroundColor White
    Write-Host "  A Records Removed : $($script:ScriptResult.DnsARecordsRemoved)" -ForegroundColor White
    Write-Host "  PTR Removed       : $($script:ScriptResult.DnsPtrRecordsRemoved)" -ForegroundColor White
    Write-Host "  AD Disabled       : $($script:ScriptResult.AdObjectDisabled)" -ForegroundColor White
    Write-Host "  AD Moved          : $($script:ScriptResult.AdObjectMoved)" -ForegroundColor White

    Write-Host "`nManual follow-ups:" -ForegroundColor Yellow
    Write-Host '  [ ] Remove the node from SolarWinds if still managed.' -ForegroundColor White
    Write-Host '  [ ] Remove the device from Automox if present.' -ForegroundColor White
    Write-Host '  [ ] Remove any public DNS records if present.' -ForegroundColor White
    Write-Host '  [ ] Update documentation mentioning this server.' -ForegroundColor White

    if ($script:ScriptResult.Notes.Count -gt 0) {
        Write-Host "`nNotes:" -ForegroundColor White
        foreach ($note in $script:ScriptResult.Notes) {
            Write-Host "  - $note" -ForegroundColor Gray
        }
    }

    $script:ScriptResult.Timestamp = Get-Date
    $script:ResultFile = $script:LogFile -replace '\.log$', '_result.json'
    $script:ScriptResult.ResultFile = $script:ResultFile
    $script:ScriptResult | ConvertTo-Json -Depth 6 | Out-File -FilePath $script:ResultFile -Encoding utf8
    Write-Host "`nResult JSON: $script:ResultFile" -ForegroundColor DarkGray

    $script:ExitCode = if ($script:ScriptResult.PreflightPassed -and $script:ScriptResult.Phase1Succeeded) { 0 } else { 1 }
} catch {
    $fatalMessage = if ([string]::IsNullOrWhiteSpace($_.Exception.Message)) {
        $_.ToString()
    } else {
        $_.Exception.Message
    }
    Write-Host "`n[FATAL] $fatalMessage" -ForegroundColor Red
    if (-not [string]::IsNullOrWhiteSpace($_.InvocationInfo.PositionMessage)) {
        Write-Host $_.InvocationInfo.PositionMessage -ForegroundColor DarkRed
    }
    Add-ResultNote "Fatal error: $fatalMessage"
    Add-ResultNote ("Fatal detail: {0}" -f (($_ | Out-String).Trim()))

    if ($null -ne $script:LogFile) {
        try {
            $script:ScriptResult.Timestamp = Get-Date
            $script:ResultFile = $script:LogFile -replace '\.log$', '_result.json'
            $script:ScriptResult.ResultFile = $script:ResultFile
            $script:ScriptResult | ConvertTo-Json -Depth 6 | Out-File -FilePath $script:ResultFile -Encoding utf8
            Write-Host "Result JSON: $script:ResultFile" -ForegroundColor DarkGray
        } catch {
            Write-Warn "Could not write result JSON after fatal error: $($_.Exception.Message)"
        }
    }

    $script:ExitCode = 1
} finally {
    Stop-Safely
}

exit $script:ExitCode
