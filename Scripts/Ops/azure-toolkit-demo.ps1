# Demo version - Shows UI without requiring Az module

param()

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

function Show-Banner {
    Clear-Host
    Write-Host @"
`e[1;36m   ____  __  __          _____   _____ _    ___     __
  |  _ \|  \/  |   /\   |  __ \ / ____| |  | \ \   / /
  | |_) | \  / |  /  \  | |__) | |    | |__| |\ \_/ / 
  |  _ <| |\/| | / /\ \ |  _  /| |    |  __  | \   /  
  | |_) | |  | |/ ____ \| | \ \| |____| |  | |  | |   
  |____/|_|  |_/_/    \_\_|  \_\\_____|_|  |_|  |_|   
                  ADMIN TOOLKIT v1.0 (DEMO)
`e[0m
"@
}

function Get-CurrentSubscription {
    Write-ColorOutput "Current Subscription:" -Color BrightCyan
    Write-ColorOutput "Name: Production-Subscription" -Color BrightGreen
    Write-ColorOutput "ID: 12345678-1234-1234-1234-1234567890ab" -Color Cyan
    Write-ColorOutput "Tenant: 87654321-4321-4321-4321-ba0987654321" -Color Cyan
    Write-Host ""
}

function Show-MainMenu {
    while ($true) {
        Show-Banner
        Get-CurrentSubscription
        Write-ColorOutput "Main Menu" -Color BrightCyan
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
            '5' { 
                Write-ColorOutput "Switch Subscription" -Color BrightCyan
                Write-Host "Available Subscriptions:"
                Write-Host "1. Production-Subscription (12345678-1234-1234-1234-1234567890ab)"
                Write-Host "2. Development-Subscription (87654321-4321-4321-4321-87654321ba09)"
                Write-Host "3. Test-Subscription (11112222-3333-4444-5555-666677778888)"
                Read-Host "Press Enter to continue"
            }
            '0' { Write-ColorOutput "✓ Goodbye!" -Color BrightGreen; exit }
            default { Write-ColorOutput "✗ Invalid option" -Color BrightRed }
        }
    }
}

function Show-ComputeMenu {
    while ($true) {
        Show-Banner
        Get-CurrentSubscription
        Write-ColorOutput "Compute & Fixes" -Color BrightCyan
        Write-Host ""
        Write-Host "1) List Running VMs"
        Write-Host "2) Restart VM"
        Write-Host "3) Emergency Fix (DNS/WinRM)"
        Write-Host "4) Resize VM"
        Write-Host "0) Back to Main Menu"
        Write-Host ""
        
        $choice = Read-Host "Select option"
        
        switch ($choice) {
            '1' { 
                Write-ColorOutput "Running Virtual Machines" -Color BrightCyan
                Write-Host ""
                Write-Host "Name           ResourceGroup  Location   Size"
                Write-Host "----           -------------  --------   ----"
                Write-Host "web-server-01  rg-prod-eastus eastus     Standard_D2s_v3"
                Write-Host "web-server-02  rg-prod-eastus eastus     Standard_D2s_v3"
                Write-Host "app-server-01  rg-prod-westus westus     Standard_B2s"
                Write-Host "db-server-01   rg-prod-eastus eastus     Standard_D4s_v3"
                Read-Host "Press Enter to continue"
            }
            '0' { break }
            default { Write-ColorOutput "✗ Invalid option (Demo - try option 1)" -Color BrightRed; Start-Sleep -Seconds 1 }
        }
    }
}

function Show-NetworkMenu {
    while ($true) {
        Show-Banner
        Get-CurrentSubscription
        Write-ColorOutput "Networking & Diagnostics" -Color BrightCyan
        Write-Host ""
        Write-Host "1) IP Address Lookup"
        Write-Host "2) Deep Debug - Effective Routes"
        Write-Host "3) Test Connectivity"
        Write-Host "4) Packet Capture"
        Write-Host "0) Back to Main Menu"
        Write-Host ""
        
        $choice = Read-Host "Select option"
        
        switch ($choice) {
            '1' { 
                Write-ColorOutput "IP Address Lookup" -Color BrightCyan
                Write-Host ""
                Write-ColorOutput "ℹ Example: Search for IP 10.0.1.4" -Color Cyan
                Write-Host ""
                Write-Host "Name                 ResourceGroup  Location   PrivateIP"
                Write-Host "----                 -------------  --------   ---------"
                Write-Host "nic-web-server-01    rg-prod-eastus eastus     10.0.1.4"
                Write-Host ""
                Write-Host "Name                 ResourceGroup  Location   PublicIP"
                Write-Host "----                 -------------  --------   --------"
                Write-Host "pip-web-server-01    rg-prod-eastus eastus     52.123.45.67"
                Read-Host "Press Enter to continue"
            }
            '0' { break }
            default { Write-ColorOutput "✗ Invalid option (Demo - try option 1)" -Color BrightRed; Start-Sleep -Seconds 1 }
        }
    }
}

function Show-IdentityMenu {
    while ($true) {
        Show-Banner
        Get-CurrentSubscription
        Write-ColorOutput "Identity & Governance" -Color BrightCyan
        Write-Host ""
        Write-Host "1) Audit User Permissions"
        Write-Host "2) Break Glass (Add as Owner)"
        Write-Host "3) Find Orphaned Disks"
        Write-Host "0) Back to Main Menu"
        Write-Host ""
        
        $choice = Read-Host "Select option"
        
        switch ($choice) {
            '3' { 
                Write-ColorOutput "Find Orphaned Disks (Cost Savings)" -Color BrightCyan
                Write-Host ""
                Write-ColorOutput "✓ No orphaned disks found!" -Color BrightGreen
                Read-Host "Press Enter to continue"
            }
            '0' { break }
            default { Write-ColorOutput "✗ Invalid option (Demo - try option 3)" -Color BrightRed; Start-Sleep -Seconds 1 }
        }
    }
}

function Show-SearchMenu {
    while ($true) {
        Show-Banner
        Get-CurrentSubscription
        Write-ColorOutput "Global Search" -Color BrightCyan
        Write-Host ""
        Write-Host "1) Fuzzy Search by Name"
        Write-Host "0) Back to Main Menu"
        Write-Host ""
        
        $choice = Read-Host "Select option"
        
        switch ($choice) {
            '1' { 
                Write-ColorOutput "Global Resource Search (Fuzzy)" -Color BrightCyan
                Write-Host ""
                Write-ColorOutput "ℹ Searching for resources matching: web" -Color Cyan
                Write-Host ""
                Write-Host "Name                ResourceType              ResourceGroup Location"
                Write-Host "----                -----------              ------------- --------"
                Write-Host "web-server-01       Microsoft.Compute/virtualMachines rg-prod-eastus eastus"
                Write-Host "web-server-02       Microsoft.Compute/virtualMachines rg-prod-eastus eastus"
                Write-Host "web-nic-01          Microsoft.Network/networkInterfaces rg-prod-eastus eastus"
                Write-Host "web-nic-02          Microsoft.Network/networkInterfaces rg-prod-eastus eastus"
                Read-Host "Press Enter to continue"
            }
            '0' { break }
            default { Write-ColorOutput "✗ Invalid option (Demo - try option 1)" -Color BrightRed; Start-Sleep -Seconds 1 }
        }
    }
}

Show-MainMenu
