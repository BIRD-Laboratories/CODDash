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

# Function to validate URL format
validate_url() {
    local url=$1
    if echo "$url" | grep -E '^https?://[a-zA-Z0-9.-]+(:[0-9]+)?(/.*)?$' >/dev/null; then
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
    for tool in ip nmap ss curl; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_deps="$missing_deps $tool"
        fi
    done
    
    if [ -n "$missing_deps" ]; then
        print_warning "Missing dependencies: $missing_deps"
        print_info "Some auto-detection features may be limited"
        return 1
    else
        print_success "All dependencies available"
        return 0
    fi
}

# Function to detect local network
detect_local_network() {
    print_info "Detecting local network configuration..."
    
    # Try to get default gateway and subnet
    local gateway=$(ip route | grep default | awk '{print $3}' | head -1)
    local interface=$(ip route | grep default | awk '{print $5}' | head -1)
    
    if [ -n "$interface" ]; then
        local network=$(ip addr show "$interface" 2>/dev/null | grep inet | awk '{print $2}' | head -1)
        if [ -n "$network" ]; then
            SUBNET="$network"
            print_success "Detected subnet: $SUBNET"
        fi
    fi
    
    if [ -n "$gateway" ] && validate_ip "$gateway"; then
        GATEWAY="$gateway"
        print_success "Detected gateway: $GATEWAY"
    fi
    
    # Extract network portion for scanning
    if [ -n "$SUBNET" ]; then
        NETWORK_PREFIX=$(echo "$SUBNET" | cut -d'/' -f1 | cut -d'.' -f1-3)
        print_info "Network prefix: $NETWORK_PREFIX.0/24"
    else
        print_warning "Could not detect network configuration"
        NETWORK_PREFIX="192.168.1"
    fi
}

# Function to test Guacamole connection
test_guacamole_connection() {
    local url="$1"
    local username="$2"
    local password="$3"
    
    print_info "Testing Guacamole connection to: $url"
    
    # Try to connect using curl
    if curl -s -f --connect-timeout 5 "$url" > /dev/null 2>&1; then
        print_success "Guacamole server is reachable"
        return 0
    else
        print_warning "Cannot reach Guacamole server at $url"
        return 1
    fi
}

