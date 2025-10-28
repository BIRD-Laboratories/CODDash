#!/bin/bash

# Kali Linux Security Auto-Updater with Debian Advisory Monitoring
# Single script installation and management

set -e

SCRIPT_NAME="kali-security-autoupdate"
INSTALL_DIR="/usr/local/bin"
SERVICE_FILE="/etc/systemd/system/${SCRIPT_NAME}.service"
TIMER_FILE="/etc/systemd/system/${SCRIPT_NAME}.timer"
CONFIG_FILE="/etc/${SCRIPT_NAME}.conf"
LOG_FILE="/var/log/${SCRIPT_NAME}.log"
STATE_DIR="/var/lib/${SCRIPT_NAME}"
LOCK_FILE="/var/run/${SCRIPT_NAME}.lock"

# Default configuration
TRIGGER_INTERVAL=9000  # 2.5 hours in seconds
CHECK_INTERVAL=30      # Check every 30 minutes
REBOOT_DELAY=5         # Reboot delay in minutes

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_status() {
    echo -e "${GREEN}[+]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

print_error() {
    echo -e "${RED}[-]${NC} $1"
}

print_info() {
    echo -e "${BLUE}[*]${NC} $1"
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root"
        exit 1
    fi
}

# Create main script
create_main_script() {
    cat > "${INSTALL_DIR}/${SCRIPT_NAME}" << 'EOF'
#!/bin/bash

# Kali Linux Security Auto-Updater Main Script

set -e

SCRIPT_NAME="kali-security-autoupdate"
CONFIG_FILE="/etc/${SCRIPT_NAME}.conf"
LOG_FILE="/var/log/${SCRIPT_NAME}.log"
STATE_DIR="/var/lib/${SCRIPT_NAME}"
LOCK_FILE="/var/run/${SCRIPT_NAME}.lock"

# Source configuration
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
else
    # Default values
    TRIGGER_INTERVAL=9000
    DEBIAN_SECURITY_URL="https://security-tracker.debian.org/tracker/data/json"
    CHECK_INTERVAL=30
    REBOOT_DELAY=5
fi

CACHE_FILE="${STATE_DIR}/debian-security-cache.json"
LAST_CHECK_FILE="${STATE_DIR}/last_trigger"
LAST_UPDATE_FILE="${STATE_DIR}/last_update"
ADVISORY_CHECK_FILE="${STATE_DIR}/last_advisory_check"

# Create necessary directories
mkdir -p "$STATE_DIR"

log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
    logger -t "$SCRIPT_NAME" "$1"
}

send_notification() {
    local message="$1"
    local priority="${2:-normal}"
    
    # Desktop notification for logged-in users
    for user in $(who | cut -d' ' -f1 | sort -u); do
        user_id=$(id -u "$user" 2>/dev/null || true)
        if [[ -n "$user_id" ]]; then
            # Try desktop notification
            sudo -u "$user" DISPLAY=:0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/"$user_id"/bus \
                notify-send "Security Update" "$message" -u "$priority" 2>/dev/null || true
        fi
    done
    
    # System-wide message
    wall "SECURITY UPDATE: $message" 2>/dev/null || true
}

acquire_lock() {
    exec 200>"$LOCK_FILE"
    flock -n 200 || {
        log_message "Another instance is already running"
        exit 0
    }
    echo $$ 1>&200
}

release_lock() {
    flock -u 200
    rm -f "$LOCK_FILE"
}

check_trigger_cooldown() {
    if [[ -f "$LAST_CHECK_FILE" ]]; then
        local last_trigger=$(cat "$LAST_CHECK_FILE")
        local current_time=$(date +%s)
        local time_diff=$((current_time - last_trigger))
        
        if [[ $time_diff -lt $TRIGGER_INTERVAL ]]; then
            local remaining=$((TRIGGER_INTERVAL - time_diff))
            local minutes=$((remaining / 60))
            log_message "Still in cooldown period. $minutes minutes remaining"
            return 1
        fi
    fi
    return 0
}

fetch_advisories() {
    log_message "Fetching Debian security advisories..."
    
    # Rate limiting - don't check more than once per hour
    if [[ -f "$ADVISORY_CHECK_FILE" ]]; then
        local last_check=$(cat "$ADVISORY_CHECK_FILE")
        local current_time=$(date +%s)
        if [[ $((current_time - last_check)) -lt 3600 ]]; then
            log_message "Using cached advisories (checked recently)"
            return 0
        fi
    fi
    
    if curl -s -f -H "Cache-Control: no-cache" "$DEBIAN_SECURITY_URL" -o "$CACHE_FILE.tmp"; then
        mv "$CACHE_FILE.tmp" "$CACHE_FILE"
        date +%s > "$ADVISORY_CHECK_FILE"
        log_message "Successfully fetched security advisories"
    else
        log_message "WARNING: Failed to fetch latest advisories, using cache if available"
    fi
}

check_security_advisories() {
    if [[ ! -f "$CACHE_FILE" ]]; then
        log_message "No advisory data available"
        return 1
    fi
    
    # Check if jq is available
    if ! command -v jq &> /dev/null; then
        log_message "jq not available, installing..."
        apt update && apt install -y jq
    fi
    
    # Check for recent high-priority vulnerabilities (last 7 days)
    local recent_vulns=0
    if [[ -f "$CACHE_FILE" ]]; then
        recent_vulns=$(jq -r 'to_entries[] | select(.value.release_date? != null) | select(.value.release_date > (now - 604800)) | .key' "$CACHE_FILE" 2>/dev/null | wc -l || echo "0")
    fi
    
    # Also check for any critical vulnerabilities
    local critical_vulns=0
    if [[ -f "$CACHE_FILE" ]]; then
        critical_vulns=$(jq -r 'to_entries[] | select(.value.scope? == "critical" or .value.priority? == "high") | .key' "$CACHE_FILE" 2>/dev/null | wc -l || echo "0")
    fi
    
    log_message "Found $recent_vulns recent vulnerabilities, $critical_vulns critical/high priority"
    
    # Trigger if we have recent vulnerabilities OR critical vulnerabilities
    if [[ "$recent_vulns" -gt 5 ]] || [[ "$critical_vulns" -gt 0 ]]; then
        log_message "Security trigger met: recent_vulns=$recent_vulns, critical_vulns=$critical_vulns"
        return 0
    else
        log_message "No significant security threats detected"
        return 1
    fi
}

check_updates_available() {
    log_message "Checking for available updates..."
    
    # Update package lists
    if ! apt update >> "$LOG_FILE" 2>&1; then
        log_message "ERROR: apt update failed"
        return 1
    fi
    
    # Check for upgradable packages
    local upgrade_count=$(apt list --upgradable 2>/dev/null | grep -c upgradable || true)
    
    if [[ "$upgrade_count" -eq 0 ]]; then
        log_message "No upgrades available"
        return 1
    fi
    
    # Check specifically for security upgrades
    local security_upgrades=$(apt list --upgradable 2>/dev/null | grep -i security | wc -l || true)
    
    log_message "Found $upgrade_count total upgrades, $security_upgrades security related"
    
    if [[ "$security_upgrades" -gt 0 ]] || [[ "$upgrade_count" -gt 10 ]]; then
        return 0
    else
        return 1
    fi
}

perform_update() {
    log_message "Starting system update and upgrade process..."
    send_notification "Starting security updates - system may be unavailable temporarily" "normal"
    
    # Update package lists
    if ! apt update >> "$LOG_FILE" 2>&1; then
        log_message "ERROR: apt update failed"
        send_notification "Security update failed during package list update" "critical"
        return 1
    fi
    
    # Perform upgrade (unattended)
    if ! DEBIAN_FRONTEND=noninteractive apt upgrade -y >> "$LOG_FILE" 2>&1; then
        log_message "ERROR: apt upgrade failed"
        send_notification "Security upgrade failed during package upgrade" "critical"
        return 1
    fi
    
    # Perform dist-upgrade if needed
    if ! DEBIAN_FRONTEND=noninteractive apt dist-upgrade -y >> "$LOG_FILE" 2>&1; then
        log_message "ERROR: apt dist-upgrade failed"
        send_notification "Security upgrade failed during distribution upgrade" "critical"
        return 1
    fi
    
    # Clean up
    apt autoremove -y >> "$LOG_FILE" 2>&1
    apt autoclean >> "$LOG_FILE" 2>&1
    
    log_message "System update completed successfully"
    send_notification "Security updates completed successfully" "normal"
    
    # Record update time
    date +%s > "$LAST_UPDATE_FILE"
    date +%s > "$LAST_CHECK_FILE"
    
    return 0
}

schedule_reboot() {
    if [[ ! -f "/var/run/reboot-required" ]]; then
        log_message "No reboot required"
        return 1
    fi
    
    log_message "Reboot required - scheduling restart in $REBOOT_DELAY minutes"
    send_notification "System will reboot in $REBOOT_DELAY minutes for security updates. Save your work!" "critical"
    
    # Use at command for delayed reboot
    echo "/bin/systemctl reboot" | at now + "$REBOOT_DELAY" minutes 2>/dev/null || {
        # Fallback: use shutdown if at is not available
        log_message "Using shutdown command as fallback"
        shutdown -r +"$REBOOT_DELAY" "Security updates require system reboot"
    }
    
    return 0
}

show_status() {
    echo "=== Kali Security Auto-Update Status ==="
    
    if [[ -f "$LAST_UPDATE_FILE" ]]; then
        local last_update=$(cat "$LAST_UPDATE_FILE")
        local current_time=$(date +%s)
        local days_ago=$(( (current_time - last_update) / 86400 ))
        echo "Last update: $(date -d "@$last_update") ($days_ago days ago)"
    else
        echo "Last update: Never"
    fi
    
    if [[ -f "$LAST_CHECK_FILE" ]]; then
        local last_trigger=$(cat "$LAST_CHECK_FILE")
        echo "Last trigger: $(date -d "@$last_trigger")"
    fi
    
    if [[ -f "/var/run/reboot-required" ]]; then
        echo "Reboot required: YES"
        echo "Reboot reason: $(cat /var/run/reboot-required.pkgs 2>/dev/null || echo 'unknown')"
    else
        echo "Reboot required: NO"
    fi
    
    echo "Log file: $LOG_FILE"
    echo "Configuration: $CONFIG_FILE"
}

main() {
    acquire_lock
    
    case "${1:-check}" in
        "check")
            log_message "=== Starting security check ==="
            
            if check_trigger_cooldown; then
                fetch_advisories
                if check_security_advisories || check_updates_available; then
                    log_message "Security trigger met - performing update"
                    if perform_update; then
                        schedule_reboot
                    fi
                else
                    log_message "No security updates required"
                fi
            fi
            ;;
            
        "force")
            log_message "=== Forced update triggered ==="
            send_notification "Forced security update started" "normal"
            if perform_update; then
                schedule_reboot
            fi
            ;;
            
        "status")
            show_status
            ;;
            
        "test-notify")
            send_notification "Test notification from security update system" "normal"
            echo "Test notification sent"
            ;;
            
        "log")
            tail -f "$LOG_FILE"
            ;;
            
        *)
            echo "Usage: $0 {check|force|status|test-notify|log}"
            echo "  check      - Check for updates and apply if needed"
            echo "  force      - Force update immediately"
            echo "  status     - Show current status"
            echo "  test-notify - Send test notification"
            echo "  log        - Follow log file"
            exit 1
            ;;
    esac
    
    release_lock
}

