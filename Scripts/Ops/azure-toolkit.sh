#!/bin/bash

set -euo pipefail

# ANSI Color Codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Global Variables
CURRENT_SUB=""
ALL_SUBS=()

# Function: Print colored output
print_header() {
    echo -e "${BOLD}${BLUE}$1${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_info() {
    echo -e "${CYAN}ℹ $1${NC}"
}

# Function: Display Banner
display_banner() {
    clear
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}    AZURE ADMIN TOOLKIT v1.0${NC}"
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════${NC}"
    echo
}

# Function: Check prerequisites
check_prerequisites() {
    print_header "Checking Prerequisites..."
    
    if ! command -v az &> /dev/null; then
        print_error "Azure CLI (az) is not installed. Please install it first."
        exit 1
    fi
    print_success "Azure CLI found"

    if ! command -v jq &> /dev/null; then
        print_error "jq is not installed. Please install it first."
        exit 1
    fi
    print_success "jq found"

    if ! az account show &> /dev/null; then
        print_warning "Not logged in to Azure. Initiating login..."
        az login
    fi
    print_success "Logged in to Azure"
}

# Function: Get current subscription info
get_current_subscription() {
    CURRENT_SUB=$(az account show --query '{id: id, name: name, tenantId: tenantId}' -o json)
    local sub_name=$(echo "$CURRENT_SUB" | jq -r '.name')
    local sub_id=$(echo "$CURRENT_SUB" | jq -r '.id')
    print_header "Current Subscription: ${BOLD}${GREEN}$sub_name${NC}"
    echo -e "${CYAN}ID: $sub_id${NC}"
    echo
}

# Function: Switch subscription
switch_subscription() {
    print_header "Switch Subscription"
    
    ALL_SUBS=$(az account list --query '[].{id: id, name: name, isDefault: isDefault}' -o json)
    local sub_count=$(echo "$ALL_SUBS" | jq 'length')
    
    echo "Available Subscriptions:"
    echo "$ALL_SUBS" | jq -r '. | to_entries[] | "\(.key + 1): \(.value.name) (\(.value.id))"'
    
    echo
    read -p "Select subscription number: " sub_num
    
    if [[ "$sub_num" =~ ^[0-9]+$ ]] && [ "$sub_num" -ge 1 ] && [ "$sub_num" -le "$sub_count" ]; then
        local selected_id=$(echo "$ALL_SUBS" | jq -r ".[$((sub_num-1))].id")
        az account set --subscription "$selected_id"
        print_success "Switched to subscription"
        get_current_subscription
    else
        print_error "Invalid selection"
    fi
}

# Function: Confirm destructive action
confirm_action() {
    local action="$1"
    echo
    print_warning "WARNING: $action"
    read -p "Are you sure you want to proceed? (y/n): " confirm
    
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        print_info "Action cancelled"
        return 1
    fi
    return 0
}

# Function: List running VMs
get_vm_status() {
    print_header "Running Virtual Machines"
    
    az vm list --show-details \
        --query "[?powerState=='VM running'].{Name: name, ResourceGroup: resourceGroup, Location: location, Size: hardwareProfile.vmSize}" \
        -o table
}

# Function: Restart VM
restart_vm() {
    print_header "Restart Virtual Machine"
    
    get_vm_status
    echo
    
    read -p "Enter VM Name: " vm_name
    read -p "Enter Resource Group: " rg_name
    
    if confirm_action "Restart VM '$vm_name'"; then
        az vm restart --name "$vm_name" --resource-group "$rg_name" --no-wait
        print_success "Restart command sent (no-wait mode)"
    fi
}

