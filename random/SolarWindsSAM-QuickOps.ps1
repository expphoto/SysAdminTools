#Requires -Modules SwisPowerShell

<#
.SYNOPSIS
SolarWinds SAM QuickOps - Interactive Manager for SolarWinds SAM

.DESCRIPTION
Interactive TUI application for managing SolarWinds SAM without web console.
Features: Node search, template management, monitor deployment, maintenance mode, alert management, bulk operations, export, maintenance calendar.

.PARAMETER SwisServer
SolarWinds SWIS server (required for non-interactive mode)

.PARAMETER UserName
Username for SolarWinds (optional for interactive mode)

.PARAMETER Password
Password for SolarWinds (optional for interactive mode)

.EXAMPLE
# Run in interactive mode
.\SolarWindsSAM-QuickOps.ps1

.EXAMPLE
# Connect to specific server interactively
.\SolarWindsSAM-QuickOps.ps1 -SwisServer "solarwinds.domain.local"

.NOTES
Requires: SwisPowerShell module
Author: Infrastructure Team
Version: 2.0 - Phase 2 Enhanced
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$SwisServer = $global:SOLARWINDS_SERVER,

    [Parameter(Mandatory = $false)]
    [string]$UserName,

    [Parameter(Mandatory = $false)]
    [securestring]$Password
,
    [Parameter(Mandatory = $false)]
    [switch]$DryRun
,
    [Parameter(Mandatory = $false)]
    [switch]$TrustSwisCert
,
    [Parameter(Mandatory = $false)]
    [int]$SwisCertPort = 17778
)

$ErrorActionPreference = "Stop"

#region Helper Functions

function Write-SWLog {
    param(
        [string]$Message,
        [ValidateSet("INFO", "WARNING", "ERROR", "DEBUG", "SUCCESS", "HEADER", "PROMPT")]
        [string]$Level = "INFO",
        [switch]$NoNewLine
    )

    $color = switch ($Level) {
        "INFO" { "White" }
        "WARNING" { "Yellow" }
        "ERROR" { "Red" }
        "DEBUG" { "Gray" }
        "SUCCESS" { "Green" }
        "HEADER" { "Cyan" }
        "PROMPT" { "Magenta" }
        default { "White" }
    }

    $timestamp = if ($Level -notin @("HEADER", "PROMPT")) { "[$(Get-Date -Format 'HH:mm:ss')] " } else { "" }
    
    if ($NoNewLine) {
        Write-Host "$timestamp$Message" -ForegroundColor $color -NoNewline
    } else {
        Write-Host "$timestamp$Message" -ForegroundColor $color
    }
}

function Get-SWServerCertificate {
    param(
        [Parameter(Mandatory = $true)]
        [string]$HostName,

        [Parameter(Mandatory = $false)]
        [int]$Port = 17778,

        [Parameter(Mandatory = $false)]
        [switch]$Install
    )

    try {
        Write-SWLog "Fetching certificate from ${HostName}:$Port" -Level INFO
        $tcp = New-Object Net.Sockets.TcpClient($HostName, $Port)
        $ssl = New-Object Net.Security.SslStream($tcp.GetStream(), $false, ({ $true }))
        $ssl.AuthenticateAsClient($HostName)

        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($ssl.RemoteCertificate)

        $sanExtension = $cert.Extensions | Where-Object { $_.Oid.FriendlyName -eq "Subject Alternative Name" } | Select-Object -First 1
        $sanText = if ($sanExtension) { $sanExtension.Format($true) } else { "" }
        $subjectMatches = $cert.Subject -match "CN=$HostName" -or $cert.Subject -match "CN=\*\.$HostName"
        $sanMatches = $false
        if ($sanText) {
            $sanMatches = ($sanText -match "DNS Name=\s*$HostName(\s|$)") -or ($sanText -match "DNS Name=\s*\*\.$HostName(\s|$)")
        }

        if (-not ($subjectMatches -or $sanMatches)) {
            Write-SWLog "WARNING: Certificate name does not appear to match host '$HostName'" -Level WARNING
            if ($sanText) {
                Write-SWLog "Cert SANs: $sanText" -Level WARNING
            } else {
                Write-SWLog "Cert Subject: $($cert.Subject)" -Level WARNING
            }
        }

        $path = Join-Path -Path $env:TEMP -ChildPath "$HostName-$Port.cer"
        [IO.File]::WriteAllBytes($path, $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert))

        Write-SWLog "Cert Subject: $($cert.Subject)" -Level INFO
        Write-SWLog "Thumbprint: $($cert.Thumbprint)" -Level INFO
        Write-SWLog "Expires: $($cert.NotAfter)" -Level INFO
        Write-SWLog "Saved cert to: $path" -Level INFO

        if ($Install) {
            try {
                $store = New-Object System.Security.Cryptography.X509Certificates.X509Store("Root", "LocalMachine")
                $store.Open("ReadWrite")
                $store.Add($cert)
                $store.Close()
                Write-SWLog "Installed cert to LocalMachine\Root" -Level SUCCESS
            } catch {
                Write-SWLog "Failed to install to LocalMachine\Root, trying CurrentUser\Root" -Level WARNING
                $store = New-Object System.Security.Cryptography.X509Certificates.X509Store("Root", "CurrentUser")
                $store.Open("ReadWrite")
                $store.Add($cert)
                $store.Close()
                Write-SWLog "Installed cert to CurrentUser\Root" -Level SUCCESS
            }
        }

        $ssl.Close()
        $tcp.Close()

        return $cert
    } catch {
        Write-SWLog "Failed to fetch/install certificate: $_" -Level ERROR
        return $null
    }
}

function Get-SWConnection {
    param(
        [string]$Server,
        [string]$User,
        [securestring]$SecurePassword
    )

    try {
        if ($User -and $SecurePassword) {
            Write-SWLog "Connecting to SolarWinds: $Server" -Level INFO
            $credential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $User, $SecurePassword
            $swis = Connect-Swis -Hostname $Server -Credential $credential -ErrorAction Stop
        } else {
            Write-SWLog "Connecting to SolarWinds: $Server (trusted)" -Level INFO
            $swis = Connect-Swis -Hostname $Server -Trusted -ErrorAction Stop
        }

        $script:SWServer = $Server
        $script:SWLastRefresh = Get-Date
        Write-SWLog "Connected successfully" -Level SUCCESS
        return @{ Connected = $true; Connection = $swis; Server = $Server }
    } catch {
        Write-SWLog "Failed to connect: $_" -Level ERROR
        return @{ Connected = $false; Connection = $null; Server = $Server }
    }
}

function Get-SWDashboardStats {
    param([object]$Swis)

    try {
        $nodesQuery = @"
        SELECT 
            COUNT(*) AS TotalNodes,
            SUM(CASE WHEN Status = 1 THEN 1 ELSE 0 END) AS UpNodes,
            SUM(CASE WHEN Status = 2 THEN 1 ELSE 0 END) AS DownNodes,
            SUM(CASE WHEN Status = 3 THEN 1 ELSE 0 END) AS WarningNodes,
            SUM(CASE WHEN Unmanaged = 1 THEN 1 ELSE 0 END) AS UnmanagedNodes,
            AVG(CPULoad) AS AvgCPU,
            AVG(AvgResponseTime) AS AvgResponseTime
        FROM Orion.Nodes
"@

        $nodesStats = Get-SwisData -SwisConnection $Swis -Query $nodesQuery

        $appsQuery = @"
        SELECT
            COUNT(*) AS TotalApps,
            SUM(CASE WHEN Status = 14 THEN 1 ELSE 0 END) AS UpApps,
            SUM(CASE WHEN Status = 2 THEN 1 ELSE 0 END) AS DownApps,
            SUM(CASE WHEN Status = 3 THEN 1 ELSE 0 END) AS WarningApps
        FROM Orion.APM.Application
"@

        $appsStats = Get-SwisData -SwisConnection $Swis -Query $appsQuery

        $alertsQuery = @"
        SELECT
            COUNT(*) AS TotalAlerts,
            SUM(CASE WHEN Severity = 2 THEN 1 ELSE 0 END) AS CriticalAlerts,
            SUM(CASE WHEN Severity = 3 THEN 1 ELSE 0 END) AS WarningAlerts,
            SUM(CASE WHEN Acknowledged = 0 THEN 1 ELSE 0 END) AS UnacknowledgedAlerts
        FROM Orion.AlertActive aa
        JOIN Orion.AlertConfigurations ac ON aa.AlertObjectID = ac.AlertID
"@

        $alertsStats = Get-SwisData -SwisConnection $Swis -Query $alertsQuery

        $maintenanceQuery = @"
        SELECT NodeID, Caption, UnmanageFrom, UnmanageUntil
        FROM Orion.Nodes
        WHERE Unmanaged = 1 AND UnmanageUntil > GetUtcDate()
"@

        $maintenanceNodes = Get-SwisData -SwisConnection $Swis -Query $maintenanceQuery

        return @{
            Nodes = $nodesStats
            Apps = $appsStats
            Alerts = $alertsStats
            MaintenanceCount = $maintenanceNodes.Count
            MaintenanceNodes = $maintenanceNodes
        }
    } catch {
        Write-SWLog "Failed to get dashboard stats: $_" -Level ERROR
        return $null
    }
}

function Get-SWNodes {
    param(
        [object]$Swis,
        [string]$SearchTerm = "",
        [string]$StatusFilter = "All",
        [int]$MaxResults = 50
    )

    try {
        $query = @"
        SELECT NodeID, Caption, NodeName, IP_Address, Status, StatusLED,
               Vendor, MachineType, Unmanaged, UnmanageFrom, UnmanageUntil,
               ObjectSubType
        FROM Orion.Nodes
        WHERE 1=1
"@

        if ($SearchTerm) {
            $query += " AND (NodeName LIKE @Search OR Caption LIKE @Search OR IP_Address LIKE @Search)"
        }

        if ($StatusFilter -ne "All") {
            $statusValue = switch ($StatusFilter) {
                "Up" { "1" }
                "Down" { "2" }
                "Warning" { "3" }
                "Unmanaged" { "Unmanaged = 1" }
                default { "1" }
            }
            
            if ($StatusFilter -eq "Unmanaged") {
                $query += " AND Unmanaged = 1"
            } else {
                $query += " AND Status = $statusValue"
            }
        }

        $query += " ORDER BY Caption LIMIT $MaxResults"

        $params = @{}
        if ($SearchTerm) {
            $params = @{ Search = "%$SearchTerm%" }
        }

        $results = Get-SwisData -SwisConnection $Swis -Query $query -Parameters $params
        return $results
    } catch {
        Write-SWLog "Failed to search nodes: $_" -Level ERROR
        return @()
    }
}

