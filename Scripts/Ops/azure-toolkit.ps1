#Requires -Modules Az

param()

# Define color scheme
$colors = @{
    Header = 'Cyan'
    Success = 'Green'
    Error = 'Red'
    Warning = 'Yellow'
    Info = 'Cyan'
}

function Write-ColorOutput {
    param(
        [string]$Message,
        [string]$Color = 'White',
        [switch]$NoNewline
    )
    
    $ansiColors = @{
        Black = 30
        Red = 31
        Green = 32
        Yellow = 33
        Blue = 34
        Magenta = 35
        Cyan = 36
        White = 37
        BrightBlack = 90
        BrightRed = 91
        BrightGreen = 92
        BrightYellow = 93
        BrightBlue = 94
        BrightMagenta = 95
        BrightCyan = 96
        BrightWhite = 97
    }
    
    $colorCode = $ansiColors[$Color]
    $reset = "`e[0m"
    $bold = "`e[1m"
    
    $output = "$bold`e[${colorCode}m${Message}${reset}"
    if ($NoNewline) {
        Write-Host -NoNewline $output
    } else {
        Write-Host $output
    }
}

function Write-Header {
    param([string]$Message)
    Write-ColorOutput -Message $Message -Color BrightCyan
}

function Write-Success {
    param([string]$Message)
    Write-ColorOutput -Message "✓ $Message" -Color BrightGreen
}

function Write-Error {
    param([string]$Message)
    Write-ColorOutput -Message "✗ $Message" -Color BrightRed
}

function Write-Warning {
    param([string]$Message)
    Write-ColorOutput -Message "⚠ $Message" -Color BrightYellow
}

function Write-Info {
    param([string]$Message)
    Write-ColorOutput -Message "ℹ $Message" -Color Cyan
}

function Show-Banner {
    Clear-Host
    Write-Host "`e[1;36m═══════════════════════════════════════════`e[0m"
    Write-Host "`e[1;36m    AZURE ADMIN TOOLKIT v1.0`e[0m"
    Write-Host "`e[1;36m═══════════════════════════════════════════`e[0m"
    Write-Host ""
}

function Test-Prerequisites {
    Write-Header "Checking Prerequisites..."
    
    $module = Get-Module -ListAvailable -Name Az -ErrorAction SilentlyContinue
    if (-not $module) {
        Write-Error "Az PowerShell module not installed. Run: Install-Module -Name Az"
        exit 1
    }
    Write-Success "Az PowerShell module found"
    
    $context = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $context) {
        Write-Warning "Not logged in to Azure. Initiating login..."
        Connect-AzAccount
    }
    Write-Success "Logged in to Azure"
}

function Get-CurrentSubscription {
    $global:currentContext = Get-AzContext
    $subName = $global:currentContext.Subscription.Name
    $subId = $global:currentContext.Subscription.Id
    $tenantId = $global:currentContext.Tenant.Id
    
    Write-Header "Current Subscription:"
    Write-ColorOutput -Message "Name: $subName" -Color BrightGreen
    Write-ColorOutput -Message "ID: $subId" -Color Cyan
    Write-ColorOutput -Message "Tenant: $tenantId" -Color Cyan
    Write-Host ""
}

function Switch-Subscription {
    Write-Header "Switch Subscription"
    
    $subscriptions = Get-AzSubscription
    $i = 1
    
    Write-Host "Available Subscriptions:"
    foreach ($sub in $subscriptions) {
        Write-Host "$i. $($sub.Name) ($($sub.Id))"
        $i++
    }
    
    Write-Host ""
    $selection = Read-Host "Select subscription number"
    
    if ($selection -match '^\d+$' -and $selection -ge 1 -and $selection -le $subscriptions.Count) {
        $selectedSub = $subscriptions[$selection - 1]
        Set-AzContext -SubscriptionId $selectedSub.Id | Out-Null
        Write-Success "Switched to $($selectedSub.Name)"
        Get-CurrentSubscription
    } else {
        Write-Error "Invalid selection"
    }
}

