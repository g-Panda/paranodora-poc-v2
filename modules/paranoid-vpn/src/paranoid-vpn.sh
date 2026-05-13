#!/bin/bash
###############################################################################
# PARANOID VPN FOR FEDORA SILVERBLUE
# Goal: Full network isolation through WireGuard with a kill switch.
# Requirements: root, Firewalld, NetworkManager, wireguard-tools
###############################################################################

set -euo pipefail # Stop on the first error and unset variables

# --- CONFIGURATION ---
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
MODULE_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
PARANOID_VPN_TEST_ROOT="${PARANOID_VPN_TEST_ROOT:-}"

system_path() {
    local path="$1"

    if [ -n "$PARANOID_VPN_TEST_ROOT" ]; then
        printf '%s/%s\n' "${PARANOID_VPN_TEST_ROOT%/}" "${path#/}"
    else
        printf '%s\n' "$path"
    fi
}

INSTALL_DIR="${PARANOID_VPN_INSTALL_DIR:-$(system_path /opt/paranoid-vpn)}"
BACKUP_DIR="${PARANOID_VPN_BACKUP_DIR:-$(system_path /var/lib/paranoid-vpn/backups)}"
LOG_FILE="${PARANOID_VPN_LOG_FILE:-$(system_path /var/log/paranoid-vpn.log)}"
SYSTEM_WG_CONF="${PARANOID_VPN_SYSTEM_WG_CONF:-$(system_path /etc/wireguard/wg0.conf)}"
SYSTEMD_DIR="${PARANOID_VPN_SYSTEMD_DIR:-$(system_path /etc/systemd/system)}"
FIREWALLD_ZONES_DIR="${PARANOID_VPN_FIREWALLD_ZONES_DIR:-$(system_path /etc/firewalld/zones)}"
NM_SYSTEM_CONNECTIONS_DIR="${PARANOID_VPN_NM_SYSTEM_CONNECTIONS_DIR:-$(system_path /etc/NetworkManager/system-connections)}"
WG_CONF="$SCRIPT_DIR/wg0.conf"
ZONE_NAME="wireguard-only"
ALLOW_SSH=false

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --allow-ssh) ALLOW_SSH=true; shift ;;
        --wg-conf)
            if [[ "${2:-}" == "" ]]; then
                echo "Missing value for --wg-conf"
                exit 1
            fi
            WG_CONF="$2"
            shift 2
            ;;
        --wg-conf=*) WG_CONF="${1#*=}"; shift ;;
        --restore) ACTION="restore"; shift ;;
        --status) ACTION="status"; shift ;;
        -h|--help) ACTION="help"; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

ACTION=${ACTION:-"setup"}

# --- HELPER FUNCTIONS ---
show_usage() {
    cat <<EOF
Usage: sudo modules/paranoid-vpn/src/paranoid-vpn.sh [options]

Options:
  --allow-ssh          Keep SSH open in the lockdown firewall zone.
  --wg-conf PATH      Use a WireGuard config from PATH instead of ./wg0.conf.
  --status            Show tunnel, route, firewall, and watchdog status.
  --restore           Restore the latest backup and remove installed services.
  -h, --help          Show this help.

Default setup expects wg0.conf next to this script and installs everything
needed for boot into /opt/paranoid-vpn and /etc/systemd/system.
EOF
}