function Set-SWMaintenance {
    param(
        [object]$Swis,
        [int]$NodeId,
        [int]$Hours = 2,
        [bool]$IsRelative = $false
    )

    try {
        if ($IsRelative) {
            $now = [DateTime]::UtcNow
            $end = $now.AddHours($Hours)
            Invoke-SwisVerb -SwisConnection $Swis -EntityName "Orion.Nodes" -Verb "Unmanage" -Arguments @("N:$NodeId", $now, $end, $true)
        } else {
            $start = [DateTime]::UtcNow
            $end = $start.AddHours($Hours)
            Invoke-SwisVerb -SwisConnection $Swis -EntityName "Orion.Nodes" -Verb "Unmanage" -Arguments @("N:$NodeId", $start, $end, $false)
        }

        return @{ Success = $true }
    } catch {
        Write-SWLog "Failed to set maintenance: $_" -Level ERROR
        return @{ Success = $false; Error = $_ }
    }
}

function Remove-SWMaintenance {
    param(
        [object]$Swis,
        [int]$NodeId
    )

    try {
        Invoke-SwisVerb -SwisConnection $Swis -EntityName "Orion.Nodes" -Verb "Remanage" -Arguments @("N:$NodeId")
        return @{ Success = $true }
    } catch {
        Write-SWLog "Failed to remove maintenance: $_" -Level ERROR
        return @{ Success = $false; Error = $_ }
    }
}

function Get-SWTemplates {
    param([object]$Swis)

    try {
        $query = @"
        SELECT ApplicationTemplateID, Name, Description, Uri
        FROM Orion.APM.ApplicationTemplate
        ORDER BY Name
"@

        $results = Get-SwisData -SwisConnection $Swis -Query $query
        return $results
    } catch {
        Write-SWLog "Failed to get templates: $_" -Level ERROR
        return @()
    }
}

function Get-SWApplications {
    param(
        [object]$Swis,
        [int]$NodeId = 0
    )

    try {
        $query = @"
        SELECT a.ApplicationID, a.Name, a.Status, a.Availability,
               at.Name AS TemplateName, a.NodeID,
               n.Caption AS NodeName
        FROM Orion.APM.Application a
        JOIN Orion.APM.ApplicationTemplate at ON a.ApplicationTemplateID = at.ApplicationTemplateID
        JOIN Orion.Nodes n ON a.NodeID = n.NodeID
"@

        if ($NodeId -gt 0) {
            $query += " WHERE a.NodeID = $NodeId"
        }

        $query += " ORDER BY a.Name"

        $results = Get-SwisData -SwisConnection $Swis -Query $query
        return $results
    } catch {
        Write-SWLog "Failed to get applications: $_" -Level ERROR
        return @()
    }
}

function Assign-SWTemplate {
    param(
        [object]$Swis,
        [int]$NodeId,
        [int]$TemplateId
    )

    try {
        $appProps = @{
            NodeID = $NodeId
            ApplicationTemplateID = $TemplateId
        }

        $app = Invoke-SwisVerb -SwisConnection $Swis -EntityName "Orion.APM.Application" -Verb "CreateApplication" -Arguments @($appProps)
        Write-SWLog "Assigned template to node successfully" -Level SUCCESS
        return @{ Success = $true; Application = $app }
    } catch {
        Write-SWLog "Failed to assign template: $_" -Level ERROR
        return @{ Success = $false; Error = $_ }
    }
}

function Get-SWAlerts {
    param(
        [object]$Swis,
        [string]$SeverityFilter = "All",
        [bool]$AcknowledgedOnly = $false
    )

    try {
        $query = @"
        SELECT aa.AlertActiveID, ao.AlertObjectID, ao.EntityCaption,
               ao.EntityType, aa.Acknowledged, aa.AcknowledgedBy,
               ac.Name AS AlertName, ac.Severity,
               aa.TriggeredDateTime
        FROM Orion.AlertActive aa
        JOIN Orion.AlertObjects ao ON aa.AlertObjectID = ao.AlertObjectID
        JOIN Orion.AlertConfigurations ac ON ao.AlertID = ac.AlertID
        WHERE 1=1
"@

        if ($SeverityFilter -ne "All") {
            $severityValue = switch ($SeverityFilter) {
                "Critical" { "2" }
                "Warning" { "3" }
                "Info" { "4" }
                default { "2" }
            }
            $query += " AND ac.Severity = $severityValue"
        }

        if ($AcknowledgedOnly) {
            $query += " AND aa.Acknowledged = 0"
        }

        $query += " ORDER BY aa.TriggeredDateTime DESC"

        $results = Get-SwisData -SwisConnection $Swis -Query $query
        return $results
    } catch {
        Write-SWLog "Failed to get alerts: $_" -Level ERROR
        return @()
    }
}

function Acknowledge-SWAlerts {
    param(
        [object]$Swis,
        [int[]]$AlertObjectIds,
        [string]$Note = ""
    )

    try {
        Invoke-SwisVerb -SwisConnection $Swis -EntityName "Orion.AlertActive" -Verb "Acknowledge" -Arguments @($AlertObjectIds, $Note)
        Write-SWLog "Acknowledged $($AlertObjectIds.Count) alert(s)" -Level SUCCESS
        return @{ Success = $true }
    } catch {
        Write-SWLog "Failed to acknowledge alerts: $_" -Level ERROR
        return @{ Success = $false; Error = $_ }
    }
}

function New-SWTemplate {
    param(
        [object]$Swis,
        [string]$TemplateName,
        [string]$Description,
        [hashtable[]]$Components
    )

    try {
        $templateProps = @{
            Name = $TemplateName
            Description = $Description
        }

        $templateUri = Invoke-SwisVerb -SwisConnection $Swis -EntityName "Orion.APM.Application" -Verb "CreateApplicationTemplate" -Arguments @($templateProps, $false)
        $templateId = ($templateUri -split '/')[4]
        Write-SWLog "Created template: $TemplateName (ID: $templateId)" -Level SUCCESS

        foreach ($component in $Components) {
            Invoke-SwisVerb -SwisConnection $Swis -EntityName "Orion.APM.ApplicationTemplate" -Verb "CreateComponent" -Arguments @($templateId, $component) | Out-Null
            Write-SWLog "  Added component: $($component.Name)" -Level INFO
        }

        return @{ Success = $true; TemplateId = $templateId }
    } catch {
        Write-SWLog "Failed to create template: $_" -Level ERROR
        return @{ Success = $false; Error = $_ }
    }
}

#endregion

#region Multi-Select Interface

function Get-SWSelection {
    param(
        [array]$Items,
        [string]$Title = "Select an item",
        [string]$DisplayProperty = "Name",
        [bool]$AllowMultiple = $false,
        [bool]$AllowAll = $false,
        [array]$PreSelected = @()
    )

    Clear-Host
    Write-SWLog "=== $Title ===" -Level HEADER
    Write-SWLog ""
    Write-SWLog "Controls: SPACE = Select/Deselect | ENTER = Confirm | A = All | 0 = Back" -Level PROMPT
    Write-SWLog ""

    $selectedIndices = @{}

    for ($i = 0; $i -lt $PreSelected.Count; $i++) {
        $selectedIndices[$i] = $true
    }

    function Show-SelectionList {
        param([array]$ItemsList, [hashtable]$SelectedMap)

        Clear-Host
        Write-SWLog "=== $Title ===" -Level HEADER
        Write-SWLog ""
        Write-SWLog "Controls: SPACE = Select/Deselect | ENTER = Confirm | A = All | 0 = Back" -Level PROMPT
        Write-SWLog ""

        for ($i = 0; $i -lt $ItemsList.Count; $i++) {
            $displayValue = if ($ItemsList[$i].PSObject.Properties[$DisplayProperty]) { $ItemsList[$i].$DisplayProperty } else { $ItemsList[$i] }
            $isSelected = $SelectedMap.ContainsKey($i) -and $SelectedMap[$i]
            $selector = if ($isSelected) { "[X]" } else { "[ ]" }
            $selectColor = if ($isSelected) { "Cyan" } else { "Gray" }

            if ($ItemsList[$i].Status) {
                $statusText = switch ($ItemsList[$i].Status) {
                    1 { "[Up]" }
                    2 { "[Down]" }
                    3 { "[Warn]" }
                    14 { "[Up]" }
                    default { "[$($ItemsList[$i].Status)]" }
                }
                $statusColor = switch ($statusText) {
                    "[Up]" { "Green" }
                    "[Down]" { "Red" }
                    "[Warn]" { "Yellow" }
                    default { "Gray" }
                }
                Write-Host "  $selector " -NoNewline -ForegroundColor $selectColor
                Write-Host " $($i + 1). $displayValue" -NoNewline -ForegroundColor White
                Write-Host " $statusText" -ForegroundColor $statusColor
            } else {
                Write-Host "  $selector " -NoNewline -ForegroundColor $selectColor
                Write-Host "  $($i + 1). $displayValue" -ForegroundColor White
            }
        }

        if ($AllowAll) {
            Write-Host "  A. Select/Deselect All" -ForegroundColor Cyan
        }

        Write-Host "  0. Back" -ForegroundColor Gray
        Write-SWLog ""
    }

    Show-SelectionList -ItemsList $Items -SelectedMap $selectedIndices

    :mainMenuLoop do {
        $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown").Key

        switch ($key) {
            { $_ -eq "Enter" } {
                $selected = @()
                for ($i = 0; $i -lt $Items.Count; $i++) {
                    if ($selectedIndices.ContainsKey($i) -and $selectedIndices[$i]) {
                        $selected += $Items[$i]
                    }
                }
                return $selected
            }

            { $_ -eq "Spacebar" } {
                $cursor = $Host.UI.RawUI.CursorPosition
                $firstSelected = $null
                for ($i = 0; $i -lt $Items.Count; $i++) {
                    if (-not $selectedIndices.ContainsKey($i)) {
                        $selectedIndices[$i] = $true
                        $firstSelected = $i
                        break
                    }
                }

                if ($null -ne $firstSelected) {
                    for ($i = 0; $i -lt $Items.Count; $i++) {
                        $selectedIndices[$i] = $true
                    }
                }

                Show-SelectionList -ItemsList $Items -SelectedMap $selectedIndices
            }

            { $_ -eq "A" } {
                if ($AllowAll) {
                    $allSelected = $true
                    for ($i = 0; $i -lt $Items.Count; $i++) {
                        $selectedIndices[$i] = $true
                    }
                    Show-SelectionList -ItemsList $Items -SelectedMap $selectedIndices
                }
            }

            { $_ -eq "0" } {
                return $null
            }

            default {
                Write-Host "`a" -NoNewline
                Start-Sleep -Milliseconds 100
            }
        }
    } while ($true)
}

