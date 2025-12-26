#Requires -Version 5.1

param(
    [Parameter(Mandatory = $true)]
    [string]$SwisServer,
    
    [string]$UserName,
    [securestring]$Password,
    
    [string]$MonitorTemplateName = "Critical Services Monitor",
    
    [string[]]$SQLServers = @(),
    [string[]]$IISServers = @(),
    [string[]]$DomainControllers = @(),
    
    [string]$SQLServices = @("MSSQLSERVER", "SQLAgent$MSSQLSERVER"),
    [string[]]$IISServices = @("W3SVC"),
    [string[]]$DCServices = @("Netlogon", "Kdc", "Dns", "W32Time"),
    
    [switch]$CreateTemplate,
    [switch]$AssignTemplate,
    [switch]$CreateAlert
)

$ErrorActionPreference = "Stop"

function Get-SwisConnection {
    param(
        [string]$Server,
        [string]$User,
        [securestring]$SecurePassword
    )
    
    Write-Output "Connecting to SolarWinds Information Service: $Server"
    
    if ($User -and $SecurePassword) {
        $credential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $User, $SecurePassword
        $swis = Connect-Swis -Hostname $Server -Credential $credential -ErrorAction Stop
    } else {
        $swis = Connect-Swis -Hostname $Server -Trusted -ErrorAction Stop
    }
    
    Write-Output "Connected to SolarWinds"
    return $swis
}

function Get-NodeByHostname {
    param(
        [object]$Swis,
        [string]$Hostname
    )
    
    $query = @"
SELECT NodeID, Caption, IP_Address, NodeName 
FROM Orion.Nodes 
WHERE NodeName = @Hostname OR Caption = @Hostname OR IP_Address = @Hostname
"@
    
    $params = @{ Hostname = $Hostname }
    $results = Get-SwisData -Swis $Swis -Query $query -Parameters $params
    
    return $results
}

function New-ServiceMonitorTemplate {
    param(
        [object]$Swis,
        [string]$TemplateName,
        [string[]]$Services,
        [string]$Description = "Monitors critical Windows services"
    )
    
    Write-Output "Creating SAM template: $TemplateName"
    
    $templateProps = @{
        Name = $TemplateName
        Description = $Description
    }
    
    $templateUri = Invoke-SwisVerb -Swis $Swis -EntityName "Orion.APM.Application" -Verb "CreateApplicationTemplate" -Arguments @($templateProps, $false)
    
    $templateId = ($templateUri -split '/')[4]
    Write-Output "Created template with ID: $templateId"
    
    foreach ($service in $Services) {
        $componentProps = @{
            ComponentType = "WinService"
            Name = "Service: $service"
            DisplayName = "$service Service"
            ServiceName = $service
        }
        
        Invoke-SwisVerb -Swis $Swis -EntityName "Orion.APM.ApplicationTemplate" -Verb "CreateComponent" -Arguments @($templateId, $componentProps) | Out-Null
        Write-Output "Added service monitor for: $service"
    }
    
    return $templateId
}

function Add-ApplicationToNode {
    param(
        [object]$Swis,
        [int]$NodeId,
        [int]$ApplicationTemplateId
    )
    
    Write-Output "Assigning template $ApplicationTemplateId to node $NodeId"
    
    $appProps = @{
        NodeID = $NodeId
        ApplicationTemplateID = $ApplicationTemplateId
    }
    
    $app = Invoke-SwisVerb -Swis $Swis -EntityName "Orion.APM.Application" -Verb "CreateApplication" -Arguments @($appProps)
    
    Write-Output "Application assigned successfully"
    return $app
}