# Handle traps
trap release_lock EXIT

main "$@"
EOF

    chmod +x "${INSTALL_DIR}/${SCRIPT_NAME}"
}

# Create configuration file
create_config() {
    cat > "$CONFIG_FILE" << EOF
# Kali Linux Security Auto-Update Configuration

# Debian security advisories URL
DEBIAN_SECURITY_URL="https://security-tracker.debian.org/tracker/data/json"

# Cooldown period between triggers (in seconds)
TRIGGER_INTERVAL=9000

# Check interval for the timer (in minutes)
CHECK_INTERVAL=30

# Reboot delay after updates (in minutes)
REBOOT_DELAY=5

# Enable desktop notifications (true/false)
ENABLE_NOTIFICATIONS=true

# Minimum security level to trigger update (low/medium/high/critical)
MIN_SECURITY_LEVEL="medium"
EOF

    chmod 644 "$CONFIG_FILE"
}

# Create systemd service file
create_service_file() {
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Kali Linux Security Auto-Update
Documentation=https://security-tracker.debian.org/tracker/
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=root
ExecStart=${INSTALL_DIR}/${SCRIPT_NAME} check
StandardOutput=journal
StandardError=journal

# Security settings
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
PrivateTmp=yes
ReadWritePaths=/var/lib/apt /var/cache/apt /var/log /var/lib/${SCRIPT_NAME}

[Install]
WantedBy=multi-user.target
EOF
}