#endregion

#region Menu Functions

<# LEGACY MENU BLOCK (replaced due to corrupted characters)
function Show-MainMenu {
    Clear-Host

    Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║        SolarWinds SAM QuickOps - Interactive Manager V2.0               ║" -ForegroundColor Cyan
    Write-Host "╚═════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""

    if ($script:SWConnection) {
        Write-SWLog "Connected to: $script:SWServer" -Level SUCCESS
        if ($script:SWLastRefresh) {
            $refreshAge = ((Get-Date) - $script:SWLastRefresh).TotalMinutes
            Write-SWLog "Last refresh: $($refreshAge.ToString('F0')) min ago" -Level DEBUG
        }
    } else {
        Write-SWLog "Not connected" -Level ERROR
    }

    Write-Host ""

    if ($script:SWConnection) {
        $stats = Get-SWDashboardStats -Swis $script:SWConnection
        if ($stats) {
            Write-SWLog "DASHBOARD SUMMARY" -Level HEADER
            Write-SWLog "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -Level HEADER
            $nodeUpPct = [math]::Round(($stats.Nodes.UpNodes / $stats.Nodes.TotalNodes) * 100, 0)
            Write-SWLog "  Nodes: $($stats.Nodes.TotalNodes) total - $($stats.Nodes.UpNodes) Up ($nodeUpPct) - $($stats.Nodes.DownNodes) Down - $($stats.Nodes.UnmanagedNodes) Unmanaged" -Level INFO

            $appUpPct = [math]::Round(($stats.Apps.UpApps / $stats.Apps.TotalApps) * 100, 0)
            Write-SWLog "  Apps: $($stats.Apps.TotalApps) total - $($stats.Apps.UpApps) Available ($appUpPct) - $($stats.Apps.DownApps) Down - $($stats.Apps.WarningApps) Warning" -Level INFO

            Write-SWLog "  Alerts: $($stats.Alerts.TotalAlerts) active - $($stats.Alerts.CriticalAlerts) Critical - $($stats.Alerts.WarningAlerts) Warning - $($stats.Alerts.UnacknowledgedAlerts) Unacknowledged" -Level INFO
            Write-SWLog "  Maintenance: $($stats.MaintenanceCount) nodes currently unmanaged" -Level INFO
            Write-Host ""
        }
    }

    Write-SWLog "SELECT AN OPERATION" -Level HEADER
    Write-SWLog "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -Level HEADER
    Write-SWLog "  1. Node Management (Search, View, Bulk Actions)" -Level INFO
    Write-SWLog "  2. Template Management (List, Create, Assign)" -Level INFO
    Write-SWLog "  3. Application Monitors (View, Deploy, Configure)" -Level INFO
    Write-SWLog "  4. Alert Management (View, Acknowledge, Create)" -Level INFO
    Write-SWLog "  5. Maintenance Mode (Enter, Exit, Calendar)" -Level INFO
    Write-SWLog "  6. Dashboard & Statistics (Full detailed views)" -Level INFO
    Write-SWLog "  7. Quick Actions (Frequent operations)" -Level INFO
    Write-SWLog "  8. Export Data (Nodes, Alerts, Applications)" -Level INFO
    Write-SWLog "  9. Settings & Connection" -Level INFO
    Write-SWLog "  0. Exit" -Level INFO
    Write-Host ""

    Write-SWLog "QUICK SHORTCUTS: [N]ode Search  [T]emplates  [A]lerts  [M]aintenance  [R]efresh [E]xport" -Level PROMPT
    Write-SWLog ""
}

#>
function Show-MainMenu {
    Clear-Host

    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "        SolarWinds SAM QuickOps - Interactive Manager V2.0        " -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""

    if ($script:SWConnection) {
        Write-SWLog "Connected to: $script:SWServer" -Level SUCCESS
        if ($script:SWLastRefresh) {
            $refreshAge = ((Get-Date) - $script:SWLastRefresh).TotalMinutes
            Write-SWLog ("Last refresh: {0} min ago" -f $refreshAge.ToString('F0')) -Level DEBUG
        }
    } else {
        Write-SWLog "Not connected" -Level ERROR
    }

    Write-Host ""

    if ($script:SWConnection) {
        $stats = Get-SWDashboardStats -Swis $script:SWConnection
        if ($stats) {
            Write-SWLog "DASHBOARD SUMMARY" -Level HEADER
            Write-SWLog "----------------------------------------" -Level HEADER
            $nodeUpPct = [math]::Round(($stats.Nodes.UpNodes / $stats.Nodes.TotalNodes) * 100, 0)
            Write-SWLog "  Nodes: $($stats.Nodes.TotalNodes) total - $($stats.Nodes.UpNodes) Up ($nodeUpPct) - $($stats.Nodes.DownNodes) Down - $($stats.Nodes.UnmanagedNodes) Unmanaged" -Level INFO

            $appUpPct = [math]::Round(($stats.Apps.UpApps / $stats.Apps.TotalApps) * 100, 0)
            Write-SWLog "  Apps: $($stats.Apps.TotalApps) total - $($stats.Apps.UpApps) Available ($appUpPct) - $($stats.Apps.DownApps) Down - $($stats.Apps.WarningApps) Warning" -Level INFO

            Write-SWLog "  Alerts: $($stats.Alerts.TotalAlerts) active - $($stats.Alerts.CriticalAlerts) Critical - $($stats.Alerts.WarningAlerts) Warning - $($stats.Alerts.UnacknowledgedAlerts) Unacknowledged" -Level INFO
            Write-SWLog "  Maintenance: $($stats.MaintenanceCount) nodes currently unmanaged" -Level INFO
            Write-Host ""
        }
    }

    Write-SWLog "SELECT AN OPERATION" -Level HEADER
    Write-SWLog "----------------------------------------" -Level HEADER
    Write-SWLog "  1. Node Management (Search, View, Bulk Actions)" -Level INFO
    Write-SWLog "  2. Template Management (List, Create, Assign)" -Level INFO
    Write-SWLog "  3. Application Monitors (View, Deploy, Configure)" -Level INFO
    Write-SWLog "  4. Alert Management (View, Acknowledge, Create)" -Level INFO
    Write-SWLog "  5. Maintenance Mode (Enter, Exit, Calendar)" -Level INFO
    Write-SWLog "  6. Dashboard & Statistics (Full detailed views)" -Level INFO
    Write-SWLog "  7. Quick Actions (Frequent operations)" -Level INFO
    Write-SWLog "  8. Export Data (Nodes, Alerts, Applications)" -Level INFO
    Write-SWLog "  9. Settings & Connection" -Level INFO
    Write-SWLog "  0. Exit" -Level INFO
    Write-Host ""

    Write-SWLog "QUICK SHORTCUTS: [N]ode Search  [T]emplates  [A]lerts  [M]aintenance  [R]efresh [E]xport" -Level PROMPT
    Write-SWLog ""
}

function Invoke-NodeManagement {
    param([object]$Swis)

    :nodeMenu do {
        Clear-Host
        Write-SWLog "=== NODE MANAGEMENT ===" -Level HEADER
        Write-SWLog ""
        Write-SWLog "  1. Search Nodes" -Level INFO
        Write-SWLog "  2. View Node Details" -Level INFO
        Write-SWLog "  3. List Nodes by Status" -Level INFO
        Write-SWLog "  4. Bulk Maintenance Mode" -Level INFO
        Write-SWLog "  0. Back to Main Menu" -Level INFO
        Write-SWLog ""

        $selection = Read-Host "Enter selection"

        switch ($selection) {
            "1" {
                Write-SWLog "Enter search term (hostname/IP/partial name):" -Level PROMPT -NoNewline
                $searchTerm = Read-Host

                $nodes = Get-SWNodes -Swis $Swis -SearchTerm $searchTerm

                if ($nodes.Count -eq 0) {
                    Write-SWLog "No nodes found matching: $searchTerm" -Level WARNING
                    Read-Host "Press Enter to continue"
                    continue
                }

                $selectedNode = Get-SWSelection -Items $nodes -Title "Search Results" -DisplayProperty "Caption"

                if ($selectedNode) {
                    Show-SWNodeDetails -Swis $Swis -NodeId $selectedNode.NodeID
                }
            }

            "2" {
                $nodes = Get-SWNodes -Swis $Swis -MaxResults 20
                $selectedNode = Get-SWSelection -Items $nodes -Title "Select Node for Details" -DisplayProperty "Caption"

                if ($selectedNode) {
                    Show-SWNodeDetails -Swis $Swis -NodeId $selectedNode.NodeID
                }
            }

            "3" {
                Write-SWLog "Filter by status:" -Level PROMPT
                Write-SWLog "  1. All" -Level INFO
                Write-SWLog "  2. Up" -Level INFO
                Write-SWLog "  3. Down" -Level INFO
                Write-SWLog "  4. Warning" -Level INFO
                Write-SWLog "  5. Unmanaged" -Level INFO
                Write-SWLog "  0. Back" -Level INFO

                $statusSel = Read-Host "Enter selection"
                $statusMap = @{
                    "1" = "All"
                    "2" = "Up"
                    "3" = "Down"
                    "4" = "Warning"
                    "5" = "Unmanaged"
                    "0" = $null
                }

                $statusFilter = $statusMap[$statusSel]
                if ($statusFilter) {
                    $nodes = Get-SWNodes -Swis $Swis -StatusFilter $statusFilter
                    $selectedNode = Get-SWSelection -Items $nodes -Title "Nodes - Status: $statusFilter" -DisplayProperty "Caption"

                    if ($selectedNode) {
                        Show-SWNodeDetails -Swis $Swis -NodeId $selectedNode.NodeID
                    }
                }
            }

            "4" {
                $nodes = Get-SWNodes -Swis $Swis
                $selectedNodes = Get-SWSelection -Items $nodes -Title "Select Nodes for Bulk Maintenance" -DisplayProperty "Caption" -AllowMultiple $true

                if ($selectedNodes -and $selectedNodes.Count -gt 0) {
                    Write-SWLog "Selected $($selectedNodes.Count) node(s)" -Level INFO
                    Write-SWLog "Enter maintenance duration in hours (default: 2):" -Level PROMPT -NoNewline
                    $hours = Read-Host

                    if (-not $hours -or $hours -notmatch '^\d+$') {
                        $hours = 2
                    }

                    foreach ($node in $selectedNodes) {
                        $result = Set-SWMaintenance -Swis $Swis -NodeId $node.NodeID -Hours [int]$hours -IsRelative $true
                        if ($result.Success) {
                            Write-SWLog "  Set maintenance for: $($node.Caption)" -Level SUCCESS
                        } else {
                            Write-SWLog "  Failed for: $($node.Caption)" -Level ERROR
                        }
                    }
                    Read-Host "Press Enter to continue"
                }
            }

            "0" {
                break nodeMenu
            }
        }
    } while ($true)
}