# Function: Emergency fix - DNS flush & WinRM restart
emergency_fix() {
    print_header "Emergency Fix - DNS Flush & WinRM Restart"
    
    get_vm_status
    echo
    
    read -p "Enter VM Name: " vm_name
    read -p "Enter Resource Group: " rg_name
    read -p "OS Type (windows/linux): " os_type
    
    if confirm_action "Execute emergency fix on '$vm_name'"; then
        if [[ "$os_type" == "windows" ]]; then
            # Windows: Flush DNS and restart WinRM service
            az vm run-command invoke \
                --command-id RunPowerShellScript \
                --name "$vm_name" \
                --resource-group "$rg_name" \
                --scripts "Clear-DnsClientCache; Restart-Service WinRM -Force; Write-Host 'DNS flushed and WinRM restarted'"
            print_success "Emergency fix executed on Windows VM"
        elif [[ "$os_type" == "linux" ]]; then
            # Linux: Flush DNS cache and restart SSH
            az vm run-command invoke \
                --command-id RunShellScript \
                --name "$vm_name" \
                --resource-group "$rg_name" \
                --scripts "sudo systemd-resolve --flush-caches; sudo systemctl restart sshd; echo 'DNS flushed and SSH restarted'"
            print_success "Emergency fix executed on Linux VM"
        else
            print_error "Invalid OS type. Use 'windows' or 'linux'"
        fi
    fi
}

# Function: Resize VM
resize_vm() {
    print_header "Resize Virtual Machine"
    
    get_vm_status
    echo
    
    read -p "Enter VM Name: " vm_name
    read -p "Enter Resource Group: " rg_name
    
    echo
    print_info "Available VM sizes in this region:"
    az vm list-vm-resize-options \
        --name "$vm_name" \
        --resource-group "$rg_name" \
        --query '[].{Name: name, NumberOfCores: numberOfCores, MemoryInMB: memoryInMB}' \
        -o table | head -20
    
    echo
    read -p "Enter new VM size (e.g., D2s_v3): " new_size
    
    if confirm_action "Resize VM '$vm_name' to '$new_size'"; then
        az vm resize \
            --name "$vm_name" \
            --resource-group "$rg_name" \
            --size "$new_size"
        print_success "VM resized to $new_size"
    fi
}

# Function: Compute submenu
compute_menu() {
    while true; do
        display_banner
        get_current_subscription
        print_header "Compute & Fixes"
        echo
        echo "1) List Running VMs"
        echo "2) Restart VM"
        echo "3) Emergency Fix (DNS/WinRM)"
        echo "4) Resize VM"
        echo "0) Back to Main Menu"
        echo
        read -p "Select option: " choice
        
        case $choice in
            1) get_vm_status; read -p "Press Enter to continue..." ;;
            2) restart_vm; read -p "Press Enter to continue..." ;;
            3) emergency_fix; read -p "Press Enter to continue..." ;;
            4) resize_vm; read -p "Press Enter to continue..." ;;
            0) break ;;
            *) print_error "Invalid option" ;;
        esac
    done
}

# Function: IP Lookup via Azure Resource Graph
ip_lookup() {
    print_header "IP Address Lookup"
    
    read -p "Enter IP Address (public or private): " ip_address
    
    echo
    print_info "Searching for resources with IP: $ip_address"
    
    local query="where type =~ 'Microsoft.Network/*' or type =~ 'Microsoft.Compute/*'"
    query="$query | where properties.ipConfigurations != null or properties.privateIPAddress == '$ip_address' or properties.publicIPAddress == '$ip_address'"
    
    az graph query -q "$query" -o table 2>/dev/null || {
        # Fallback: Search NICs directly
        print_info "Searching Network Interfaces..."
        az network nic list --query "[?contains(to_string(properties.ipConfigurations[0].properties.privateIPAddress), '$ip_address')].{Name: name, RG: resourceGroup, Location: location, PrivateIP: properties.ipConfigurations[0].properties.privateIPAddress}" -o table
        
        print_info "Searching Public IP Addresses..."
        az network public-ip list --query "[?properties.ipAddress == '$ip_address'].{Name: name, RG: resourceGroup, Location: location, PublicIP: properties.ipAddress}" -o table
    }
}

# Function: Deep debug - Effective Route Table
debug_routing() {
    print_header "Deep Debug - Effective Route Table"
    
    print_info "Available Network Interfaces:"
    az network nic list --query '[].{Name: name, RG: resourceGroup, Location: location}' -o table | head -20
    
    echo
    read -p "Enter NIC Name: " nic_name
    read -p "Enter Resource Group: " rg_name
    
    echo
    print_info "Effective Route Table for $nic_name:"
    az network nic show-effective-route-table \
        --name "$nic_name" \
        --resource-group "$rg_name" \
        -o json | jq '.value[] | {name: .name, source: .source, state: .state, addressPrefix: .addressPrefix, nextHopType: .nextHopType}'
}