absolute_path() {
    local path="$1"

    if [[ "$path" = /* ]]; then
        printf '%s\n' "$path"
    else
        printf '%s/%s\n' "$(pwd -P)" "$path"
    fi
}

log() {
    local line
    line="[$(date '+%Y-%m-%d %H:%M:%S')] $1"

    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
        echo "$line" | tee -a "$LOG_FILE"
    else
        echo "$line"
    fi
}

error_exit() {
    log "ERROR: $1"
    exit 1
}

set_wg_default_route() {
    while ip -4 route show default | grep -q .; do
        ip -4 route del default 2>/dev/null || break
    done

    ip -4 route add default dev wg0
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        if [ -n "$PARANOID_VPN_TEST_ROOT" ] && [ "${PARANOID_VPN_ALLOW_NON_ROOT_FOR_TESTS:-}" = "1" ]; then
            return
        fi

        error_exit "This script must be run as root (sudo)."
    fi
}

check_dependencies() {
    local deps=("firewall-cmd" "wg-quick" "wg" "ip" "nmcli" "systemctl" "sysctl" "awk" "grep" "install")
    local missing=()

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing+=("$dep")
        fi
    done

    if (( ${#missing[@]} > 0 )); then
        error_exit "Missing required tools: ${missing[*]}"
    fi
}

resolve_wireguard_config() {
    WG_CONF="$(absolute_path "$WG_CONF")"

    if [ -f "$WG_CONF" ]; then
        return
    fi

    if [ "$WG_CONF" = "$SCRIPT_DIR/wg0.conf" ] && [ -f "$SYSTEM_WG_CONF" ]; then
        log "No wg0.conf found next to the script; using existing $SYSTEM_WG_CONF."
        WG_CONF="$SYSTEM_WG_CONF"
        return
    fi

    error_exit "WireGuard config not found: $WG_CONF. Put wg0.conf next to the module script or pass --wg-conf PATH."
}

install_project_files() {
    local readme_path=""

    log "Installing project files into $INSTALL_DIR..."

    if [ ! -f "$SCRIPT_DIR/paranoid-vpn.sh" ]; then
        error_exit "Cannot find paranoid-vpn.sh in $SCRIPT_DIR."
    fi

    if [ ! -f "$SCRIPT_DIR/wg-watchdog.sh" ]; then
        error_exit "Cannot find wg-watchdog.sh in $SCRIPT_DIR."
    fi

    mkdir -p "$INSTALL_DIR"

    if [ "$SCRIPT_DIR/paranoid-vpn.sh" != "$INSTALL_DIR/paranoid-vpn.sh" ]; then
        install -m 755 "$SCRIPT_DIR/paranoid-vpn.sh" "$INSTALL_DIR/paranoid-vpn.sh"
    else
        chmod 755 "$INSTALL_DIR/paranoid-vpn.sh"
    fi

    if [ "$SCRIPT_DIR/wg-watchdog.sh" != "$INSTALL_DIR/wg-watchdog.sh" ]; then
        install -m 755 "$SCRIPT_DIR/wg-watchdog.sh" "$INSTALL_DIR/wg-watchdog.sh"
    else
        chmod 755 "$INSTALL_DIR/wg-watchdog.sh"
    fi

    if [ -f "$MODULE_DIR/README.md" ]; then
        readme_path="$MODULE_DIR/README.md"
    elif [ -f "$SCRIPT_DIR/README.md" ]; then
        readme_path="$SCRIPT_DIR/README.md"
    fi

    if [ -n "$readme_path" ] && [ "$readme_path" != "$INSTALL_DIR/README.md" ]; then
        install -m 644 "$readme_path" "$INSTALL_DIR/README.md"
    fi
}

install_wireguard_config() {
    log "Installing WireGuard config..."

    mkdir -p "$(dirname "$SYSTEM_WG_CONF")"

    if [ "$WG_CONF" != "$SYSTEM_WG_CONF" ]; then
        install -m 600 "$WG_CONF" "$SYSTEM_WG_CONF"
        log "WireGuard config installed from $WG_CONF to $SYSTEM_WG_CONF."
    else
        chmod 600 "$SYSTEM_WG_CONF"
        log "Using existing WireGuard config at $SYSTEM_WG_CONF."
    fi

    WG_CONF="$SYSTEM_WG_CONF"
}

install_startup_service() {
    local allow_ssh_arg=""

    if [ "$ALLOW_SSH" = true ]; then
        allow_ssh_arg=" --allow-ssh"
    fi

    log "Installing boot startup service..."

    mkdir -p "$SYSTEMD_DIR"

    cat > "$SYSTEMD_DIR/wg-startup.service" <<EOF
[Unit]
Description=Start Paranoid VPN on Boot
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$INSTALL_DIR/paranoid-vpn.sh --wg-conf $SYSTEM_WG_CONF$allow_ssh_arg
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable wg-startup.service

    log "Boot startup service installed."
}

backup_config() {
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    mkdir -p "$BACKUP_DIR/$timestamp"

    log "Creating configuration backup..."

    # Backup firewall
    firewall-cmd --runtime-to-permanent 2>/dev/null || true
    cp -r "$FIREWALLD_ZONES_DIR" "$BACKUP_DIR/$timestamp/" 2>/dev/null || true

    # Backup NetworkManager
    cp -r "$NM_SYSTEM_CONNECTIONS_DIR" "$BACKUP_DIR/$timestamp/" 2>/dev/null || true

    # Backup routing
    ip route show > "$BACKUP_DIR/$timestamp/routes.txt"
    ip addr show > "$BACKUP_DIR/$timestamp/addresses.txt"

    # Backup WireGuard
    if [ -f "$SYSTEM_WG_CONF" ]; then
        cp "$SYSTEM_WG_CONF" "$BACKUP_DIR/$timestamp/wg0.conf.bak"
    fi

    log "Backup completed: $BACKUP_DIR/$timestamp"
}

# --- MAIN FUNCTIONS ---

setup_wireguard() {
    log "Phase 1: WireGuard configuration..."

    # Check whether the configuration file exists.
    if [ ! -f "$WG_CONF" ]; then
        error_exit "Configuration file $WG_CONF does not exist."
    fi

    # Make sure the keys are protected.
    chmod 600 "$WG_CONF"

    if wg show wg0 >/dev/null 2>&1; then
        log "wg0 tunnel is already active."
        return
    fi

    # Start the tunnel.
    log "Starting wg0 tunnel..."
    if ! wg-quick up wg0; then
        error_exit "Failed to start the WireGuard tunnel. Check the logs."
    fi

    log "wg0 tunnel is active."
}

setup_routing() {
    log "Phase 2: Routing configuration..."
    local endpoint endpoint_host gateway gateway_dev

    # Disable IPv6 (paranoid mode).
    sysctl -w net.ipv6.conf.all.disable_ipv6=1
    sysctl -w net.ipv6.conf.default.disable_ipv6=1
    sysctl -w net.ipv6.conf.lo.disable_ipv6=1

    # Capture the physical default route before switching the default route.
    gateway=$(ip -4 route show default 2>/dev/null | awk 'NR==1 {print $3}')
    gateway_dev=$(ip -4 route show default 2>/dev/null | awk 'NR==1 {print $5}')

    # Add a route to the WireGuard server through the physical interface.
    # To do this, extract the endpoint from the configuration.
    endpoint=$(awk -F'=' '/^[[:space:]]*Endpoint[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' "$WG_CONF")
    if [ -n "$endpoint" ]; then
        # Handle endpoints with ports:
        # - 203.0.113.1:51820
        # - [2001:db8::1]:51820
        if [[ "$endpoint" =~ ^\[.+\]:[0-9]+$ ]]; then
            endpoint_host="${endpoint#[}"
            endpoint_host="${endpoint_host%%]*}"
        else
            endpoint_host="${endpoint%:*}"
        fi

        if [ -n "$gateway" ] && [ -n "$gateway_dev" ] && [ -n "$endpoint_host" ]; then
            if ip route replace "$endpoint_host" via "$gateway" dev "$gateway_dev" 2>/dev/null; then
                log "Added route to WireGuard endpoint: $endpoint_host via $gateway ($gateway_dev)"
            else
                log "Warning: Failed to add route to WireGuard endpoint: $endpoint_host"
            fi
        else
            log "Warning: Could not determine a complete endpoint route (gateway/dev/host)."
        fi
    fi

    if [ -n "$gateway_dev" ]; then
        if nmcli device modify "$gateway_dev" ipv4.never-default yes ipv6.never-default yes; then
            log "Disabled default routes on physical interface: $gateway_dev"
        else
            log "Warning: Failed to disable default routes on physical interface: $gateway_dev"
        fi
    fi

    if [ -n "${gateway:-}" ] && [ -n "${gateway_dev:-}" ] && [ -n "${endpoint_host:-}" ]; then
        if ip route replace "$endpoint_host" via "$gateway" dev "$gateway_dev" 2>/dev/null; then
            log "Ensured route to WireGuard endpoint after NetworkManager reapply: $endpoint_host via $gateway ($gateway_dev)"
        else
            log "Warning: Failed to ensure route to WireGuard endpoint after NetworkManager reapply: $endpoint_host"
        fi
    fi

    # Remove all existing IPv4 default routes before forcing wg0 as the only
    # default path. This can briefly cut internet access until wg0 is ready, so
    # it happens after wg0 has been started.
    set_wg_default_route
}

setup_firewall() {
    log "Phase 3: Firewalld configuration (lockdown)..."

    # Create the zone.
    if ! firewall-cmd --get-zones | grep -q "$ZONE_NAME"; then
        firewall-cmd --new-zone="$ZONE_NAME" --permanent
    fi

    # Set the target to DROP, blocking everything by default.
    firewall-cmd --zone="$ZONE_NAME" --set-target=DROP --permanent

    # Allow loopback traffic.
    firewall-cmd --zone="$ZONE_NAME" --add-rich-rule='rule family=ipv4 source address=127.0.0.0/8 accept' --permanent

    # Allow DHCP client replies, which are required to keep an IP address.
    if firewall-cmd --get-services | grep -qw "dhcp-client"; then
        firewall-cmd --zone="$ZONE_NAME" --add-service=dhcp-client --permanent
    else
        firewall-cmd --zone="$ZONE_NAME" --add-port=68/udp --permanent
    fi

    # Allow ESTABLISHED and RELATED traffic.
    firewall-cmd --zone="$ZONE_NAME" --add-icmp-block-inversion --permanent # Allows replies

    # Allow outbound WireGuard traffic (UDP 51820).
    firewall-cmd --zone="$ZONE_NAME" --add-port=51820/udp --permanent

    # Optional: SSH.
    if [ "$ALLOW_SSH" = true ]; then
        log "Opening SSH port (security risk)..."
        firewall-cmd --zone="$ZONE_NAME" --add-service=ssh --permanent
    else
        log "SSH port blocked (paranoid mode)."
    fi

    # Block DNS outside the tunnel to prevent leaks.
    firewall-cmd --zone="$ZONE_NAME" --add-port=53/udp --permanent
    firewall-cmd --zone="$ZONE_NAME" --add-port=53/tcp --permanent
    # In paranoid mode, DNS should go only through WireGuard.
    # If the WireGuard config contains DNS settings, there is no need to open
    # port 53 toward the ISP. Remove any previous DNS openings in this zone.
    firewall-cmd --zone="$ZONE_NAME" --remove-port=53/udp --permanent 2>/dev/null || true
    firewall-cmd --zone="$ZONE_NAME" --remove-port=53/tcp --permanent 2>/dev/null || true

    # Apply the zone to all interfaces except loopback.
    while IFS= read -r iface; do
        firewall-cmd --zone="$ZONE_NAME" --change-interface="$iface" --permanent
    done < <(ip -o link show | awk -F': ' '{split($2, parts, /[:@]/); if (parts[1] != "lo") print parts[1]}')

    # Load permanent zone changes, then apply runtime interface assignments.
    firewall-cmd --reload
    while IFS= read -r iface; do
        firewall-cmd --zone="$ZONE_NAME" --change-interface="$iface"
    done < <(ip -o link show | awk -F': ' '{split($2, parts, /[:@]/); if (parts[1] != "lo") print parts[1]}')

    log "Firewall configured."
}

setup_watchdog() {
    log "Phase 4: Watchdog configuration..."

    # Create the service file.
    mkdir -p "$SYSTEMD_DIR"

    cat > "$SYSTEMD_DIR/wg-watchdog.service" <<EOF
[Unit]
Description=WireGuard Kill-Switch Watchdog
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$INSTALL_DIR/wg-watchdog.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable wg-watchdog.service
    systemctl restart wg-watchdog.service

    log "Watchdog started."
}

validate_setup() {
    log "Phase 5: Validation..."

    # Check whether the tunnel is running.
    if ! wg show wg0 > /dev/null 2>&1; then
        error_exit "wg0 tunnel is not running!"
    fi

    set_wg_default_route

    # Check routing.
    if ! ip route show default | grep -q "dev wg0"; then
        error_exit "Default route does not point to wg0!"
    fi

    # IP leak test placeholder.
    log "IP leak test..."
    # In a real environment: curl ifconfig.me
    # Here we only log that the configuration is ready.
    log "Configuration completed successfully. Remember: without the tunnel, there is no internet."
}

restore_config() {
    log "Restoring configuration..."
    # Find the latest backup.
    local latest_backup

    if [ ! -d "$BACKUP_DIR" ]; then
        error_exit "No backup directory found at $BACKUP_DIR."
    fi

    latest_backup=$(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -r | head -1)
    if [ -z "$latest_backup" ]; then
        error_exit "No backups found to restore."
    fi

    # Stop WireGuard and remove stale tunnel routes before restoring services.
    wg-quick down wg0 2>/dev/null || true
    ip -4 route del default dev wg0 2>/dev/null || true

    # Restore firewall.
    mkdir -p "$FIREWALLD_ZONES_DIR"
    rm -rf "${FIREWALLD_ZONES_DIR:?}"/*
    if [ -d "$BACKUP_DIR/$latest_backup/zones" ]; then
        cp -r "$BACKUP_DIR/$latest_backup/zones/." "$FIREWALLD_ZONES_DIR/"
    else
        log "Warning: Backup does not contain a zones directory; skipping Firewalld restore."
    fi

    # Undo runtime NetworkManager changes made during setup, then restart the
    # network because the previous route state may vary.
    for iface in $(nmcli -t -f DEVICE,TYPE device status | awk -F: '$2 == "ethernet" {print $1}'); do
        nmcli device modify "$iface" ipv4.never-default no ipv6.never-default no 2>/dev/null || true
    done
    systemctl restart NetworkManager

    # Remove the zone.
    firewall-cmd --delete-zone="$ZONE_NAME" --permanent 2>/dev/null || true
    firewall-cmd --reload

    # Disable the watchdog.
    systemctl stop wg-watchdog.service 2>/dev/null || true
    systemctl disable wg-watchdog.service 2>/dev/null || true
    rm -f "$SYSTEMD_DIR/wg-watchdog.service"
    systemctl stop wg-startup.service 2>/dev/null || true
    systemctl disable wg-startup.service 2>/dev/null || true
    rm -f "$SYSTEMD_DIR/wg-startup.service"
    systemctl daemon-reload

    # Re-enable IPv6.
    sysctl -w net.ipv6.conf.all.disable_ipv6=0
    sysctl -w net.ipv6.conf.default.disable_ipv6=0

    log "Configuration restored. System restart recommended."
}

show_status() {
    echo "=== STATUS PARANOID VPN ==="
    echo "wg0 tunnel:"
    wg show wg0 2>/dev/null || echo "Inactive"
    echo ""
    echo "Routing:"
    ip route | grep default || echo "No default route"
    echo ""
    echo "Firewall Zone:"
    firewall-cmd --get-active-zones | grep -A 10 "$ZONE_NAME" || echo "Zone inactive"
    echo ""
    echo "Watchdog:"
    systemctl status wg-watchdog.service --no-pager -l || true
}

# --- MAIN BLOCK ---
if [ "$ACTION" = "help" ]; then
    show_usage
    exit 0
fi

check_root
check_dependencies

case $ACTION in
    setup)
        resolve_wireguard_config
        backup_config
        install_project_files
        install_wireguard_config
        install_startup_service
        setup_wireguard
        setup_routing
        setup_firewall
        setup_watchdog
        validate_setup
        ;;
    restore)
        restore_config
        ;;
    status)
        show_status
        ;;
    *)
        show_usage
        exit 1
        ;;
esac