function Show-SWNodeDetails {
    param(
        [object]$Swis,
        [int]$NodeId
    )

    try {
        Clear-Host

        $nodeQuery = @"
        SELECT NodeID, Caption, NodeName, IP_Address, Status, StatusLED,
               Vendor, MachineType, Unmanaged, UnmanageFrom, UnmanageUntil,
               ObjectSubType, CPULoad, AvgResponseTime,
               n.SysName, n.DNSName,
               cp.Site, cp.Department, cp.Contact
        FROM Orion.Nodes n
        LEFT JOIN Orion.NodesCustomProperties cp ON n.NodeID = cp.NodeID
        WHERE NodeID = @NodeId
"@

        $node = Get-SwisData -SwisConnection $Swis -Query $nodeQuery -Parameters @{ NodeId = $nodeId }

        if (-not $node) {
            Write-SWLog "Node not found" -Level ERROR
            Read-Host "Press Enter to continue"
            return
        }

        Write-SWLog "=== NODE DETAILS ===" -Level HEADER
        Write-SWLog ""

        Write-SWLog "Basic Information" -Level HEADER
        Write-SWLog "  Name: $($node.Caption)" -Level INFO
        Write-SWLog "  Node Name: $($node.NodeName)" -Level INFO
        Write-SWLog "  IP Address: $($node.IP_Address)" -Level INFO
        Write-SWLog "  Status: $($node.StatusLED)" -Level INFO
        Write-SWLog "  Vendor: $($node.Vendor)" -Level INFO
        Write-SWLog "  Type: $($node.ObjectSubType)" -Level INFO

        Write-SWLog ""
        Write-SWLog "Performance" -Level HEADER
        Write-SWLog "  CPU Load: $([math]::Round($node.CPULoad, 2))%" -Level INFO
        Write-SWLog "  Response Time: $([math]::Round($node.AvgResponseTime, 2))ms" -Level INFO

        Write-SWLog ""
        Write-SWLog "Maintenance Status" -Level HEADER
        if ($node.Unmanaged) {
            Write-SWLog "  Currently Unmanaged: YES" -Level WARNING
            Write-SWLog "  From: $($node.UnmanageFrom)" -Level INFO
            Write-SWLog "  Until: $($node.UnmanageUntil)" -Level INFO
        } else {
            Write-SWLog "  Currently Unmanaged: NO" -Level SUCCESS
        }

        if ($node.Site -or $node.Department) {
            Write-SWLog ""
            Write-SWLog "Custom Properties" -Level HEADER
            if ($node.Site) { Write-SWLog "  Site: $($node.Site)" -Level INFO }
            if ($node.Department) { Write-SWLog "  Department: $($node.Department)" -Level INFO }
        }

        Write-SWLog ""
        Write-SWLog "Applications on this Node" -Level HEADER

        $appsQuery = @"
        SELECT a.ApplicationID, a.Name, a.Status, a.Availability,
               at.Name AS TemplateName, a.NodeID,
               n.Caption AS NodeName
        FROM Orion.APM.Application a
        JOIN Orion.APM.ApplicationTemplate at ON a.ApplicationTemplateID = at.ApplicationTemplateID
        JOIN Orion.Nodes n ON a.NodeID = n.NodeID
        WHERE a.NodeID = @NodeId
        ORDER BY a.Name
"@

        $apps = Get-SwisData -SwisConnection $Swis -Query $appsQuery -Parameters @{ NodeId = $nodeId }

        if ($apps.Count -eq 0) {
            Write-SWLog "  No applications assigned" -Level INFO
        } else {
            foreach ($app in $apps) {
                $statusColor = switch ($app.Status) {
                    14 { "Green" }
                    2 { "Red" }
                    3 { "Yellow" }
                    default { "Gray" }
                }
                $statusText = switch ($app.Status) {
                    14 { "Available" }
                    2 { "Down" }
                    3 { "Warning" }
                    default { "Unknown" }
                }
                Write-Host "  - $($app.Name)" -NoNewline -ForegroundColor White
                Write-Host " [$statusText]" -ForegroundColor $statusColor
            }
        }

        Write-SWLog ""
        Read-Host "Press Enter to continue"

    } catch {
        Write-SWLog "Failed to get node details: $_" -Level ERROR
        Read-Host "Press Enter to continue"
    }
}

function Invoke-TemplateManagement {
    param([object]$Swis)

    :templateMenu do {
        Clear-Host
        Write-SWLog "=== TEMPLATE MANAGEMENT ===" -Level HEADER
        Write-SWLog ""
        Write-SWLog "  1. List Templates" -Level INFO
        Write-SWLog "  2. Create New Template" -Level INFO
        Write-SWLog "  3. Assign Template to Node(s)" -Level INFO
        Write-SWLog "  0. Back to Main Menu" -Level INFO
        Write-SWLog ""

        $selection = Read-Host "Enter selection"

        switch ($selection) {
            "1" {
                $templates = Get-SWTemplates -Swis $Swis

                if ($templates.Count -eq 0) {
                    Write-SWLog "No templates found" -Level WARNING
                    Read-Host "Press Enter to continue"
                    continue
                }

                Write-SWLog "Found $($templates.Count) template(s)" -Level INFO
                foreach ($tmpl in $templates) {
                    Write-SWLog "  - $($tmpl.Name)" -Level INFO
                }
                Write-SWLog ""
                Read-Host "Press Enter to continue"
            }

            "2" {
                Write-SWLog "=== CREATE TEMPLATE WIZARD ===" -Level HEADER
                Write-SWLog ""

                Write-SWLog "Step 1: Template Name" -Level PROMPT -NoNewline
                Write-SWLog ""
                $templateName = Read-Host "Enter template name:"

                Write-SWLog "Step 2: Description" -Level PROMPT -NoNewline
                Write-SWLog ""
                $description = Read-Host "Enter description:"

                Write-SWLog "Step 3: Component Type" -Level PROMPT -NoNewline
                Write-SWLog ""
                Write-SWLog "  1. Windows Service" -Level INFO
                Write-SWLog "  2. IIS Application Pool" -Level INFO
                Write-SWLog "  3. HTTP/HTTPS Monitor" -Level INFO
                Write-SWLog "  4. Process Monitor" -Level INFO
                Write-SWLog "  5. Custom (SWQL Query)" -Level INFO
                Write-SWLog "  0. Finish Components" -Level INFO
                $compType = Read-Host "Select component type:"

                $components = @()

                if ($compType -ne "5") {
                    do {
                        Write-SWLog "Step 4: Add Components" -Level PROMPT -NoNewline
                        Write-SWLog ""
                        
                        $compName = Read-Host "Enter component name (or 'done' to finish):"

                        if ($compName -eq 'done' -or [string]::IsNullOrWhiteSpace($compName)) {
                            break
                        }

                        $component = @{
                            ComponentType = switch ($compType) {
                                "1" { "WinService" }
                                "2" { "IISAppPool" }
                                "3" { "IIS" }
                                "4" { "Process" }
                                "5" { "WinService" }
                                default { "WinService" }
                            }
                            Name = $compName
                            DisplayName = $compName
                        }

                        if ($compType -eq "1") {
                            Write-SWLog "  Enter service name (e.g., MSSQLSERVER):" -Level PROMPT -NoNewline
                            $serviceName = Read-Host
                            $component.ServiceName = $serviceName
                        }

                        if ($compType -eq "2") {
                            Write-SWLog "  Enter app pool name:" -Level PROMPT -NoNewline
                            $appPoolName = Read-Host
                            $component.AppPoolName = $appPoolName
                        }

                        if ($compType -eq "3") {
                            Write-SWLog "  Enter URL to monitor:" -Level PROMPT -NoNewline
                            $url = Read-Host
                            $component.Url = $url
                        }

                        if ($compType -eq "4") {
                            Write-SWLog "  Enter process name:" -Level PROMPT -NoNewline
                            $processName = Read-Host
                            $component.ProcessName = $processName
                        }

                        $components += $component
                        Write-SWLog "  Added component: $compName" -Level SUCCESS

                    } while ($true)
                }

                Write-SWLog ""
                Write-SWLog "Creating template with $($components.Count) component(s)..." -Level INFO

                $result = New-SWTemplate -Swis $Swis -TemplateName $templateName -Description $description -Components $components

                if ($result.Success) {
                    Write-SWLog "Template created successfully with ID: $($result.TemplateId)" -Level SUCCESS
                }

                Read-Host "Press Enter to continue"
            }

            "3" {
                $templates = Get-SWTemplates -Swis $Swis
                $selectedTemplate = Get-SWSelection -Items $templates -Title "Select Template to Assign" -DisplayProperty "Name"

                if (-not $selectedTemplate) {
                    continue
                }

                $nodes = Get-SWNodes -Swis $Swis -MaxResults 100
                $selectedNodes = Get-SWSelection -Items $nodes -Title "Select Node(s)" -DisplayProperty "Caption" -AllowMultiple $true -AllowAll $true

                if ($selectedNodes -and $selectedNodes.Count -gt 0) {
                    Write-SWLog "Assigning template to $($selectedNodes.Count) node(s)..." -Level INFO

                    $successCount = 0
                    foreach ($node in $selectedNodes) {
                        $result = Assign-SWTemplate -Swis $Swis -NodeId $node.NodeID -TemplateId $selectedTemplate.ApplicationTemplateID
                        if ($result.Success) {
                            $successCount++
                        } else {
                            Write-SWLog "  Failed: $($node.Caption)" -Level ERROR
                        }
                    }

                    Write-SWLog "Successfully assigned to $successCount/$($selectedNodes.Count) nodes" -Level SUCCESS
                    Read-Host "Press Enter to continue"
                }
            }

            "0" {
                break templateMenu
            }
        }
    } while ($true)
}