# Function: Test Connectivity
test_connectivity() {
    print_header "Network Connectivity Test"
    
    read -p "Enter Source Resource ID or VM Name: " source
    read -p "Enter Destination IP Address: " dest_ip
    read -p "Destination Port (default 80): " dest_port
    dest_port=${dest_port:-80}
    
    print_info "Testing connectivity from $source to $dest_ip:$dest_port"
    
    az network watcher test-connectivity \
        --source-resource "$source" \
        --dest-address "$dest_ip" \
        --dest-port "$dest_port" \
        -o json | jq '.{status: .connectionStatus, latency: .latency, avgLatency: .avgLatency}'
}

# Function: Packet Capture
packet_capture() {
    print_header "Packet Capture"
    
    get_vm_status
    echo
    
    read -p "Enter VM Name: " vm_name
    read -p "Enter Resource Group: " rg_name
    read -p "Enter Network Watcher Region: " region
    read -p "Capture Filter (optional, e.g., 'port 80'): " filter
    
    local capture_name="capture-$(date +%Y%m%d-%H%M%S)"
    local storage_account="${rg_name}-cap$(date +%s | cut -c6-10)"
    
    print_info "Creating packet capture: $capture_name"
    
    if confirm_action "Start 60-second packet capture on '$vm_name'"; then
        # Check if storage account exists, create if not
        if ! az storage account show --name "$storage_account" &>/dev/null; then
            print_info "Creating storage account $storage_account..."
            az storage account create \
                --name "$storage_account" \
                --resource-group "$rg_name" \
                --location "$region" \
                --sku Standard_LRS
        fi
        
        # Create packet capture
        az network watcher packet-capture create \
            --resource-group "$rg_name" \
            --vm "$vm_name" \
            --name "$capture_name" \
            --storage-account "$storage_account" \
            --time-limit 60 \
            ${filter:+--filters "[$filter]"}
        
        print_success "Packet capture started. Duration: 60 seconds"
        print_info "Capture will be saved in storage account: $storage_account"
    fi
}

# Function: Networking submenu
network_menu() {
    while true; do
        display_banner
        get_current_subscription
        print_header "Networking & Diagnostics"
        echo
        echo "1) IP Address Lookup"
        echo "2) Deep Debug - Effective Routes"
        echo "3) Test Connectivity"
        echo "4) Packet Capture"
        echo "0) Back to Main Menu"
        echo
        read -p "Select option: " choice
        
        case $choice in
            1) ip_lookup; read -p "Press Enter to continue..." ;;
            2) debug_routing; read -p "Press Enter to continue..." ;;
            3) test_connectivity; read -p "Press Enter to continue..." ;;
            4) packet_capture; read -p "Press Enter to continue..." ;;
            0) break ;;
            *) print_error "Invalid option" ;;
        esac
    done
}

# Function: Audit User Permissions
audit_user() {
    print_header "Audit User Permissions"
    
    read -p "Enter User/Service Principal email or object ID: " user_id
    
    local sub_id=$(echo "$CURRENT_SUB" | jq -r '.id')
    
    echo
    print_info "Checking effective permissions for: $user_id"
    
    # Get role assignments for the user
    print_info "Role Assignments:"
    az role assignment list \
        --assignee "$user_id" \
        --include-inherited \
        --include-groups \
        --query "[].{Role: roleDefinitionName, Scope: scope, Assigned: principalName}" \
        -o table
    
    echo
    print_info "Direct Assignments on Subscription:"
    az role assignment list \
        --assignee "$user_id" \
        --scope "/subscriptions/$sub_id" \
        --query "[].{Role: roleDefinitionName}" \
        -o table
}