function Test-Confirmation {
    param([string]$Action)
    
    Write-Host ""
    Write-Warning "WARNING: $Action"
    $confirm = Read-Host "Are you sure you want to proceed? (y/n)"
    
    if ($confirm -ne 'y' -and $confirm -ne 'Y') {
        Write-Info "Action cancelled"
        return $false
    }
    return $true
}

function Get-VMStatus {
    Write-Header "Running Virtual Machines"
    
    $vms = Get-AzVM -Status | Where-Object { $_.PowerState -eq 'VM running' }
    
    if ($vms.Count -eq 0) {
        Write-Info "No running VMs found"
        return
    }
    
    $vms | Format-Table Name, ResourceGroupName, Location, @{Name='Size'; Expression={$_.HardwareProfile.VmSize}} -AutoSize
}

function Restart-AzureVM {
    Write-Header "Restart Virtual Machine"
    
    Get-VMStatus
    Write-Host ""
    
    $vmName = Read-Host "Enter VM Name"
    $rgName = Read-Host "Enter Resource Group"
    
    if (Test-Confirmation -Action "Restart VM '$vmName'") {
        Restart-AzVM -Name $vmName -ResourceGroupName $rgName -NoWait
        Write-Success "Restart command sent (no-wait mode)"
    }
}

function Invoke-EmergencyFix {
    Write-Header "Emergency Fix - DNS Flush & WinRM Restart"
    
    Get-VMStatus
    Write-Host ""
    
    $vmName = Read-Host "Enter VM Name"
    $rgName = Read-Host "Enter Resource Group"
    $osType = Read-Host "OS Type (windows/linux)"
    
    if (Test-Confirmation -Action "Execute emergency fix on '$vmName'") {
        if ($osType -eq 'windows') {
            Invoke-AzVMRunCommand `
                -ResourceGroupName $rgName `
                -VMName $vmName `
                -CommandId 'RunPowerShellScript' `
                -ScriptString "Clear-DnsClientCache; Restart-Service WinRM -Force; Write-Host 'DNS flushed and WinRM restarted'"
            Write-Success "Emergency fix executed on Windows VM"
        } elseif ($osType -eq 'linux') {
            Invoke-AzVMRunCommand `
                -ResourceGroupName $rgName `
                -VMName $vmName `
                -CommandId 'RunShellScript' `
                -ScriptString "sudo systemd-resolve --flush-caches 2>/dev/null || sudo service dns-clean restart; sudo systemctl restart sshd; echo 'DNS flushed and SSH restarted'"
            Write-Success "Emergency fix executed on Linux VM"
        } else {
            Write-Error "Invalid OS type. Use 'windows' or 'linux'"
        }
    }
}

function Resize-AzureVM {
    Write-Header "Resize Virtual Machine"
    
    Get-VMStatus
    Write-Host ""
    
    $vmName = Read-Host "Enter VM Name"
    $rgName = Read-Host "Enter Resource Group"
    
    Write-Host ""
    Write-Info "Available VM sizes in this region:"
    $vm = Get-AzVM -Name $vmName -ResourceGroupName $rgName
    $location = $vm.Location
    
    $sizes = Get-AzVMSize -Location $location | Select-Object -First 20
    $sizes | Format-Table Name, NumberOfCores, MemoryInMB -AutoSize
    
    Write-Host ""
    $newSize = Read-Host "Enter new VM size (e.g., D2s_v3)"
    
    if (Test-Confirmation -Action "Resize VM '$vmName' to '$newSize'") {
        $vm.HardwareProfile.VmSize = $newSize
        Update-AzVM -VM $vm -ResourceGroupName $rgName
        Write-Success "VM resized to $newSize"
    }
}

function Show-ComputeMenu {
    while ($true) {
        Show-Banner
        Get-CurrentSubscription
        Write-Header "Compute & Fixes"
        Write-Host ""
        Write-Host "1) List Running VMs"
        Write-Host "2) Restart VM"
        Write-Host "3) Emergency Fix (DNS/WinRM)"
        Write-Host "4) Resize VM"
        Write-Host "0) Back to Main Menu"
        Write-Host ""
        
        $choice = Read-Host "Select option"
        
        switch ($choice) {
            '1' { Get-VMStatus; Read-Host "Press Enter to continue" }
            '2' { Restart-AzureVM; Read-Host "Press Enter to continue" }
            '3' { Invoke-EmergencyFix; Read-Host "Press Enter to continue" }
            '4' { Resize-AzureVM; Read-Host "Press Enter to continue" }
            '0' { break }
            default { Write-Error "Invalid option" }
        }
    }
}