function Invoke-AlertManagement {
    param([object]$Swis)

    :alertMenu do {
        Clear-Host
        Write-SWLog "=== ALERT MANAGEMENT ===" -Level HEADER
        Write-SWLog ""
        Write-SWLog "  1. View Active Alerts" -Level INFO
        Write-SWLog "  2. View Unacknowledged Alerts" -Level INFO
        Write-SWLog "  3. Acknowledge Alerts" -Level INFO
        Write-SWLog "  4. View Alerts by Severity" -Level INFO
        Write-SWLog "  0. Back to Main Menu" -Level INFO
        Write-SWLog ""

        $selection = Read-Host "Enter selection"

        switch ($selection) {
            "1" {
                $alerts = Get-SWAlerts -Swis $Swis

                if ($alerts.Count -eq 0) {
                    Write-SWLog "No active alerts" -Level SUCCESS
                    Read-Host "Press Enter to continue"
                    continue
                }

                Write-SWLog "Found $($alerts.Count) active alert(s)" -Level INFO
                foreach ($alert in $alerts | Select-Object -First 20) {
                    $severityColor = switch ($alert.Severity) {
                        2 { "Red" }
                        3 { "Yellow" }
                        4 { "Blue" }
                        default { "Gray" }
                    }
                    $severityText = switch ($alert.Severity) {
                        2 { "CRITICAL" }
                        3 { "WARNING" }
                        4 { "INFO" }
                        default { "UNKNOWN" }
                    }
                    $ackStatus = if ($alert.Acknowledged) { "[ACK]" } else { "[NEW]" }
                    $ackColor = if ($alert.Acknowledged) { "Green" } else { "Red" }

                    Write-Host "  - $($alert.EntityCaption)" -NoNewline -ForegroundColor White
                    Write-Host " $ackStatus" -NoNewline -ForegroundColor $ackColor
                    Write-Host " [$severityText]" -ForegroundColor $severityColor
                    Write-Host "    $($alert.AlertName)" -ForegroundColor DarkGray
                    Write-Host "    Triggered: $($alert.TriggeredDateTime)" -ForegroundColor DarkGray
                }

                if ($alerts.Count -gt 20) {
                    Write-SWLog "  ... and $($alerts.Count - 20) more alerts" -Level INFO
                }

                Write-SWLog ""
                Read-Host "Press Enter to continue"
            }

            "2" {
                $alerts = Get-SWAlerts -Swis $Swis -AcknowledgedOnly $true

                if ($alerts.Count -eq 0) {
                    Write-SWLog "No unacknowledged alerts" -Level SUCCESS
                    Read-Host "Press Enter to continue"
                    continue
                }

                Write-SWLog "Found $($alerts.Count) unacknowledged alert(s)" -Level INFO
                foreach ($alert in $alerts | Select-Object -First 20) {
                    $severityColor = switch ($alert.Severity) {
                        2 { "Red" }
                        3 { "Yellow" }
                        4 { "Blue" }
                        default { "Gray" }
                    }
                    $severityText = switch ($alert.Severity) {
                        2 { "CRITICAL" }
                        3 { "WARNING" }
                        4 { "INFO" }
                        default { "UNKNOWN" }
                    }

                    Write-Host "  - $($alert.EntityCaption)" -NoNewline -ForegroundColor White
                    Write-Host " [$severityText]" -ForegroundColor $severityColor
                    Write-Host "    $($alert.AlertName)" -ForegroundColor DarkGray
                    Write-Host "    Triggered: $($alert.TriggeredDateTime)" -ForegroundColor DarkGray
                }

                Write-SWLog ""
                Read-Host "Press Enter to continue"
            }

            "3" {
                $alerts = Get-SWAlerts -Swis $Swis -AcknowledgedOnly $true

                if ($alerts.Count -eq 0) {
                    Write-SWLog "No unacknowledged alerts to acknowledge" -Level WARNING
                    Read-Host "Press Enter to continue"
                    continue
                }

                Write-SWLog "Select alert(s) to acknowledge" -Level INFO

                $selectedAlerts = @()
                do {
                    Write-SWLog "Enter alert number to acknowledge (1-$($alerts.Count)), or 'all' for all, or 'done':" -Level PROMPT -NoNewline
                    $input = Read-Host

                    if ($input -eq 'done') {
                        break
                    }

                    if ($input -eq 'all') {
                        $selectedAlerts = $alerts
                        break
                    }

                    if ($input -match '^\d+$') {
                        $index = [int]$input - 1
                        if ($index -ge 0 -and $index -lt $alerts.Count) {
                            $selectedAlerts += $alerts[$index]
                            Write-SWLog "  Added: $($alerts[$index].EntityCaption)" -Level INFO
                        }
                    }
                } while ($true)

                if ($selectedAlerts.Count -gt 0) {
                    continue
                }

                Write-SWLog "Enter acknowledgment note (optional):" -Level PROMPT -NoNewline
                $note = Read-Host

                $alertObjectIds = $selectedAlerts | ForEach-Object { $_.AlertObjectID }
                $result = Acknowledge-SWAlerts -Swis $Swis -AlertObjectIds $alertObjectIds -Note $note

                if ($result.Success) {
                    Write-SWLog "Acknowledged $($alertObjectIds.Count) alert(s)" -Level SUCCESS
                }

                Read-Host "Press Enter to continue"
            }

            "4" {
                Write-SWLog "Filter by severity:" -Level PROMPT
                Write-SWLog "  1. All" -Level INFO
                Write-SWLog "  2. Critical" -Level INFO
                Write-SWLog "  3. Warning" -Level INFO
                Write-SWLog "  4. Info" -Level INFO
                Write-SWLog "  0. Back" -Level INFO

                $severitySel = Read-Host "Enter selection"
                $severityMap = @{
                    "1" = "All"
                    "2" = "Critical"
                    "3" = "Warning"
                    "4" = "Info"
                    "0" = $null
                }

                $severityFilter = $severityMap[$severitySel]
                if ($severityFilter) {
                    $alerts = Get-SWAlerts -Swis $Swis -SeverityFilter $severityFilter

                    Write-SWLog "Found $($alerts.Count) $($severityFilter) alert(s)" -Level INFO
                    foreach ($alert in $alerts | Select-Object -First 20) {
                        $ackStatus = if ($alert.Acknowledged) { "[ACK]" } else { "[NEW]" }
                        $ackColor = if ($alert.Acknowledged) { "Green" } else { "Red" }

                        Write-Host "  - $($alert.EntityCaption)" -NoNewline -ForegroundColor White
                        Write-Host " $ackStatus" -NoNewline -ForegroundColor $ackColor
                        Write-Host " Triggered: $($alert.TriggeredDateTime)" -ForegroundColor DarkGray
                    }

                    Write-SWLog ""
                    Read-Host "Press Enter to continue"
                }
            }

            "0" {
                break alertMenu
            }
        }
    } while ($true)
}