# Function to scan for Guacamole instances
scan_for_guacamole() {
    print_info "Scanning network for Guacamole instances..."
    
    local found_instances=()
    local common_ports="8080 4822 8443 80 443"
    
    # Check if nmap is available
    if ! command -v nmap >/dev/null 2>&1; then
        print_warning "nmap not available, using simple port scanning"
        # Simple port scanning without nmap
        for port in $common_ports; do
            print_info "Scanning port $port on network $NETWORK_PREFIX.0/24"
            for i in $(seq 1 254); do
                local target="$NETWORK_PREFIX.$i"
                if timeout 1 bash -c "echo >/dev/tcp/$target/$port" 2>/dev/null; then
                    print_info "Found service on $target:$port"
                    # Test if it might be Guacamole
                    if curl -s --connect-timeout 3 "http://$target:$port/guacamole" | grep -i "guacamole" >/dev/null 2>&1; then
                        found_instances+=("http://$target:$port/guacamole")
                        print_success "Found Guacamole at: http://$target:$port/guacamole"
                    elif curl -s --connect-timeout 3 "http://$target:$port" | grep -i "guacamole" >/dev/null 2>&1; then
                        found_instances+=("http://$target:$port")
                        print_success "Found Guacamole at: http://$target:$port")
                    fi
                fi
            done
        done
    else
        # Use nmap for more comprehensive scanning
        for port in $common_ports; do
            print_info "Scanning for services on port $port..."
            local results=$(nmap -p "$port" --open "$NETWORK_PREFIX.0/24" -oG - 2>/dev/null | grep "/open/" | awk '{print $2}')
            
            for target in $results; do
                print_info "Testing $target:$port for Guacamole..."
                # Test HTTP
                if curl -s --connect-timeout 3 "http://$target:$port/guacamole" | grep -i "guacamole" >/dev/null 2>&1; then
                    found_instances+=("http://$target:$port/guacamole")
                    print_success "Found Guacamole at: http://$target:$port/guacamole"
                elif curl -s --connect-timeout 3 "http://$target:$port" | grep -i "guacamole" >/dev/null 2>&1; then
                    found_instances+=("http://$target:$port")
                    print_success "Found Guacamole at: http://$target:$port")
                # Test HTTPS
                elif curl -s -k --connect-timeout 3 "https://$target:$port/guacamole" | grep -i "guacamole" >/dev/null 2>&1; then
                    found_instances+=("https://$target:$port/guacamole")
                    print_success "Found Guacamole at: https://$target:$port/guacamole")
                elif curl -s -k --connect-timeout 3 "https://$target:$port" | grep -i "guacamole" >/dev/null 2>&1; then
                    found_instances+=("https://$target:$port")
                    print_success "Found Guacamole at: https://$target:$port")
                fi
            done
        done
    fi
    
    if [ ${#found_instances[@]} -eq 0 ]; then
        print_warning "No Guacamole instances found automatically"
        return 1
    fi
    
    # Display found instances
    echo ""
    print_info "Found Guacamole instances:"
    for i in "${!found_instances[@]}"; do
        echo "  $((i+1)). ${found_instances[$i]}"
    done
    
    # Let user choose
    echo ""
    get_input "Select Guacamole instance (1-${#found_instances[@]})" "1" SELECTED_INDEX validate_number
    
    if [ "$SELECTED_INDEX" -ge 1 ] && [ "$SELECTED_INDEX" -le ${#found_instances[@]} ]; then
        GUACAMOLE_URL="${found_instances[$((SELECTED_INDEX-1))]}"
        print_success "Selected Guacamole URL: $GUACAMOLE_URL"
        return 0
    else
        print_error "Invalid selection"
        return 1
    fi
}

# Function to auto-configure Guacamole settings
auto_configure_guacamole() {
    print_info "Attempting to auto-configure Guacamole..."
    
    detect_local_network
    
    get_yes_no "Do you want to scan for Guacamole instances automatically?" "yes" SCAN_GUACAMOLE
    
    if [ "$SCAN_GUACAMOLE" = "true" ]; then
        if scan_for_guacamole; then
            # Test the connection
            if test_guacamole_connection "$GUACAMOLE_URL" "$GUACAMOLE_USERNAME" "$GUACAMOLE_PASSWORD"; then
                print_success "Guacamole auto-configuration successful"
                return 0
            else
                print_warning "Auto-detected Guacamole URL but cannot connect"
                get_yes_no "Do you want to use this URL anyway?" "yes" USE_ANYWAY
                if [ "$USE_ANYWAY" = "true" ]; then
                    return 0
                fi
            fi
        fi
    fi
    
    # Fall back to manual configuration
    print_info "Manual Guacamole configuration"
    get_input "Enter Guacamole server URL" "http://$NETWORK_PREFIX.101:8080/guacamole" GUACAMOLE_URL validate_url
    get_input "Enter Guacamole username" "guacadmin" GUACAMOLE_USERNAME
    get_input "Enter Guacamole password" "guacadmin" GUACAMOLE_PASSWORD
    get_input "Enter Guacamole data source" "postgresql" GUACAMOLE_DATASOURCE
    
    # Test the connection
    if test_guacamole_connection "$GUACAMOLE_URL" "$GUACAMOLE_USERNAME" "$GUACAMOLE_PASSWORD"; then
        print_success "Guacamole connection test successful"
    else
        print_warning "Guacamole connection test failed, but continuing with configuration"
    fi
}

# Main configuration function
main() {
    print_info "Dynamic VM Management System - Auto Configuration"
    echo "=========================================================="
    echo "This script will create a configuration file."
    echo ""
    
    # Check dependencies
    if ! check_dependencies; then
        print_warning "Some dependencies are missing. Auto-scan features may not work properly."
        get_yes_no "Continue anyway?" "yes" CONTINUE_ANYWAY
        if [ "$CONTINUE_ANYWAY" = "false" ]; then
            print_error "Please install missing dependencies and run the script again."
            exit 1
        fi
    fi
    
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
    get_input "Enter Proxmox server host (IP only)" "192.168.1.100" PROXMOX_HOST validate_ip
    get_input "Enter Proxmox username with realm" "root@pam" PROXMOX_USERNAME
    get_input "Enter Proxmox password" "" PROXMOX_PASSWORD
    get_input "Enter Proxmox node name" "pve" PROXMOX_NODE
    get_input "Enter template VM ID" "1000" TEMPLATE_VM_ID validate_number
    get_yes_no "Verify SSL certificates? (recommended: no for self-signed)" "no" VERIFY_SSL

    # Guacamole Configuration with auto-detection
    print_info "Apache Guacamole Configuration"
    echo "----------------------------------"
    auto_configure_guacamole

    # VM Pool Configuration
    print_info "VM Pool Configuration"
    echo "-----------------------"
    get_input "Enter base load (minimum VMs to keep running)" "2" BASE_LOAD validate_number
    get_input "Enter maximum users per VM" "25" USERS_PER_VM validate_number
    get_input "Enter maximum VMs that can be created" "20" MAX_VMS validate_number
    get_input "Enter check interval in seconds" "60" CHECK_INTERVAL validate_number
    get_input "Enter health check timeout in seconds" "300" HEALTH_TIMEOUT validate_number

    # Network Configuration
    print_info "Network Configuration"
    echo "-----------------------"
    detect_local_network
    get_input "Enter network subnet (CIDR)" "$SUBNET" SUBNET
    get_input "Enter network gateway" "$GATEWAY" GATEWAY validate_ip

    # pfSense Configuration (Optional)
    print_info "pfSense Configuration (Optional)"
    echo "-------------------------------------"
    get_yes_no "Configure pfSense integration?" "no" CONFIGURE_PFSENSE
    
    if [ "$CONFIGURE_PFSENSE" = "true" ]; then
        get_input "Enter pfSense server URL" "https://$NETWORK_PREFIX.1" PFSENSE_URL validate_url
        get_input "Enter pfSense username" "admin" PFSENSE_USERNAME
        get_input "Enter pfSense password" "" PFSENSE_PASSWORD
    else
        PFSENSE_URL=""
        PFSENSE_USERNAME=""
        PFSENSE_PASSWORD=""
    fi

    # Convert boolean values to lowercase for JSON
    if [ "$VERIFY_SSL" = "true" ]; then
        VERIFY_SSL_JSON="true"
    else
        VERIFY_SSL_JSON="false"
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
        printf "    \"verify_ssl\": %s\n" "$VERIFY_SSL_JSON"
        printf "  },\n"
        printf "  \"guacamole\": {\n"
        printf "    \"url\": \"%s\",\n" "$GUACAMOLE_URL"
        printf "    \"username\": \"%s\",\n" "$GUACAMOLE_USERNAME"
        printf "    \"password\": \"%s\",\n" "$GUACAMOLE_PASSWORD"
        printf "    \"data_source\": \"%s\"\n" "$GUACAMOLE_DATASOURCE"
        printf "  },\n"
        printf "  \"vm\": {\n"
        printf "    \"base_load\": %s,\n" "$BASE_LOAD"
        printf "    \"users_per_vm\": %s,\n" "$USERS_PER_VM"
        printf "    \"max_vms\": %s,\n" "$MAX_VMS"
        printf "    \"check_interval\": %s,\n" "$CHECK_INTERVAL"
        printf "    \"health_check_timeout\": %s\n" "$HEALTH_TIMEOUT"
        printf "  },\n"
        printf "  \"network\": {\n"
        printf "    \"subnet\": \"%s\",\n" "$SUBNET"
        printf "    \"gateway\": \"%s\"\n" "$GATEWAY"
        printf "  }"
        
        # Add pfSense section only if configured
        if [ "$CONFIGURE_PFSENSE" = "true" ]; then
            printf ",\n"
            printf "  \"pfsense\": {\n"
            printf "    \"url\": \"%s\",\n" "$PFSENSE_URL"
            printf "    \"username\": \"%s\",\n" "$PFSENSE_USERNAME"
            printf "    \"password\": \"%s\"\n" "$PFSENSE_PASSWORD"
            printf "  }\n"
        else
            printf "\n"
        fi
        
        printf "}\n"
    } > "$CONFIG_FILE"

    print_success "Configuration file created successfully: $CONFIG_FILE"
    
    # Show summary
    echo ""
    print_info "Configuration Summary:"
    echo "  - Proxmox: $PROXMOX_HOST (Node: $PROXMOX_NODE)"
    echo "  - Guacamole: $GUACAMOLE_URL"
    if [ "$CONFIGURE_PFSENSE" = "true" ]; then
        echo "  - pfSense: $PFSENSE_URL"
    else
        echo "  - pfSense: Not configured"
    fi
    echo "  - VM Pool: $BASE_LOAD base VMs, max $MAX_VMS VMs, $USERS_PER_VM users/VM"
    echo "  - Network: $SUBNET (Gateway: $GATEWAY)"
    
    echo ""
    print_info "You can now run the test script to validate your configuration:"
    echo "  python3 test_vm_manager.py"
}

# Run main function
main "$@"
