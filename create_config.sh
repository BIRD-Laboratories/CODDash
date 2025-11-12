#!/bin/sh

# Configuration file path
CONFIG_FILE="config.json"
BACKUP_FILE="config.json.backup.$(date +%Y%m%d_%H%M%S)"

# Function to print output
print_info() {
    echo "[INFO] $1"
}

print_success() {
    echo "[SUCCESS] $1"
}

print_warning() {
    echo "[WARNING] $1"
}

print_error() {
    echo "[ERROR] $1"
}

# Function to validate IP address
validate_ip() {
    local ip=$1
    if echo "$ip" | grep -E '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$' >/dev/null; then
        # Split IP into octets
        local oct1=$(echo "$ip" | cut -d. -f1)
        local oct2=$(echo "$ip" | cut -d. -f2)
        local oct3=$(echo "$ip" | cut -d. -f3)
        local oct4=$(echo "$ip" | cut -d. -f4)
        
        if [ "$oct1" -ge 0 ] 2>/dev/null && [ "$oct1" -le 255 ] 2>/dev/null &&
           [ "$oct2" -ge 0 ] 2>/dev/null && [ "$oct2" -le 255 ] 2>/dev/null &&
           [ "$oct3" -ge 0 ] 2>/dev/null && [ "$oct3" -le 255 ] 2>/dev/null &&
           [ "$oct4" -ge 0 ] 2>/dev/null && [ "$oct4" -le 255 ] 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

# Function to validate number
validate_number() {
    local num=$1
    if echo "$num" | grep -E '^[0-9]+$' >/dev/null && [ "$num" -gt 0 ] 2>/dev/null; then
        return 0
    fi
    return 1
}

# Function to get input with default value
get_input() {
    local prompt="$1"
    local default="$2"
    local var_name="$3"
    local validator="$4"
    
    while true; do
        if [ -n "$default" ]; then
            printf "%s [%s]: " "$prompt" "$default"
            read input
            if [ -z "$input" ]; then
                input="$default"
            fi
        else
            printf "%s: " "$prompt"
            read input
        fi
        
        if [ -z "$input" ]; then
            print_error "This field cannot be empty."
            continue
        fi
        
        # Run validator if provided
        if [ -n "$validator" ]; then
            if $validator "$input"; then
                eval "$var_name=\$input"
                break
            else
                print_error "Invalid input. Please try again."
            fi
        else
            eval "$var_name=\$input"
            break
        fi
    done
}

# Function to get yes/no input
get_yes_no() {
    local prompt="$1"
    local default="$2"
    local var_name="$3"
    
    while true; do
        if [ -n "$default" ]; then
            printf "%s [y/N]: " "$prompt"
            read input
            if [ -z "$input" ]; then
                input="$default"
            fi
        else
            printf "%s [y/N]: " "$prompt"
            read input
        fi
        
        case "$(echo "$input" | tr '[:upper:]' '[:lower:]')" in
            y|yes)
                eval "$var_name=true"
                break
                ;;
            n|no|"")
                eval "$var_name=false"
                break
                ;;
            *)
                print_error "Please enter 'y' for yes or 'n' for no."
                ;;
        esac
    done
}

# Function to check dependencies
check_dependencies() {
    print_info "Checking dependencies..."
    
    local missing_deps=""
    
    # Check for common network tools
    for tool in ip nmap ss; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_deps="$missing_deps $tool"
        fi
    done
    
    if [ -n "$missing_deps" ]; then
        print_warning "Missing dependencies: $missing_deps"
        print_info "Some auto-detection features may be limited"
    else
        print_success "All dependencies available"
    fi
}