function Search-IPAddress {
    Write-Header "IP Address Lookup"
    
    $ipAddress = Read-Host "Enter IP Address (public or private)"
    
    Write-Host ""
    Write-Info "Searching for resources with IP: $ipAddress"
    
    Write-Info "Searching Network Interfaces..."
    $nics = Get-AzNetworkInterface
    $foundNics = $nics | Where-Object { $_.IpConfigurations.PrivateIpAddress -eq $ipAddress }
    
    if ($foundNics) {
        $foundNics | Format-Table Name, ResourceGroupName, Location, @{Name='PrivateIP'; Expression={$_.IpConfigurations.PrivateIpAddress}} -AutoSize
    } else {
        Write-Info "No NICs found with IP $ipAddress"
    }
    
    Write-Host ""
    Write-Info "Searching Public IP Addresses..."
    $publicIps = Get-AzPublicIpAddress
    $foundPublic = $publicIps | Where-Object { $_.IpAddress -eq $ipAddress }
    
    if ($foundPublic) {
        $foundPublic | Format-Table Name, ResourceGroupName, Location, IpAddress, @{Name='AllocationMethod'; Expression={$_.PublicIpAllocationMethod}} -AutoSize
    } else {
        Write-Info "No Public IPs found with IP $ipAddress"
    }
}

function Show-RoutingDebug {
    Write-Header "Deep Debug - Effective Route Table"
    
    Write-Info "Available Network Interfaces:"
    $nics = Get-AzNetworkInterface | Select-Object -First 20
    $nics | Format-Table Name, ResourceGroupName, Location -AutoSize
    
    Write-Host ""
    $nicName = Read-Host "Enter NIC Name"
    $rgName = Read-Host "Enter Resource Group"
    
    Write-Host ""
    Write-Info "Effective Route Table for $nicName:"
    
    try {
        $nic = Get-AzNetworkInterface -Name $nicName -ResourceGroupName $rgName
        $routes = Get-AzEffectiveRouteTable -NetworkInterface $nic
        
        $routes | Format-Table Name, Source, State, AddressPrefix, NextHopType, NextHopIpAddress -AutoSize
    } catch {
        Write-Error "Failed to get effective routes: $_"
    }
}