function New-ServiceMonitorAlert {
    param(
        [object]$Swis,
        [string]$TemplateName,
        [string]$AlertName = "$TemplateName - Service Down"
    )
    
    Write-Output "Creating alert definition: $AlertName"
    
    $alertDef = @{
        Name = $AlertName
        Description = "Alert when any monitored service is not running"
        Enabled = $true
        Severity = 2
        TriggerType = "Immediate"
        Frequency = 60
        ObjectType = "Orion.APM.Application"
    }
    
    $alertUri = Invoke-SwisVerb -Swis $Swis -EntityName "Orion.Alerting" -Verb "CreateAlert" -Arguments @($alertDef)
    $alertId = ($alertUri -split '/')[4]
    
    $condition = @{
        Operator = "And"
        Conditions = @(
            @{
                Metric = "ApplicationAvailability"
                Operator = "NotEqual"
                Value = "Up"
            },
            @{
                Metric = "ApplicationTemplate"
                Operator = "Equal"
                Value = $TemplateName
            }
        )
    }
    
    Invoke-SwisVerb -Swis $Swis -EntityName "Orion.Alerting.AlertDefinition" -Verb "SetTriggerCondition" -Arguments @($alertId, $condition) | Out-Null
    
    Write-Output "Alert definition created with ID: $alertId"
    return $alertId
}

function Invoke-ServiceMonitorAssignment {
    param(
        [object]$Swis,
        [hashtable]$ServerGroups
    )
    
    Write-Output "Starting service monitor assignment..."
    
    $templateId = $null
    
    if ($CreateTemplate) {
        $allServices = $SQLServices + $IISServices + $DCServices
        $templateId = New-ServiceMonitorTemplate -Swis $Swis -TemplateName $MonitorTemplateName -Services $allServices
    } else {
        $query = "SELECT ApplicationTemplateID FROM Orion.APM.ApplicationTemplate WHERE Name = @Name"
        $params = @{ Name = $MonitorTemplateName }
        $result = Get-SwisData -Swis $Swis -Query $query -Parameters $params
        
        if (-not $result) {
            Write-Error "Template '$MonitorTemplateName' not found. Use -CreateTemplate to create it first."
            throw
        }
        
        $templateId = $result.ApplicationTemplateID
    }
    
    $assignedNodes = @()
    
    foreach ($group in $ServerGroups.GetEnumerator()) {
        Write-Output "Processing $($group.Key) group..."
        
        foreach ($hostname in $group.Value) {
            $node = Get-NodeByHostname -Swis $Swis -Hostname $hostname
            
            if (-not $node) {
                Write-Warning "Node not found: $hostname"
                continue
            }
            
            Write-Output "Found node: $($node.Caption) (ID: $($node.NodeID))"
            
            if ($AssignTemplate) {
                try {
                    Add-ApplicationToNode -Swis $Swis -NodeId $node.NodeID -ApplicationTemplateId $templateId
                    $assignedNodes += $node
                } catch {
                    Write-Error "Failed to assign template to node $($node.Caption): $_"
                }
            } else {
                $assignedNodes += $node
            }
        }
    }
    
    if ($CreateAlert -and $templateId) {
        New-ServiceMonitorAlert -Swis $Swis -TemplateName $MonitorTemplateName
    }
    
    return @{
        TemplateId = $templateId
        AssignedNodes = $assignedNodes
    }
}

$swisConnection = $null

try {
    $swisConnection = Get-SwisConnection -Server $SwisServer -User $UserName -SecurePassword $Password
    
    $serverGroups = @{
        SQLServers = $SQLServers
        IISServers = $IISServers
        DomainControllers = $DomainControllers
    }
    
    $serverGroups = $serverGroups.GetEnumerator() | Where-Object { $_.Value.Count -gt 0 }
    
    if (-not $serverGroups) {
        Write-Warning "No servers specified in any group. Use -SQLServers, -IISServers, or -DomainControllers parameters."
        return
    }
    
    $result = Invoke-ServiceMonitorAssignment -Swis $swisConnection -ServerGroups $serverGroups
    
    Write-Output "`nAssignment complete."
    Write-Output "Template ID: $($result.TemplateId)"
    Write-Output "Nodes processed: $($result.AssignedNodes.Count)"
    
    return $result
    
} finally {
    if ($swisConnection) {
        Disconnect-Swis -Swis $swisConnection
        Write-Output "Disconnected from SolarWinds"
    }
}