# Main configuration function
main() {
    print_info "Dynamic VM Management System - Auto Configuration"
    echo "=========================================================="
    echo "This script will create a configuration file."
    echo ""
    
    # Check dependencies
    check_dependencies
    
    # Backup existing config
    if [ -f "$CONFIG_FILE" ]; then
        print_warning "Configuration file already exists. Creating backup: $BACKUP_FILE"
        cp "$CONFIG_FILE" "$BACKUP_FILE"
    fi
    
    # Server Configuration
    print_info "Server Configuration"
    echo "----------------------"
    get_input "Enter API server port" "3000" SERVER_PORT validate_number
    get_input "Enter server host IP" "0.0.0.0" SERVER_HOST validate_ip
    get_input "Enter log level (DEBUG/INFO/WARNING/ERROR)" "INFO" LOG_LEVEL
    get_input "Enter log file path" "vm_service.log" LOG_FILE

    # Proxmox Configuration
    print_info "Proxmox VE Configuration"
    echo "---------------------------"
    get_input "Enter Proxmox server URL (https://ip:8006)" "https://192.168.1.100:8006" PROXMOX_HOST
    get_input "Enter Proxmox username with realm" "root@pam" PROXMOX_USERNAME
    get_input "Enter Proxmox password" "" PROXMOX_PASSWORD
    get_input "Enter Proxmox node name" "pve" PROXMOX_NODE
    get_input "Enter template VM ID" "1000" TEMPLATE_VM_ID validate_number
    get_input "Enter storage name" "local-lvm" PROXMOX_STORAGE
    get_yes_no "Verify SSL certificates? (recommended: no for self-signed)" "no" VERIFY_SSL

    # Guacamole Configuration
    print_info "Apache Guacamole Configuration"
    echo "----------------------------------"
    get_input "Enter Guacamole server URL" "http://192.168.1.101:8080/guacamole" GUACAMOLE_HOST
    get_input "Enter Guacamole username" "guacadmin" GUACAMOLE_USERNAME
    get_input "Enter Guacamole password" "guacadmin" GUACAMOLE_PASSWORD
    get_input "Enter Guacamole data source" "mysql" GUACAMOLE_DATASOURCE

    # VM Pool Configuration
    print_info "VM Pool Configuration"
    echo "-----------------------"
    get_input "Enter base load (minimum VMs to keep running)" "4" BASE_LOAD validate_number
    get_input "Enter maximum users per VM" "3" USERS_PER_VM validate_number
    get_input "Enter maximum VMs that can be created" "20" MAX_VMS validate_number
    get_input "Enter check interval in seconds" "30" CHECK_INTERVAL validate_number
    get_input "Enter CPU cores per VM" "2" VM_CPU validate_number
    get_input "Enter memory per VM in MB" "4096" VM_MEMORY validate_number
    get_input "Enter disk size per VM (e.g., 32G)" "32G" VM_DISK
    get_input "Enter health check timeout in seconds" "300" HEALTH_TIMEOUT validate_number

    # Network Configuration
    print_info "Network Configuration"
    echo "-----------------------"
    get_input "Enter base IP for VM assignments" "192.168.1.100" BASE_IP validate_ip
    get_input "Enter network subnet (CIDR)" "192.168.1.0/24" SUBNET
    get_input "Enter network gateway" "192.168.1.1" GATEWAY validate_ip
    get_input "Enter DNS server" "8.8.8.8" DNS_SERVER validate_ip
    get_input "Enter DHCP range start" "192.168.1.100" DHCP_START validate_ip
    get_input "Enter DHCP range end" "192.168.1.200" DHCP_END validate_ip

    # Monitoring Configuration
    print_info "Monitoring Configuration"
    echo "---------------------------"
    get_yes_no "Enable health checks?" "yes" ENABLE_HEALTH_CHECKS
    get_input "Enter health check interval in seconds" "60" HEALTH_CHECK_INTERVAL validate_number
    get_input "Enter maximum VM creation attempts" "3" MAX_CREATION_ATTEMPTS validate_number
    get_input "Enter VM ready timeout in seconds" "300" VM_READY_TIMEOUT validate_number

    # Convert boolean values to lowercase for JSON
    if [ "$VERIFY_SSL" = "true" ]; then
        VERIFY_SSL_JSON="true"
    else
        VERIFY_SSL_JSON="false"
    fi
    
    if [ "$ENABLE_HEALTH_CHECKS" = "true" ]; then
        ENABLE_HEALTH_CHECKS_JSON="true"
    else
        ENABLE_HEALTH_CHECKS_JSON="false"
    fi

    # Create the JSON configuration using printf to avoid shell issues
    {
        printf "{\n"
        printf "  \"server\": {\n"
        printf "    \"port\": %s,\n" "$SERVER_PORT"
        printf "    \"host\": \"%s\",\n" "$SERVER_HOST"
        printf "    \"log_level\": \"%s\",\n" "$LOG_LEVEL"
        printf "    \"log_file\": \"%s\"\n" "$LOG_FILE"
        printf "  },\n"
        printf "  \"proxmox\": {\n"
        printf "    \"host\": \"%s\",\n" "$PROXMOX_HOST"
        printf "    \"username\": \"%s\",\n" "$PROXMOX_USERNAME"
        printf "    \"password\": \"%s\",\n" "$PROXMOX_PASSWORD"
        printf "    \"node\": \"%s\",\n" "$PROXMOX_NODE"
        printf "    \"template_vm_id\": %s,\n" "$TEMPLATE_VM_ID"
        printf "    \"storage\": \"%s\",\n" "$PROXMOX_STORAGE"
        printf "    \"verify_ssl\": %s\n" "$VERIFY_SSL_JSON"
        printf "  },\n"
        printf "  \"guacamole\": {\n"
        printf "    \"host\": \"%s\",\n" "$GUACAMOLE_HOST"
        printf "    \"username\": \"%s\",\n" "$GUACAMOLE_USERNAME"
        printf "    \"password\": \"%s\",\n" "$GUACAMOLE_PASSWORD"
        printf "    \"data_source\": \"%s\"\n" "$GUACAMOLE_DATASOURCE"
        printf "  },\n"
        printf "  \"vm\": {\n"
        printf "    \"base_load\": %s,\n" "$BASE_LOAD"
        printf "    \"users_per_vm\": %s,\n" "$USERS_PER_VM"
        printf "    \"max_vms\": %s,\n" "$MAX_VMS"
        printf "    \"check_interval\": %s,\n" "$CHECK_INTERVAL"
        printf "    \"cpu\": %s,\n" "$VM_CPU"
        printf "    \"memory\": %s,\n" "$VM_MEMORY"
        printf "    \"disk\": \"%s\",\n" "$VM_DISK"
        printf "    \"health_check_timeout\": %s\n" "$HEALTH_TIMEOUT"
        printf "  },\n"
        printf "  \"network\": {\n"
        printf "    \"base_ip\": \"%s\",\n" "$BASE_IP"
        printf "    \"subnet\": \"%s\",\n" "$SUBNET"
        printf "    \"gateway\": \"%s\",\n" "$GATEWAY"
        printf "    \"dns\": \"%s\",\n" "$DNS_SERVER"
        printf "    \"dhcp_range_start\": \"%s\",\n" "$DHCP_START"
        printf "    \"dhcp_range_end\": \"%s\"\n" "$DHCP_END"
        printf "  },\n"
        printf "  \"monitoring\": {\n"
        printf "    \"enable_health_checks\": %s,\n" "$ENABLE_HEALTH_CHECKS_JSON"
        printf "    \"health_check_interval\": %s,\n" "$HEALTH_CHECK_INTERVAL"
        printf "    \"max_vm_creation_attempts\": %s,\n" "$MAX_CREATION_ATTEMPTS"
        printf "    \"vm_ready_timeout\": %s\n" "$VM_READY_TIMEOUT"
        printf "  }\n"
        printf "}\n"
    } > "$CONFIG_FILE"

    print_success "Configuration file created successfully: $CONFIG_FILE"
    print_info "You can now run the test script to validate your configuration:"
    echo "  python3 test_vm_manager.py"
}

# Run main function
main "$@"