function Test-NetworkConnectivity {
    Write-Header "Network Connectivity Test"
    
    $source = Read-Host "Enter Source Resource ID or VM Name"
    $destIp = Read-Host "Enter Destination IP Address"
    $destPort = Read-Host "Destination Port (default: 80)"
    if (-not $destPort) { $destPort = 80 }
    
    Write-Info "Testing connectivity from $source to $destIp:$destPort"
    
    try {
        $result = Test-AzNetworkWatcherConnectivity `
            -SourceId $source `
            -DestinationAddress $destIp `
            -DestinationPort $destPort
        
        Write-Host ""
        Write-Host "Status: $($result.ConnectionStatus)"
        Write-Host "Latency: $($result.Latency)ms"
        Write-Host "Avg Latency: $($result.AvgLatency)ms"
        
        if ($result.ConnectionStatus -eq 'Success') {
            Write-Success "Connectivity test passed"
        } else {
            Write-Error "Connectivity test failed"
        }
    } catch {
        Write-Error "Failed to test connectivity: $_"
    }
}

function Start-PacketCapture {
    Write-Header "Packet Capture"
    
    Get-VMStatus
    Write-Host ""
    
    $vmName = Read-Host "Enter VM Name"
    $rgName = Read-Host "Enter Resource Group"
    $region = Read-Host "Enter Network Watcher Region"
    $filter = Read-Host "Capture Filter (optional, e.g., 'TCP.Port == 80')"
    
    $captureName = "capture-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    $storageAccount = "$($rgName)-cap$(Get-Random -Maximum 99999)"
    
    Write-Info "Creating packet capture: $captureName"
    
    if (Test-Confirmation -Action "Start 60-second packet capture on '$vmName'") {
        try {
            $storage = Get-AzStorageAccount -ResourceGroupName $rgName -Name $storageAccount -ErrorAction SilentlyContinue
            if (-not $storage) {
                Write-Info "Creating storage account $storageAccount..."
                New-AzStorageAccount `
                    -ResourceGroupName $rgName `
                    -Name $storageAccount `
                    -Location $region `
                    -SkuName Standard_LRS `
                    | Out-Null
            }
            
            $nw = Get-AzNetworkWatcher -Location $region
            $vm = Get-AzVM -Name $vmName -ResourceGroupName $rgName
            $nic = Get-AzNetworkInterface -ResourceGroupName $rgName | Where-Object { $_.VirtualMachine.Id -eq $vm.Id }
            
            $config = New-AzNetworkWatcherPacketCaptureConfig `
                -TargetObjectId $nic.Id `
                -StorageAccountId $storage.Id `
                -TimeLimitInSeconds 60 `
                -LocalFilePath "C:\captures\$captureName.cap"
            
            if ($filter) {
                $config.Filters = @([Microsoft.Azure.Commands.Network.Models.PSPacketCaptureFilter]::new($filter))
            }
            
            New-AzNetworkWatcherPacketCapture `
                -NetworkWatcher $nw `
                -PacketCaptureConfiguration $config `
                | Out-Null
            
            Write-Success "Packet capture started. Duration: 60 seconds"
            Write-Info "Capture will be saved in storage account: $storageAccount"
        } catch {
            Write-Error "Failed to start packet capture: $_"
        }
    }
}

function Show-NetworkMenu {
    while ($true) {
        Show-Banner
        Get-CurrentSubscription
        Write-Header "Networking & Diagnostics"
        Write-Host ""
        Write-Host "1) IP Address Lookup"
        Write-Host "2) Deep Debug - Effective Routes"
        Write-Host "3) Test Connectivity"
        Write-Host "4) Packet Capture"
        Write-Host "0) Back to Main Menu"
        Write-Host ""
        
        $choice = Read-Host "Select option"
        
        switch ($choice) {
            '1' { Search-IPAddress; Read-Host "Press Enter to continue" }
            '2' { Show-RoutingDebug; Read-Host "Press Enter to continue" }
            '3' { Test-NetworkConnectivity; Read-Host "Press Enter to continue" }
            '4' { Start-PacketCapture; Read-Host "Press Enter to continue" }
            '0' { break }
            default { Write-Error "Invalid option" }
        }
    }
}

function Audit-UserPermissions {
    Write-Header "Audit User Permissions"
    
    $userId = Read-Host "Enter User/Service Principal email or object ID"
    
    Write-Host ""
    Write-Info "Checking effective permissions for: $userId"
    
    Write-Info "Role Assignments:"
    $assignments = Get-AzRoleAssignment -ObjectId $userId -IncludeClassicAdministrators -ExpandPrincipalGroups
    
    $assignments | Select-Object RoleDefinitionName, Scope, DisplayName, SignInName | Format-Table -AutoSize
    
    Write-Host ""
    Write-Info "Direct Assignments on Subscription:"
    $subId = $global:currentContext.Subscription.Id
    $subAssignments = $assignments | Where-Object { $_.Scope -eq "/subscriptions/$subId" }
    
    if ($subAssignments) {
        $subAssignments | Select-Object RoleDefinitionName, DisplayName | Format-Table -AutoSize
    } else {
        Write-Info "No direct assignments on current subscription"
    }
}

function Invoke-BreakGlass {
    Write-Header "Break Glass - Emergency Access"
    
    $currentUser = $global:currentContext.Account.Id
    
    Write-Warning "This will add you as Owner to the subscription!"
    Write-Error "This is a privileged action and will be logged."
    Write-Info "Your email: $currentUser"
    
    if (Test-Confirmation -Action "Add '$currentUser' as Owner to subscription") {
        $subId = $global:currentContext.Subscription.Id
        
        New-AzRoleAssignment `
            -ObjectId $currentUser `
            -RoleDefinitionName "Owner" `
            -Scope "/subscriptions/$subId" `
            | Out-Null
        
        Write-Success "Owner role assigned to $currentUser"
        Write-Warning "Remember to remove this access after the emergency!"
    }
}

function Find-OrphanedDisks {
    Write-Header "Find Orphaned Disks (Cost Savings)"
    
    Write-Info "Scanning for unattached managed disks..."
    
    $disks = Get-AzDisk
    $orphaned = $disks | Where-Object { -not $_.ManagedBy }
    
    if ($orphaned.Count -eq 0) {
        Write-Success "No orphaned disks found!"
    } else {
        Write-Warning "Found $($orphaned.Count) orphaned disk(s):"
        $orphaned | Format-Table Name, ResourceGroupName, Location, @{Name='SizeGB'; Expression={$_.DiskSizeGB}}, @{Name='SKU'; Expression={$_.Sku.Name}} -AutoSize
        
        Write-Host ""
        $totalGB = ($orphaned | Measure-Object -Property DiskSizeGB -Sum).Sum
        Write-Info "Total unattached storage: ${totalGB}GB"
        Write-Info "These disks can be safely deleted to save costs."
    }
}

function Show-IdentityMenu {
    while ($true) {
        Show-Banner
        Get-CurrentSubscription
        Write-Header "Identity & Governance"
        Write-Host ""
        Write-Host "1) Audit User Permissions"
        Write-Host "2) Break Glass (Add as Owner)"
        Write-Host "3) Find Orphaned Disks"
        Write-Host "0) Back to Main Menu"
        Write-Host ""
        
        $choice = Read-Host "Select option"
        
        switch ($choice) {
            '1' { Audit-UserPermissions; Read-Host "Press Enter to continue" }
            '2' { Invoke-BreakGlass; Read-Host "Press Enter to continue" }
            '3' { Find-OrphanedDisks; Read-Host "Press Enter to continue" }
            '0' { break }
            default { Write-Error "Invalid option" }
        }
    }
}

function Search-GlobalResources {
    Write-Header "Global Resource Search (Fuzzy)"
    
    $searchTerm = Read-Host "Enter resource name or partial name"
    
    Write-Host ""
    Write-Info "Searching for resources matching: $searchTerm"
    
    # Search across current subscription
    $resources = Get-AzResource | Where-Object { $_.Name -like "*$searchTerm*" -or $_.ResourceGroupName -like "*$searchTerm*" }
    
    if ($resources.Count -eq 0) {
        Write-Info "No resources found matching '$searchTerm'"
    } else {
        $resources | Select-Object Name, ResourceType, ResourceGroupName, Location | Format-Table -AutoSize
    }
}

function Show-SearchMenu {
    while ($true) {
        Show-Banner
        Get-CurrentSubscription
        Write-Header "Global Search"
        Write-Host ""
        Write-Host "1) Fuzzy Search by Name"
        Write-Host "0) Back to Main Menu"
        Write-Host ""
        
        $choice = Read-Host "Select option"
        
        switch ($choice) {
            '1' { Search-GlobalResources; Read-Host "Press Enter to continue" }
            '0' { break }
            default { Write-Error "Invalid option" }
        }
    }
}

function Show-MainMenu {
    while ($true) {
        Show-Banner
        Get-CurrentSubscription
        Write-Header "Main Menu"
        Write-Host ""
        Write-Host "1) Compute & Fixes"
        Write-Host "2) Networking & Diagnostics"
        Write-Host "3) Identity & Governance"
        Write-Host "4) Global Search"
        Write-Host "5) Switch Subscription"
        Write-Host "0) Exit"
        Write-Host ""
        
        $choice = Read-Host "Select option"
        
        switch ($choice) {
            '1' { Show-ComputeMenu }
            '2' { Show-NetworkMenu }
            '3' { Show-IdentityMenu }
            '4' { Show-SearchMenu }
            '5' { Switch-Subscription; Read-Host "Press Enter to continue" }
            '0' { Write-Success "Goodbye!"; exit }
            default { Write-Error "Invalid option" }
        }
    }
}

# Main execution
try {
    Test-Prerequisites
    Get-CurrentSubscription
    Show-MainMenu
} catch {
    Write-Error "An error occurred: $_"
    exit 1
}