# Create systemd timer file
create_timer_file() {
    cat > "$TIMER_FILE" << EOF
[Unit]
Description=Kali Linux Security Auto-Update Timer
Requires=${SCRIPT_NAME}.service

[Timer]
# Check every 30 minutes
OnCalendar=*:0/${CHECK_INTERVAL}
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
EOF
}

# Install dependencies
install_dependencies() {
    print_status "Installing dependencies..."
    
    apt update
    apt install -y jq at curl libnotify-bin
    
    # Enable and start at daemon
    systemctl enable atd
    systemctl start atd
}

# Setup directories and permissions
setup_filesystem() {
    print_status "Setting up filesystem..."
    
    mkdir -p "$STATE_DIR"
    touch "$LOG_FILE"
    
    chmod 755 "$STATE_DIR"
    chmod 644 "$LOG_FILE"
}

# Enable and start services
enable_services() {
    print_status "Enabling systemd services..."
    
    systemctl daemon-reload
    systemctl enable "${SCRIPT_NAME}.timer"
    systemctl start "${SCRIPT_NAME}.timer"
    
    # Create logrotate configuration
    cat > "/etc/logrotate.d/${SCRIPT_NAME}" << EOF
${LOG_FILE} {
    weekly
    missingok
    rotate 4
    compress
    delaycompress
    notifempty
    copytruncate
}
EOF
}