# Function: Break Glass - Add as Owner
break_glass() {
    print_header "Break Glass - Emergency Access"
    
    local current_user=$(az account show --query user.name -o tsv)
    
    print_warning "This will add you as Owner to the subscription!"
    print_error "This is a privileged action and will be logged."
    print_info "Your email: $current_user"
    
    if confirm_action "Add '$current_user' as Owner to subscription"; then
        local sub_id=$(echo "$CURRENT_SUB" | jq -r '.id')
        
        az role assignment create \
            --assignee "$current_user" \
            --role "Owner" \
            --scope "/subscriptions/$sub_id"
        
        print_success "Owner role assigned to $current_user"
        print_warning "Remember to remove this access after the emergency!"
    fi
}

# Function: Find Orphaned Disks
find_orphaned_disks() {
    print_header "Find Orphaned Disks (Cost Savings)"
    
    print_info "Scanning for unattached managed disks..."
    
    local orphaned_disks=$(az disk list \
        --query "[?managedBy==null].{Name: name, RG: resourceGroup, Location: location, SizeGB: diskSizeGB, SKU: sku.name}" \
        -o json)
    
    local count=$(echo "$orphaned_disks" | jq 'length')
    
    if [ "$count" -eq 0 ]; then
        print_success "No orphaned disks found!"
    else
        print_warning "Found $count orphaned disk(s):"
        echo "$orphaned_disks" | jq -r '.[] | "\(.Name) | \(.RG) | \(.Location) | \(.SizeGB)GB | \(.SKU)"' | column -t -s '|'
        
        echo
        local total_gb=$(echo "$orphaned_disks" | jq '[.[].SizeGB] | add // 0')
        print_info "Total unattached storage: ${total_gb}GB"
        print_info "These disks can be safely deleted to save costs."
    fi
}

# Function: Identity submenu
identity_menu() {
    while true; do
        display_banner
        get_current_subscription
        print_header "Identity & Governance"
        echo
        echo "1) Audit User Permissions"
        echo "2) Break Glass (Add as Owner)"
        echo "3) Find Orphaned Disks"
        echo "0) Back to Main Menu"
        echo
        read -p "Select option: " choice
        
        case $choice in
            1) audit_user; read -p "Press Enter to continue..." ;;
            2) break_glass; read -p "Press Enter to continue..." ;;
            3) find_orphaned_disks; read -p "Press Enter to continue..." ;;
            0) break ;;
            *) print_error "Invalid option" ;;
        esac
    done
}

# Function: Global Resource Search
global_search() {
    print_header "Global Resource Search (Fuzzy)"
    
    read -p "Enter resource name or partial name: " search_term
    
    echo
    print_info "Searching for resources matching: $search_term"
    
    local query="where name contains '$search_term'"
    query="$query | project name, type, resourceGroup, subscriptionId, location"
    query="$query | order by name asc"
    
    az graph query -q "$query" -o table
}

# Function: Global Search submenu
search_menu() {
    while true; do
        display_banner
        get_current_subscription
        print_header "Global Search"
        echo
        echo "1) Fuzzy Search by Name"
        echo "0) Back to Main Menu"
        echo
        read -p "Select option: " choice
        
        case $choice in
            1) global_search; read -p "Press Enter to continue..." ;;
            0) break ;;
            *) print_error "Invalid option" ;;
        esac
    done
}

# Function: Main Menu
main_menu() {
    while true; do
        display_banner
        get_current_subscription
        print_header "Main Menu"
        echo
        echo "1) Compute & Fixes"
        echo "2) Networking & Diagnostics"
        echo "3) Identity & Governance"
        echo "4) Global Search"
        echo "5) Switch Subscription"
        echo "0) Exit"
        echo
        read -p "Select option: " choice
        
        case $choice in
            1) compute_menu ;;
            2) network_menu ;;
            3) identity_menu ;;
            4) search_menu ;;
            5) switch_subscription; read -p "Press Enter to continue..." ;;
            0) 
                print_success "Goodbye!"
                exit 0
                ;;
            *) print_error "Invalid option" ;;
        esac
    done
}

# Main execution
main() {
    check_prerequisites
    get_current_subscription
    main_menu
}

main "$@"