function Invoke-MaintenanceManagement {
    param([object]$Swis)

    :maintenanceMenu do {
        Clear-Host
        Write-SWLog "=== MAINTENANCE MODE ===" -Level HEADER
        Write-SWLog ""
        Write-SWLog "  1. View Maintenance Calendar" -Level INFO
        Write-SWLog "  2. Enter Maintenance Mode" -Level INFO
        Write-SWLog "  3. Exit Maintenance Mode" -Level INFO
        Write-SWLog "  0. Back to Main Menu" -Level INFO
        Write-SWLog ""

        $selection = Read-Host "Enter selection"

        switch ($selection) {
            "1" {
                $maintenanceQuery = @"
                SELECT NodeID, Caption, UnmanageFrom, UnmanageUntil,
                       CASE 
                           WHEN UnmanageUntil > GetUtcDate() THEN 'Active'
                           WHEN UnmanageFrom > GetUtcDate() THEN 'Scheduled'
                           ELSE 'Expired'
                       END AS MaintenanceStatus,
                       DATEDIFF(minute, GetUtcDate(), UnmanageUntil) AS MinutesRemaining
                FROM Orion.Nodes
                WHERE Unmanaged = 1
                ORDER BY UnmanageUntil DESC
"@

                $maintenanceNodes = Get-SwisData -SwisConnection $Swis -Query $maintenanceQuery

                if (-not $maintenanceNodes -or $maintenanceNodes.Count -eq 0) {
                    Write-SWLog "No nodes in maintenance" -Level INFO
                    Write-SWLog "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -Level HEADER
                    Read-Host "Press Enter to continue"
                    return
                }

                Write-SWLog "=== MAINTENANCE CALENDAR ===" -Level HEADER
                Write-SWLog ""
                Write-SWLog "Displaying $($maintenanceNodes.Count) maintenance window(s)" -Level INFO
                Write-SWLog ""

                foreach ($node in $maintenanceNodes) {
                    $status = $node.MaintenanceStatus
                    $statusColor = switch ($status) {
                        "Active" { "Red" }
                        "Scheduled" { "Yellow" }
                        "Expired" { "Green" }
                        default { "Gray" }
                    }

                    $remaining = if ($node.MinutesRemaining -gt 0) {
                        $minutes = [int]$node.MinutesRemaining
                        $hours = [math]::Floor($minutes / 60)
                        $mins = $minutes % 60
                        if ($hours -gt 24) {
                            $days = [math]::Floor($hours / 24)
                            "$days days, $($hours % 24)h $mins min"
                        } elseif ($hours -gt 0) {
                            "$hours h $mins min"
                        } else {
                            "$mins min"
                        }
                    } elseif ($node.MinutesRemaining -eq 0) {
                        "Now"
                    } else {
                        "Overdue"
                    }

                    $startTime = [DateTime]::Parse($node.UnmanageFrom)
                    $endTime = [DateTime]::Parse($node.UnmanageUntil)

                    Write-Host "  [$status] " -NoNewline -ForegroundColor $statusColor
                    Write-Host " $($node.Caption)" -ForegroundColor White
                    Write-Host "    From: $($startTime.ToString('yyyy-MM-dd HH:mm'))" -ForegroundColor DarkGray
                    Write-Host "    Until: $($endTime.ToString('yyyy-MM-dd HH:mm'))" -ForegroundColor DarkGray
                    Write-Host "    $remaining remaining" -ForegroundColor Cyan
                    Write-Host ""
                }

                Write-SWLog "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -Level HEADER
                Write-SWLog ""
                Write-SWLog "Controls: 1. Extend | 2. End Early | 3. Resume All | 0. Back" -Level PROMPT
                Write-SWLog ""

                $action = Read-Host "Enter action"

                switch ($action) {
                    "1" {
                        Write-SWLog "Enter node number to extend:" -Level PROMPT -NoNewline
                        $nodeNum = Read-Host

                        if ($nodeNum -match '^\d+$') {
                            $index = [int]$nodeNum - 1
                            if ($index -ge 0 -and $index -lt $maintenanceNodes.Count) {
                                $node = $maintenanceNodes[$index]

                                Write-SWLog "Enter additional hours to extend:" -Level PROMPT -NoNewline
                                $hours = Read-Host

                                if ($hours -match '^\d+$') {
                                    $now = [DateTime]::UtcNow
                                    $currentEnd = [DateTime]::Parse($node.UnmanageUntil)
                                    if ($currentEnd -lt $now) {
                                        $currentEnd = $now
                                    }
                                    $newEnd = $currentEnd.AddHours([int]$hours)

                                    $result = Set-SWMaintenance -Swis $Swis -NodeId $node.NodeID -Hours 0 -IsRelative $false
                                    
                                    if ($result.Success) {
                                        Write-SWLog "Maintenance extended successfully" -Level SUCCESS
                                    }
                                } else {
                                    Write-SWLog "Invalid hours" -Level ERROR
                                }
                            } else {
                                Write-SWLog "Invalid node number" -Level ERROR
                            }
                        } else {
                            Write-SWLog "Invalid node number" -Level ERROR
                        }
                    }

                    "2" {
                        Write-SWLog "Enter node number to end early:" -Level PROMPT -NoNewline
                        $nodeNum = Read-Host

                        if ($nodeNum -match '^\d+$') {
                            $index = [int]$nodeNum - 1
                            if ($index -ge 0 -and $index -lt $maintenanceNodes.Count) {
                                $node = $maintenanceNodes[$index]
                                $result = Remove-SWMaintenance -Swis $Swis -NodeId $node.NodeID

                                if ($result.Success) {
                                    Write-SWLog "Maintenance ended early" -Level SUCCESS
                                }
                            } else {
                                Write-SWLog "Invalid node number" -Level ERROR
                            }
                        } else {
                            Write-SWLog "Invalid node number" -Level ERROR
                        }
                    }

                    "3" {
                        Write-SWLog "Resume all maintenance windows?" -Level PROMPT -NoNewline
                        $confirm = Read-Host "Confirm? (Y/N)"

                        if ($confirm -eq 'Y' -or $confirm -eq 'y') {
                            foreach ($node in $maintenanceNodes) {
                                $result = Remove-SWMaintenance -Swis $Swis -NodeId $node.NodeID

                                if ($result.Success) {
                                    Write-SWLog "  Resumed: $($node.Caption)" -Level INFO
                                } else {
                                    Write-SWLog "  Failed: $($node.Caption)" -Level ERROR
                                }
                            }
                            Write-SWLog "Completed resuming all maintenance windows" -Level SUCCESS
                        }
                    }

                    "0" {
                        break
                    }

                    default {
                        Write-SWLog "Invalid selection" -Level WARNING
                    }
                }

                Write-SWLog ""
                Read-Host "Press Enter to continue"
            }

            "2" {
                $nodes = Get-SWNodes -Swis $Swis
                $selectedNode = Get-SWSelection -Items $nodes -Title "Select Node for Maintenance" -DisplayProperty "Caption"

                if (-not $selectedNode) {
                    continue
                }

                Write-SWLog "Maintenance options for: $($selectedNode.Caption)" -Level INFO
                Write-SWLog "  1. Fixed duration (e.g., 2 hours from now)" -Level INFO
                Write-SWLog "  2. Specific end time" -Level INFO
                Write-SWLog "  0. Back" -Level INFO

                $typeSel = Read-Host "Enter selection"

                switch ($typeSel) {
                    "1" {
                        Write-SWLog "Enter duration in hours:" -Level PROMPT -NoNewline
                        $hours = Read-Host

                        if (-not $hours -or $hours -notmatch '^\d+$') {
                            Write-SWLog "Invalid duration" -Level ERROR
                            continue
                        }

                        $result = Set-SWMaintenance -Swis $Swis -NodeId $selectedNode.NodeID -Hours [int]$hours -IsRelative $true

                        if ($result.Success) {
                            Write-SWLog "Set maintenance for $($hours) hour(s)" -Level SUCCESS
                        }

                        Read-Host "Press Enter to continue"
                    }

                    "2" {
                        Write-SWLog "Enter end time (UTC, format: yyyy-MM-dd HH:mm):" -Level PROMPT -NoNewline
                        $endTimeStr = Read-Host

                        try {
                            $endTime = [DateTime]::ParseExact($endTimeStr, "yyyy-MM-dd HH:mm", [Globalization.CultureInfo]::InvariantCulture)
                            
                            if ($endTime -le [DateTime]::UtcNow) {
                                Write-SWLog "End time must be in the future" -Level ERROR
                                continue
                            }

                            $now = [DateTime]::UtcNow
                            $result = Set-SWMaintenance -Swis $Swis -NodeId $selectedNode.NodeID -Hours 0 -IsRelative $false

                            if ($result.Success) {
                                Write-SWLog "Set maintenance until: $endTime" -Level SUCCESS
                            }
                        } catch {
                            Write-SWLog "Invalid date format" -Level ERROR
                        }

                        Read-Host "Press Enter to continue"
                    }

                    "0" {
                        break
                    }
            }
        }

        "3" {
            break
        }

        "0" {
            break maintenanceMenu
        }

            default {
                Write-SWLog "Invalid selection" -Level WARNING
            }
        }
    } while ($true)
}

function Invoke-ApplicationManagement {
    param([object]$Swis)

    :appMenu do {
        Clear-Host
        Write-SWLog "=== APPLICATION MONITOR MANAGEMENT ===" -Level HEADER
        Write-SWLog ""
        Write-SWLog "  1. View Applications by Node" -Level INFO
        Write-SWLog "  2. Search Applications" -Level INFO
        Write-SWLog "  3. Assign Template to Node" -Level INFO
        Write-SWLog "  0. Back to Main Menu" -Level INFO
        Write-SWLog ""

        $selection = Read-Host "Enter selection"

        switch ($selection) {
            "1" {
                $nodes = Get-SWNodes -Swis $Swis -MaxResults 50
                $selectedNode = Get-SWSelection -Items $nodes -Title "Select Node" -DisplayProperty "Caption"

                if (-not $selectedNode) {
                    continue
                }

                $apps = Get-SWApplications -Swis $Swis -NodeId $selectedNode.NodeID

                Write-SWLog "Found $($apps.Count) application(s) on: $($selectedNode.Caption)" -Level INFO
                foreach ($app in $apps) {
                    $statusColor = switch ($app.Status) {
                        14 { "Green" }
                        2 { "Red" }
                        3 { "Yellow" }
                        default { "Gray" }
                    }
                    $statusText = switch ($app.Status) {
                        14 { "Available" }
                        2 { "Down" }
                        3 { "Warning" }
                        default { "Unknown" }
                    }

                    Write-Host "  - $($app.Name)" -NoNewline -ForegroundColor White
                    Write-Host " [$statusText]" -ForegroundColor $statusColor
                    Write-Host "    Template: $($app.TemplateName)" -ForegroundColor DarkGray
                    Write-Host "    Availability: $([math]::Round($app.Availability, 1))%" -ForegroundColor DarkGray
                }

                Write-SWLog ""
                Read-Host "Press Enter to continue"
            }

            "2" {
                Write-SWLog "Enter application name to search:" -Level PROMPT -NoNewline
                $searchTerm = Read-Host

                if ([string]::IsNullOrWhiteSpace($searchTerm)) {
                    continue
                }

                $query = @"
                SELECT a.ApplicationID, a.Name, a.Status, a.Availability,
                       at.Name AS TemplateName, a.NodeID,
                       n.Caption AS NodeName
                FROM Orion.APM.Application a
                JOIN Orion.APM.ApplicationTemplate at ON a.ApplicationTemplateID = at.ApplicationTemplateID
                JOIN Orion.Nodes n ON a.NodeID = n.NodeID
                WHERE a.Name LIKE @Search
                ORDER BY a.Name
"@

                $apps = Get-SwisData -SwisConnection $Swis -Query $query -Parameters @{ Search = "%$searchTerm%" }

                if ($apps.Count -eq 0) {
                    Write-SWLog "No applications found matching: $searchTerm" -Level WARNING
                    Read-Host "Press Enter to continue"
                    continue
                }

                Write-SWLog "Found $($apps.Count) application(s)" -Level INFO
                foreach ($app in $apps | Select-Object -First 20) {
                    $statusColor = switch ($app.Status) {
                        14 { "Green" }
                        2 { "Red" }
                        3 { "Yellow" }
                        default { "Gray" }
                    }
                    $statusText = switch ($app.Status) {
                        14 { "Available" }
                        2 { "Down" }
                        3 { "Warning" }
                        default { "Unknown" }
                    }

                    Write-Host "  - $($app.Name) on $($app.NodeName)" -NoNewline -ForegroundColor White
                    Write-Host " [$statusText]" -ForegroundColor $statusColor
                }

                Write-SWLog ""
                Read-Host "Press Enter to continue"
            }

            "3" {
                $templates = Get-SWTemplates -Swis $Swis
                $selectedTemplate = Get-SWSelection -Items $templates -Title "Select Template" -DisplayProperty "Name"

                if (-not $selectedTemplate) {
                    continue
                }

                $nodes = Get-SWNodes -Swis -MaxResults 50
                $selectedNode = Get-SWSelection -Items $nodes -Title "Select Node" -DisplayProperty "Caption"

                if (-not $selectedNode) {
                    continue
                }

                $result = Assign-SWTemplate -Swis $Swis -NodeId $selectedNode.NodeID -TemplateId $selectedTemplate.ApplicationTemplateID

                if ($result.Success) {
                    Write-SWLog "Assigned template to node" -Level SUCCESS
                }

                Read-Host "Press Enter to continue"
            }

            "0" {
                break appMenu
            }
        }
    } while ($true)
}

