#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration file path
CONFIG_FILE="config.json"
BACKUP_FILE="config.json.backup.$(date +%Y%m%d_%H%M%S)"

# Function to print colored output
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_debug() {
    echo -e "${CYAN}[DEBUG]${NC} $1"
}

# Function to validate IP address
validate_ip() {
    local ip=$1
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        IFS='.' read -r -a octets <<< "$ip"
        for octet in "${octets[@]}"; do
            if [[ $octet -lt 0 || $octet -gt 255 ]]; then
                return 1
            fi
        done
        return 0
    fi
    return 1
}

# Function to validate number
validate_number() {
    local num=$1
    if [[ $num =~ ^[0-9]+$ ]] && [ $num -gt 0 ]; then
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
            read -p "$prompt [$default]: " input
            input=${input:-$default}
        else
            read -p "$prompt: " input
        fi
        
        if [ -z "$input" ]; then
            print_error "This field cannot be empty."
            continue
        fi
        
        # Run validator if provided
        if [ -n "$validator" ]; then
            if $validator "$input"; then
                eval "$var_name=\"$input\""
                break
            else
                print_error "Invalid input. Please try again."
            fi
        else
            eval "$var_name=\"$input\""
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
            read -p "$prompt [y/N]: " input
            input=${input:-$default}
        else
            read -p "$prompt [y/N]: " input
        fi
        
        case "${input,,}" in
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

# Function to detect network configuration
detect_network_config() {
    print_info "Detecting network configuration..."
    
    # Detect default gateway
    local gateway=$(ip route | grep default | awk '{print $3}' | head -1)
    if [ -n "$gateway" ] && validate_ip "$gateway"; then
        DETECTED_GATEWAY="$gateway"
        print_success "Detected gateway: $gateway"
    else
        print_warning "Could not detect gateway automatically"
    fi
    
    # Detect primary interface and subnet
    local primary_iface=$(ip route | grep default | awk '{print $5}' | head -1)
    if [ -n "$primary_iface" ]; then
        local ip_info=$(ip addr show dev "$primary_iface" | grep 'inet ' | awk '{print $2}' | head -1)
        if [ -n "$ip_info" ]; then
            DETECTED_SUBNET=$(echo "$ip_info" | cut -d'/' -f1 | sed 's/[0-9]*$/0/')"/24"
            local current_ip=$(echo "$ip_info" | cut -d'/' -f1)
            DETECTED_BASE_IP=$(echo "$current_ip" | sed 's/[0-9]*$/100/')
            DETECTED_DHCP_START=$(echo "$current_ip" | sed 's/[0-9]*$/100/')
            DETECTED_DHCP_END=$(echo "$current_ip" | sed 's/[0-9]*$/200/')
            
            print_success "Detected subnet: $DETECTED_SUBNET"
            print_success "Detected base IP: $DETECTED_BASE_IP"
        fi
    fi
    
    # Detect DNS servers
    local dns_servers=$(grep nameserver /etc/resolv.conf | awk '{print $2}' | head -1)
    if [ -n "$dns_servers" ] && validate_ip "$dns_servers"; then
        DETECTED_DNS="$dns_servers"
        print_success "Detected DNS: $dns_servers"
    else
        DETECTED_DNS="8.8.8.8"
        print_info "Using fallback DNS: $DETECTED_DNS"
    fi
}

# Function to detect Proxmox configuration
detect_proxmox_config() {
    print_info "Attempting to detect Proxmox configuration..."
    
    # Check if we're running on a Proxmox server
    if [ -f "/etc/pve/.version" ]; then
        print_success "Running on a Proxmox server"
        
        # Detect node name
        local node_name=$(hostname)
        DETECTED_PROXMOX_NODE="$node_name"
        print_success "Detected node: $node_name"
        
        # Detect Proxmox host (try to get management IP)
        local management_ip=$(ip addr show | grep 'inet ' | grep -v '127.0.0.1' | awk '{print $2}' | cut -d'/' -f1 | head -1)
        if [ -n "$management_ip" ]; then
            DETECTED_PROXMOX_HOST="https://$management_ip:8006"
            print_success "Detected Proxmox host: $DETECTED_PROXMOX_HOST"
        fi
        
        # Try to detect storage
        if command -v pvesm >/dev/null 2>&1; then
            local storage=$(pvesm status | grep active | awk '{print $1}' | head -1)
            if [ -n "$storage" ]; then
                DETECTED_PROXMOX_STORAGE="$storage"
                print_success "Detected storage: $storage"
            fi
        fi
        
        # Try to find template VMs
        if command -v qm >/dev/null 2>&1; then
            local templates=$(qm list | grep template | awk '{print $1}' | head -1)
            if [ -n "$templates" ]; then
                DETECTED_TEMPLATE_VM_ID="$templates"
                print_success "Detected template VM ID: $templates"
            fi
        fi
    else
        print_warning "Not running on a Proxmox server, limited auto-detection available"
        
        # Try to detect Proxmox via common ports
        print_info "Scanning for Proxmox servers on local network..."
        local proxmox_ip=$(nmap -p 8006 --open 192.168.1.0/24 2>/dev/null | grep "Nmap scan report" | awk '{print $5}' | head -1)
        if [ -n "$proxmox_ip" ]; then
            DETECTED_PROXMOX_HOST="https://$proxmox_ip:8006"
            print_success "Found Proxmox server at: $DETECTED_PROXMOX_HOST"
        fi
    fi
}

# Function to detect Guacamole configuration
detect_guacamole_config() {
    print_info "Attempting to detect Guacamole configuration..."
    
    # Check if Guacamole is running locally
    if docker ps 2>/dev/null | grep -q guacamole; then
        print_success "Guacamole Docker container detected"
        DETECTED_GUACAMOLE_HOST="http://localhost:8080/guacamole"
    fi
    
    # Check common Guacamole ports
    local guac_port=$(ss -tln | grep ':8080' | wc -l)
    if [ "$guac_port" -gt 0 ]; then
        print_info "Service detected on port 8080 (common Guacamole port)"
        local guac_ip="localhost"
        DETECTED_GUACAMOLE_HOST="http://$guac_ip:8080/guacamole"
    fi
    
    # Try to find Guacamole via nmap scan
    print_info "Scanning for Guacamole servers on local network..."
    local guacamole_ip=$(nmap -p 8080 --open 192.168.1.0/24 2>/dev/null | grep "Nmap scan report" | awk '{print $5}' | head -1)
    if [ -n "$guacamole_ip" ]; then
        DETECTED_GUACAMOLE_HOST="http://$guacamole_ip:8080/guacamole"
        print_success "Found Guacamole server at: $DETECTED_GUACAMOLE_HOST"
    fi
}

# Function to detect system resources for VM sizing
detect_system_resources() {
    print_info "Detecting system resources for VM sizing..."
    
    # Detect total CPU cores
    if command -v nproc >/dev/null 2>&1; then
        local total_cores=$(nproc)
        DETECTED_VM_CPU=$((total_cores / 4))
        if [ $DETECTED_VM_CPU -lt 1 ]; then
            DETECTED_VM_CPU=1
        fi
        print_success "Detected $total_cores total cores, suggesting $DETECTED_VM_CPU cores per VM"
    fi
    
    # Detect total memory
    if command -v free >/dev/null 2>&1; then
        local total_mem_mb=$(free -m | grep Mem: | awk '{print $2}')
        if [ -n "$total_mem_mb" ]; then
            DETECTED_VM_MEMORY=$((total_mem_mb / 8))
            if [ $DETECTED_VM_MEMORY -lt 1024 ]; then
                DETECTED_VM_MEMORY=1024
            elif [ $DETECTED_VM_MEMORY -gt 8192 ]; then
                DETECTED_VM_MEMORY=8192
            fi
            print_success "Detected ${total_mem_mb}MB total RAM, suggesting ${DETECTED_VM_MEMORY}MB per VM"
        fi
    fi
    
    # Detect disk space
    if command -v df >/dev/null 2>&1; then
        local disk_info=$(df -h /var/lib/vz 2>/dev/null | tail -1 || df -h / | tail -1)
        local available_gb=$(echo "$disk_info" | awk '{print $4}' | sed 's/G//')
        if [[ $available_gb =~ ^[0-9]+$ ]]; then
            DETECTED_VM_DISK=$((available_gb / 20))
            if [ $DETECTED_VM_DISK -lt 20 ]; then
                DETECTED_VM_DISK=20
            elif [ $DETECTED_VM_DISK -gt 100 ]; then
                DETECTED_VM_DISK=100
            fi
            DETECTED_VM_DISK="${DETECTED_VM_DISK}G"
            print_success "Detected ${available_gb}GB available, suggesting ${DETECTED_VM_DISK} disk per VM"
        fi
    fi
}

# Function to check dependencies
check_dependencies() {
    print_info "Checking dependencies..."
    
    local missing_deps=()
    
    # Check for common network tools
    for tool in ip nmap ss; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_deps+=("$tool")
        fi
    done
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        print_warning "Missing dependencies: ${missing_deps[*]}"
        print_info "Some auto-detection features may be limited"
        get_yes_no "Install missing dependencies?" "no" INSTALL_DEPS
        
        if [ "$INSTALL_DEPS" = true ]; then
            if command -v apt-get >/dev/null 2>&1; then
                sudo apt-get update
                sudo apt-get install -y "${missing_deps[@]}"
            elif command -v yum >/dev/null 2>&1; then
                sudo yum install -y "${missing_deps[@]}"
            else
                print_error "Cannot automatically install dependencies. Please install manually."
            fi
        fi
    else
        print_success "All dependencies available"
    fi
}

# Main configuration function
main() {
    print_info "Dynamic VM Management System - Auto Configuration"
    echo "=========================================================="
    echo "This script will attempt to auto-detect values and create"
    echo "the configuration file. Manual input will be requested for"
    echo "values that cannot be detected automatically."
    echo ""
    
    # Check dependencies
    check_dependencies
    
    # Backup existing config
    if [ -f "$CONFIG_FILE" ]; then
        print_warning "Configuration file already exists. Creating backup: $BACKUP_FILE"
        cp "$CONFIG_FILE" "$BACKUP_FILE"
    fi
    
    # Auto-detect values
    detect_network_config
    echo ""
    detect_proxmox_config
    echo ""
    detect_guacamole_config
    echo ""
    detect_system_resources
    echo ""
    
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
    get_input "Enter Proxmox server URL (https://ip:8006)" "${DETECTED_PROXMOX_HOST:-https://192.168.1.100:8006}" PROXMOX_HOST
    get_input "Enter Proxmox username with realm" "root@pam" PROXMOX_USERNAME
    get_input "Enter Proxmox password" "" PROXMOX_PASSWORD
    get_input "Enter Proxmox node name" "${DETECTED_PROXMOX_NODE:-pve}" PROXMOX_NODE
    get_input "Enter template VM ID" "${DETECTED_TEMPLATE_VM_ID:-1000}" TEMPLATE_VM_ID validate_number
    get_input "Enter storage name" "${DETECTED_PROXMOX_STORAGE:-local-lvm}" PROXMOX_STORAGE
    get_yes_no "Verify SSL certificates? (recommended: no for self-signed)" "no" VERIFY_SSL

    # Guacamole Configuration
    print_info "Apache Guacamole Configuration"
    echo "----------------------------------"
    get_input "Enter Guacamole server URL" "${DETECTED_GUACAMOLE_HOST:-http://192.168.1.101:8080/guacamole}" GUACAMOLE_HOST
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
    get_input "Enter CPU cores per VM" "${DETECTED_VM_CPU:-2}" VM_CPU validate_number
    get_input "Enter memory per VM in MB" "${DETECTED_VM_MEMORY:-4096}" VM_MEMORY validate_number
    get_input "Enter disk size per VM (e.g., 32G)" "${DETECTED_VM_DISK:-32G}" VM_DISK
    get_input "Enter health check timeout in seconds" "300" HEALTH_TIMEOUT validate_number

    # Network Configuration
    print_info "Network Configuration"
    echo "-----------------------"
    get_input "Enter base IP for VM assignments" "${DETECTED_BASE_IP:-192.168.1.100}" BASE_IP validate_ip
    get_input "Enter network subnet (CIDR)" "${DETECTED_SUBNET:-192.168.1.0/24}" SUBNET
    get_input "Enter network gateway" "${DETECTED_GATEWAY:-192.168.1.1}" GATEWAY validate_ip
    get_input "Enter DNS server" "${DETECTED_DNS:-8.8.8.8}" DNS_SERVER validate_ip
    get_input "Enter DHCP range start" "${DETECTED_DHCP_START:-192.168.1.100}" DHCP_START validate_ip
    get_input "Enter DHCP range end" "${DETECTED_DHCP_END:-192.168.1.200}" DHCP_END validate_ip

    # Monitoring Configuration
    print_info "Monitoring Configuration"
    echo "---------------------------"
    get_yes_no "Enable health checks?" "yes" ENABLE_HEALTH_CHECKS
    get_input "Enter health check interval in seconds" "60" HEALTH_CHECK_INTERVAL validate_number
    get_input "Enter maximum VM creation attempts" "3" MAX_CREATION_ATTEMPTS validate_number
    get_input "Enter VM ready timeout in seconds" "300" VM_READY_TIMEOUT validate_number

    # Create the JSON configuration
    print_info "Generating configuration file..."
    
    cat > "$CONFIG_FILE" << EOF
{
  "server": {
    "port": $SERVER_PORT,
    "host": "$SERVER_HOST",
    "log_level": "$LOG_LEVEL",
    "log_file": "$LOG_FILE"
  },
  "proxmox": {
    "host": "$PROXMOX_HOST",
    "username": "$PROXMOX_USERNAME",
    "password": "$PROXMOX_PASSWORD",
    "node": "$PROXMOX_NODE",
    "template_vm_id": $TEMPLATE_VM_ID,
    "storage": "$PROXMOX_STORAGE",
    "verify_ssl": $VERIFY_SSL
  },
  "guacamole": {
    "host": "$GUACAMOLE_HOST",
    "username": "$GUACAMOLE_USERNAME",
    "password": "$GUACAMOLE_PASSWORD",
    "data_source": "$GUACAMOLE_DATASOURCE"
  },
  "vm": {
    "base_load": $BASE_LOAD,
    "users_per_vm": $USERS_PER_VM,
    "max_vms": $MAX_VMS,
    "check_interval": $CHECK_INTERVAL,
    "cpu": $VM_CPU,
    "memory": $VM_MEMORY,
    "disk": "$VM_DISK",
    "health_check_timeout": $HEALTH_TIMEOUT
  },
  "network": {
    "base_ip": "$BASE_IP",
    "subnet": "$SUBNET",
    "gateway": "$GATEWAY",
    "dns": "$DNS_SERVER",
    "dhcp_range_start": "$DHCP_START",
    "dhcp_range_end": "$DHCP_END"
  },
  "monitoring": {
    "enable_health_checks": $ENABLE_HEALTH_CHECKS,
    "health_check_interval": $HEALTH_CHECK_INTERVAL,
    "max_vm_creation_attempts": $MAX_CREATION_ATTEMPTS,
    "vm_ready_timeout": $VM_READY_TIMEOUT
  }
}
EOF

    # Validate the created JSON
    if command -v jq >/dev/null 2>&1; then
        if jq empty "$CONFIG_FILE" 2>/dev/null; then
            print_success "Configuration file created successfully: $CONFIG_FILE"
            print_info "Configuration summary:"
            echo "----------------------------------------"
            echo "Server: $SERVER_HOST:$SERVER_PORT"
            echo "Proxmox: $PROXMOX_HOST (Node: $PROXMOX_NODE)"
            echo "Guacamole: $GUACAMOLE_HOST"
            echo "VM Pool: $BASE_LOAD base VMs, max $MAX_VMS VMs"
            echo "Network: $BASE_IP - $DHCP_END ($SUBNET)"
            echo "VM Specs: ${VM_CPU}CPU, ${VM_MEMORY}MB RAM, ${VM_DISK} disk"
            echo "----------------------------------------"
            
            print_info "You can now run the test script to validate your configuration:"
            echo "  python3 test_vm_manager.py"
            
        else
            print_error "Generated configuration file contains invalid JSON."
            print_info "Please check the file manually or run the script again."
            exit 1
        fi
    else
        print_warning "jq not found. Cannot validate JSON syntax automatically."
        print_success "Configuration file created: $CONFIG_FILE"
        print_info "Please verify the JSON syntax manually or install jq for automatic validation."
    fi

    # Create a simple validation script
    create_validation_script
}

# Function to create validation script
create_validation_script() {
    cat > validate-config.sh << 'EOF'
#!/bin/bash
# Configuration validation script

CONFIG_FILE="config.json"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: $CONFIG_FILE not found"
    exit 1
fi

echo "Validating $CONFIG_FILE..."

# Check if jq is available for JSON validation
if command -v jq >/dev/null 2>&1; then
    echo "✓ jq found, performing JSON syntax validation..."
    if jq empty "$CONFIG_FILE" 2>/dev/null; then
        echo "✓ JSON syntax is valid"
    else
        echo "✗ Invalid JSON syntax"
        exit 1
    fi
else
    echo "ℹ jq not installed, skipping JSON syntax validation"
fi

# Python-based validation
python3 - << EOF
import json
import sys

try:
    with open('$CONFIG_FILE', 'r') as f:
        config = json.load(f)
    
    required_sections = ['server', 'proxmox', 'guacamole', 'vm', 'network', 'monitoring']
    missing_sections = []
    
    print("Checking required sections...")
    for section in required_sections:
        if section in config:
            print(f"  ✓ {section}")
        else:
            print(f"  ✗ {section}")
            missing_sections.append(section)
    
    if missing_sections:
        print(f"✗ Missing sections: {', '.join(missing_sections)}")
        sys.exit(1)
    
    # Check critical fields
    critical_checks = [
        ('proxmox', ['host', 'username', 'password', 'node', 'template_vm_id']),
        ('vm', ['base_load', 'users_per_vm', 'max_vms']),
        ('network', ['base_ip', 'subnet', 'gateway'])
    ]
    
    print("Checking critical fields...")
    all_good = True
    for section, fields in critical_checks:
        if section in config:
            for field in fields:
                if field in config[section]:
                    print(f"  ✓ {section}.{field}")
                else:
                    print(f"  ✗ {section}.{field}")
                    all_good = False
    
    if all_good:
        print("✓ All critical fields are present")
        print("✓ Configuration validation passed!")
    else:
        print("✗ Some critical fields are missing")
        sys.exit(1)
        
except Exception as e:
    print(f"✗ Validation error: {e}")
    sys.exit(1)
EOF

    chmod +x validate-config.sh
    print_info "Created validation script: validate-config.sh"

    print_success "Setup complete! You can now:"
    echo "1. Review the generated config.json file"
    echo "2. Run: ./validate-config.sh to validate the configuration"
    echo "3. Run: python3 test_vm_manager.py to test the system with mock services"
}

# Run main function
main "$@"