# Show installation status
show_installation_status() {
    print_status "Installation completed successfully!"
    echo
    print_info "Service: ${SCRIPT_NAME}.service"
    print_info "Timer: ${SCRIPT_NAME}.timer"
    print_info "Main script: ${INSTALL_DIR}/${SCRIPT_NAME}"
    print_info "Configuration: ${CONFIG_FILE}"
    print_info "Log file: ${LOG_FILE}"
    print_info "State directory: ${STATE_DIR}"
    echo
    print_info "Available commands:"
    echo "  ${INSTALL_DIR}/${SCRIPT_NAME} status     - Show current status"
    echo "  ${INSTALL_DIR}/${SCRIPT_NAME} force      - Force immediate update"
    echo "  ${INSTALL_DIR}/${SCRIPT_NAME} check      - Manual check"
    echo "  ${INSTALL_DIR}/${SCRIPT_NAME} test-notify - Test notifications"
    echo "  ${INSTALL_DIR}/${SCRIPT_NAME} log        - Follow logs"
    echo
    print_info "Timer status: systemctl status ${SCRIPT_NAME}.timer"
    print_info "Service logs: journalctl -u ${SCRIPT_NAME}.service"
}

# Uninstall function
uninstall() {
    print_warning "Uninstalling Kali Security Auto-Update..."
    
    systemctl stop "${SCRIPT_NAME}.timer" 2>/dev/null || true
    systemctl disable "${SCRIPT_NAME}.timer" 2>/dev/null || true
    systemctl stop "${SCRIPT_NAME}.service" 2>/dev/null || true
    systemctl disable "${SCRIPT_NAME}.service" 2>/dev/null || true
    
    rm -f "$SERVICE_FILE"
    rm -f "$TIMER_FILE"
    rm -f "${INSTALL_DIR}/${SCRIPT_NAME}"
    rm -f "/etc/logrotate.d/${SCRIPT_NAME}"
    
    systemctl daemon-reload
    
    print_status "Uninstallation complete. Configuration and log files preserved:"
    echo "  Config: $CONFIG_FILE"
    echo "  Logs: $LOG_FILE"
    echo "  State: $STATE_DIR"
}

# Main installation function
install() {
    print_status "Starting Kali Linux Security Auto-Update installation..."
    
    check_root
    install_dependencies
    create_main_script
    create_config
    create_service_file
    create_timer_file
    setup_filesystem
    enable_services
    show_installation_status
    
    print_status "Installation completed! The system will now:"
    echo "  - Check Debian security advisories every 30 minutes"
    echo "  - Wait 2.5 hours after detecting threats before updating"
    echo "  - Automatically install security updates"
    echo "  - Reboot if necessary with 5-minute warning"
}

# Show usage
usage() {
    echo "Kali Linux Security Auto-Update Installer"
    echo
    echo "Usage: $0 [command]"
    echo
    echo "Commands:"
    echo "  install    - Install the auto-update system (default)"
    echo "  uninstall  - Remove the auto-update system"
    echo "  status     - Show current status"
    echo "  help       - Show this help message"
    echo
    echo "After installation, use: ${INSTALL_DIR}/${SCRIPT_NAME} {status|force|check|test-notify|log}"
}

# Check if we're sourcing or executing
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-install}" in
        "install")
            install
            ;;
        "uninstall")
            uninstall
            ;;
        "status")
            if [[ -f "${INSTALL_DIR}/${SCRIPT_NAME}" ]]; then
                "${INSTALL_DIR}/${SCRIPT_NAME}" status
            else
                print_error "Not installed. Run '$0 install' first."
                exit 1
            fi
            ;;
        "help"|"-h"|"--help")
            usage
            ;;
        *)
            print_error "Unknown command: $1"
            usage
            exit 1
            ;;
    esac
fi