function Export-NodeData {
    param(
        [object]$Swis,
        [string]$Format = "CSV"
    )

    try {
        Write-SWLog "Exporting nodes to $Format..." -Level INFO

        $query = @"
        SELECT n.NodeID, n.Caption, n.NodeName, n.IP_Address, n.Status,
               n.Vendor, n.MachineType, n.Unmanaged, n.UnmanageFrom, n.UnmanageUntil,
               n.CPULoad, n.AvgResponseTime, n.PercentMemoryUsed,
               cp.Site, cp.Department, cp.Contact
        FROM Orion.Nodes n
        LEFT JOIN Orion.NodesCustomProperties cp ON n.NodeID = cp.NodeID
        ORDER BY n.Caption
"@

        $nodes = Get-SwisData -SwisConnection $Swis -Query $query

        if (-not $nodes -or $nodes.Count -eq 0) {
            Write-SWLog "No nodes to export" -Level WARNING
            return @{ Success = $false }
        }

        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $filename = "SolarWindsNodes_$timestamp"

        if ($Format -eq "CSV") {
            $filepath = "$filename.csv"
            $nodes | Export-Csv -Path $filepath -NoTypeInformation
            Write-SWLog "Exported $($nodes.Count) nodes to: $filepath" -Level SUCCESS
        } elseif ($Format -eq "JSON") {
            $filepath = "$filename.json"
            $nodes | ConvertTo-Json -Depth 10 | Set-Content -Path $filepath
            Write-SWLog "Exported $($nodes.Count) nodes to: $filepath" -Level SUCCESS
        } else {
            Write-SWLog "Unknown format: $Format" -Level ERROR
            return @{ Success = $false }
        }

        $fullPath = Join-Path (Get-Location) $filepath
        Invoke-Item $fullPath

        return @{ Success = $true; Path = $fullPath; Count = $nodes.Count }
    } catch {
        Write-SWLog "Failed to export nodes: $_" -Level ERROR
        return @{ Success = $false; Error = $_ }
    }
}

function Export-AlertData {
    param(
        [object]$Swis,
        [string]$Format = "CSV"
    )

    try {
        Write-SWLog "Exporting alerts to $Format..." -Level INFO

        $query = @"
        SELECT ac.AlertID, ac.Name AS AlertName, ac.Severity, ac.Enabled,
               ao.EntityCaption, ao.EntityType,
               aa.Acknowledged, aa.AcknowledgedBy, aa.TriggeredDateTime,
               aa.AlertActiveID
        FROM Orion.AlertConfigurations ac
        JOIN Orion.AlertObjects ao ON ac.AlertID = ao.AlertID
        LEFT JOIN Orion.AlertActive aa ON aa.AlertObjectID = ao.AlertObjectID
        WHERE ac.AlertActiveID IS NOT NULL
        ORDER BY aa.TriggeredDateTime DESC
"@

        $alerts = Get-SwisData -SwisConnection $Swis -Query $query

        if (-not $alerts -or $alerts.Count -eq 0) {
            Write-SWLog "No active alerts to export" -Level WARNING
            return @{ Success = $false }
        }

        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $filename = "SolarWindsAlerts_$timestamp"

        if ($Format -eq "CSV") {
            $filepath = "$filename.csv"
            $alerts | Export-Csv -Path $filepath -NoTypeInformation
            Write-SWLog "Exported $($alerts.Count) alerts to: $filepath" -Level SUCCESS
        } elseif ($Format -eq "JSON") {
            $filepath = "$filename.json"
            $alerts | ConvertTo-Json -Depth 10 | Set-Content -Path $filepath
            Write-SWLog "Exported $($alerts.Count) alerts to: $filepath" -Level SUCCESS
        } else {
            Write-SWLog "Unknown format: $Format" -Level ERROR
            return @{ Success = $false }
        }

        $fullPath = Join-Path (Get-Location) $filepath
        Invoke-Item $fullPath

        return @{ Success = $true; Path = $fullPath; Count = $alerts.Count }
    } catch {
        Write-SWLog "Failed to export alerts: $_" -Level ERROR
        return @{ Success = $false; Error = $_ }
    }
}

function Invoke-ExportMenu {
    param([object]$Swis)

    :exportMenu do {
        Clear-Host
        Write-SWLog "=== EXPORT CAPABILITIES ===" -Level HEADER
        Write-SWLog ""
        Write-SWLog "  1. Export All Nodes" -Level INFO
        Write-SWLog "  2. Export Active Alerts" -Level INFO
        Write-SWLog "  3. Export Applications by Node" -Level INFO
        Write-SWLog "  0. Back to Main Menu" -Level INFO
        Write-SWLog ""

        $selection = Read-Host "Enter selection"

        switch ($selection) {
            "1" {
                Write-SWLog "Export format:" -Level PROMPT
                Write-SWLog "  1. CSV" -Level INFO
                Write-SWLog "  2. JSON" -Level INFO
                Write-SWLog "  0. Back" -Level INFO
                $formatSel = Read-Host "Enter selection"

                $format = switch ($formatSel) {
                    "1" { "CSV" }
                    "2" { "JSON" }
                    "0" { $null }
                    default { "CSV" }
                }

                if ($format) {
                    Export-NodeData -Swis $Swis -Format $format
                    Read-Host "Press Enter to continue"
                }
            }

            "2" {
                Write-SWLog "Export format:" -Level PROMPT
                Write-SWLog "  1. CSV" -Level INFO
                Write-SWLog "  2. JSON" -Level INFO
                Write-SWLog "  0. Back" -Level INFO
                $formatSel = Read-Host "Enter selection"

                $format = switch ($formatSel) {
                    "1" { "CSV" }
                    "2" { "JSON" }
                    "0" { $null }
                    default { "CSV" }
                }

                if ($format) {
                    Export-AlertData -Swis $Swis -Format $format
                    Read-Host "Press Enter to continue"
                }
            }

            "3" {
                $nodes = Get-SWNodes -Swis -Swis -MaxResults 100
                if ($nodes.Count -eq 0) {
                    Write-SWLog "No nodes available" -Level WARNING
                    Read-Host "Press Enter to continue"
                    continue
                }

                $selectedNode = Get-SWSelection -Items $nodes -Title "Select Node" -DisplayProperty "Caption"

                if (-not $selectedNode) {
                    continue
                }

                Write-SWLog "Export format:" -Level PROMPT
                Write-SWLog "  1. CSV" -Level INFO
                Write-SWLog " 2. JSON" -Level INFO
                $formatSel = Read-Host "Enter selection"

                $format = switch ($formatSel) {
                    "1" { "CSV" }
                    "2" { "JSON" }
                    "0" { $null }
                    default { "CSV" }
                }

                if ($format) {
                    $apps = Get-SWApplications -Swis $Swis -NodeId $selectedNode.NodeID

                    if ($apps.Count -gt 0) {
                        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
                        $filename = "SolarWindsApps_($($selectedNode.Caption))_$timestamp"

                        if ($format -eq "CSV") {
                            $filepath = "$filename.csv"
                            $apps | Export-Csv -Path $filepath -NoTypeInformation
                            Write-SWLog "Exported $($apps.Count) applications to: $filepath" -Level SUCCESS
                        } elseif ($format -eq "JSON") {
                            $filepath = "$filename.json"
                            $apps | ConvertTo-Json -Depth 10 | Set-Content -Path $filepath
                            Write-SWLog "Exported $($apps.Count) applications to: $filepath" -Level SUCCESS
                        }

                        $fullPath = Join-Path (Get-Location) $filepath
                        Invoke-Item $fullPath
                    } else {
                        Write-SWLog "No applications found on this node" -Level WARNING
                    }

                    Read-Host "Press Enter to continue"
                }
            }

            "0" {
                break exportMenu
            }

            default {
                Write-SWLog "Invalid selection. Try again." -Level WARNING
                Start-Sleep -Seconds 1
            }
        }
    } while ($true)
}

function Invoke-QuickActions {
    param([object]$Swis)

    :quickMenu do {
        Clear-Host
        Write-SWLog "=== QUICK ACTIONS ===" -Level HEADER
        Write-SWLog ""
        Write-SWLog "  1. Quick Node Search" -Level INFO
        Write-SWLog "  2. Quick Template Assign" -Level INFO
        Write-SWLog "   3. Quick Maintenance (Enter)" -Level INFO
        Write-SWLog "  4. Refresh Dashboard" -Level INFO
        Write-SWLog "  0. Back to Main Menu" -Level INFO
        Write-SWLog ""

        $selection = Read-Host "Enter selection"

        switch ($selection) {
            "1" {
                Write-SWLog "Enter search term:" -Level PROMPT -NoNewline
                $searchTerm = Read-Host
                $nodes = Get-SWNodes -Swis $Swis -SearchTerm $searchTerm
                $selectedNode = Get-SWSelection -Items $nodes -Title "Quick Search Results" -DisplayProperty "Caption"

                if ($selectedNode) {
                    Show-SWNodeDetails -Swis $Swis -NodeId $selectedNode.NodeID
                }
            }

            "2" {
                $templates = Get-SWTemplates -Swis $Swis
                $selectedTemplate = Get-SWSelection -Items $templates -Title "Quick Template Selection" -DisplayProperty "Name"

                if (-not $selectedTemplate) {
                    continue
                }

                Write-SWLog "Enter node hostname/IP:" -Level PROMPT -NoNewline
                $hostname = Read-Host

                $node = Get-SWNodes -Swis -SearchTerm $hostname | Select-Object -First 1

                if (-not $node) {
                    Write-SWLog "Node not found" -Level WARNING
                    continue
                }

                $result = Assign-SWTemplate -Swis $Swis -NodeId $node.NodeID -TemplateId $selectedTemplate.ApplicationTemplateID

                if ($result.Success) {
                    Write-SWLog "Assigned template successfully" -Level SUCCESS
                }

                Read-Host "Press Enter to continue"
            }

            "3" {
                Write-SWLog "Enter node hostname/IP:" -Level PROMPT -NoNewline
                $hostname = Read-Host

                $node = Get-SWNodes -Swis -SearchTerm $hostname | Select-Object -First 1

                if (-not $node) {
                    Write-SWLog "Node not found" -Level WARNING
                    continue
                }

                Write-SWLog "Enter duration in hours:" -Level PROMPT -NoNewline
                $hours = Read-Host

                if (-not $hours -or $hours -notmatch '^\d+$') {
                    $hours = 2
                }

                $result = Set-SWMaintenance -Swis $Swis -NodeId $node.NodeID -Hours [int]$hours -IsRelative $true

                if ($result.Success) {
                    Write-SWLog "Set maintenance for $($hours) hour(s)" -Level SUCCESS
                }

                Read-Host "Press Enter to continue"
            }

            "4" {
                $script:SWLastRefresh = Get-Date
                Write-SWLog "Dashboard refreshed" -Level SUCCESS
                Start-Sleep -Seconds 1
            }

            "0" {
                break quickMenu
            }

            default {
                Write-SWLog "Invalid selection" -Level WARNING
            }
        }
    } while ($true)
}

function Invoke-DashboardView {
    param([object]$Swis)

    Clear-Host

    $stats = Get-SWDashboardStats -Swis $Swis

    if (-not $stats) {
        Write-SWLog "Failed to retrieve dashboard statistics" -Level ERROR
        Read-Host "Press Enter to continue"
        return
    }

    Write-SWLog "=== DASHBOARD & STATISTICS ===" -Level HEADER
    Write-SWLog ""

    Write-SWLog "Node Statistics" -Level HEADER
    Write-SWLog "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -Level HEADER
    Write-SWLog "  Total Nodes: $($stats.Nodes.TotalNodes)" -Level INFO

    $nodeUpPct2 = [math]::Round(($stats.Nodes.UpNodes / $stats.Nodes.TotalNodes) * 100, 0)
    Write-SWLog "  Up: $($stats.Nodes.UpNodes) ($nodeUpPct2)" -Level SUCCESS
    Write-SWLog "  Down: $($stats.Nodes.DownNodes)" -Level ERROR
    Write-SWLog "  Warning: $($stats.Nodes.WarningNodes)" -Level WARNING
    Write-SWLog "  Unmanaged: $($stats.Nodes.UnmanagedNodes)" -Level INFO

    $avgCPU = [math]::Round($stats.Nodes.AvgCPU, 1)
    Write-SWLog "  Average CPU: $avgCPU" -Level INFO

    $avgResp = [math]::Round($stats.Nodes.AvgResponseTime, 1)
    Write-SWLog "  Average Response: ${avgResp}ms" -Level INFO

    Write-SWLog ""
    Write-SWLog "Application Statistics" -Level HEADER
    Write-SWLog "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -Level HEADER
    Write-SWLog "  Total Apps: $($stats.Apps.TotalApps)" -Level INFO

    $appUpPct2 = [math]::Round(($stats.Apps.UpApps / $stats.Apps.TotalApps) * 100, 0)
    Write-SWLog "  Available: $($stats.Apps.UpApps) ($appUpPct2)" -Level SUCCESS
    Write-SWLog "  Down: $($stats.Apps.DownApps)" -Level ERROR
    Write-SWLog "  Warning: $($stats.Apps.WarningApps)" -Level WARNING

    Write-SWLog ""
    Write-SWLog "Alert Statistics" -Level HEADER
    Write-SWLog "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -Level HEADER
    Write-SWLog "  Total Active: $($stats.Alerts.TotalAlerts)" -Level INFO
    Write-SWLog "  Critical: $($stats.Alerts.CriticalAlerts)" -Level ERROR
    Write-SWLog "  Warning: $($stats.Alerts.WarningAlerts)" -Level WARNING
    Write-SWLog "  Unacknowledged: $($stats.Alerts.UnacknowledgedAlerts)" -Level INFO

    Write-SWLog ""
    if ($stats.MaintenanceCount -gt 0) {
        Write-SWLog "Maintenance Status" -Level HEADER
        Write-SWLog "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -Level HEADER
        Write-SWLog "  Nodes in Maintenance: $($stats.MaintenanceCount)" -Level INFO

        foreach ($node in $stats.MaintenanceNodes | Select-Object -First 5) {
            $remaining = if ($node.MinutesRemaining -gt 0) {
                $minutes = [int]$node.MinutesRemaining
                $hours = [math]::Floor($minutes / 60)
                $mins = $minutes % 60
                if ($hours -gt 24) {
                    $days = [math]::Floor($hours / 24)
                    "$days days, $($hours % 24)h $mins min"
                } elseif ($hours -gt 0) {
                    "$hours h $mins min"
                } else {
                    "$mins min"
                }
            } elseif ($node.MinutesRemaining -eq 0) {
                "Now"
            } else {
                "Overdue"
            }

            Write-Host "  - $($node.Caption)" -ForegroundColor Cyan
            Write-Host "    Remaining: $remaining" -ForegroundColor Yellow
        }

        if ($stats.MaintenanceCount -gt 5) {
            Write-SWLog "  ... and $($stats.MaintenanceCount - 5) more" -Level INFO
        }
    }

    Write-SWLog "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -Level HEADER
    Write-SWLog ""
    Read-Host "Press Enter to return to main menu"
}

#endregion

#region Main Script

$script:SWConnection = $null
$script:SWServer = $null
$script:SWLastRefresh = $null

try {
    if ($DryRun) {
        if (-not $SwisServer) {
            $SwisServer = "(not set)"
        }

        Write-SWLog "DRY RUN: no changes will be made" -Level WARNING
        Write-SWLog "Would connect to SWIS server: $SwisServer" -Level INFO
        Write-SWLog "Would prompt for credentials if not supplied" -Level INFO
        Write-SWLog "Would show main menu and execute selected actions" -Level INFO
        Write-SWLog "Use -TrustSwisCert to fetch/install the SWIS cert" -Level INFO
        exit 0
    }

    if ($TrustSwisCert) {
        if (-not $SwisServer) {
            Write-SWLog "Enter SolarWinds SWIS server (FQDN preferred):" -Level PROMPT -NoNewline
            $SwisServer = Read-Host
        }

        Get-SWServerCertificate -HostName $SwisServer -Port $SwisCertPort -Install | Out-Null
        Write-SWLog "Proceeding with connection using $SwisServer" -Level INFO
    }

    if (-not $SwisServer) {
        Write-SWLog "Enter SolarWinds SWIS server:" -Level PROMPT -NoNewline
        $SwisServer = Read-Host
    }

    if (-not $UserName) {
        $credential = Get-Credential -Message "SolarWinds Credentials"
        $UserName = $credential.UserName
        $Password = $credential.Password
    }

    $connection = Get-SWConnection -Server $SwisServer -User $UserName -SecurePassword $Password

    if (-not $connection.Connected) {
        Write-SWLog "Failed to connect to SolarWinds" -Level ERROR
        exit 1
    }

    $script:SWConnection = $connection.Connection

    do {
        Show-MainMenu

        Write-SWLog "Your selection:" -Level PROMPT -NoNewline
        $selection = Read-Host

        if ($selection -eq "R" -or $selection -eq "r") {
            $script:SWLastRefresh = Get-Date
            continue
        }

        if ($selection -eq "N" -or $selection -eq "n") {
            Invoke-NodeManagement -Swis $script:SWConnection
            continue
        }

        if ($selection -eq "T" -or $selection -eq "t") {
            Invoke-TemplateManagement -Swis $script:SWConnection
            continue
        }

        if ($selection -eq "A" -or $selection -eq "a") {
            Invoke-AlertManagement -Swis $script:SWConnection
            continue
        }

        if ($selection -eq "M" -or $selection -eq "m") {
            Invoke-MaintenanceManagement -Swis $script:SWConnection
            continue
        }

        switch ($selection) {
            "1" {
                Invoke-NodeManagement -Swis $script:SWConnection
            }

            "2" {
                Invoke-TemplateManagement -Swis $script:SWConnection
            }

            "3" {
                Invoke-ApplicationManagement -Swis $script:SWConnection
            }

            "4" {
                Invoke-AlertManagement -Swis $script:SWConnection
            }

            "5" {
                Invoke-MaintenanceManagement -Swis $script:SWConnection
            }

            "6" {
                Invoke-DashboardView -Swis $script:SWConnection
            }

            "7" {
                Invoke-QuickActions -Swis $script:SWConnection
            }

            "8" {
                Invoke-ExportMenu -Swis $script:SWConnection
            }

            "9" {
                Write-SWLog "Current connection: $script:SWServer" -Level INFO
                Write-SWLog "To reconnect to a different server, restart the script" -Level INFO
                Read-Host "Press Enter to continue"
            }

            "0" {
                Clear-Host
                Write-SWLog "Goodbye!" -Level SUCCESS
                break mainMenuLoop
            }

            default {
                Write-SWLog "Invalid selection. Please try again." -Level WARNING
                Start-Sleep -Seconds 1
            }
        }
    } while ($true)

} finally {
    if ($script:SWConnection) {
        if (Get-Command Disconnect-Swis -ErrorAction SilentlyContinue) {
            Disconnect-Swis -SwisConnection $script:SWConnection -ErrorAction SilentlyContinue
        }
        Write-SWLog "Disconnected from SolarWinds" -Level INFO
    }
}

#endregion
